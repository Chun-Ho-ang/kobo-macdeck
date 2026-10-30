"""Clock-screen info: weather (Open-Meteo, no API key) and the next calendar event (EventKit).

Both are read-only and cached, so the Kobo can ask as often as it likes.
"""

import json
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from typing import Callable, Optional

from . import helper_apps

WEATHER_TTL = 15 * 60
EVENT_TTL = 2 * 60

# WMO weather codes → short English text (fits the Kobo tile)
WMO = {
    0: "Clear", 1: "Mostly clear", 2: "Partly cloudy", 3: "Overcast",
    45: "Fog", 48: "Fog",
    51: "Light drizzle", 53: "Drizzle", 55: "Heavy drizzle", 56: "Freezing drizzle", 57: "Freezing drizzle",
    61: "Light rain", 63: "Rain", 65: "Heavy rain", 66: "Freezing rain", 67: "Freezing rain",
    71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains",
    80: "Showers", 81: "Showers", 82: "Heavy showers", 85: "Snow showers", 86: "Snow showers",
    95: "Thunderstorm", 96: "Thunderstorm", 99: "Thunderstorm",
}


def weather_icon(code: int, is_day: bool = True) -> str:
    """WMO code → icon name on the Kobo (macdeck.koplugin/assets/icons/weather-<name>.svg)."""
    if code in (0, 1):
        return "clear-day" if is_day else "clear-night"
    if code == 2:
        return "partly-day" if is_day else "partly-night"
    if code == 3:
        return "cloudy"
    if code in (45, 48):
        return "fog"
    if 51 <= code <= 57:
        return "drizzle"
    if 61 <= code <= 67 or 80 <= code <= 82:
        return "rain"
    if 71 <= code <= 77 or code in (85, 86):
        return "snow"
    if code >= 95:
        return "thunder"
    return "cloudy"


class InfoError(Exception):
    pass


def fetch_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "MacDeck-Companion"})
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.loads(r.read())


def geocode(name: str, fetch: Callable[[str], dict] = fetch_json) -> dict:
    """City name → {name, latitude, longitude}（Open-Meteo geocoding）."""
    url = "https://geocoding-api.open-meteo.com/v1/search?" + urllib.parse.urlencode({"name": name, "count": 1})
    results = fetch(url).get("results") or []
    if not results:
        raise InfoError(f"no place called {name!r}")
    r = results[0]
    label = ", ".join(x for x in (r.get("name"), r.get("admin1"), r.get("country_code")) if x)
    return {"name": r["name"], "label": label, "latitude": r["latitude"], "longitude": r["longitude"]}


LOAD_ERRORS = (OSError, ValueError, KeyError, IndexError, TypeError, subprocess.SubprocessError)


class Background:
    """A value kept fresh in the background.

    get() never waits: it returns the last value right away and, if that's older than ttl, starts
    a refresh. A failed refresh keeps the last good value (retrying after `retry` seconds), so a
    slow network or a busy calendar never blanks the Kobo.
    """

    def __init__(self, load: Callable[[], dict], ttl: float, initial: dict, describe: Callable[[Exception], str],
                 clock=time.time, background: bool = True, retry: float = 60):
        self.load, self.ttl, self.describe = load, ttl, describe
        self.clock, self.background, self.retry = clock, background, retry
        self.lock = threading.Lock()
        self.value, self.at, self.busy = initial, None, False

    def get(self) -> dict:
        with self.lock:
            stale = self.at is None or self.clock() - self.at >= self.ttl
            start = stale and not self.busy
            if start:
                self.busy = True
        if start:
            if self.background:
                threading.Thread(target=self._refresh, daemon=True).start()
            else:
                self._refresh()
        with self.lock:
            return self.value

    def _refresh(self) -> None:
        try:
            value, ok = self.load(), True
        except LOAD_ERRORS + (InfoError,) as e:
            value, ok = {"error": self.describe(e)}, False
        with self.lock:
            now = self.clock()
            if ok or "error" in self.value:
                self.value = value  # 失敗時保留上一次成功的資料
            self.at = now if ok else now - self.ttl + self.retry
            self.busy = False


class Weather:
    def __init__(self, config: dict, fetch: Callable[[str], dict] = fetch_json, clock=time.time,
                 background: bool = True):
        w = config.get("weather") if isinstance(config.get("weather"), dict) else {}
        self.lat, self.lon = w.get("latitude"), w.get("longitude")
        self.name = str(w.get("name") or "")
        self.fahrenheit = w.get("unit") == "fahrenheit"
        self.fetch = fetch
        # 背景抓：Kobo 只等 3 秒，不能在回應裡現場上網（最多 8 秒）
        self.cache = Background(self._load, WEATHER_TTL, {"error": "Loading weather…"},
                                lambda e: f"Weather unavailable ({type(e).__name__})", clock, background)

    def get(self) -> dict:
        if not isinstance(self.lat, (int, float)) or not isinstance(self.lon, (int, float)):
            return {"error": "Set a location on the Mac"}
        return self.cache.get()

    def _load(self) -> dict:
        q = {
            "latitude": self.lat, "longitude": self.lon, "timezone": "auto", "forecast_days": 1,
            "current": "temperature_2m,weather_code,is_day", "daily": "temperature_2m_max,temperature_2m_min",
        }
        if self.fahrenheit:
            q["temperature_unit"] = "fahrenheit"
        d = self.fetch("https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q))
        cur, daily = d["current"], d["daily"]
        return {
            "temp": round(cur["temperature_2m"]),
            "text": WMO.get(cur["weather_code"], "—"),
            "icon": weather_icon(cur["weather_code"], cur.get("is_day", 1) == 1),
            "high": round(daily["temperature_2m_max"][0]),
            "low": round(daily["temperature_2m_min"][0]),
            "unit": "F" if self.fahrenheit else "C",
            "location": self.name,
        }


def when_label(start: float, end: float, now: datetime) -> str:
    s, e = datetime.fromtimestamp(start), datetime.fromtimestamp(end)
    if s <= now:
        return f"Now · until {e:%H:%M}"
    if s.date() == now.date():
        day = "Today"
    elif s.date() == (now + timedelta(days=1)).date():
        day = "Tomorrow"
    else:
        day = s.strftime("%a")
    return f"{day} {s:%H:%M}–{e:%H:%M}"


class NextEvent:
    """Runs helpers/next_event.swift as its own app (MacDeck Calendar.app), so macOS asks for
    Calendar access in that app's name no matter which terminal started the Companion.
    Read in the background (see Background)."""

    def __init__(self, run: Optional[Callable[[], str]] = None, clock=time.time, now=datetime.now,
                 background: bool = True):
        self.run = run or self._run_helper
        self.now = now
        self.cache = Background(self._load, EVENT_TTL, {"error": "Reading calendar…"},
                                lambda e: str(e) if isinstance(e, InfoError) else f"Calendar unavailable ({type(e).__name__})",
                                clock, background)

    def get(self) -> dict:
        return self.cache.get()

    def _load(self) -> dict:
        d = json.loads(self.run())
        if d.get("error"):
            raise InfoError(d["error"])
        events = d.get("events") or []
        if not events:
            return {"event": None}
        ev = events[0]
        return {"event": {
            "title": str(ev.get("title") or "(No title)")[:60],
            "when": when_label(ev["start"], ev["end"], self.now()),
            "location": str(ev.get("location") or "")[:60],
        }}

    @staticmethod
    def _run_helper() -> str:
        app = helper_apps.build("MacDeck Calendar", "next_event.swift", "Info.plist", "next-event")
        out = helper_apps.run(app, timeout=180)  # 第一次會等你回答權限詢問
        return out
