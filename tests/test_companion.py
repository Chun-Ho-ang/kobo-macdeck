"""python3 -m unittest discover -s tests  （在 kobo-macdeck 目錄下）"""

import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "mac-companion"))

from macdeck_companion.actions import ActionError, Actions  # noqa: E402
from macdeck_companion.protocol import Deduper, ProtocolError, ack, parse_command  # noqa: E402


class DryRunActions(unittest.TestCase):
    def setUp(self):
        self.a = Actions({}, dry_run=True)

    def test_media(self):
        for action in ("media.previous", "media.toggle", "media.next"):
            detail, data = self.a.execute(action, {})
            self.assertIsNone(data)

    def test_volume(self):
        self.assertEqual(self.a.execute("volume.get", {})[1], {"level": 50, "muted": False})
        self.assertEqual(self.a.execute("volume.set", {"level": 72.4})[1], {"level": 72, "muted": False})
        self.assertEqual(self.a.execute("volume.set", {"level": 500})[1]["level"], 100)
        self.assertTrue(self.a.execute("audio.mute", {})[1]["muted"])
        with self.assertRaises(ActionError):
            self.a.execute("volume.set", {"level": "50; rm -rf ~"})

    def test_displays(self):
        displays = self.a.execute("display.list", {})[1]["displays"]
        self.assertEqual([d["id"] for d in displays], ["builtin", "1"])
        self.a.execute("display.brightness.set", {"display_id": "1", "level": 30})
        self.assertEqual(self.a.execute("display.list", {})[1]["displays"][1]["brightness"], 30)
        for bad in ("../x", "1; ls", 3, "123"):
            with self.assertRaises(ActionError):
                self.a.execute("display.brightness.set", {"display_id": bad, "level": 30})

    def test_whitelist(self):
        for action in ("mac.lock", "app.activate", "rm -rf"):
            with self.assertRaises(ActionError):
                self.a.execute(action, {})


class Protocol(unittest.TestCase):
    def test_parse_and_ack(self):
        with self.assertRaises(ProtocolError):
            parse_command({"protocol": "x"})
        msg = parse_command({"protocol": "macdeck/1", "id": "c1", "type": "command"})
        self.assertEqual(msg["id"], "c1")
        self.assertNotIn("data", ack("c1", "ok"))
        self.assertEqual(ack("c1", "ok", "", {"a": 1})["data"], {"a": 1})

    def test_dedupe(self):
        d = Deduper(size=2)
        d.put("a", {"x": 1}); d.put("b", {}); d.put("c", {})
        self.assertIsNone(d.get("a"))
        self.assertEqual(d.get("c"), {})


if __name__ == "__main__":
    unittest.main()
