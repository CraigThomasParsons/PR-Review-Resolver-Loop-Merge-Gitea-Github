#!/usr/bin/env python3
"""fake-gitea.py: loopback stand-in for the Gitea calls night_shift_gitea.py makes.

Usage: fake-gitea.py STATE_DIR TOKEN
Writes STATE_DIR/port once listening. Serves GET /api/v1/repos/O/R/issues/N from
STATE_DIR/issue.json, GET .../pulls?state=open from STATE_DIR/pulls.json (default [], paged by
the page and limit parameters), and
records every POST .../pulls body to STATE_DIR/created.jsonl, answering number 99. Every
request is appended to STATE_DIR/requests.log as "METHOD PATH authorized|unauthorized";
a request without "Authorization: token TOKEN" gets 401.
"""
import json
import os
import sys
import tempfile
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

STATE = Path(sys.argv[1])
TOKEN = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    """Answer the three endpoints from files in STATE."""

    def log_message(self, *_args: object) -> None:
        return

    def reply(self, status: int, body: object) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self) -> bool:
        ok = self.headers.get("Authorization") == "token " + TOKEN
        with (STATE / "requests.log").open("a") as log:
            log.write(f"{self.command} {self.path} {'authorized' if ok else 'unauthorized'}\n")
        if not ok:
            self.reply(401, {"message": "unauthorized"})
        return ok

    def do_GET(self) -> None:
        if not self.authorized():
            return
        path = self.path.split("?")[0]
        if "/issues/" in path:
            issue = STATE / "issue.json"
            if not issue.exists():
                self.reply(404, {"message": "not found"})
                return
            self.reply(200, json.loads(issue.read_text()))
            return
        if path.endswith("/pulls"):
            pulls = STATE / "pulls.json"
            every = json.loads(pulls.read_text()) if pulls.exists() else []
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            limit = int(query.get("limit", ["30"])[0])
            page = int(query.get("page", ["1"])[0])
            self.reply(200, every[(page - 1) * limit:page * limit])
            return
        self.reply(404, {"message": "not found"})

    def do_POST(self) -> None:
        if not self.authorized():
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        with (STATE / "created.jsonl").open("a") as created:
            created.write(json.dumps(body) + "\n")
        self.reply(201, {"number": 99, "html_url": "http://gitea.test/owner/repo/pulls/99"})


def write_atomic(path: Path, text: str) -> None:
    """Publish the port so the waiting test never reads a partial file."""
    handle, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".")
    with os.fdopen(handle, "w") as output:
        output.write(text)
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)


server = HTTPServer(("127.0.0.1", 0), Handler)
write_atomic(STATE / "port", str(server.server_address[1]))
server.serve_forever()
