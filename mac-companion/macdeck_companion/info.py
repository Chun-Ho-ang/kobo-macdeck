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
from pathlib import Path
from typing import Callable, Optional

WEATHER_TTL = 15 * 60
EVENT_TTL = 2 * 60
HELPERS = Path(__file__).resolve().parent.parent / "helpers"

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


class Cached:
    def __init__(self, ttl: float, clock: Callable[[], float]):
        self.ttl, self.clock = ttl, clock
        self.value, self.at = None, None
        self.lock = threading.Lock()

    def get(self, load: Callable[[], dict]) -> dict:
        with self.lock:
            now = self.clock()
            if self.at is None or now - self.at >= self.ttl:
                self.value, self.at = load(), now
            return self.value


class Weather:
    def __init__(self, config: dict, fetch: Callable[[str], dict] = fetch_json, clock=time.time):
        w = config.get("weather") if isinstance(config.get("weather"), dict) else {}
        self.lat, self.lon = w.get("latitude"), w.get("longitude")
        self.name = str(w.get("name") or "")
        self.fahrenheit = w.get("unit") == "fahrenheit"
        self.fetch = fetch
        self.cache = Cached(WEATHER_TTL, clock)

    def get(self) -> dict:
        if not isinstance(self.lat, (int, float)) or not isinstance(self.lon, (int, float)):
            return {"error": "Set a location on the Mac"}
        try:
            return self.cache.get(self._load)
        except (OSError, ValueError, KeyError, IndexError, TypeError) as e:
            self.cache.at = None  # 下次再試
            return {"error": f"Weather unavailable ({type(e).__name__})"}

    def _load(self) -> dict:
        q = {
            "latitude": self.lat, "longitude": self.lon, "timezone": "auto", "forecast_days": 1,
            "current": "temperature_2m,weather_code", "daily": "temperature_2m_max,temperature_2m_min",
        }
        if self.fahrenheit:
            q["temperature_unit"] = "fahrenheit"
        d = self.fetch("https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(q))
        cur, daily = d["current"], d["daily"]
        return {
            "temp": round(cur["temperature_2m"]),
            "text": WMO.get(cur["weather_code"], "—"),
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
    """Runs helpers/next_event.swift (compiled once). macOS asks for Calendar access the first time."""

    def __init__(self, run: Optional[Callable[[], str]] = None, clock=time.time, now=datetime.now):
        self.run = run or self._run_helper
        self.cache = Cached(EVENT_TTL, clock)
        self.now = now

    def get(self) -> dict:
        try:
            return self.cache.get(self._load)
        except (OSError, ValueError, subprocess.SubprocessError, InfoError) as e:
            self.cache.at = None
            return {"error": str(e) if isinstance(e, InfoError) else f"Calendar unavailable ({type(e).__name__})"}

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
        src = HELPERS / "next_event.swift"
        plist = HELPERS / "Info.plist"
        out = HELPERS / ".build" / "next-event"
        if not out.exists() or out.stat().st_mtime < max(src.stat().st_mtime, plist.stat().st_mtime):
            out.parent.mkdir(exist_ok=True)
            # 把 Info.plist 嵌進執行檔，macOS 才會顯示行事曆權限的說明而不是直接拒絕
            subprocess.run(["swiftc", "-O", str(src), "-o", str(out),
                            "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                            "-Xlinker", str(plist)], check=True, timeout=180, capture_output=True)
        return subprocess.run([str(out)], check=True, timeout=30, capture_output=True, text=True).stdout
