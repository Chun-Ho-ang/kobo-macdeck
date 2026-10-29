"""Local HTTP transport (Wi-Fi fallback route)."""

import argparse
import json
import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .actions import ActionError, Actions
from .protocol import Deduper, ProtocolError, ack, parse_command

log = logging.getLogger("macdeck")

MAX_BODY = 4096


def load_config(path: Path) -> dict:
    if path.exists():
        return json.loads(path.read_text())
    return {}


def make_handler(actions: Actions, deduper: Deduper):
    class Handler(BaseHTTPRequestHandler):
        def _reply(self, code: int, body: dict):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            if self.path != "/command":
                return self._reply(404, {"error": "not found"})
            length = int(self.headers.get("Content-Length", 0))
            if length > MAX_BODY:
                return self._reply(413, {"error": "too large"})
            try:
                msg = parse_command(json.loads(self.rfile.read(length)))
            except (json.JSONDecodeError, ProtocolError) as e:
                return self._reply(400, {"error": str(e)})

            # TODO(Phase 3): 驗證配對 token / session、時間窗、重放防護
            cached = deduper.get(msg["id"])
            if cached is not None:
                return self._reply(200, cached)

            if msg["type"] == "ping":
                reply = ack(msg["id"], "ok", "pong")
            else:
                try:
                    detail = actions.execute(msg.get("action", ""), msg.get("args", {}))
                    reply = ack(msg["id"], "ok", detail)
                except ActionError as e:
                    reply = ack(msg["id"], "error", str(e))
            deduper.put(msg["id"], reply)
            log.info("%s %s -> %s", msg["id"], msg.get("action", "ping"), reply["status"])
            self._reply(200, reply)

        def log_message(self, fmt, *args):
            pass

    return Handler


def main():
    p = argparse.ArgumentParser(description="MacDeck Companion")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--config", type=Path, default=Path("config.json"))
    p.add_argument("--live", action="store_true", help="actually run actions (default: dry-run)")
    a = p.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    actions = Actions(load_config(a.config), dry_run=not a.live)
    server = ThreadingHTTPServer((a.host, a.port), make_handler(actions, Deduper()))
    log.info("listening on %s:%d (%s)", a.host, a.port, "live" if a.live else "dry-run")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
