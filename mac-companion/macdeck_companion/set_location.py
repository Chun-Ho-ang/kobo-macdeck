"""Set the weather location in config.json.

    python3 -m macdeck_companion.set_location "Ann Arbor"
    python3 -m macdeck_companion.set_location "Taipei" --unit celsius
"""

import argparse
import json
import sys
from pathlib import Path

from .info import InfoError, geocode


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("place")
    p.add_argument("--unit", choices=("celsius", "fahrenheit"), default="celsius")
    p.add_argument("--config", type=Path, default=Path("config.json"))
    a = p.parse_args()
    try:
        place = geocode(a.place)
    except (InfoError, OSError) as e:
        print(f"Could not find that place: {e}", file=sys.stderr)
        return 1
    config = json.loads(a.config.read_text()) if a.config.exists() else {"schema": 1, "media_player": "Music"}
    config["weather"] = {"name": place["name"], "latitude": place["latitude"], "longitude": place["longitude"],
                         "unit": a.unit}
    a.config.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
    print(f"Weather location: {place['label']} ({place['latitude']}, {place['longitude']}), {a.unit}")
    print("Restart the Companion to use it.")


if __name__ == "__main__":
    sys.exit(main())
