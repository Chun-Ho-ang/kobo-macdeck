"""Whitelisted actions. Never pass arbitrary strings to a shell.

Current scope: media control (previous / play-pause / next, volume, mute)
the agent deck (Claude Code session status, a few fixed keys), and clock info
(weather, next calendar event; read-only).
"""

import json
import re
import subprocess
import time
from typing import Optional

from . import helper_apps
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
DICTATION_MAX_SEC = 60

# 先按畫面上的按鈕 / 選單項目（不受鍵盤焦點影響），找不到才送按鍵。名稱依序優先，比對不分大小寫、可只比開頭
BUTTONS = {
    "approve": ["Allow once", "Allow", "Approve", "Accept", "Yes", "允許", "核准"],
    "stop": ["Stop", "Stop response", "Stop generating", "Stop streaming", "Interrupt", "停止"],
    "send": ["Send message", "Send", "傳送", "送出"],
    # 多數 Mac App 的「編輯」選單（聽寫中這個項目不會變成「停止」，停止改送 Esc，見 agent_key）
    "dictate": ["Start Dictation", "開始聽寫", "开始听写"],
}
# 這些 App 的按鈕對按鍵沒有可靠的反應，優先按按鈕；終端機則直接送按鍵（Return / Esc 很可靠）
BUTTON_APPS = {"com.anthropic.claudefordesktop", "com.openai.codex"}


def press_button(bundle: str, names: list[str]) -> Optional[str]:
    """MacDeck Windows 按下第一個符合的按鈕；回傳按到的名稱，沒找到回傳 None"""
    app = helper_apps.build("MacDeck Windows", "app_windows.swift", "AppWindows-Info.plist", "app-windows")
    d = json.loads(helper_apps.run(app, "--press", bundle, *names, timeout=20))
    if d.get("error"):
        raise ActionError(d["error"])
    return d.get("pressed")


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
        self.press = press_button
        self.dictating_since: Optional[float] = None  # 聽寫由我們開啟的時間（macOS 不會告訴我們它開著沒）
        self.hub = hub or AgentHub()
        self.weather = weather or Weather(config)
        self.calendar = calendar or NextEvent()
        self.handlers = {
            "media.previous": self.media_previous,
            "media.toggle": self.media_toggle,
            "media.next": self.media_next,
            "volume.get": self.volume_get,
            "media.now": self.media_now,
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

    def _read(self, script: str) -> str:
        """唯讀的 AppleScript：dry-run 也真的執行（不會改變 Mac 的任何狀態）"""
        return subprocess.run(["osascript", "-e", script], check=True, timeout=10,
                              capture_output=True, text=True).stdout

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

    def media_now(self, args):
        """正在播放：{player, state, title, artist, album, position, duration}（秒）。
        播放器沒開時不會把它開起來（先用 is running 檢查）。"""
        if self.player not in ("Music", "Spotify"):
            raise ActionError("unsupported media_player")
        sep = "character id 31"  # 用不會出現在歌名裡的分隔字元
        script = f'''
if application "{self.player}" is running then
    tell application "{self.player}"
        try
            set s to player state as string
            if s is "stopped" then return "stopped"
            set t to current track
            return s & {sep} & (name of t) & {sep} & (artist of t) & {sep} & (album of t) & {sep} & (player position as string) & {sep} & (duration of t as string)
        on error
            return "stopped"
        end try
    end tell
else
    return "closed"
end if'''
        out = self._read(script).rstrip("\n")
        parts = out.split("\x1f")
        if len(parts) < 6:
            state = parts[0] if parts[0] in ("closed", "stopped") else "stopped"
            return state, {"player": self.player, "state": state}

        def seconds(text: str) -> int:
            try:
                return int(round(float(text.replace(",", "."))))
            except ValueError:
                return 0
        duration = seconds(parts[5])
        if self.player == "Spotify":
            duration //= 1000  # Spotify 的長度是毫秒
        state = parts[0] if parts[0] in ("playing", "paused") else "playing"
        data = {"player": self.player, "state": state, "title": parts[1][:80], "artist": parts[2][:60],
                "album": parts[3][:60], "position": seconds(parts[4]), "duration": duration}
        return f"{state}: {data['title']}", data

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
        if key not in KEYS and key != "dictate":
            raise ActionError("unknown key")
        app = self.hub.app_for(sid)
        if self.dry_run:
            return key, None
        # 1. 有自訂聽寫快速鍵就用它：macOS 的聽寫快速鍵按一次開始、再按一次停止
        if key == "dictate" and self.dictation:
            now = time.time()
            # macOS 安靜一陣子會自己停；超過 DICTATION_MAX_SEC 就當作已經停了
            on = self.dictating_since is not None and now - self.dictating_since < DICTATION_MAX_SEC
            self._focus(sid)
            self._osascript(self.dictation)
            self.dictating_since = None if on else now
            return ("dictate: stop" if on else "dictate: start"), {"dictating": not on}
        # 2a. 聽寫中再按一次 → Esc（macOS 停止聽寫的方式）
        #     只在我們 60 秒內開啟的聽寫才送；那個 session 正在工作時不送，免得 Esc 中斷 Claude 的回答
        if key == "dictate":
            now = time.time()
            if self.dictating_since is not None and now - self.dictating_since < DICTATION_MAX_SEC:
                self.dictating_since = None
                if self.hub.state_of(sid) == "working":
                    raise ActionError("agent is working; stop dictation on the Mac")
                self._focus(sid)
                self._osascript(KEYS["stop"])  # Escape
                return "dictate: stop (Esc)", {"dictating": False}
        # 2. 按畫面上的按鈕 / 選單項目（聽寫開始：「編輯 → 開始聽寫…」）
        if key in BUTTONS and (app in BUTTON_APPS or key == "dictate") and app and BUNDLE_ID.match(app):
            self._focus(sid)
            try:
                pressed = self.press(app, BUTTONS[key])
            except (ActionError, OSError, ValueError, subprocess.SubprocessError) as e:
                pressed = None
                if key == "dictate":
                    raise ActionError(f"dictation: {e}") from e
            if pressed:
                data = None
                if key == "dictate":
                    self.dictating_since = time.time()
                    data = {"dictating": True}
                return f"{key}: {pressed}", data
            if key == "dictate":
                raise ActionError("this app has no Start Dictation menu; set dictation_key in config.json")
        # 3. 送按鍵（終端機，或 App 裡找不到對應的按鈕）
        self._focus(sid)
        self._osascript(KEYS[key])
        return key, None
