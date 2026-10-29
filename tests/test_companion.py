"""python3 -m unittest discover -s tests  （在 kobo-macdeck 目錄下）"""

import json
import pathlib
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "mac-companion"))

from macdeck_companion.actions import ActionError, Actions  # noqa: E402
from macdeck_companion.protocol import Deduper, ProtocolError, ack, parse_command  # noqa: E402
from macdeck_companion.server import check_host, load_token, make_handler  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOKEN = "test-token"


def start_server():
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(Actions({}, dry_run=True), Deduper(), TOKEN))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}/command"


def post(url, body, token=TOKEN):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=3) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, None


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


class Server(unittest.TestCase):
    def setUp(self):
        self.server, self.url = start_server()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_token_required(self):
        ping = {"protocol": "macdeck/1", "id": "p1", "type": "ping"}
        self.assertEqual(post(self.url, ping, token="wrong")[0], 401)
        self.assertEqual(post(self.url, ping, token="")[0], 401)
        code, reply = post(self.url, ping)
        self.assertEqual((code, reply["detail"]), (200, "pong"))

    def test_chunked_body_rejected(self):
        # LuaSocket 沒帶 Content-Length 時會送 chunked；要明確拒絕而不是讀成空內容
        import http.client
        port = self.server.server_address[1]
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        body = json.dumps({"protocol": "macdeck/1", "id": "p1", "type": "ping"}).encode()
        conn.request("POST", "/command", body=iter([body]), encode_chunked=True,
                     headers={"Authorization": f"Bearer {TOKEN}", "Transfer-Encoding": "chunked"})
        self.assertEqual(conn.getresponse().status, 411)
        conn.close()

    def test_command(self):
        code, reply = post(self.url, {"protocol": "macdeck/1", "id": "c1", "type": "command",
                                      "action": "volume.set", "args": {"level": 30}})
        self.assertEqual(reply["data"], {"level": 30, "muted": False})

    def test_host_and_token_file(self):
        for ok in ("127.0.0.1", "192.168.1.20", "10.0.0.5"):
            check_host(ok)
        for bad in ("0.0.0.0", "8.8.8.8", "example.com"):
            with self.assertRaises(SystemExit):
                check_host(bad)
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d) / "token.txt"
            token = load_token(path)
            self.assertEqual(len(token), 16)
            self.assertEqual(load_token(path), token, "reused on next start")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


try:
    import lupa
except ImportError:
    lupa = None


@unittest.skipIf(lupa is None, "pip install lupa")
class KoboToCompanion(unittest.TestCase):
    """End to end: the plugin's real Wi-Fi transport talks to the real server over HTTP."""

    def setUp(self):
        self.server, self.url = start_server()
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(f"package.path = {str(ROOT / 'macdeck.koplugin' / '?.lua')!r} .. ';' .. package.path")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def to_py(self, v):
        if lupa.lua_type(v) == "table":
            keys = list(v.keys())
            if keys and all(isinstance(k, int) for k in keys):
                return [self.to_py(v[k]) for k in sorted(keys)]
            return {k: self.to_py(v[k]) for k in keys}
        return v

    def http_post(self, url, headers, body, timeout):
        req = urllib.request.Request(url, data=body.encode(), method="POST", headers=dict(headers.items()))
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, ""

    def run_transport(self, token, steps):
        port = self.server.server_address[1]
        json_mod = self.lua.table(encode=lambda t: json.dumps(self.to_py(t)),
                                  decode=lambda s: self.lua.table_from(json.loads(s), recursive=True))
        results = []
        run = self.lua.eval("""function(port, token, post, json, steps, record)
            local t = require("transport/wifi").new{
                ui_manager = { nextTick = function(_, fn) fn() end },
                host = "127.0.0.1", port = port, token = token, http_post = post, json = json,
            }
            t:connect(function(ok, err) record("connect", ok, err) end)
            for _, s in ipairs(steps) do
                t:send(s[1], s[2], function(ack) record(s[1], ack.status, ack.detail, ack.data) end)
            end
        end""")
        steps_lua = self.lua.table_from([self.lua.table(a, self.lua.table_from(args)) for a, args in steps])
        run(port, token, self.http_post, json_mod, steps_lua,
            lambda *r: results.append(tuple(self.to_py(x) for x in r)))
        return results

    def test_round_trip(self):
        r = self.run_transport(TOKEN, [("volume.set", {"level": 40}), ("display.list", {}), ("mac.lock", {})])
        self.assertEqual(r[0], ("connect", True, None))
        self.assertEqual(r[1][1:], ("ok", "volume 40", {"level": 40, "muted": False}))
        self.assertEqual([d["id"] for d in r[2][3]["displays"]], ["builtin", "1"])
        self.assertEqual(r[3][1], "error", "non-whitelisted action rejected")

    def test_bad_token(self):
        r = self.run_transport("wrong", [])
        self.assertEqual(r, [("connect", False, "Mac rejected the token (check settings)")])


if __name__ == "__main__":
    unittest.main()
