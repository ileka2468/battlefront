"""Exercise the Companion's signup and DCS proof flow on loopback only."""

from contextlib import closing, contextmanager
from http.cookies import SimpleCookie
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.error import URLError

from cloud import render_gateway
from scripts.verify_production_workspace import Browser
from server.persistence import workspace_store


ROOT = Path(__file__).resolve().parents[1]
SIGNUP = "/api/workspace/signup"
START = "/api/dcs/link/start"
FINISH = "/api/dcs/link/finish"
DELIVER = "/api/dcs/deliver"
APPROVED_UCID = "a1" * 16
OTHER_UCID = "b2" * 16
PASSWORD = "fixture passphrase only"


class WorkspacePairingHTTP(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="battlefront-pair-http-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.db = self.root / "workspace.sqlite3"
        self.spool, self.lane = self.root / "pairing", self.root / "delivery"
        self.spool.mkdir(mode=0o700)
        self.lane.mkdir(mode=0o700)
        self.approved = self.root / "pilot.ucid"
        self.approved.write_bytes((APPROVED_UCID + "\n").encode("ascii"))
        self.approved.chmod(0o600)

    @contextmanager
    def daemon(self):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        origin = f"http://127.0.0.1:{port}"
        env = {key: value for key, value in os.environ.items() if not key.startswith(("BF_", "DCS_"))}
        env.update({
            "PORT": str(port), "BF_WORKSPACE": "1", "BF_BIND": "127.0.0.1",
            "BF_WORKSPACE_ORIGIN": origin, "BF_WORKSPACE_DB": str(self.db),
            "BF_LIVE_CAMPAIGN_ONLY": "1", "BF_DCS_LINK_DIR": str(self.spool),
            "BF_DCS_DELIVERY_DIR": str(self.lane), "BF_DCS_DELIVERY_AIRFIELD": "Vaziani",
            "BF_DCS_DELIVERY_LINK_PILOT_FILE": str(self.approved), "BF_DCS_LINK_DEMO_MERITS": "25",
        })
        log = self.root / "server.log"
        with log.open("ab") as stream:
            proc = subprocess.Popen([sys.executable, "-B", str(ROOT / "web/server.py")],
                                    env=env, cwd=ROOT, stdout=stream, stderr=stream)
            try:
                for _ in range(100):
                    if proc.poll() is not None:
                        self.fail(log.read_text(errors="replace"))
                    try:
                        Browser(origin).get("/healthz")
                        break
                    except URLError:
                        time.sleep(0.05)
                else:
                    self.fail("Loopback Companion did not start")
                yield origin
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=5)

    def signup(self, browser, name, **extras):
        _, response, headers = browser.post(SIGNUP, {"username": name, "password": PASSWORD, **extras})
        self.assertEqual(response, {"success": True})
        cookie = SimpleCookie(headers["Set-Cookie"])["bf_workspace"]
        self.assertTrue(cookie["httponly"])
        self.assertEqual(cookie["samesite"], "Strict")
        state = browser.state()
        browser.csrf = state["workspace"]["csrf"]
        self.assertTrue(state["workspace"]["authenticated"])
        self.assertTrue(state["workspace"]["link_required"])
        self.assertIsNone(state["workspace"]["player_id"])
        self.assertNotIn("delivery", state)
        self.assertTrue(all("inventory" not in player for player in state["players"].values()))
        return state

    def start(self, browser):
        status, body, headers = browser.post(START, {})
        self.assertEqual(status, 200)
        self.assertEqual(headers["Cache-Control"], "no-store")
        code = body["code"]
        self.assertRegex(code, r"^[A-Z2-7]{12}$")
        self.assertGreater(body["expires"], int(time.time()))
        return code

    def publish_native_fixture(self, code, ucid, side):
        path = self.spool / (code + ".pair")
        scratch = path.with_suffix(".pair.tmp")
        scratch.write_bytes(f"BFPAIR1 {code} {ucid} {side}\n".encode("ascii"))
        scratch.replace(path)
        return path

    def test_signup_pairing_preserves_authority_and_does_not_dispatch(self):
        for route in (SIGNUP, START, FINISH):
            self.assertIn(route, render_gateway.WRITE)
            self.assertNotIn(route, render_gateway.READ | render_gateway.STATIC)

        with self.daemon() as origin:
            guest, approved, other = (Browser(origin) for _ in range(3))
            self.assertTrue(guest.state()["workspace"]["signup_enabled"])
            self.assertFalse(guest.state()["workspace"]["authenticated"])
            guest.post(SIGNUP, {"username": "wrong-origin", "password": PASSWORD},
                       headers={"Origin": "https://unrelated.invalid"}, expected=403)
            guest.post(START, {}, expected=401)
            guest.post(FINISH, {"code": "ABCDEFGHIJKL"}, expected=401)

            unlinked = self.signup(approved, "eligible-pilot", side=2, ucid=APPROVED_UCID, merits=25)
            self.assertEqual(unlinked["players"], {})
            self.signup(other, "other-pilot")
            approved.post("/api/requisition", {"munition": "AIM-120D"}, expected=403)
            approved.post(START, {}, csrf=False, expected=403)
            approved.post(START, {}, headers={"Sec-Fetch-Site": "cross-site"}, expected=403)
            code = self.start(approved)
            approved.post(FINISH, {"code": code}, csrf=False, expected=403)
            approved.post(FINISH, {"code": "NOT-A-CODE"}, expected=400)
            self.assertEqual(approved.post(FINISH, {"code": code})[1]["status"], "waiting")
            # Only a trusted native proof file can create the linkage; the web
            # body cannot supply any part of the identity, side or award.
            receipt = self.publish_native_fixture(code, APPROVED_UCID, 2)
            other.post(FINISH, {"code": code}, expected=409)
            self.assertTrue(receipt.is_file())
            (self.lane / workspace_store.DELIVERY_CAPABILITY).write_bytes(b"BF3 VIPER_D_READY VAZIANI\n")
            self.assertEqual(approved.post(FINISH, {"code": code.lower(), "side": 1})[1]["status"], "linked")
            self.assertFalse(receipt.exists())
            state = approved.state()
            actor = state["workspace"]["player_id"]
            self.assertRegex(actor, r"^acct_[0-9a-f]{32}$")
            self.assertEqual(state["players"][actor]["side"], 2)
            self.assertEqual(state["players"][actor]["points"], 25)
            self.assertEqual(state["players"][actor]["inventory"], {})
            self.assertEqual(state["delivery"]["status"], "idle")
            self.assertEqual(state["delivery"]["airfield"], "Vaziani")
            self.assertFalse(state["workspace"]["can_command"])
            self.assertNotIn(APPROVED_UCID, json.dumps(state))
            self.assertNotIn("points", guest.state()["players"][actor])
            approved.post(FINISH, {"code": code}, expected=409)
            approved.post(DELIVER, {"munition": "AIM-120D"}, expected=409)

            expired = self.start(other)
            with closing(sqlite3.connect(self.db)) as conn, conn:
                conn.execute("UPDATE workspace_pairing SET issued=0, expires=0")
            other.post(FINISH, {"code": expired}, expected=410)
            other_code = self.start(other)
            self.publish_native_fixture(other_code, OTHER_UCID, 2)
            self.assertEqual(other.post(FINISH, {"code": other_code})[1]["status"], "linked")
            other_state = other.state()
            other_actor = other_state["workspace"]["player_id"]
            self.assertNotEqual(other_actor, actor)
            self.assertEqual(other_state["players"][other_actor]["side"], 2)
            self.assertEqual(other_state["players"][other_actor]["points"], 0)
            self.assertNotIn("points", other_state["players"][actor])
            self.assertNotIn("delivery", other_state)
            other.post(DELIVER, {"munition": "AIM-120D"}, expected=403)
            self.assertEqual(Browser(origin).login("eligible-pilot", PASSWORD), actor)

        self.assertEqual({file.name for file in self.lane.iterdir()}, {workspace_store.DELIVERY_CAPABILITY})
        with closing(sqlite3.connect(self.db)) as conn:
            linkage = conn.execute("SELECT side, dcs_owner FROM workspace_signups WHERE id=?", (actor,)).fetchone()
            self.assertEqual(linkage, (2, workspace_store.native_owner(APPROVED_UCID.encode("ascii"))))
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM workspace_ledger WHERE action='delivery_escrow'").fetchone(), (0,))
