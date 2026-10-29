"""Message envelope / ACK helpers (spec ch. 06)."""

from collections import OrderedDict

from . import PROTOCOL


class ProtocolError(ValueError):
    pass


def parse_command(msg: dict) -> dict:
    if not isinstance(msg, dict) or msg.get("protocol") != PROTOCOL:
        raise ProtocolError("unsupported protocol")
    if not isinstance(msg.get("id"), str) or not msg["id"]:
        raise ProtocolError("missing id")
    if msg.get("type") not in ("command", "ping"):
        raise ProtocolError("unsupported type")
    return msg


def ack(cmd_id: str, status: str, detail: str = "") -> dict:
    return {"protocol": PROTOCOL, "id": cmd_id, "type": "ack", "status": status, "detail": detail}


class Deduper:
    """Remember recent command ids so retries don't execute twice."""

    def __init__(self, size: int = 256):
        self._seen: OrderedDict[str, dict] = OrderedDict()
        self._size = size

    def get(self, cmd_id: str):
        return self._seen.get(cmd_id)

    def put(self, cmd_id: str, reply: dict):
        self._seen[cmd_id] = reply
        if len(self._seen) > self._size:
            self._seen.popitem(last=False)
