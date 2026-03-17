#!/usr/bin/env python3
"""
ldx-ctl — Remote control for ldx containers.

Talks to the control socket inside a running ldx container
to manage pipe connections for migration.

Usage:
    ldx-ctl HOST:PORT status
    ldx-ctl HOST:PORT disconnect
    ldx-ctl HOST:PORT reconnect NEW_HOST:NEW_PORT
    ldx-ctl HOST:PORT suspend
    ldx-ctl HOST:PORT resume
"""

import json
import socket
import sys


def send_cmd(host, port, cmd_obj):
    """Send a JSON command and receive the response."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(10)
    try:
        sock.connect((host, port))
        msg = json.dumps(cmd_obj) + "\n"
        sock.sendall(msg.encode())

        # Receive response (one line).
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk

        resp = data.decode().strip()
        return json.loads(resp) if resp else {"ok": False, "error": "no response"}
    except ConnectionRefusedError:
        return {"ok": False, "error": f"connection refused to {host}:{port}"}
    except socket.timeout:
        return {"ok": False, "error": "timeout"}
    except Exception as e:
        return {"ok": False, "error": str(e)}
    finally:
        sock.close()


def parse_host_port(s):
    """Parse 'host:port' string."""
    if ":" not in s:
        return s, 9800  # default port
    parts = s.rsplit(":", 1)
    return parts[0], int(parts[1])


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip())
        sys.exit(1)

    target = sys.argv[1]
    command = sys.argv[2]
    host, port = parse_host_port(target)

    if command == "status":
        resp = send_cmd(host, port, {"cmd": "status"})
    elif command == "disconnect":
        resp = send_cmd(host, port, {"cmd": "disconnect"})
    elif command == "reconnect":
        if len(sys.argv) < 4:
            print("Usage: ldx-ctl HOST:PORT reconnect NEW_HOST:NEW_PORT")
            sys.exit(1)
        new_host, new_port = parse_host_port(sys.argv[3])
        resp = send_cmd(host, port, {
            "cmd": "reconnect",
            "host": new_host,
            "port": new_port,
        })
    elif command == "suspend":
        resp = send_cmd(host, port, {"cmd": "suspend"})
    elif command == "resume":
        resp = send_cmd(host, port, {"cmd": "resume"})
    else:
        print(f"Unknown command: {command}")
        sys.exit(1)

    # Pretty-print response.
    print(json.dumps(resp, indent=2))

    if not resp.get("ok"):
        sys.exit(1)


if __name__ == "__main__":
    main()
