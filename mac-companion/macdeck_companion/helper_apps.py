"""Small Swift helper apps (helpers/*.swift) built into helpers/.build/<Name>.app.

Each helper is its own app so macOS asks for a permission (Calendar, Accessibility) in that
app's name, whatever started the Companion. Rebuilding changes the signature, and macOS then
asks again, so we only rebuild when the source changed.
"""

import platform
import shutil
import subprocess
import tempfile
from pathlib import Path

HELPERS = Path(__file__).resolve().parent.parent / "helpers"
MIN_MACOS = "14.0"  # 和各 helper 的 LSMinimumSystemVersion 一致


def build(name: str, source: str, plist: str, executable: str) -> Path:
    src, info = HELPERS / source, HELPERS / plist
    app = HELPERS / ".build" / f"{name}.app"
    exe = app / "Contents" / "MacOS" / executable
    if not exe.exists() or exe.stat().st_mtime < max(src.stat().st_mtime, info.stat().st_mtime):
        exe.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(info, app / "Contents" / "Info.plist")
        # 明確指定最低系統版本：swiftc 預設可能標成比這台 Mac 還新的版本，系統會拒絕啟動（-10825）
        target = f"{platform.machine()}-apple-macos{MIN_MACOS}"
        subprocess.run(["swiftc", "-O", "-target", target, str(src), "-o", str(exe)],
                       check=True, timeout=300, capture_output=True)
        # 簽成完整的 App（ad-hoc），macOS 才會用 bundle 記住你給的權限
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, timeout=60, capture_output=True)
    return app


def run(app: Path, *args: str, timeout: float = 60) -> str:
    """open -n -W -g -j：新開一份、等它結束、不搶前景；結果寫在暫存檔回傳"""
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "out.json"
        subprocess.run(["open", "-n", "-W", "-g", "-j", str(app), "--args", str(out), *args],
                       timeout=timeout, capture_output=True)
        if not out.exists():
            raise OSError(f"{app.stem} didn't answer")
        return out.read_text()
