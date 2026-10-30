"""Local HTTP transport (Wi-Fi fallback route)."""

import argparse
import hmac
import ipaddress
import json
import logging
import os
import secrets
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .actions import ActionError, Actions
from .agents import AgentHub
from .sources import start_watchers
from .protocol import Deduper, ProtocolError, ack, parse_command

log = logging.getLogger("macdeck")

MAX_BODY = 4096
MAX_HOOK_BODY = 4 * 1024 * 1024  # hook 會帶整個 tool_input（例如 Write 的檔案內容）
QUIET_ACTIONS = ("agents.list",)  # Kobo 每幾秒輪詢一次，不寫 log


def load_config(path: Path) -> dict:
    if path.exists():
        return json.loads(path.read_text())
    return {}


def load_token(path: Path) -> str:
    """Pairing token shared with the Kobo. Created on first run; never logged."""
    if path.exists():
        token = path.read_text().strip()
        if token:
            return token
    token = secrets.token_hex(8)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    return token


def write_hook_auth(token: str, token_path: Path) -> Path:
    """Header file for the Claude Code hook script (curl -H @file), so the token never shows up in `ps`."""
    path = token_path.resolve().with_name("hook-auth.txt")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(f"Authorization: Bearer {token}\n")
    return path


def lan_address() -> str:
    """The IPv4 address other devices on this network reach the Mac at (no packet is sent)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]


def check_host(host: str) -> None:
    """Only loopback or private-network addresses; never all interfaces or a public IP."""
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        raise SystemExit(f"--host must be an IP address, got {host!r}")
    if ip.is_unspecified or not (ip.is_loopback or ip.is_private):
        raise SystemExit(f"refusing to listen on {host}: use 127.0.0.1 or this Mac's local network address (--lan)")


def make_handler(actions: Actions, deduper: Deduper, token: str, hub: AgentHub = None, hooks: bool = False):
    """hooks = True only on the 127.0.0.1 listener: Claude Code status never comes from the network."""
    expected = f"Bearer {token}".encode()

    class Handler(BaseHTTPRequestHandler):
        def _reply(self, code: int, body: dict):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _body(self, limit: int):
            """Raw body, or None after replying with an error."""
            if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), expected):
                log.warning("rejected request from %s: bad token", self.client_address[0])
                return self._reply(401, {"error": "bad token"})
            if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
                log.warning("rejected request from %s: chunked body (client must send Content-Length)", self.client_address[0])
                return self._reply(411, {"error": "Content-Length required"})
            try:
                length = int(self.headers.get("Content-Length", 0))
            except ValueError:
                length = -1
            if length < 0 or length > limit:
                return self._reply(413, {"error": "bad length"})
            return self.rfile.read(length)

        def do_POST(self):
            if self.path == "/hook" and hooks and hub is not None:
                return self._hook()
            if self.path != "/command":
                return self._reply(404, {"error": "not found"})
            body = self._body(MAX_BODY)
            if body is None:
                return
            try:
                msg = parse_command(json.loads(body))
            except (json.JSONDecodeError, ProtocolError) as e:
                log.warning("rejected request from %s: %s", self.client_address[0], e)
                return self._reply(400, {"error": str(e)})

            cached = deduper.get(msg["id"])
            if cached is not None:
                return self._reply(200, cached)

            if msg["type"] == "ping":
                reply = ack(msg["id"], "ok", "pong")
            else:
                try:
                    args = msg.get("args", {})
                    detail, data = actions.execute(msg.get("action", ""), args if isinstance(args, dict) else {})
                    reply = ack(msg["id"], "ok", detail, data)
                except ActionError as e:
                    reply = ack(msg["id"], "error", str(e))
            deduper.put(msg["id"], reply)
            if msg.get("action") not in QUIET_ACTIONS or reply["status"] != "ok":
                # 錯誤時連原因一起記（原因是我們自己產生的說明，不含使用者內容）
                # agent 按鍵成功時也記是哪一顆、按到哪個按鈕（例如「approve: Allow」），方便確認
                show = reply["status"] != "ok" or msg.get("action") in ("agent.key", "agent.open")
                why = f" ({reply.get('detail')})" if show else ""
                log.info("%s %s -> %s%s", msg["id"], msg.get("action", "ping"), reply["status"], why)
            self._reply(200, reply)

        def _hook(self):
            body = self._body(MAX_HOOK_BODY)
            if body is None:
                return
            try:
                event = json.loads(body)
            except json.JSONDecodeError:
                return self._reply(400, {"error": "bad json"})
            if isinstance(event, dict):
                # 只記事件名稱，不記 prompt / 指令內容
                log.debug("hook %s", event.get("hook_event_name"))
                hub.handle(event, self.headers.get("X-MacDeck-App", ""), self.headers.get("X-MacDeck-Term", ""))
            self._reply(200, {})

        def log_message(self, fmt, *args):
            pass

    return Handler


def main():
    p = argparse.ArgumentParser(description="MacDeck Companion")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--lan", action="store_true", help="listen on this Mac's local network address so the Kobo can connect")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--config", type=Path, default=Path("config.json"))
    p.add_argument("--token-file", type=Path, default=Path("token.txt"))
    p.add_argument("--live", action="store_true", help="actually run actions (default: dry-run)")
    a = p.parse_args()

    host = lan_address() if a.lan else a.host
    check_host(host)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s", stream=sys.stdout)
    token = load_token(a.token_file)
    write_hook_auth(token, a.token_file)
    hub = AgentHub()
    config = load_config(a.config)
    actions = Actions(config, dry_run=not a.live, hub=hub)
    start_watchers(hub, config)  # Codex 的 session 檔、ChatGPT / Claude App 是否開著

    # 天氣和行事曆：啟動就先抓，之後每分鐘檢查一次，Kobo 來問時一律有現成的資料
    def keep_info_fresh():
        while True:
            actions.weather.get()
            actions.calendar.get()
            time.sleep(60)
    threading.Thread(target=keep_info_fresh, name="macdeck-info", daemon=True).start()
    deduper = Deduper()
    loopback = ipaddress.ip_address(host).is_loopback
    server = ThreadingHTTPServer((host, a.port), make_handler(actions, deduper, token, hub, hooks=loopback))
    if not loopback:
        # Claude Code hooks 一律打 127.0.0.1；另開一個只收本機的 listener
        local = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(actions, deduper, token, hub, hooks=True))
        threading.Thread(target=local.serve_forever, daemon=True).start()
    log.info("listening on %s:%d (%s)", host, a.port, "live" if a.live else "dry-run")
    log.info("Kobo settings: host = \"%s\", port = %d, token = contents of %s", host, a.port, a.token_file.resolve())
    log.info("Claude Code hooks: http://127.0.0.1:%d/hook", a.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
