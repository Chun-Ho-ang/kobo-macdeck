"""Whitelisted actions. Never pass arbitrary strings to a shell."""

import subprocess


class ActionError(Exception):
    pass


def _run(argv: list[str]) -> None:
    subprocess.run(argv, check=True, timeout=10, capture_output=True)


class Actions:
    def __init__(self, config: dict, dry_run: bool = True):
        self.apps = config.get("apps", {})
        self.workflows = config.get("workflows", {})
        self.dry_run = dry_run
        self.handlers = {
            "app.activate": self.app_activate,
            "media.toggle": self.media_toggle,
            "audio.mute": self.audio_mute,
            "workflow.run": self.workflow_run,
            "mac.lock": self.mac_lock,
        }

    def execute(self, action: str, args: dict) -> str:
        handler = self.handlers.get(action)
        if handler is None:
            raise ActionError(f"action not allowed: {action}")
        argv = handler(args or {})
        if self.dry_run:
            return f"dry-run: {argv}"
        try:
            _run(argv)
        except (subprocess.SubprocessError, OSError) as e:
            raise ActionError(f"{action} failed: {e}") from e
        return f"{action} executed"

    def app_activate(self, args):
        app = self.apps.get(args.get("app_id"))
        if app is None:
            raise ActionError("unknown app_id")
        return ["open", "-a", app]

    def media_toggle(self, args):
        # TODO: 依實際播放器調整（Music / Spotify / 系統媒體鍵）
        return ["osascript", "-e", 'tell application "Music" to playpause']

    def audio_mute(self, args):
        return ["osascript", "-e", "set volume output muted not (output muted of (get volume settings))"]

    def workflow_run(self, args):
        name = self.workflows.get(args.get("workflow_id"))
        if name is None:
            raise ActionError("unknown workflow_id")
        return ["shortcuts", "run", name]

    def mac_lock(self, args):
        return ["pmset", "displaysleepnow"]
