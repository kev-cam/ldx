#!/usr/bin/env python3
"""
ldx-controller — Orchestrate sharded application containers.

Tracks containers (shards), their placement on hardware nodes,
function ownership, and inter-shard pipe routes.

Usage:
    ldx-controller [--port PORT] [--config topology.json]

REST API (JSON over HTTP):
    GET  /topology              — full topology dump
    GET  /nodes                 — list nodes
    POST /nodes                 — add node {name, host, port, cores, memory_mb, arch}
    GET  /shards                — list shards
    POST /shards                — add shard {name}
    POST /shards/:id/place      — place shard on node {node_id}
    POST /shards/:id/start      — start shard
    POST /shards/:id/stop       — stop shard
    POST /shards/:id/migrate    — migrate shard to new node {node_id}
    GET  /functions             — list functions
    POST /functions             — register function {name, owner_shard_id}
    POST /functions/:id/move    — move function to different shard {shard_id}
    GET  /routes                — list routes
    POST /routes                — add route {from_shard, to_shard, type, host, port}
    POST /routes/resolve/:id    — resolve routes for shard
"""

import json
import socket
import sys
import os
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs


class Topology:
    """In-memory topology state."""

    def __init__(self):
        self.nodes = []
        self.shards = []
        self.functions = []
        self.routes = []
        self.lock = threading.Lock()

    def add_node(self, name, host, port=22, cores=0, memory_mb=0, arch="x86_64"):
        with self.lock:
            nid = len(self.nodes)
            self.nodes.append({
                "id": nid, "name": name, "host": host, "port": port,
                "cores": cores, "memory_mb": memory_mb, "arch": arch,
                "shards": 0,
            })
            return nid

    def add_shard(self, name):
        with self.lock:
            sid = len(self.shards)
            self.shards.append({
                "id": sid, "name": name, "node_id": -1, "state": "stopped",
                "host": "", "control_port": 0, "pipe_port": 0,
                "functions": [],
            })
            return sid

    def place_shard(self, shard_id, node_id):
        with self.lock:
            s = self.shards[shard_id]
            if s["node_id"] >= 0:
                self.nodes[s["node_id"]]["shards"] -= 1
            s["node_id"] = node_id
            n = self.nodes[node_id]
            s["host"] = n["host"]
            n["shards"] += 1

    def add_function(self, name, owner_shard_id):
        with self.lock:
            fid = len(self.functions)
            self.functions.append({
                "id": fid, "name": name, "owner": owner_shard_id,
            })
            self.shards[owner_shard_id]["functions"].append(fid)
            return fid

    def move_function(self, func_id, new_shard_id):
        with self.lock:
            f = self.functions[func_id]
            old = f["owner"]
            if func_id in self.shards[old]["functions"]:
                self.shards[old]["functions"].remove(func_id)
            f["owner"] = new_shard_id
            self.shards[new_shard_id]["functions"].append(func_id)

    def add_route(self, from_shard, to_shard, route_type="function",
                  host="", port=0):
        with self.lock:
            rid = len(self.routes)
            self.routes.append({
                "id": rid, "from": from_shard, "to": to_shard,
                "type": route_type, "host": host, "port": port,
                "active": False, "calls": 0, "latency_ms": 0,
            })
            return rid

    def resolve_routes(self, shard_id):
        """Resolve route destinations from shard placement."""
        with self.lock:
            count = 0
            for r in self.routes:
                if r["from"] == shard_id and r["to"] >= 0:
                    dest = self.shards[r["to"]]
                    if dest["host"]:
                        r["host"] = dest["host"]
                        r["port"] = dest.get("pipe_port", 0)
                        count += 1
            return count

    def migrate_shard(self, shard_id, new_node_id):
        """Migrate shard to new node: disconnect, re-place, resolve."""
        with self.lock:
            s = self.shards[shard_id]
            s["state"] = "migrating"

            # Disconnect routes
            for r in self.routes:
                if r["from"] == shard_id or r["to"] == shard_id:
                    r["active"] = False

        # Re-place (acquires lock internally)
        self.place_shard(shard_id, new_node_id)

        with self.lock:
            s = self.shards[shard_id]
            # Update routes pointing to this shard
            for r in self.routes:
                if r["to"] == shard_id:
                    r["host"] = s["host"]

        self.resolve_routes(shard_id)

    def send_control(self, shard_id, cmd_obj):
        """Send a control command to a shard's control socket."""
        s = self.shards[shard_id]
        host = s["host"]
        port = s["control_port"]
        if not host or not port:
            return {"ok": False, "error": "no control socket"}

        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(10)
            sock.connect((host, port))
            msg = json.dumps(cmd_obj) + "\n"
            sock.sendall(msg.encode())
            data = b""
            while b"\n" not in data:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
            sock.close()
            return json.loads(data.decode().strip()) if data else {"ok": False}
        except Exception as e:
            return {"ok": False, "error": str(e)}

    def to_dict(self):
        with self.lock:
            return {
                "nodes": list(self.nodes),
                "shards": list(self.shards),
                "functions": list(self.functions),
                "routes": list(self.routes),
            }

    def load(self, data):
        with self.lock:
            self.nodes = data.get("nodes", [])
            self.shards = data.get("shards", [])
            self.functions = data.get("functions", [])
            self.routes = data.get("routes", [])


# Global topology
topo = Topology()


class ControllerHandler(BaseHTTPRequestHandler):
    """HTTP handler for the controller API."""

    def log_message(self, fmt, *args):
        sys.stderr.write(f"ldx-controller: {fmt % args}\n")

    def _send_json(self, obj, code=200):
        body = json.dumps(obj, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length))

    def _path_parts(self):
        return [p for p in self.path.split("/") if p]

    def do_GET(self):
        parts = self._path_parts()

        if not parts or parts[0] == "topology":
            self._send_json(topo.to_dict())
        elif parts[0] == "nodes":
            self._send_json(topo.nodes)
        elif parts[0] == "shards":
            self._send_json(topo.shards)
        elif parts[0] == "functions":
            self._send_json(topo.functions)
        elif parts[0] == "routes":
            self._send_json(topo.routes)
        else:
            self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        parts = self._path_parts()
        data = self._read_json()

        if parts == ["nodes"]:
            nid = topo.add_node(
                data["name"], data["host"],
                data.get("port", 22),
                data.get("cores", 0),
                data.get("memory_mb", 0),
                data.get("arch", "x86_64"),
            )
            self._send_json({"ok": True, "id": nid})

        elif parts == ["shards"]:
            sid = topo.add_shard(data["name"])
            self._send_json({"ok": True, "id": sid})

        elif len(parts) == 3 and parts[0] == "shards" and parts[2] == "place":
            topo.place_shard(int(parts[1]), data["node_id"])
            self._send_json({"ok": True})

        elif len(parts) == 3 and parts[0] == "shards" and parts[2] == "migrate":
            topo.migrate_shard(int(parts[1]), data["node_id"])
            self._send_json({"ok": True})

        elif len(parts) == 3 and parts[0] == "shards" and parts[2] == "control":
            resp = topo.send_control(int(parts[1]), data)
            self._send_json(resp)

        elif parts == ["functions"]:
            fid = topo.add_function(data["name"], data["owner_shard_id"])
            self._send_json({"ok": True, "id": fid})

        elif len(parts) == 3 and parts[0] == "functions" and parts[2] == "move":
            topo.move_function(int(parts[1]), data["shard_id"])
            self._send_json({"ok": True})

        elif parts == ["routes"]:
            rid = topo.add_route(
                data["from_shard"], data.get("to_shard", -1),
                data.get("type", "function"),
                data.get("host", ""), data.get("port", 0),
            )
            self._send_json({"ok": True, "id": rid})

        elif len(parts) == 3 and parts[0] == "routes" and parts[1] == "resolve":
            n = topo.resolve_routes(int(parts[2]))
            self._send_json({"ok": True, "resolved": n})

        elif parts == ["save"]:
            path = data.get("path", "topology.json")
            with open(path, "w") as f:
                json.dump(topo.to_dict(), f, indent=2)
            self._send_json({"ok": True, "path": path})

        elif parts == ["load"]:
            path = data.get("path", "topology.json")
            with open(path) as f:
                topo.load(json.load(f))
            self._send_json({"ok": True})

        else:
            self._send_json({"error": "not found"}, 404)


def main():
    port = 9900
    config_file = None

    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--port" and i + 1 < len(args):
            port = int(args[i + 1])
            i += 2
        elif args[i] == "--config" and i + 1 < len(args):
            config_file = args[i + 1]
            i += 2
        else:
            i += 1

    if config_file and os.path.exists(config_file):
        with open(config_file) as f:
            topo.load(json.load(f))
        print(f"Loaded topology from {config_file}", file=sys.stderr)

    server = HTTPServer(("0.0.0.0", port), ControllerHandler)
    print(f"ldx-controller: listening on port {port}", file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
