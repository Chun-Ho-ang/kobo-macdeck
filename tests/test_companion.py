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
from macdeck_companion.agents import AgentHub, describe_tool  # noqa: E402
from macdeck_companion.info import NextEvent, Weather, geocode, when_label  # noqa: E402
from macdeck_companion.install_hooks import SCRIPT, merged  # noqa: E402
from macdeck_companion.server import check_host, load_token, make_handler  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOKEN = "test-token"


def start_server(hooks=False, hub=None):
    hub = hub or AgentHub()
    handler = make_handler(Actions({}, dry_run=True, hub=hub), Deduper(), TOKEN, hub, hooks=hooks)
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}/command"


def post(url, body, token=TOKEN, path=None):
    if path:
        url = url.rsplit("/", 1)[0] + path
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

    def test_whitelist(self):
        for action in ("mac.lock", "app.activate", "rm -rf", "display.list", "display.brightness.set"):
            with self.assertRaises(ActionError):
                self.a.execute(action, {})


def hook(hub, name, sid="s1", cwd="/Users/me/kobo-macdeck", **fields):
    hub.handle(dict(session_id=sid, cwd=cwd, hook_event_name=name, **fields), app="com.apple.Terminal")


class Agents(unittest.TestCase):
    def setUp(self):
        self.now = [1000.0]
        self.hub = AgentHub(clock=lambda: self.now[0])

    def one(self, sid="s1"):
        return next(s for s in self.hub.snapshot() if s["id"] == sid)

    def test_lifecycle(self):
        hook(self.hub, "SessionStart", source="startup")
        self.assertEqual(self.one()["state"], "idle")
        hook(self.hub, "UserPromptSubmit", prompt="Add Wi-Fi\n<pasted_content id=\"x\">secret</pasted_content id=\"x\">")
        s = self.one()
        self.assertEqual((s["state"], s["project"], s["prompt"]), ("working", "kobo-macdeck", "Add Wi-Fi [pasted]"))
        hook(self.hub, "PreToolUse", tool_name="Edit", tool_input={"file_path": "/x/transport/wifi.lua"})
        self.assertEqual(self.one()["summary"], "Edit wifi.lua")
        hook(self.hub, "PermissionRequest", tool_name="Bash", tool_input={"command": "npm test", "description": "Run tests"})
        s = self.one()
        self.assertEqual((s["state"], s["label"], s["summary"]), ("waiting", "Needs you", "Allow Run: Run tests?"))
        hook(self.hub, "Notification", notification_type="permission_prompt", message="Claude needs your permission")
        self.assertEqual(self.one()["summary"], "Allow Run: Run tests?", "specific text kept")
        hook(self.hub, "PostToolUse", tool_name="Bash", tool_input={})
        self.assertEqual(self.one()["state"], "working")
        self.now[0] += 252
        self.assertEqual(self.one()["elapsed"], "4m 12s")
        hook(self.hub, "Stop")
        self.now[0] += 720
        s = self.one()
        self.assertEqual((s["state"], s["summary"]), ("done", "12 min ago"))
        hook(self.hub, "StopFailure", error_type="rate_limit")
        self.assertEqual((self.one()["state"], self.one()["summary"]), ("error", "rate_limit"))
        hook(self.hub, "SessionEnd", reason="other")
        self.assertEqual(self.hub.snapshot(), [])

    def test_tasks(self):
        hook(self.hub, "UserPromptSubmit", prompt="go")
        hook(self.hub, "TaskCreated", task_id="1", task_subject="Read code")
        hook(self.hub, "PostToolUse", tool_name="TaskCreate", tool_input={"subject": "Write tests"},
             tool_response={"task": {"id": "2"}})
        hook(self.hub, "PostToolUse", tool_name="TaskUpdate", tool_input={"taskId": "1", "status": "completed"})
        hook(self.hub, "PostToolUse", tool_name="TaskUpdate", tool_input={"taskId": "2", "status": "in_progress"})
        s = self.one()
        self.assertEqual(s["progress"], "1/2")
        self.assertEqual([t["status"] for t in s["tasks"]], ["completed", "in_progress"])
        hook(self.hub, "PostToolUse", tool_name="TodoWrite", tool_input={"todos": [
            {"content": "A", "status": "completed"}, {"content": "B", "status": "completed"}]})
        self.assertEqual(self.one()["progress"], "2/2")
        hook(self.hub, "UserPromptSubmit", prompt="next")
        self.assertEqual(self.one()["tasks"], [], "finished list cleared on a new prompt")

    def test_order_and_limits(self):
        for i, (sid, ev) in enumerate([("a", "Stop"), ("b", "UserPromptSubmit"), ("c", "PermissionRequest")]):
            self.now[0] += 1
            hook(self.hub, ev, sid=sid, tool_name="Bash", tool_input={})
        self.assertEqual([s["id"] for s in self.hub.snapshot()], ["c", "b", "a"], "needs-you first")
        hook(self.hub, "Stop", sid="../../etc")
        hook(self.hub, "Stop", sid="sub", agent_id="x")
        self.assertEqual(len(self.hub.snapshot()), 3, "bad ids and subagents ignored")
        self.now[0] += 13 * 3600
        self.assertEqual(self.hub.snapshot(), [], "stale sessions expire")

    def test_describe_tool(self):
        self.assertEqual(describe_tool("Read", {"file_path": "/a/b.py"}), "Read b.py")
        self.assertIsNone(describe_tool("TodoWrite", {}))
        self.assertEqual(describe_tool("mcp__slack__send", {}), "Tool: send")

    def test_actions(self):
        a = Actions({"dictation_key": {"key": "d", "modifiers": ["control", "option"]}}, dry_run=True, hub=self.hub)
        hook(self.hub, "UserPromptSubmit", prompt="go")
        self.assertEqual(len(a.execute("agents.list", {})[1]["sessions"]), 1)
        for key in ("approve", "stop", "send", "auto", "dictate"):
            self.assertEqual(a.execute("agent.key", {"session_id": "s1", "key": key})[0], key)
        a.execute("agent.open", {"session_id": "s1"})
        for bad in ({"session_id": "nope", "key": "stop"}, {"session_id": "s1", "key": "rm -rf"},
                    {"session_id": "s1", "key": "q"}):
            with self.assertRaises(ActionError):
                a.execute("agent.key", bad)
        with self.assertRaises(ActionError):
            Actions({}, hub=self.hub).execute("agent.key", {"session_id": "s1", "key": "dictate"})
        for bad in ({"key": "d;", "modifiers": ["control"]}, {"key": "d", "modifiers": ["hyper"]}, {"key": "d"}):
            self.assertIsNone(Actions({"dictation_key": bad}).dictation)

    def test_install_hooks(self):
        mine = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}, "model": "opus"}
        new = merged(mine)
        self.assertEqual(new["model"], "opus")
        self.assertEqual(len(new["hooks"]["Stop"]), 2, "user hook kept")
        self.assertEqual(new["hooks"]["PreToolUse"][0]["hooks"][0]["command"], str(SCRIPT))
        self.assertEqual(merged(new), new, "idempotent")
        self.assertEqual(merged(new, remove=True), mine)
        self.assertTrue(SCRIPT.exists())


class ClockInfo(unittest.TestCase):
    def test_weather(self):
        urls, now = [], [0]
        forecast = {"current": {"temperature_2m": 16.6, "weather_code": 3},
                    "daily": {"temperature_2m_max": [22.7], "temperature_2m_min": [8.9]}}
        fetch = lambda url: urls.append(url) or forecast
        cfg = {"weather": {"name": "Ann Arbor", "latitude": 42.28, "longitude": -83.74, "unit": "fahrenheit"}}
        w = Weather(cfg, fetch=fetch, clock=lambda: now[0])
        self.assertEqual(w.get(), {"temp": 17, "text": "Overcast", "high": 23, "low": 9, "unit": "F",
                                   "location": "Ann Arbor"})
        self.assertIn("temperature_unit=fahrenheit", urls[0])
        w.get(); self.assertEqual(len(urls), 1, "cached")
        now[0] = 16 * 60; w.get(); self.assertEqual(len(urls), 2, "refetched after 15 min")
        self.assertEqual(Weather({}).get(), {"error": "Set a location on the Mac"})

        def down(url):
            raise OSError("offline")
        self.assertEqual(Weather(cfg, fetch=down).get(), {"error": "Weather unavailable (OSError)"})

    def test_geocode(self):
        place = geocode("ann arbor", fetch=lambda url: {"results": [
            {"name": "Ann Arbor", "admin1": "Michigan", "country_code": "US", "latitude": 42.2, "longitude": -83.7}]})
        self.assertEqual(place["label"], "Ann Arbor, Michigan, US")

    def test_next_event(self):
        from datetime import datetime
        now = datetime(2026, 10, 29, 9, 0)
        at = lambda h, m=0, d=29: datetime(2026, 10, d, h, m).timestamp()
        self.assertEqual(when_label(at(14), at(15), now), "Today 14:00–15:00")
        self.assertEqual(when_label(at(9, 30, 30), at(10, 0, 30), now), "Tomorrow 09:30–10:00")
        self.assertEqual(when_label(at(8, 30), at(9, 30), now), "Now · until 09:30")
        self.assertEqual(when_label(at(10, 0, 31), at(11, 0, 31), now), "Sat 10:00–11:00")

        out = json.dumps({"events": [{"title": "Design review", "start": at(14), "end": at(15), "location": "Room 3"}]})
        ev = NextEvent(run=lambda: out, now=lambda: now, background=False).get()
        self.assertEqual(ev["event"], {"title": "Design review", "when": "Today 14:00–15:00", "location": "Room 3"})
        self.assertEqual(NextEvent(run=lambda: '{"events": []}', background=False).get(), {"event": None})
        denied = NextEvent(run=lambda: '{"error": "Allow Calendar for MacDeck Calendar"}', background=False).get()
        self.assertEqual(denied, {"error": "Allow Calendar for MacDeck Calendar"})

    def test_next_event_background(self):
        import threading as th
        gate, calls, clock = th.Event(), [], [0]

        def slow():
            calls.append(1)
            gate.wait(2)
            return '{"events": []}'
        ne = NextEvent(run=slow, clock=lambda: clock[0])
        reading = {"error": "Reading calendar…"}
        self.assertEqual(ne.get(), reading, "answers at once while reading")
        self.assertEqual(ne.get(), reading)
        gate.set()
        for _ in range(100):
            if ne.at is not None:
                break
            th.Event().wait(0.01)
        self.assertEqual(ne.get(), {"event": None})
        self.assertEqual(len(calls), 1, "one read at a time, then cached")
        clock[0] = 3 * 60
        ne.get()
        for _ in range(100):
            if len(calls) == 2 and not ne.busy:
                break
            th.Event().wait(0.01)
        self.assertEqual(len(calls), 2, "re-read after the cache expires")

    def test_info_action(self):
        weather = Weather({}, fetch=None)
        cal = NextEvent(run=lambda: '{"events": []}', background=False)
        detail, data = Actions({}, weather=weather, calendar=cal).execute("info.get", {})
        self.assertEqual(data["weather"], {"error": "Set a location on the Mac"})
        self.assertIsNone(data["event"])
        self.assertRegex(data["synced"], r"^\d\d:\d\d$")


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

    def test_hooks_only_on_loopback_listener(self):
        event = {"session_id": "s1", "cwd": "/p/demo", "hook_event_name": "UserPromptSubmit", "prompt": "hi"}
        self.assertEqual(post(self.url, event, path="/hook")[0], 404, "LAN listener refuses hooks")
        hub = AgentHub()
        server, url = start_server(hooks=True, hub=hub)
        try:
            self.assertEqual(post(url, event, token="wrong", path="/hook")[0], 401)
            self.assertEqual(post(url, event, path="/hook")[0], 200)
            code, reply = post(url, {"protocol": "macdeck/1", "id": "c1", "type": "command", "action": "agents.list"})
            self.assertEqual(reply["data"]["sessions"][0]["project"], "demo")
        finally:
            server.shutdown()
            server.server_close()

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
        r = self.run_transport(TOKEN, [("volume.set", {"level": 40}), ("agents.list", {}), ("mac.lock", {})])
        self.assertEqual(r[0], ("connect", True, None))
        self.assertEqual(r[1][1:], ("ok", "volume 40", {"level": 40, "muted": False}))
        self.assertEqual(r[2][1:3], ("ok", "0 sessions"))
        self.assertEqual(r[3][1], "error", "non-whitelisted action rejected")

    def test_bad_token(self):
        r = self.run_transport("wrong", [])
        self.assertEqual(r, [("connect", False, "Mac rejected the token (check settings)")])


if __name__ == "__main__":
    unittest.main()
