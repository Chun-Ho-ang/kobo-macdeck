"""Agent sources besides Claude Code hooks.

- Codex: reads the session files Codex writes to ~/.codex/sessions (task started / finished,
  current command or file, waiting for your input). Nothing in Codex's config is changed.
- ChatGPT / Claude desktop apps: whether the app is open and in front (`lsappinfo`, no permission
  needed), plus — when "MacDeck Windows" has Accessibility permission — the conversation name and
  whether it's answering right now (a Stop button on screen). Nothing else of the chat is read.

Everything stays in memory and only goes to the Kobo; nothing is logged.
"""

import json
import logging
import os
import re
import subprocess
import threading
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Optional

from . import helper_apps
from .agents import AgentHub

log = logging.getLogger("macdeck")

CODEX_APP = "com.openai.codex"  # ChatGPT.app（Codex 也跑在這個 App 裡）
APPS = {  # bundle id → slot name
    CODEX_APP: "ChatGPT",
    "com.anthropic.claudefordesktop": "Claude",
}
RECENT_SEC = 12 * 3600


def _epoch(ts, fallback: float) -> float:
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return fallback


def _text(content) -> str:
    """First text in a Codex content list (user message)."""
    for c in content if isinstance(content, list) else []:
        if isinstance(c, dict) and isinstance(c.get("text"), str):
            return c["text"]
    return ""


def describe_item(item: dict) -> Optional[str]:
    """Codex item_completed → one short line, like Claude Code's describe_tool."""
    kind = item.get("type")
    if kind == "CommandExecution":
        cmd = item.get("command")
        if isinstance(cmd, list) and cmd:
            cmd = cmd[-1]  # ["/bin/zsh", "-lc", "npm test"] → "npm test"
        return f"Run: {cmd}" if cmd else "Run command"
    if kind == "FileChange" and isinstance(item.get("changes"), dict) and item["changes"]:
        paths = list(item["changes"])
        more = f" +{len(paths) - 1}" if len(paths) > 1 else ""
        return f"Edit {os.path.basename(paths[0])}{more}"
    if kind == "McpToolCall":
        return f"Tool: {item.get('tool') or item.get('server') or 'tool'}"
    if kind == "WebSearch":
        return f"Web: {item.get('query') or ''}"
    return None


class CodexWatcher:
    """Tails ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl and feeds the hub."""

    def __init__(self, hub: AgentHub, root: Path = Path.home() / ".codex", clock=time.time):
        self.hub, self.root, self.clock = hub, root, clock
        self.offsets: dict[Path, int] = {}
        self.sids: dict[Path, str] = {}
        self.titles: dict[str, str] = {}
        self.titles_mtime = 0.0
        self.waiting_calls: dict[str, str] = {}  # call_id → sid

    def files(self) -> list[Path]:
        """Session files touched in the last 12 hours (only today's and yesterday's folders)."""
        now = self.clock()
        out = []
        for days in (0, 1):
            d = datetime.fromtimestamp(now) - timedelta(days=days)
            folder = self.root / "sessions" / f"{d:%Y}" / f"{d:%m}" / f"{d:%d}"
            if folder.is_dir():
                out += [p for p in folder.glob("rollout-*.jsonl") if now - p.stat().st_mtime < RECENT_SEC]
        return out

    def load_titles(self) -> None:
        index = self.root / "session_index.jsonl"
        try:
            mtime = index.stat().st_mtime
        except OSError:
            return
        if mtime == self.titles_mtime:
            return
        self.titles_mtime = mtime
        for line in index.read_text(errors="replace").splitlines():
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("id") and e.get("thread_name"):
                self.titles[str(e["id"])] = str(e["thread_name"])

    def poll(self) -> None:
        self.load_titles()
        for path in self.files():
            try:
                size = path.stat().st_size
                start = self.offsets.get(path, 0)
                if size <= start:
                    continue
                with open(path, "rb") as f:
                    f.seek(start)
                    chunk = f.read(size - start)
            except OSError:
                continue
            end = chunk.rfind(b"\n") + 1  # 只處理完整的行，寫到一半的留到下次
            self.offsets[path] = start + end
            for line in chunk[:end].splitlines():
                try:
                    self.handle(path, json.loads(line))
                except (ValueError, TypeError, AttributeError):
                    continue

    def handle(self, path: Path, e: dict) -> None:
        kind = e.get("type")
        p = e.get("payload") if isinstance(e.get("payload"), dict) else {}
        at = _epoch(e.get("timestamp"), self.clock())
        if kind == "session_meta":
            thread = str(p.get("id") or p.get("session_id") or "")
            sid = "codex-" + re.sub(r"[^A-Za-z0-9_-]", "", thread)[:58]
            self.sids[path] = sid
            self.hub.apply(sid, "Codex", at, project=os.path.basename(str(p.get("cwd") or "").rstrip("/")),
                           title=self.titles.get(thread), state="idle", summary="Started", app=CODEX_APP)
            return
        sid = self.sids.get(path)
        if not sid:
            return
        sub = p.get("type")
        if kind == "turn_context" and p.get("cwd"):
            self.hub.apply(sid, "Codex", at, project=os.path.basename(str(p["cwd"]).rstrip("/")))
        elif kind == "event_msg" and sub == "task_started":
            self.hub.apply(sid, "Codex", at, new_turn=True, state="working", summary="Thinking…")
        elif kind == "event_msg" and sub == "task_complete":
            err = p.get("error")
            if isinstance(err, dict) and err.get("message"):
                self.hub.apply(sid, "Codex", at, state="error", summary=err["message"], step="")
            else:
                self.hub.apply(sid, "Codex", at, state="done", summary="Finished", step="")
        elif kind == "event_msg" and sub == "turn_aborted":
            self.hub.apply(sid, "Codex", at, state="done", summary="Stopped", step="")
        elif kind == "event_msg" and sub == "item_completed" and isinstance(p.get("item"), dict):
            item = p["item"]
            if item.get("type") == "UserMessage":
                prompt = _text(item.get("content"))
                if prompt:
                    self.hub.apply(sid, "Codex", at, prompt=prompt)
                return
            step = describe_item(item)
            if step:
                self.hub.apply(sid, "Codex", at, state="working", step=step, summary=step)
        elif kind == "response_item" and sub == "custom_tool_call" and p.get("name") == "request_user_input_async":
            self.waiting_calls[str(p.get("call_id"))] = sid
            self.hub.apply(sid, "Codex", at, state="waiting", summary="Needs your input")
        elif kind == "response_item" and sub == "custom_tool_call_output":
            if self.waiting_calls.pop(str(p.get("call_id")), None):
                self.hub.apply(sid, "Codex", at, state="working", summary="Thinking…")


def running_apps(run: Callable[[list[str]], str] = None) -> tuple[set[str], Optional[str]]:
    """(bundle ids of APPS that are running, bundle id of the front app) via lsappinfo."""
    run = run or (lambda argv: subprocess.run(argv, capture_output=True, text=True, timeout=5).stdout)
    alive = {b for b in APPS if re.search(r"\bpid = \d+", run(["lsappinfo", "info", "-only", "pid", "-app", b]))}
    front = re.search(r'bundleID="([^"]+)"', run(["lsappinfo", "info", "-only", "bundleid", run(["lsappinfo", "front"]).strip()]))
    return alive, front.group(1) if front else None


def read_windows() -> dict:
    """helpers/app_windows.swift → {bundle: {windows, answering, conversation}} or {"error": …}"""
    app = helper_apps.build("MacDeck Windows", "app_windows.swift", "AppWindows-Info.plist", "app-windows")
    return json.loads(helper_apps.run(app, timeout=30))


class AppPresence:
    """One slot per desktop app (ChatGPT, Claude) while it's open."""

    WINDOWS_EVERY = 10  # 讀視窗比 lsappinfo 重，10 秒一次就好
    RETRY_AFTER = 120  # 沒權限或失敗時，隔久一點再試

    def __init__(self, hub: AgentHub, run=None, windows: Callable[[], dict] = read_windows, clock=time.time):
        self.hub, self.run, self.windows, self.clock = hub, run, windows, clock
        self.win: dict = {}
        self.win_error = ""
        self.next_windows = 0.0
        self.answering: dict[str, bool] = {}

    def refresh_windows(self, alive: set) -> None:
        now = self.clock()
        if not alive or now < self.next_windows:
            return
        try:
            d = self.windows()
        except (OSError, ValueError, subprocess.SubprocessError) as e:
            d = {"error": f"window reader failed ({type(e).__name__})"}
        if d.get("error"):
            self.win, self.win_error = {}, str(d["error"])
            self.next_windows = now + self.RETRY_AFTER
        else:
            self.win, self.win_error = d.get("apps") or {}, ""
            self.next_windows = now + self.WINDOWS_EVERY

    def poll(self) -> None:
        alive, front = running_apps(self.run) if self.run else running_apps()
        self.refresh_windows(alive)
        for bundle, name in APPS.items():
            sid = "app-" + name.lower()
            if bundle not in alive:
                self.hub.remove(sid)
                self.answering.pop(bundle, None)
                continue
            w = self.win.get(bundle) or {}
            titles = [t for t in w.get("windows") or [] if t and t not in (name, "ChatGPT", "Claude")]
            conversation = (titles[0] if titles else "") or w.get("conversation") or name
            answering = bool(w.get("answering"))
            started = answering and not self.answering.get(bundle)
            self.answering[bundle] = answering
            where = "In front" if bundle == front else "Open"
            if answering:
                self.hub.apply(sid, name, new_turn=started, project=conversation, state="working",
                               summary=where, app=bundle)
            else:
                summary = f"{where} · {self.win_error}" if self.win_error else where
                self.hub.apply(sid, name, project=conversation, state="idle", summary=summary, app=bundle)


def start_watchers(hub: AgentHub, config: dict, interval: float = 3.0) -> None:
    """Background thread polling Codex files and app presence (config "sources" can turn either off)."""
    sources = config.get("sources") if isinstance(config.get("sources"), dict) else {}
    watchers = []
    if sources.get("codex", True):
        watchers.append(CodexWatcher(hub))
    if sources.get("apps", True):
        watchers.append(AppPresence(hub))
    if not watchers:
        return

    def loop():
        while True:
            for w in watchers:
                try:
                    w.poll()
                except Exception as e:  # 一個來源壞掉不能拖垮其他來源
                    log.warning("source %s failed: %s", type(w).__name__, type(e).__name__)
            time.sleep(interval)

    threading.Thread(target=loop, name="macdeck-sources", daemon=True).start()
