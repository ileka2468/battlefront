"""Exercise production auth, role boundaries, transfers and restart using loopback fixtures."""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing, contextmanager
from http.cookiejar import CookieJar
from http.cookies import SimpleCookie
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import build_opener, HTTPCookieProcessor, Request

ROOT = Path(__file__).resolve().parents[1]


class Browser:
    def __init__(self, origin, gate=None):
        self.origin = origin
        self.jar = CookieJar()
        self.opener = build_opener(HTTPCookieProcessor(self.jar))
        self.auth = "Basic " + base64.b64encode(f"professor:{gate}".encode()).decode() if gate else ""
        self.csrf = None

    def get(self, path):
        return self.call(path)

    def post(self, path, data, **options):
        return self.call(path, data, **options)

    def call(self, path, data=None, *, expected=200, headers=None, csrf=True, head=False):
        base_headers = {}
        if self.auth:
            base_headers["Authorization"] = self.auth
        payload = None
        if data is not None:
            base_headers.update({"Origin": self.origin, "Content-Type": "application/json", "Sec-Fetch-Site": "same-origin"})
            if csrf and self.csrf:
                base_headers["X-BF-CSRF"] = self.csrf
            payload = json.dumps(data).encode()
        base_headers.update(headers or {})
        req = Request(self.origin + path, data=payload, headers=base_headers, method="HEAD" if head else None)
        try:
            response = self.opener.open(req, timeout=8)
        except HTTPError as exc:
            response = exc
        with response:
            body = response.read()
            if expected is not None:
                assert response.status == expected, (path, response.status, str(body)[:350])
            return response.status, json.loads(body) if body and "application/json" in response.headers.get("Content-Type", "") else None, response.headers

    def login(self, username, password):
        _, response, headers = self.post("/api/workspace/login", {"username": username, "password": password})
        assert response == {"success": True}
        cookie = SimpleCookie(headers["Set-Cookie"])["bf_workspace"]
        assert cookie["httponly"] and cookie["samesite"] == "Strict" and int(cookie["max-age"]) > 0
        state = self.state()
        assert state["workspace"]["authenticated"]
        self.csrf = state["workspace"]["csrf"]
        return state["workspace"]["player_id"]

    def state(self):
        return self.get("/api/state")[1]


def provision(accounts, name, side, commander=False):
    result = subprocess.run([
        sys.executable, str(ROOT / "scripts/provision_workspace_account.py"), "--file", str(accounts),
        "--username", name, "--callsign", name.title(), "--side", side,
        "--role", "commander" if commander else "member", "--starter-merits", "8", "--generate",
    ], cwd=ROOT, check=True, capture_output=True, text=True)
    return result.stdout.strip().rsplit(":", 1)[-1].strip()


@contextmanager
def daemon(directory, db, accounts, origin, port, gate=None, *, previous=False, source=None):
    env = {key: value for key, value in os.environ.items() if not key.startswith("BF_")}
    env.update({"BF_BIND":"127.0.0.1", "PORT":str(port), "BF_LIVE_CAMPAIGN_ONLY":"1"})
    if previous:
        env["BF_DEMO"] = "1"
    else:
        env.update({"BF_WORKSPACE":"1", "BF_DEMO":"1", "BF_WORKSPACE_DB":str(db),
                    "BF_WORKSPACE_ACCOUNTS_FILE":str(accounts), "BF_WORKSPACE_ORIGIN":origin})
    if gate:
        env["BF_DEMO_PASSWORD"] = gate
    with (directory / "server.log").open("ab") as log:
        proc = subprocess.Popen([sys.executable, str(source or ROOT / "web/server.py")], env=env, cwd=ROOT, stdout=log, stderr=log)
        try:
            ready = Browser(origin, gate)
            for _ in range(80):
                if proc.poll() is not None:
                    raise AssertionError((directory / "server.log").read_text(errors="replace"))
                try:
                    ready.get("/api/state" if previous else "/healthz")
                    break
                except URLError:
                    time.sleep(.075)
            else:
                raise AssertionError("Loopback companion did not start.")
            yield
        finally:
            proc.terminate()
            proc.wait(timeout=10)


def legacy_baseline(source):
    with tempfile.TemporaryDirectory(prefix="battlefront-legacy-qa-") as directory:
        directory = Path(directory)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        origin = f"http://127.0.0.1:{port}"
        gate = secrets.token_urlsafe(16)
        with daemon(directory, None, None, origin, port, gate, previous=True, source=source):
            gated = Browser(origin, gate)
            assert "workspace" not in gated.state()
            assert gated.get("/api/campaign")[1]["campaign_scope"] == "isolated_workspace"
            gated.call("/healthz", expected=404)
            gated.post("/api/workspace/login", {"username":"spectator","password":"unused"}, expected=404)
        print("LEGACY: isolated workspace; production sign-in and health routes absent", flush=True)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--legacy-source", type=Path)
    args = cli.parse_args()
    if args.legacy_source:
        legacy_baseline(args.legacy_source.resolve())
        return
    with tempfile.TemporaryDirectory(prefix="battlefront-production-qa-") as directory:
        directory = Path(directory)
        db, accounts = directory / "workspace.sqlite3", directory / "accounts.json"
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        origin = f"http://127.0.0.1:{port}"
        credentials = {name: provision(accounts, name, side, name == "seller") for name, side in (
            ("seller", "blue"), ("buyerone", "blue"), ("buyertwo", "blue"), ("redpilot", "red"))}
        assert all(password not in accounts.read_text() for password in credentials.values())
        seller, b1, b2, red, viewer = [Browser(origin) for _ in range(5)]
        with daemon(directory, db, accounts, origin, port):
            assert viewer.get("/healthz")[1] == {"status":"ok"}
            assert viewer.call("/healthz", head=True)[0] == 200
            assert viewer.state()["workspace"]["player_id"] is None
            assert viewer.get("/api/campaign")[1]["sector_source"] == "planning_map"
            assert viewer.get("/api/campaign")[1]["coalitions"] == {}
            assert viewer.get("/api/telemetry")[1]["campaign"] is None
            viewer.post("/api/requisition", {"munition":"AIM-120D"}, expected=401)
            viewer.post("/api/workspace/login", {"username":"seller","password":"not-a-password"}, expected=401)
            viewer.post("/api/workspace/login", {"username":"seller","password":credentials["seller"]},
                        headers={"Origin":"https://other.invalid"}, expected=403)
            ids = {name: browser.login(name, credentials[name]) for name, browser in
                   (("seller",seller),("buyerone",b1),("buyertwo",b2),("redpilot",red))}
            seller_id = ids["seller"]
            assert len(set(ids.values())) == 4
            assert seller.state()["workspace"]["can_command"]
            assert not b1.state()["workspace"]["can_command"]
            assert "inventory" not in viewer.state()["players"][seller_id]
            assert "points" not in b1.state()["players"][seller_id]
            b1.call(f"/api/player/{seller_id}", expected=404)
            b1.post("/api/requisition", {"munition":"AIM-120D","player_id":seller_id}, expected=403)
            b1.post("/api/requisition", {"munition":"AIM-120D","side":1}, expected=403)
            b1.post("/api/requisition", {"munition":"AIM-120D"}, csrf=False, expected=403)
            b1.post("/api/requisition", {"munition":"AIM-120D"}, headers={"Sec-Fetch-Site":"cross-site"}, expected=403)
            red.post("/api/requisition", {"munition":"AIM-120D"}, expected=403)
            b1.post("/api/player/set_callsign", {"callsign":"Seller"}, expected=409)
            b1.post("/api/player/set_callsign", {"callsign":"Flight One"})
            assert b1.state()["workspace"]["player_id"] == ids["buyerone"]
            for path in ("/api/telemetry/push","/api/kill_event","/api/assist_event",
                         "/api/demo/grant_merits","/api/campaign/test_collapse","/api/upgrades/purchase"):
                seller.post(path, {}, expected=404)
            print("AUTH: optional spectator mode, immutable pilot identity/coalition, CSRF, and production route allowlist", flush=True)
            assert seller.post("/api/requisition", {"munition":"AIM-120D"})[1]["new_balance"] == 4
            assert "No DCS aircraft was changed" in seller.post("/api/armory/mount", {"munition":"AIM-120D"})[1]["message"]
            order = {"munition":"AIM-120D","quantity":1,"price_points":3}
            listing = seller.post("/api/marketplace/list", order)[1]["listing"]["id"]
            assert not seller.state()["players"][seller_id]["planned_loadout"]
            assert not red.state()["marketplace"] and not viewer.state()["marketplace"]
            assert b1.state()["marketplace"][0]["id"] == listing
            red.post("/api/marketplace/buy", {"listing_id":listing}, expected=404)
            seller.post("/api/marketplace/buy", {"listing_id":listing}, expected=409)
            b1.post("/api/marketplace/cancel", {"listing_id":listing}, expected=403)
            with ThreadPoolExecutor(2) as pool:
                results = list(pool.map(lambda b: b.post("/api/marketplace/buy", {"listing_id":listing}, expected=None),
                                        (b1,b2)))
            assert sorted(r[0] for r in results) == [200,404]
            winner = "buyerone" if results[0][0] == 200 else "buyertwo"
            winning_browser = b1 if winner == "buyerone" else b2
            assert winning_browser.state()["players"][ids[winner]]["inventory"] == {"AIM-120D":1}
            assert winning_browser.state()["players"][ids[winner]]["points"] == 5
            assert seller.state()["players"][seller_id]["points"] == 7
            assert seller.state()["trade_history"][0]["id"] == listing
            with closing(sqlite3.connect(db)) as conn:
                audit = [json.loads(r[0]) for r in conn.execute("SELECT data FROM workspace_ledger WHERE action='buy'")]
                assert len(audit) == 1
                row = audit[0]
                assert row["buyer_before"] + row["seller_before"] == row["buyer_after"] + row["seller_after"]
                assert row["buyer_before"] - row["buyer_after"] == row["price_points"]
            print("TRADE: one of two concurrent buyers settled; escrow transferred exactly one unit; CM conserved and audited", flush=True)
            b1.post("/api/operations/command", {}, expected=403)
            seller.post("/api/operations/command", {})
            target = next(row["name"] for row in b1.get("/api/campaign")[1]["sectors"] if row["side"] == 1)
            b1.post("/api/operations/propose", {"target_sector":target})
            assert red.get("/api/campaign")[1]["operations"] == {}
            b1.post("/api/operations/join", {"slot_index":0})
            b2.post("/api/operations/join", {"slot_index":0}, expected=409)
            b1.post("/api/operations/launch", {}, expected=403)
            op = seller.post("/api/operations/launch", {})[1]["operation"]
            assert op["status"] == "SCHEDULED" and op["slots"][0]["pilot"] == ids["buyerone"]
            assert op["slots"][0]["pilot_callsign"] == "Flight One"
            print("OPS: own coalition only; member cannot command or schedule; roster and plan recorded without DCS commands", flush=True)
        with daemon(directory, db, accounts, origin, port):
            assert seller.state()["workspace"]["authenticated"]
            assert seller.state()["trade_history"][0]["id"] == listing
            assert winning_browser.state()["players"][ids[winner]]["inventory"] == {"AIM-120D":1}
            assert seller.get("/api/campaign")[1]["operations"]["2"]["status"] == "SCHEDULED"
            cookie = next(c.value for c in b1.jar if c.name == "bf_workspace")
            b1.post("/api/workspace/logout", {})
            b1.post("/api/requisition", {"munition":"AIM-120D"}, headers={"Cookie":f"bf_workspace={cookie}"}, expected=401)
        print("DURABILITY: sessions, inventory, trade, and scheduled plan survived process restart; logout invalidated session", flush=True)
        gate = secrets.token_urlsafe(16)
        with daemon(directory, db, accounts, origin, port, gate):
            viewer.call("/api/state", expected=401)
            assert viewer.get("/healthz")[1] == {"status":"ok"}
            gated = Browser(origin, gate)
            assert not gated.state()["workspace"]["authenticated"]
            gated.post("/api/requisition", {"munition":"AIM-120D"}, expected=401)
            with closing(sqlite3.connect(db)) as conn:
                conn.execute("UPDATE workspace_state SET payload='{}'")
                conn.commit()
            assert viewer.call("/healthz", expected=503)[1] == {"status":"unavailable"}
        with daemon(directory, db, accounts, origin, port, gate, previous=True):
            gated = Browser(origin, gate)
            assert "workspace" not in gated.state()
            assert gated.get("/api/campaign")[1]["campaign_scope"] == "isolated_workspace"
        print("HEALTH/COMPAT: Basic spectator gate is not write auth; health 503 on unreadable state; legacy BF_DEMO still works", flush=True)


if __name__ == "__main__":
    main()
