"""Whitelisted actions. Never pass arbitrary strings to a shell.

Current scope: media control (previous / play-pause / next, volume, mute)
and monitor control (list displays, set brightness).
"""

import re
import shutil
import subprocess
from typing import Optional


class ActionError(Exception):
    pass


DISPLAY_ID = re.compile(r"^(builtin|\d{1,2})$")


def _level(args: dict) -> int:
    level = args.get("level")
    if not isinstance(level, (int, float)) or isinstance(level, bool):
        raise ActionError("level must be a number 0-100")
    return max(0, min(100, int(round(level))))


class Actions:
    def __init__(self, config: dict, dry_run: bool = True):
        self.player = config.get("media_player", "Music")
        self.dry_run = dry_run
        self.handlers = {
            "media.previous": self.media_previous,
            "media.toggle": self.media_toggle,
            "media.next": self.media_next,
            "volume.get": self.volume_get,
            "volume.set": self.volume_set,
            "audio.mute": self.audio_mute,
            "display.list": self.display_list,
            "display.brightness.set": self.display_brightness_set,
        }
        # dry-run 時用假狀態回應，讓 Kobo 端可以完整測試
        self._fake = {
            "volume": 50,
            "muted": False,
            "displays": [
                {"id": "builtin", "name": "Built-in display", "brightness": 70},
                {"id": "1", "name": "External display", "brightness": 50},
            ],
        }

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

    # ── monitors ──
    # 內建螢幕：brew install brightness；外接螢幕（DDC/CI）：brew install m1ddc

    def display_list(self, args):
        if self.dry_run:
            return f"{len(self._fake['displays'])} displays", {"displays": [dict(d) for d in self._fake["displays"]]}
        displays = []
        if shutil.which("brightness"):
            m = re.search(r"brightness (\d*\.?\d+)", self._run(["brightness", "-l"]))
            displays.append({"id": "builtin", "name": "Built-in display",
                             "brightness": round(float(m.group(1)) * 100) if m else None})
        if shutil.which("m1ddc"):
            for line in self._run(["m1ddc", "display", "list"]).splitlines():
                m = re.match(r"\s*\[(\d{1,2})\]\s+(.+?)\s*(\(.*\))?\s*$", line)
                if m:
                    displays.append({"id": m.group(1), "name": m.group(2),
                                     "brightness": self._ddc_luminance(m.group(1))})
        return f"{len(displays)} displays", {"displays": displays}

    def _ddc_luminance(self, display_id: str):
        try:
            return int(self._run(["m1ddc", "display", display_id, "get", "luminance"]).strip())
        except (ValueError, subprocess.SubprocessError, OSError):
            return None

    def display_brightness_set(self, args):
        display_id = args.get("display_id")
        if not isinstance(display_id, str) or not DISPLAY_ID.match(display_id):
            raise ActionError("invalid display_id")
        level = _level(args)
        if display_id == "builtin":
            self._run(["brightness", f"{level / 100:.2f}"])
        else:
            self._run(["m1ddc", "display", display_id, "set", "luminance", str(level)])
        for d in self._fake["displays"]:
            if d["id"] == display_id:
                d["brightness"] = level
        return f"display {display_id} brightness {level}", {"display_id": display_id, "brightness": level}
