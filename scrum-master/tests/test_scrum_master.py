"""Offline tests for scrum_master.py: a fake Gitea and a fake Slack on localhost, and a
throwaway NightCrew-shaped SQLite file. Nothing here touches the real Gitea, Slack or
NightCrew. Run: python3 -m unittest discover -s scrum-master/tests -v
"""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import sqlite3
import sys
import tempfile
import threading
import unittest
import urllib.parse
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("scrum_master", HERE.parent / "scrum_master.py")
sm = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["scrum_master"] = sm
SPEC.loader.exec_module(sm)

CRAIG = "U046V73R3LN"
LAN = "http://127.0.0.1"  # replaced with the fake server's base in setUp
TAILNET = "http://ubuntu-2404.tail99f840.ts.net:3000"
NOW = 1794904000.0  # 2026-11-17T08:26:40Z


class World:
    """The state behind both fakes, plus a log of every request."""

    def __init__(self) -> None:
        self.prs: dict[tuple[str, int], dict[str, Any]] = {}
        self.comments: dict[tuple[str, int], list[dict[str, Any]]] = {}
        self.slack_posts: list[dict[str, str]] = []
        self.threads: dict[str, list[dict[str, Any]]] = {}
        self.requests: list[tuple[str, str]] = []
        self.ts = 1795000000

    def add_pr(self, repo: str, number: int, head: str, labels: list[str],
               author: str = "codex-bot", title: str = "Fix the thing") -> None:
        self.prs[(repo, number)] = {"number": number, "title": title, "state": "open",
                                    "head": {"sha": head, "ref": "feature/x"},
                                    "base": {"ref": "develop"}, "user": {"login": author},
                                    "labels": [{"name": l} for l in labels],
                                    "repository": {"full_name": repo}}


def make_handler(world: World):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args: Any) -> None:
            pass

        def send(self, code: int, body: Any) -> None:
            raw = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self) -> None:
            world.requests.append(("GET", self.path))
            url = urllib.parse.urlsplit(self.path)
            q = dict(urllib.parse.parse_qsl(url.query))
            parts = url.path.split("/")
            if self.headers.get("Authorization") != "token gitea-test-token":
                return self.send(401, {"message": "no"})
            if url.path == "/api/v1/repos/issues/search":
                if q.get("page", "1") != "1":
                    return self.send(200, [])
                hits = [pr for pr in world.prs.values()
                        if q.get("labels") in [l["name"] for l in pr["labels"]]]
                return self.send(200, hits)
            if len(parts) == 8 and parts[6] == "pulls":
                pr = world.prs.get((f"{parts[4]}/{parts[5]}", int(parts[7])))
                return self.send(200, pr) if pr else self.send(404, {})
            if len(parts) == 9 and parts[8] == "comments":
                key = (f"{parts[4]}/{parts[5]}", int(parts[7]))
                return self.send(200, world.comments.get(key, []) if q.get("page", "1") == "1" else [])
            self.send(404, {})

        def do_POST(self) -> None:
            world.requests.append(("POST", self.path))
            raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
            if self.path.startswith("/slack/"):
                if self.headers.get("Authorization") != "Bearer xoxb-test":
                    return self.send(200, {"ok": False, "error": "invalid_auth"})
                form = dict(urllib.parse.parse_qsl(raw))
                method = self.path[len("/slack/"):]
                if method == "conversations.open":
                    return self.send(200, {"ok": True, "channel": {"id": "D0CRAIG"}})
                if method == "chat.postMessage":
                    world.ts += 1
                    ts = f"{world.ts}.000100"
                    world.slack_posts.append({"channel": form["channel"], "text": form["text"], "ts": ts})
                    world.threads[ts] = [{"ts": ts, "bot_id": "B1", "text": form["text"]}]
                    return self.send(200, {"ok": True, "ts": ts})
                if method == "conversations.replies":
                    return self.send(200, {"ok": True, "messages": world.threads.get(form["ts"], [])})
                return self.send(200, {"ok": False, "error": "unknown_method"})
            parts = self.path.split("/")
            if len(parts) == 9 and parts[6] == "issues" and parts[8] == "comments":
                key = (f"{parts[4]}/{parts[5]}", int(parts[7]))
                world.comments.setdefault(key, []).append({"body": json.loads(raw)["body"]})
                return self.send(201, {"id": len(world.comments[key])})
            self.send(404, {})

        do_PUT = do_PATCH = do_DELETE = lambda self: (  # noqa: E731
            world.requests.append((self.command, self.path)), self.send(405, {}))
    return Handler


def make_nightcrew(path: Path, rows: list[dict[str, Any]]) -> None:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""CREATE TABLE night_crew_jobs (id integer primary key, repo varchar not null,
        kind varchar not null, reference varchar, status varchar not null default 'queued',
        attempt integer not null default 0, consecutive_failures integer not null default 0,
        last_failure_reason text, last_failed_at datetime, needs_human_at datetime,
        lease_expires_at datetime, last_heartbeat_at datetime, claimed_at datetime,
        claimed_by text, worker_id varchar, parked_reason varchar, resets_at datetime,
        payload text, updated_at datetime)""")
    for row in rows:
        cols = ", ".join(row)
        conn.execute(f"INSERT INTO night_crew_jobs ({cols}) VALUES ({', '.join('?' for _ in row)})",
                     list(row.values()))
    conn.commit()
    conn.close()


class ScrumMasterTest(unittest.TestCase):
    def setUp(self) -> None:
        self.world = World()
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.world))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.tmp = Path(tempfile.mkdtemp(prefix="hsm-test-"))
        self.db = self.tmp / "nightcrew.sqlite"
        make_nightcrew(self.db, [])
        (self.tmp / "gitea_token").write_text("gitea-test-token\n")
        (self.tmp / "slack_token").write_text("xoxb-test\n")
        self.config = self.tmp / "config.toml"
        self.write_config()
        self.env = {"HSM_STATE": str(self.tmp / "state"), "HSM_SLACK_API": self.base + "/slack",
                    "HSM_NOW": str(NOW), "GITEA_TOKEN": "", "SLACK_BOT_TOKEN": "",
                    "HSM_DRY_RUN": ""}
        self.saved = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def write_config(self, extra: str = "") -> None:
        self.config.write_text(f"""
[gitea]
api_base = "{self.base if hasattr(self, 'base') else LAN}"
public_base = "{TAILNET}"
token_file = "{self.tmp / 'gitea_token'}"

[nightcrew]
db_path = "{self.db}"
stuck_after_minutes = 60

[slack]
token_file = "{self.tmp / 'slack_token'}"
craig_user_id = "{CRAIG}"

[relay.mentions]
"agent:needs-human" = "@doctor"
{extra}
""")

    def tick(self, *args: str) -> tuple[int, dict[str, Any], str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = sm.main(["tick", "--config", str(self.config), *args])
        text = out.getvalue()
        return rc, (json.loads(text) if text.strip().startswith("{") else {}), err.getvalue()

    def reply(self, post_index: int, text: str, user: str = CRAIG, **extra: Any) -> str:
        post = self.world.slack_posts[post_index]
        self.world.ts += 1
        ts = f"{self.world.ts}.000200"
        self.world.threads[post["ts"]].append({"ts": ts, "user": user, "text": text, **extra})
        return ts

    def writes(self) -> list[tuple[str, str]]:
        return [r for r in self.world.requests if r[0] != "GET" and not r[1].startswith("/slack/")]

    # ---------------------------------------------------------------- asking

    def test_asks_decision_first_with_lettered_options_and_tailscale_link(self) -> None:
        self.world.add_pr("ElasticGun/feudal-frontiers", 183, "abc123def456", ["review:needs-human"])
        rc, report, _ = self.tick()
        self.assertEqual(rc, 0, report)
        self.assertEqual(len(self.world.slack_posts), 1)
        post = self.world.slack_posts[0]
        self.assertEqual(post["channel"], "D0CRAIG")
        lines = post["text"].splitlines()
        self.assertTrue(lines[0].startswith("*Decision needed:*"))
        self.assertIn("ElasticGun/feudal-frontiers PR #183", lines[0])
        option_lines = [l for l in lines if len(l) > 2 and l[1] == ")"]
        self.assertEqual([l[0] for l in option_lines], ["a", "b", "c", "d", "e"])
        self.assertIn(f"{TAILNET}/ElasticGun/feudal-frontiers/pulls/183", post["text"])
        self.assertNotIn("127.0.0.1", post["text"])
        self.assertNotIn("192.168.2.48", post["text"])
        self.assertLess(post["text"].index("Decision"), post["text"].index("a)"))
        self.assertLess(post["text"].index("a)"), post["text"].index(TAILNET))

    def test_does_not_re_ask_until_the_item_changes(self) -> None:
        self.world.add_pr("ElasticGun/x", 5, "sha-one", ["agent:needs-human"])
        self.tick()
        self.tick()
        self.assertEqual(len(self.world.slack_posts), 1, "same fingerprint must not re-ask")
        self.world.prs[("ElasticGun/x", 5)]["head"]["sha"] = "sha-two"
        self.tick()
        self.assertEqual(len(self.world.slack_posts), 2, "a new head is a new question")
        self.tick()
        self.assertEqual(len(self.world.slack_posts), 2)

    def test_unrelated_label_churn_does_not_re_ask(self) -> None:
        self.world.add_pr("ElasticGun/x", 5, "sha-one", ["agent:needs-human", "night:hold"])
        self.tick()
        self.world.prs[("ElasticGun/x", 5)]["labels"] = [{"name": "agent:needs-human"}]
        self.tick()
        self.assertEqual(len(self.world.slack_posts), 1)

    def test_caps_new_questions_per_tick(self) -> None:
        for n in range(1, 8):
            self.world.add_pr("ElasticGun/x", n, f"sha{n}", ["review:needs-human"])
        _, report, _ = self.tick()
        self.assertEqual(len(self.world.slack_posts), 5)
        self.assertEqual(len(report["deferred"]), 2)
        self.tick()
        self.assertEqual(len(self.world.slack_posts), 7)

    # ---------------------------------------------------------------- relaying

    def test_relays_craigs_exact_words_once(self) -> None:
        self.world.add_pr("ElasticGun/x", 9, "sha9", ["agent:needs-human"])
        self.tick()
        words = "b) give it to Clyde & tell him <not> to touch master"
        self.reply(0, words.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
        rc, report, _ = self.tick()
        self.assertEqual(rc, 0, report)
        comments = self.world.comments[("ElasticGun/x", 9)]
        self.assertEqual(len(comments), 1)
        body = comments[0]["body"]
        self.assertIn("> " + words, body)
        self.assertTrue(body.splitlines()[1].startswith("@doctor Craig answered"))
        self.assertIn(sm.MARKER, body)
        self.tick()
        self.tick()
        self.assertEqual(len(self.world.comments[("ElasticGun/x", 9)]), 1)

    def test_only_craigs_own_human_reply_counts(self) -> None:
        self.world.add_pr("ElasticGun/x", 9, "sha9", ["review:needs-human"], author="codex-bot")
        self.tick()
        self.reply(0, "a) approved, merge it", user="U0SOMEONEELSE")
        self.reply(0, "a) approved", user=CRAIG, bot_id="B99")
        self.reply(0, "a) approved", user=CRAIG, subtype="bot_message")
        self.tick()
        self.assertNotIn(("ElasticGun/x", 9), self.world.comments)
        self.reply(0, "c) hold it, I'll look tonight")
        self.tick()
        body = self.world.comments[("ElasticGun/x", 9)][0]["body"]
        self.assertIn("> c) hold it, I'll look tonight", body)
        self.assertIn("@codex-bot Craig answered", body)
        self.assertNotIn("merge it", body)

    def test_relay_survives_a_crash_after_posting(self) -> None:
        self.world.add_pr("ElasticGun/x", 9, "sha9", ["agent:needs-human"])
        self.tick()
        self.reply(0, "a")
        self.tick()
        state_path = self.tmp / "state" / "state.json"
        state = json.loads(state_path.read_text())
        for q in state["questions"]:
            q.pop("relayed_at", None)  # as if the tick died after the POST
        state_path.write_text(json.dumps(state))
        self.tick()
        self.assertEqual(len(self.world.comments[("ElasticGun/x", 9)]), 1)

    def test_the_only_gitea_write_is_a_comment(self) -> None:
        self.world.add_pr("ElasticGun/x", 9, "sha9", ["agent:needs-human"])
        self.tick()
        self.reply(0, "merge it now")
        self.tick()
        self.assertEqual(self.writes(), [("POST", "/api/v1/repos/ElasticGun/x/issues/9/comments")])
        gitea = sm.Gitea(self.base, TAILNET, "gitea-test-token")
        with self.assertRaises(sm.RefusedWrite):
            gitea.post_comment("ElasticGun/x/../../admin", 1, "x")
        self.assertFalse(hasattr(gitea, "merge"))
        source = (HERE.parent / "scrum_master.py").read_text()
        self.assertNotIn("claim-next", source.replace("POST /claim-next above all", ""))

    def test_writes_a_hand_back_log(self) -> None:
        self.world.add_pr("ElasticGun/x", 9, "sha9", ["agent:needs-human"])
        self.tick()
        self.reply(0, "a")
        self.tick()
        out = io.StringIO()
        with redirect_stdout(out):
            sm.main(["log", "--config", str(self.config)])
        events = [json.loads(l)["event"] for l in out.getvalue().splitlines()]
        self.assertEqual(events, ["asked", "relayed"])

    # ---------------------------------------------------------------- NightCrew

    def nightcrew_rows(self) -> list[dict[str, Any]]:
        return [
            {"id": 86, "repo": "ElasticGun/AMPB-API", "kind": "issue", "reference": "#20",
             "status": "failed", "attempt": 17, "consecutive_failures": 1,
             "last_failure_reason": "exit_code_2", "last_failed_at": "2026-11-13 14:08:00",
             "payload": json.dumps({"title": "systemd unit",
                                    "url": "http://192.168.2.48:3000/ElasticGun/AMPB-API/issues/20"})},
            {"id": 90, "repo": "ElasticGun/AMPB-API", "kind": "issue", "reference": "#21",
             "status": "running", "attempt": 1, "claimed_at": "2026-11-17 05:00:00",
             "last_heartbeat_at": "2026-11-17 05:10:00", "lease_expires_at": "2026-11-17 05:40:00",
             "claimed_by": "codex"},
            {"id": 91, "repo": "ElasticGun/AMPB-API", "kind": "issue", "reference": "#22",
             "status": "running", "attempt": 1, "claimed_at": "2026-11-17 08:20:00",
             "last_heartbeat_at": "2026-11-17 08:25:00", "lease_expires_at": "2026-11-17 08:55:00"},
            {"id": 92, "repo": "ElasticGun/AMPB-API", "kind": "maintenance", "reference": None,
             "status": "done", "attempt": 3},
        ]

    def test_nightcrew_failed_and_stuck_jobs_are_asked_about(self) -> None:
        self.db.unlink()
        make_nightcrew(self.db, self.nightcrew_rows())
        self.tick()
        texts = [p["text"] for p in self.world.slack_posts]
        self.assertEqual(len(texts), 2, texts)
        failed = next(t for t in texts if "job 86" in t)
        self.assertIn("failed (exit_code_2) after 17 attempt(s)", failed)
        self.assertIn(f"{TAILNET}/ElasticGun/AMPB-API/issues/20", failed)
        self.assertNotIn("192.168.2.48", failed)
        stuck = next(t for t in texts if "job 90" in t)
        self.assertIn("looks stuck", stuck)
        self.tick()
        self.assertEqual(len(self.world.slack_posts), 2)
        self.reply(texts.index(failed), "a) requeue it")
        self.tick()
        body = self.world.comments[("ElasticGun/AMPB-API", 20)][0]["body"]
        self.assertIn("> a) requeue it", body)

    def test_nightcrew_db_is_never_written(self) -> None:
        self.db.unlink()
        make_nightcrew(self.db, self.nightcrew_rows())
        before = hashlib.sha256(self.db.read_bytes()).hexdigest()
        self.tick()
        self.reply(0, "a")
        self.tick()
        self.assertEqual(hashlib.sha256(self.db.read_bytes()).hexdigest(), before)
        conn = sm.open_nightcrew(self.db)
        with self.assertRaises(sqlite3.OperationalError):
            conn.execute("UPDATE night_crew_jobs SET status = 'queued'")
        conn.close()

    def test_ignore_failed_before_skips_old_failures(self) -> None:
        self.db.unlink()
        make_nightcrew(self.db, self.nightcrew_rows()[:1])
        self.config.write_text(self.config.read_text().replace(
            "stuck_after_minutes = 60", 'stuck_after_minutes = 60\nignore_failed_before = "2026-11-14"'))
        self.tick()
        self.assertEqual(self.world.slack_posts, [])

    # ---------------------------------------------------------------- setup and dry run

    def test_dry_run_sends_and_saves_nothing(self) -> None:
        self.world.add_pr("ElasticGun/x", 9, "sha9", ["agent:needs-human"])
        rc, report, err = self.tick("--dry-run")
        self.assertEqual(rc, 0)
        self.assertEqual(self.world.slack_posts, [])
        self.assertEqual(self.writes(), [])
        self.assertIn("would DM Craig", err)
        self.assertFalse((self.tmp / "state" / "state.json").exists())

    def test_missing_slack_token_is_an_unusable_setup(self) -> None:
        (self.tmp / "slack_token").unlink()
        rc, _, err = self.tick()
        self.assertEqual(rc, 2)
        self.assertIn("Slack bot token", err)
        self.assertNotIn("xoxb", err)

    def test_craig_user_id_is_required(self) -> None:
        self.config.write_text(self.config.read_text().replace(CRAIG, ""))
        rc, _, err = self.tick()
        self.assertEqual(rc, 2)
        self.assertIn("craig_user_id", err)

    def test_sample_config_parses(self) -> None:
        sample = HERE.parent / "config" / "config.example.toml"
        cfg = sm.load_config(str(sample))
        self.assertEqual(cfg["gitea"]["labels"], ["agent:needs-human", "review:needs-human"])
        self.assertTrue(cfg["gitea"]["public_base"].endswith(".ts.net:3000"))


if __name__ == "__main__":
    unittest.main()
