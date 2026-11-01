"""
uibridge -- Python client for the UIBridge daemon (iOS, jailbroken).

Drop-in mental model: this is the iOS counterpart of ``uiautomator2``. The agent
never looks at a screenshot; it reads a structured element tree and acts on
element indexes or raw coordinates.

    import uibridge

    d = uibridge.Device("192.168.1.23")
    print(d.info())

    d.dump()                       # element tree (dicts, JSON friendly)
    d(text="设置").click()          # selector style
    d(role="AXButton", label="搜索").click()
    d.click(200, 400)              # raw coordinate
    d.send_keys("hello")           # types into the focused field
    d.swipe(200, 700, 200, 200)    # scroll down
    d.home()

Wire protocol: newline delimited JSON over TCP (default port 9700).
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from typing import Any, Dict, Iterable, List, Optional

__all__ = ["Device", "Selector", "UiBridgeError"]

DEFAULT_PORT = 9700


class UiBridgeError(RuntimeError):
    """Raised when the daemon reports ok=false or the socket dies."""


class Device:
    def __init__(self, host: str = "127.0.0.1", port: int = DEFAULT_PORT, timeout: float = 60.0,
                 token: Optional[str] = None):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.token = token
        self._sock: Optional[socket.socket] = None
        self._reader = None
        self._seq = 0
        self._last_nodes: List[Dict[str, Any]] = []
        self._root = 0
        self._alert_base: Optional[int] = None

    # ------------------------------------------------------------------ transport
    def connect(self) -> "Device":
        if self._sock is not None:
            return self
        sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self._sock = sock
        self._reader = sock.makefile("rb")
        return self

    def close(self) -> None:
        if self._reader is not None:
            try:
                self._reader.close()
            except OSError:
                pass
            self._reader = None
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def __enter__(self) -> "Device":
        return self.connect()

    def __exit__(self, *exc) -> None:
        self.close()

    def _call(self, cmd: str, **kwargs: Any) -> Dict[str, Any]:
        self.connect()
        self._seq += 1
        payload = {"id": self._seq, "cmd": cmd}
        if self.token:
            payload["token"] = self.token
        payload.update({k: v for k, v in kwargs.items() if v is not None})
        line = json.dumps(payload, ensure_ascii=False).encode("utf-8") + b"\n"
        try:
            self._sock.sendall(line)
            raw = self._reader.readline()
        except OSError as exc:
            self.close()
            raise UiBridgeError("transport: %s" % exc) from exc
        if not raw:
            self.close()
            raise UiBridgeError("daemon closed the connection")
        resp = json.loads(raw.decode("utf-8"))
        if not resp.get("ok"):
            raise UiBridgeError(resp.get("error") or "unknown daemon error")
        return resp.get("result", {})

    # ------------------------------------------------------------------ meta
    def info(self) -> Dict[str, Any]:
        return self._call("info")

    def screen(self) -> Dict[str, Any]:
        return self._call("screen")

    def frontmost(self) -> Dict[str, Any]:
        return self._call("frontmost")

    def ping(self) -> bool:
        return bool(self._call("ping").get("pong"))

    def diagnostics(self) -> Dict[str, Any]:
        return self._call("diag")

    # ------------------------------------------------------------------ tree
    def dump(
        self,
        depth: int = 16,
        max_nodes: int = 2500,
        bundle_id: Optional[str] = None,
        alerts: bool = True,
    ) -> Dict[str, Any]:
        result = self._call("dump", depth=depth, maxNodes=max_nodes, bundleId=bundle_id, alerts=alerts)
        self._last_nodes = result.get("nodes", [])
        self._root = result.get("root", 0)
        self._alert_base = result.get("systemAlertFrom")
        return result

    @property
    def nodes(self) -> List[Dict[str, Any]]:
        return self._last_nodes

    def node(self, index: int) -> Optional[Dict[str, Any]]:
        for n in self._last_nodes:
            if n.get("i") == index:
                return n
        return None

    def tree(self) -> str:
        """Pretty, indented rendering of the last dump -- handy for an LLM prompt."""
        lines: List[str] = []
        by_index = {n["i"]: n for n in self._last_nodes if "i" in n}

        def label_of(n: Dict[str, Any]) -> str:
            text = n.get("label") or n.get("title") or n.get("value") or ""
            role = n.get("role", "?")
            parts = ["[%s] %s" % (n.get("i"), role)]
            if text:
                parts.append(repr(text))
            if n.get("id"):
                parts.append("id=" + n["id"])
            frame = n.get("frame") or {}
            if frame:
                parts.append("(%d,%d %dx%d)" % (frame.get("x", 0), frame.get("y", 0),
                                                frame.get("w", 0), frame.get("h", 0)))
            if n.get("actions"):
                parts.append("actions=" + ",".join(n["actions"]))
            return " ".join(parts)

        def walk(index: int, indent: int, seen: set) -> None:
            if index in seen:
                return
            seen.add(index)
            n = by_index.get(index)
            if n is None:
                return
            lines.append("  " * indent + label_of(n))
            for child in n.get("children", []):
                walk(child, indent + 1, seen)

        roots: List[int] = []
        if self._last_nodes:
            root = getattr(self, "_root", 0)
            if any(n.get("i") == root for n in self._last_nodes):
                roots.append(root)
            alert_base = getattr(self, "_alert_base", None)
            if isinstance(alert_base, int) and 0 <= alert_base < len(self._last_nodes):
                roots.append(self._last_nodes[alert_base]["i"])
        if roots:
            seen_all: set = set()
            for r in roots:
                walk(r, 0, seen_all)
        else:
            # flat rendering when we cannot reconstruct the hierarchy
            for n in self._last_nodes:
                lines.append(label_of(n))
        return "\n".join(lines)

    def find(self, text: Optional[str] = None, role: Optional[str] = None, limit: int = 20) -> List[Dict[str, Any]]:
        return self._call("find", text=text, role=role, limit=limit).get("nodes", [])

    def wait(self, text: Optional[str] = None, role: Optional[str] = None, timeout: float = 10.0) -> Dict[str, Any]:
        return self._call("wait", text=text, role=role, timeout=timeout)

    def hit(self, x: float, y: float) -> int:
        return int(self._call("hit", x=x, y=y).get("index", -1))

    # ------------------------------------------------------------------ gestures
    def click(self, x: float, y: float) -> Dict[str, Any]:
        return self._call("tap", x=x, y=y)

    def click_element(self, index: int, force_tap: bool = False) -> Dict[str, Any]:
        return self._call("tapElement", index=index, forceTap=force_tap)

    def long_click(self, x: float, y: float, duration: float = 0.8) -> Dict[str, Any]:
        return self._call("longPress", x=x, y=y, duration=duration)

    def swipe(self, x1: float, y1: float, x2: float, y2: float, duration: float = 0.3) -> Dict[str, Any]:
        return self._call("swipe", x1=x1, y1=y1, x2=x2, y2=y2, duration=duration)

    def drag(self, x1: float, y1: float, x2: float, y2: float, duration: float = 1.0) -> Dict[str, Any]:
        return self._call("drag", x1=x1, y1=y1, x2=x2, y2=y2, duration=duration)

    def scroll(self, dy: float = -300.0, x: Optional[float] = None, y: Optional[float] = None) -> Dict[str, Any]:
        return self._call("scroll", dy=dy, x=x, y=y)

    def scroll_to(self, text: str, max_swipes: int = 8, dy: float = -400.0) -> Dict[str, Any]:
        """Scroll until `text` shows up in the element tree. Returns the matching node."""
        for _ in range(max_swipes):
            try:
                hits = self.find(text=text, limit=1)
            except UiBridgeError:
                hits = []
            if hits:
                return hits[0]
            self.scroll(dy)
            time.sleep(0.35)
        raise UiBridgeError("text not found after %d swipes: %r" % (max_swipes, text))

    # ------------------------------------------------------------------ text
    def send_keys(self, text: str, index: Optional[int] = None, force_hid: bool = False) -> Dict[str, Any]:
        return self._call("type", text=text, index=index, forceHID=force_hid)

    def set_value(self, index: int, value: str) -> Dict[str, Any]:
        return self._call("setValue", index=index, value=value)

    def press(self, index: int, action: str = "AXPress") -> Dict[str, Any]:
        return self._call("press", index=index, action=action)

    def focus(self, index: int) -> Dict[str, Any]:
        return self._call("focus", index=index)

    def press_key(self, usage: int) -> Dict[str, Any]:
        return self._call("pressKey", usage=usage)

    # ------------------------------------------------------------------ system
    def home(self) -> Dict[str, Any]:
        return self._call("home")

    def app_switcher(self) -> Dict[str, Any]:
        return self._call("appSwitcher")

    def lock(self) -> Dict[str, Any]:
        return self._call("lock")

    def open_app(self, bundle_id: str) -> Dict[str, Any]:
        return self._call("openApp", bundleId=bundle_id)

    def open_url(self, url: str) -> Dict[str, Any]:
        return self._call("launchUrl", url=url)

    # ------------------------------------------------------------------ selectors
    def __call__(self, text: Optional[str] = None, role: Optional[str] = None,
                 label: Optional[str] = None, id: Optional[str] = None) -> "Selector":
        return Selector(self, text=text, role=role, label=label, id=id)


class Selector:
    """uiautomator2-ish selector that resolves lazily against a fresh dump."""

    def __init__(self, device: Device, text: Optional[str] = None, role: Optional[str] = None,
                 label: Optional[str] = None, id: Optional[str] = None):
        self.device = device
        self.text = text
        self.role = role
        self.label = label
        self.id = id

    def __repr__(self) -> str:
        bits = []
        for k in ("text", "role", "label", "id"):
            v = getattr(self, k)
            if v:
                bits.append("%s=%r" % (k, v))
        return "Selector(%s)" % ", ".join(bits) if bits else "Selector()"

    def _refresh(self) -> List[Dict[str, Any]]:
        self.device.dump()
        candidates = self.device.nodes
        out = []
        for n in candidates:
            if self.role and n.get("role") != self.role:
                continue
            if self.id and n.get("id") != self.id:
                continue
            if self.label and n.get("label") != self.label:
                continue
            if self.text:
                haystack = " ".join(str(n.get(k, "")) for k in ("label", "title", "value", "id", "placeholder"))
                if self.text.lower() not in haystack.lower():
                    continue
            out.append(n)
        return out

    def all(self) -> List[Dict[str, Any]]:
        return self._refresh()

    def first(self) -> Optional[Dict[str, Any]]:
        hits = self._refresh()
        return hits[0] if hits else None

    @property
    def exists(self) -> bool:
        return self.first() is not None

    def wait(self, timeout: float = 10.0) -> Dict[str, Any]:
        deadline = time.time() + timeout
        node = self.first()
        if node is not None:
            return node
        while time.time() < deadline:
            time.sleep(0.3)
            node = self.first()
            if node is not None:
                return node
        raise UiBridgeError("%r not found within %.1fs" % (self, timeout))

    def click(self, timeout: float = 5.0) -> Dict[str, Any]:
        node = self.wait(timeout) if timeout > 0 else self.first()
        if node is None:
            raise UiBridgeError("%r not found" % self)
        return self.device.click_element(node["i"])

    def long_click(self, duration: float = 0.8, timeout: float = 5.0) -> Dict[str, Any]:
        node = self.wait(timeout)
        frame = node.get("frame") or {}
        cx = frame.get("x", 0) + frame.get("w", 0) / 2
        cy = frame.get("y", 0) + frame.get("h", 0) / 2
        return self.device.long_click(cx, cy, duration)

    def text_value(self) -> str:
        node = self.first()
        if not node:
            return ""
        return node.get("value") or node.get("label") or node.get("title") or ""

    def set_text(self, value: str, timeout: float = 5.0) -> Dict[str, Any]:
        node = self.wait(timeout)
        try:
            return self.device.set_value(node["i"], value)
        except UiBridgeError:
            return self.device.send_keys(value, index=node["i"])


# ---------------------------------------------------------------------- CLI
def _cli(argv: Optional[Iterable[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="uibridge", description="talk to the UIBridge daemon")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--token", default=os.environ.get("UIBRIDGE_TOKEN"))
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("info")
    sub.add_parser("diag")

    p_dump = sub.add_parser("dump")
    p_dump.add_argument("--depth", type=int, default=16)
    p_dump.add_argument("--json", action="store_true")
    p_dump.add_argument("--bundle-id", default=None)

    p_find = sub.add_parser("find")
    p_find.add_argument("text")
    p_find.add_argument("--role", default=None)

    p_tap = sub.add_parser("tap")
    p_tap.add_argument("x", type=float)
    p_tap.add_argument("y", type=float)

    p_swipe = sub.add_parser("swipe")
    for name in ("x1", "y1", "x2", "y2"):
        p_swipe.add_argument(name, type=float)
    p_swipe.add_argument("--duration", type=float, default=0.3)

    p_text = sub.add_parser("type")
    p_text.add_argument("text")

    sub.add_parser("home")
    sub.add_parser("switcher")

    p_open = sub.add_parser("open")
    p_open.add_argument("bundle_id")

    args = parser.parse_args(list(argv) if argv is not None else None)

    with Device(args.host, args.port, token=args.token) as d:
        if args.cmd == "info":
            print(json.dumps(d.info(), indent=2, ensure_ascii=False))
        elif args.cmd == "diag":
            print(json.dumps(d.diagnostics(), indent=2, ensure_ascii=False))
        elif args.cmd == "dump":
            result = d.dump(depth=args.depth, bundle_id=args.bundle_id)
            if args.json:
                print(json.dumps(result, indent=2, ensure_ascii=False))
            else:
                print(d.tree())
        elif args.cmd == "find":
            for node in d.find(text=args.text, role=args.role):
                print(json.dumps(node, ensure_ascii=False))
        elif args.cmd == "tap":
            print(d.click(args.x, args.y))
        elif args.cmd == "swipe":
            print(d.swipe(args.x1, args.y1, args.x2, args.y2, args.duration))
        elif args.cmd == "type":
            print(d.send_keys(args.text))
        elif args.cmd == "home":
            print(d.home())
        elif args.cmd == "switcher":
            print(d.app_switcher())
        elif args.cmd == "open":
            print(d.open_app(args.bundle_id))
    return 0


if __name__ == "__main__":
    sys.exit(_cli())
