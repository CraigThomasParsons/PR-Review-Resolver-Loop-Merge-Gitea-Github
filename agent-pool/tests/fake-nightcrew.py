#!/usr/bin/env python3
"""fake-nightcrew.py SCENARIO REQUEST_LOG PORT_FILE

A loopback-only stand-in for TheNightCrew's API, for offline tests. Binds 127.0.0.1 on an
ephemeral port and writes the port to PORT_FILE once listening. Every GET is appended to
REQUEST_LOG as one JSON line (path, Authorization, Accept), then answered from SCENARIO, a JSON
file re-read per request so a test can change the answer between calls:

    {"status": 200, "body": "...", "delay": 0, "headers": {"Location": "..."}}

No SCENARIO file means a 404.
"""
from __future__ import annotations

import http.server
import json
import os
import sys
import time


def main() -> int:
    scenario_path, log_path, port_path = sys.argv[1:4]

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            with open(log_path, "a", encoding="utf-8") as log:
                log.write(json.dumps({"path": self.path,
                                      "authorization": self.headers.get("Authorization", ""),
                                      "accept": self.headers.get("Accept", "")}) + "\n")
            scenario: dict = {"status": 404, "body": ""}
            if os.path.exists(scenario_path):
                with open(scenario_path, encoding="utf-8") as handle:
                    scenario = json.load(handle)
            time.sleep(float(scenario.get("delay", 0)))
            body = str(scenario.get("body", "")).encode("utf-8")
            try:
                self.send_response(int(scenario.get("status", 200)))
                for name, value in scenario.get("headers", {}).items():
                    self.send_header(name, value)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, format: str, *args: object) -> None:
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    staging = port_path + ".tmp"
    with open(staging, "w", encoding="utf-8") as handle:
        handle.write(str(server.server_address[1]))
    os.replace(staging, port_path)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
