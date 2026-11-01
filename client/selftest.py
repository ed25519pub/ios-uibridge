"""
Loopback self-test: runs a fake UIBridge daemon and drives it through the real
Python client, so the wire protocol and selector logic can be validated without
a jailbroken device.

    python3 client/selftest.py
"""

import json
import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import uibridge
from uibridge import Device, UiBridgeError

NODES = [
    {"i": 0, "role": "AXApplication", "label": "设置", "frame": {"x": 0, "y": 0, "w": 414, "h": 896},
     "children": [1]},
    {"i": 1, "role": "AXWindow", "frame": {"x": 0, "y": 0, "w": 414, "h": 896}, "children": [2, 5]},
    {"i": 2, "role": "AXButton", "label": "无线局域网", "id": "wifi-cell",
     "frame": {"x": 0, "y": 100, "w": 414, "h": 44}, "actions": ["AXPress"], "enabled": True},
    {"i": 3, "role": "AXStaticText", "value": "已连接", "frame": {"x": 300, "y": 100, "w": 80, "h": 44}},
    {"i": 4, "role": "AXTextField", "placeholder": "搜索", "id": "search-field",
     "frame": {"x": 20, "y": 200, "w": 374, "h": 36}},
    {"i": 5, "role": "AXButton", "label": "蓝牙", "frame": {"x": 0, "y": 150, "w": 414, "h": 44},
     "actions": ["AXPress"]},
]


class FakeDaemon(threading.Thread):
    daemon = True

    def __init__(self, port=0):
        super().__init__()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", port))
        self.sock.listen(4)
        self.port = self.sock.getsockname()[1]
        self.received = []

    def run(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    def serve(self, conn):
        reader = conn.makefile("rb")
        for raw in reader:
            if not raw.strip():
                continue
            req = json.loads(raw.decode())
            self.received.append(req)
            resp = self.handle(req)
            conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode())
        conn.close()

    def handle(self, req):
        rid = req.get("id", 0)
        cmd = req.get("cmd")
        try:
            if cmd == "ping":
                return {"id": rid, "ok": True, "result": {"pong": True, "ax": True, "hid": True}}
            if cmd == "info":
                return {"id": rid, "ok": True, "result": {
                    "model": "iPhone12,1", "iosVersion": "16.6.1",
                    "screen": {"width": 414, "height": 896},
                    "frontmost": {"bundleId": "com.apple.Preferences", "pid": 1234}}}
            if cmd == "dump":
                return {"id": rid, "ok": True, "result": {
                    "nodes": NODES, "root": 0, "nodeCount": len(NODES), "generation": 1,
                    "screen": {"width": 414, "height": 896}}}
            if cmd in ("find", "wait"):
                text = (req.get("text") or "").lower()
                role = req.get("role")
                hits = []
                for n in NODES:
                    if role and n.get("role") != role:
                        continue
                    hay = " ".join(str(n.get(k, "")) for k in ("label", "title", "value", "id", "placeholder"))
                    if text and text not in hay.lower():
                        continue
                    hits.append(n)
                return {"id": rid, "ok": True, "result": {"nodes": hits[: req.get("limit", 20)]}}
            if cmd in ("tap", "tapElement", "longPress", "swipe", "scroll", "type", "setValue", "home"):
                return {"id": rid, "ok": True, "result": {"ok": True}}
            return {"id": rid, "ok": False, "error": "unknown cmd %r" % cmd}
        except Exception as exc:  # noqa: BLE001
            return {"id": rid, "ok": False, "error": str(exc)}


def main() -> int:
    daemon = FakeDaemon()
    daemon.start()
    time.sleep(0.1)

    failures = []

    def check(name, cond, detail=""):
        if cond:
            print("  ok   %s" % name)
        else:
            print("  FAIL %s %s" % (name, detail))
            failures.append(name)

    with Device("127.0.0.1", daemon.port) as d:
        check("ping", d.ping())
        info = d.info()
        check("info.model", info["model"] == "iPhone12,1", info)

        result = d.dump()
        check("dump.nodeCount", result["nodeCount"] == len(NODES))
        check("dump.root", result["root"] == 0)

        rendered = d.tree()
        check("tree contains 无线局域网", "无线局域网" in rendered)
        check("tree indents children", "\n  [1]" in rendered, repr(rendered[:400]))

        hits = d.find(text="蓝牙")
        check("find by text", len(hits) == 1 and hits[0]["label"] == "蓝牙", hits)

        check("node lookup", d.node(4)["id"] == "search-field")

        sel = d(text="无线局域网")
        check("selector exists", sel.exists)
        check("selector first id", (sel.first() or {}).get("id") == "wifi-cell")

        sel.click()
        check("selector click issued tapElement",
              daemon.received[-1]["cmd"] == "tapElement" and daemon.received[-1]["index"] == 2,
              daemon.received[-1])

        d(role="AXTextField").set_text("wifi")
        check("set_text falls back to send_keys or setValue",
              daemon.received[-1]["cmd"] in ("setValue", "type"), daemon.received[-1])

        d.click(100, 100)
        check("raw click", daemon.received[-1]["cmd"] == "tap")
        d.swipe(200, 700, 200, 200, 0.25)
        check("swipe args", daemon.received[-1]["x1"] == 200 and daemon.received[-1]["y2"] == 200)
        d.home()
        check("home", daemon.received[-1]["cmd"] == "home")

        # error propagation
        try:
            d._call("nope")
            check("unknown cmd raises", False)
        except UiBridgeError as exc:
            check("unknown cmd raises", "unknown cmd" in str(exc))

    print()
    if failures:
        print("FAILED: %d" % len(failures))
        return 1
    print("all self-tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
