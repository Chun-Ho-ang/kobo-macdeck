"""Claude Code session status, fed by Claude Code hooks (POST /hook).

Only what the Kobo needs to draw a slot is kept. Prompts and commands are shown
on the Kobo but never logged.
"""

import os
import re
import threading
import time
from typing import Callable, Optional

STATES = ("waiting", "error", "working", "done", "idle")  # 也是排序順序：最需要你注意的在前
LABELS = {"waiting": "Needs you", "error": "Error", "working": "Working", "done": "Done", "idle": "Idle"}
SESSION_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
BUNDLE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{2,99}$")
TERMINAL_APPS = {
    "Apple_Terminal": "com.apple.Terminal",
    "iTerm.app": "com.googlecode.iterm2",
    "vscode": "com.microsoft.VSCode",
    "ghostty": "com.mitchellh.ghostty",
    "WarpTerminal": "dev.warp.Warp-Stable",
}
PASTED = re.compile(r"<pasted_content[^>]*>.*?</pasted_content[^>]*>", re.S)
MAX_SESSIONS = 8
MAX_TASKS = 12
EXPIRE_SEC = 12 * 3600


def _clip(text, n: int = 60) -> str:
    text = " ".join(str(text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def _duration(sec: float) -> str:
    sec = int(max(0, sec))
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m {sec % 60}s"
    return f"{sec // 3600}h {sec % 3600 // 60}m"


def _ago(sec: float) -> str:
    sec = int(max(0, sec))
    if sec < 60:
        return "just now"
    if sec < 3600:
        return f"{sec // 60} min ago"
    return f"{sec // 3600} h ago"


def describe_tool(name: str, tool_input: dict) -> Optional[str]:
    """One short line for the slot: what the agent is doing right now."""
    if name in ("TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"):
        return None  # 任務清單本身不算「目前動作」
    path = tool_input.get("file_path") or tool_input.get("notebook_path")
    if name in ("Edit", "MultiEdit", "Write", "NotebookEdit") and path:
        return f"Edit {os.path.basename(path)}"
    if name == "Read" and path:
        return f"Read {os.path.basename(path)}"
    if name == "Bash":
        return "Run: " + _clip(tool_input.get("description") or tool_input.get("command"), 50)
    if name in ("Grep", "Glob"):
        return "Search: " + _clip(tool_input.get("pattern"), 40)
    if name in ("Task", "Agent"):
        return "Subagent: " + _clip(tool_input.get("description"), 40)
    if name in ("WebSearch", "WebFetch"):
        return "Web: " + _clip(tool_input.get("query") or tool_input.get("url"), 45)
    if name.startswith("mcp__"):
        return "Tool: " + name.split("__")[-1]
    return name


class Session:
    def __init__(self, sid: str, now: float):
        self.id = sid
        self.project = ""
        self.title = ""
        self.state = "idle"
        self.summary = ""
        self.step = ""
        self.prompt = ""
        self.tasks: list[dict] = []  # {id, text, status: pending | in_progress | completed}
        self.started = now
        self.updated = now
        self.app: Optional[str] = None


class AgentHub:
    def __init__(self, clock: Callable[[], float] = time.time):
        self._clock = clock
        self._lock = threading.Lock()
        self._sessions: dict[str, Session] = {}

    # ── hook input ──

    def handle(self, event: dict, app: str = "", term: str = "") -> None:
        sid = event.get("session_id")
        name = event.get("hook_event_name")
        if not isinstance(sid, str) or not SESSION_ID.match(sid) or not isinstance(name, str):
            return
        if event.get("agent_id"):
            return  # 子代理的事件併在主 session 就好，不另開一格
        now = self._clock()
        with self._lock:
            if name == "SessionEnd":
                self._sessions.pop(sid, None)
                return
            s = self._sessions.get(sid)
            if s is None:
                s = self._sessions[sid] = Session(sid, now)
            s.updated = now
            if event.get("cwd"):
                s.project = os.path.basename(str(event["cwd"]).rstrip("/")) or s.project
            if event.get("session_title"):
                s.title = _clip(event["session_title"], 40)
            bundle = app if BUNDLE_ID.match(app or "") else TERMINAL_APPS.get(term)
            if bundle:
                s.app = bundle
            self._apply(s, name, event, now)
            self._expire(now)

    def _apply(self, s: Session, name: str, e: dict, now: float) -> None:
        tool = e.get("tool_name") or ""
        tool_input = e.get("tool_input") if isinstance(e.get("tool_input"), dict) else {}
        if name == "SessionStart":
            s.state, s.summary = "idle", "Started"
        elif name == "UserPromptSubmit":
            s.state, s.started, s.step = "working", now, ""
            s.prompt = _clip(PASTED.sub("[pasted]", str(e.get("prompt") or "")), 80)
            s.summary = "Thinking…"
            if s.tasks and all(t["status"] == "completed" for t in s.tasks):
                s.tasks = []  # 上一輪的任務都做完了，新一輪重新開始
        elif name == "PreToolUse":
            s.state = "working"
            step = describe_tool(tool, tool_input)
            if step:
                s.step = s.summary = _clip(step)
        elif name == "PermissionRequest":
            s.state = "waiting"
            what = describe_tool(tool, tool_input) or tool
            s.summary = _clip(f"Allow {what}?")
        elif name == "PostToolUse":
            s.state = "working"
            self._track_tasks(s, tool, tool_input, e.get("tool_response"))
        elif name == "TaskCreated":
            self._add_task(s, e.get("task_id"), e.get("task_subject"))
        elif name == "TaskCompleted":
            self._set_task(s, e.get("task_id"), "completed")
        elif name == "Notification":
            kind = e.get("notification_type")
            if kind == "idle_prompt":
                if s.state != "error":
                    s.state, s.summary = "done", "Waiting for your next message"
            elif kind in ("permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"):
                if s.state != "waiting":  # PermissionRequest 的說明比較具體，不要蓋掉
                    s.summary = _clip(e.get("message") or "Needs your input")
                s.state = "waiting"
        elif name == "Stop":
            s.state, s.summary, s.step = "done", "Finished", ""
        elif name == "StopFailure":
            s.state = "error"
            s.summary = _clip(e.get("error_type") or e.get("error") or e.get("matcher") or "Stopped with an error")

    def _add_task(self, s: Session, task_id, text) -> None:
        if not text:
            return
        task_id = str(task_id) if task_id is not None else str(len(s.tasks) + 1)
        if any(t["id"] == task_id for t in s.tasks):
            return
        s.tasks.append({"id": task_id, "text": _clip(text, 50), "status": "pending"})
        del s.tasks[:-MAX_TASKS]

    def _set_task(self, s: Session, task_id, status) -> None:
        if status not in ("pending", "in_progress", "completed"):
            return
        for t in s.tasks:
            if t["id"] == str(task_id):
                t["status"] = status

    def _track_tasks(self, s: Session, tool: str, tool_input: dict, response) -> None:
        if tool == "TodoWrite" and isinstance(tool_input.get("todos"), list):
            s.tasks = [
                {"id": str(i + 1), "text": _clip(t.get("content"), 50), "status": t.get("status", "pending")}
                for i, t in enumerate(tool_input["todos"][:MAX_TASKS]) if isinstance(t, dict)
            ]
        elif tool == "TaskCreate":
            task_id = None
            if isinstance(response, dict):
                task = response.get("task") if isinstance(response.get("task"), dict) else response
                task_id = task.get("id") or task.get("taskId")
            self._add_task(s, task_id, tool_input.get("subject"))
        elif tool == "TaskUpdate":
            self._set_task(s, tool_input.get("taskId"), tool_input.get("status"))

    def _expire(self, now: float) -> None:
        for sid in [k for k, s in self._sessions.items() if now - s.updated > EXPIRE_SEC]:
            del self._sessions[sid]

    # ── output for the Kobo ──

    def snapshot(self) -> list[dict]:
        now = self._clock()
        with self._lock:
            self._expire(now)
            sessions = sorted(self._sessions.values(), key=lambda s: (STATES.index(s.state), -s.updated))
            out = []
            for s in sessions[:MAX_SESSIONS]:
                done = sum(t["status"] == "completed" for t in s.tasks)
                summary = s.summary
                if s.state in ("done", "idle"):
                    summary = _ago(now - s.updated)
                out.append({
                    "id": s.id,
                    "project": s.title or s.project or "session",
                    "state": s.state,
                    "label": LABELS[s.state],
                    "summary": summary,
                    "progress": f"{done}/{len(s.tasks)}" if s.tasks else "",
                    "elapsed": _duration((s.updated if s.state != "working" else now) - s.started),
                    "prompt": s.prompt,
                    "step": s.step,
                    "tasks": [{"text": t["text"], "status": t["status"]} for t in s.tasks],
                })
            return out

    def app_for(self, sid: str) -> Optional[str]:
        with self._lock:
            s = self._sessions.get(sid)
            return s.app if s else None

    def exists(self, sid: str) -> bool:
        with self._lock:
            return sid in self._sessions
