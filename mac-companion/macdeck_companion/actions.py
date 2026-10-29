"""Whitelisted actions. Never pass arbitrary strings to a shell.

Current scope: media control (previous / play-pause / next, volume, mute)
the agent deck (Claude Code session status, a few fixed keys), and clock info
(weather, next calendar event; read-only).
"""

import re
import subprocess
import time
from typing import Optional

from .agents import BUNDLE_ID, SESSION_ID, AgentHub
from .info import NextEvent, Weather


class ActionError(Exception):
    pass


def _level(args: dict) -> int:
    level = args.get("level")
    if not isinstance(level, (int, float)) or isinstance(level, bool):
        raise ActionError("level must be a number 0-100")
    return max(0, min(100, int(round(level))))


# Agent 鍵：固定的 System Events 指令，Kobo 只能從這幾個裡面選
KEYS = {
    "approve": 'tell application "System Events" to key code 36',  # Return
    "send": 'tell application "System Events" to key code 36',  # Return
    "stop": 'tell application "System Events" to key code 53',  # Escape
    "auto": 'tell application "System Events" to key code 48 using shift down',  # Shift+Tab：切換權限模式
}
MODIFIERS = ("command", "control", "option", "shift")


def dictation_script(spec) -> Optional[str]:
    """config.dictation_key = {"key": "d", "modifiers": ["control", "option"]}
    （對應 系統設定 → 鍵盤 → 聽寫 → 快速鍵 → 自訂）"""
    if not isinstance(spec, dict):
        return None
    key, mods = spec.get("key"), spec.get("modifiers", [])
    if not isinstance(key, str) or not re.match(r"^[a-z0-9]$", key):
        return None
    if not isinstance(mods, list) or not mods or any(m not in MODIFIERS for m in mods):
        return None
    using = ", ".join(f"{m} down" for m in dict.fromkeys(mods))
    return f'tell application "System Events" to keystroke "{key}" using {{{using}}}'


class Actions:
    def __init__(self, config: dict, dry_run: bool = True, hub: Optional[AgentHub] = None,
                 weather: Optional[Weather] = None, calendar: Optional[NextEvent] = None):
        self.player = config.get("media_player", "Music")
        self.dictation = dictation_script(config.get("dictation_key"))
        self.dry_run = dry_run
        self.hub = hub or AgentHub()
        self.weather = weather or Weather(config)
        self.calendar = calendar or NextEvent()
        self.handlers = {
            "media.previous": self.media_previous,
            "media.toggle": self.media_toggle,
            "media.next": self.media_next,
            "volume.get": self.volume_get,
            "volume.set": self.volume_set,
            "audio.mute": self.audio_mute,
            "agents.list": self.agents_list,
            "agent.key": self.agent_key,
            "agent.open": self.agent_open,
            "info.get": self.info_get,
        }
        # dry-run 時用假狀態回應，讓 Kobo 端可以完整測試
        self._fake = {"volume": 50, "muted": False}

    def execute(self, action: str, args: dict) -> tuple[str, Optional[dict]]:
        handler = self.handlers.get(action)
        if handler is None:
            raise ActionError(f"action not allowed: {action}")
        try:
            return handler(args or {})
        except (subprocess.SubprocessError, OSError) as e:
            raise ActionError(f"{action} failed: {e}") from e

    def _run(self, argv: list[str]) -> str:
        if self.dry_run:
            return ""
        return subprocess.run(argv, check=True, timeout=10, capture_output=True, text=True).stdout

    def _osascript(self, script: str) -> str:
        return self._run(["osascript", "-e", script])

    # ── media ──
    # TODO: 依實際播放器調整；目前透過 AppleScript 控制 config.media_player（預設 Music）

    def _player(self, command: str, detail: str):
        if self.player not in ("Music", "Spotify"):
            raise ActionError("unsupported media_player")
        self._osascript(f'tell application "{self.player}" to {command}')
        return detail, None

    def media_previous(self, args):
        return self._player("previous track", "previous track")

    def media_toggle(self, args):
        return self._player("playpause", "play/pause")

    def media_next(self, args):
        return self._player("next track", "next track")

    def volume_get(self, args):
        if self.dry_run:
            return "volume", {"level": self._fake["volume"], "muted": self._fake["muted"]}
        out = self._osascript("get volume settings")
        level = re.search(r"output volume:(\d+)", out)
        muted = re.search(r"output muted:(true|false)", out)
        if not level:
            raise ActionError("could not read volume")
        return "volume", {"level": int(level.group(1)), "muted": bool(muted and muted.group(1) == "true")}

    def volume_set(self, args):
        level = _level(args)
        self._osascript(f"set volume output volume {level} without output muted")
        self._fake.update(volume=level, muted=False)
        return f"volume {level}", self.volume_get({})[1]

    def audio_mute(self, args):
        self._osascript("set volume output muted not (output muted of (get volume settings))")
        self._fake["muted"] = not self._fake["muted"]
        return "mute toggled", self.volume_get({})[1]

    # ── clock info ──
    # 只讀資料，dry-run 也是真的；各自有快取（天氣 15 分鐘、行事曆 2 分鐘）

    def info_get(self, args):
        event = self.calendar.get()
        return "info", {
            "weather": self.weather.get(),
            "event": event.get("event"),
            "event_error": event.get("error"),
            "synced": time.strftime("%H:%M"),
        }

    # ── agents ──
    # 狀態來自 Claude Code hooks（真實資料，dry-run 也一樣）；按鍵在 dry-run 時不會送出

    def agents_list(self, args):
        sessions = self.hub.snapshot()
        return f"{len(sessions)} sessions", {"sessions": sessions}

    def _session(self, args) -> str:
        sid = args.get("session_id")
        if not isinstance(sid, str) or not SESSION_ID.match(sid) or not self.hub.exists(sid):
            raise ActionError("unknown session")
        return sid

    def _focus(self, sid: str) -> None:
        app = self.hub.app_for(sid)
        if not app or not BUNDLE_ID.match(app):
            raise ActionError("don't know which app runs this session")
        self._run(["open", "-b", app])
        if not self.dry_run:
            time.sleep(0.4)  # 等視窗真的到前景再送按鍵

    def agent_open(self, args):
        sid = self._session(args)
        self._focus(sid)
        return "opened", None

    def agent_key(self, args):
        sid = self._session(args)
        key = args.get("key")
        if key == "dictate":
            if not self.dictation:
                raise ActionError("set dictation_key in config.json")
            script = self.dictation
        elif key in KEYS:
            script = KEYS[key]
        else:
            raise ActionError("unknown key")
        self._focus(sid)
        self._osascript(script)
        return key, None
