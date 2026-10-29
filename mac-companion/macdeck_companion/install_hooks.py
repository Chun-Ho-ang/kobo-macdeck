"""Add the MacDeck hooks to Claude Code's user settings.

    python3 -m macdeck_companion.install_hooks            # show what would change
    python3 -m macdeck_companion.install_hooks --apply    # write it (backup: settings.json.bak)
    python3 -m macdeck_companion.install_hooks --remove   # take them out again

Hooks run async, so Claude Code never waits on the Companion.
"""

import argparse
import json
import shutil
import sys
from pathlib import Path

EVENTS = (
    "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
    "Notification", "Stop", "StopFailure", "TaskCreated", "TaskCompleted", "SessionEnd",
)
SCRIPT = (Path(__file__).resolve().parent.parent / "hooks" / "macdeck-hook.sh")


def is_ours(group: dict) -> bool:
    return any(h.get("command") == str(SCRIPT) for h in group.get("hooks", []) if isinstance(h, dict))


def merged(settings: dict, remove: bool = False) -> dict:
    out = json.loads(json.dumps(settings))
    hooks = out.setdefault("hooks", {})
    for event in EVENTS:
        groups = [g for g in hooks.get(event, []) if not (isinstance(g, dict) and is_ours(g))]
        if not remove:
            groups.append({"hooks": [{"type": "command", "command": str(SCRIPT), "async": True}]})
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)
    if not hooks:
        out.pop("hooks")
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--settings", type=Path, default=Path.home() / ".claude" / "settings.json")
    p.add_argument("--apply", action="store_true")
    p.add_argument("--remove", action="store_true")
    a = p.parse_args()

    current = json.loads(a.settings.read_text()) if a.settings.exists() else {}
    new = merged(current, remove=a.remove)
    if new == current:
        print("Nothing to change.")
        return
    if not (a.apply or a.remove):
        print(f"Would update {a.settings} so these events run {SCRIPT}:")
        print("  " + ", ".join(EVENTS))
        print("Run again with --apply to write it.")
        return
    if a.settings.exists():
        shutil.copy2(a.settings, a.settings.with_name(a.settings.name + ".bak"))
    a.settings.parent.mkdir(parents=True, exist_ok=True)
    a.settings.write_text(json.dumps(new, indent=2, ensure_ascii=False) + "\n")
    print(("Removed hooks from " if a.remove else "Updated ") + str(a.settings))
    print("New Claude Code sessions pick this up; restart running ones.")


if __name__ == "__main__":
    sys.exit(main())
