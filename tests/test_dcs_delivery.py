"""Exercise only a synthetic workspace and files; never contact a DCS process."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.error import URLError

from cloud import render_gateway
from scripts.verify_production_workspace import Browser
from server.persistence import workspace_store as storage


ROOT = Path(__file__).resolve().parents[1]
SEND = "/api/dcs/deliver"
BUY = "/api/requisition"
ITEM = {"munition": "AIM-120D"}


class DeliveryFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.accounts, cls.passwords = {}, {}
        for name, callsign, side in (("demo-blue","Demo Blue",2), ("other-red","Other Red",1), ("professor","Professor",2)):
            salt, password = secrets.token_hex(16), secrets.token_urlsafe(24)
            cls.passwords[name] = password
            cls.accounts[name] = {"id":"acct_" + secrets.token_hex(16), "side":side, "role":"member",
                                  "callsign":callsign, "salt":salt, "password_hash":storage.credential(password,salt),
                                  "starter_merits":12}

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="battlefront-delivery-qa-")
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.db = self.base / "state.sqlite3"
        self.accounts_path = self.base / "accounts.json"
        fd = os.open(self.accounts_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(self.accounts,handle)
        self.lane = self.base / "local-simulator-fixture"
        self.lane.mkdir()
        self.request = self.lane / storage.DELIVERY_REQUEST
        self.receipt = self.lane / storage.DELIVERY_RECEIPT
        self.guard = self.lane / storage.DELIVERY_GUARD
        self.capability = self.lane / storage.DELIVERY_CAPABILITY
        self.pulse()

    def pulse(self, value=b"BF3 VIPER_D_READY\n", *, age=0):
        self.capability.write_bytes(value)
        if age:
            stamp = time.time() - age
            os.utime(self.capability, (stamp, stamp))

    def store(self, *, enabled=True, account="demo-blue", catalog=None, airfield=storage.DELIVERY_AIRFIELD):
        options = {"delivery_dir":self.lane, "delivery_account":account, "delivery_airfield":airfield} if enabled else {}
        if catalog is None:
            catalog = json.loads((ROOT / "server/demo_catalog.json").read_text(encoding="utf-8"))
        return storage.WorkspaceStore(self.db, self.accounts_path, catalog, **options)

    def sign(self, store, name="demo-blue"):
        return store.session(store.login(name,self.passwords[name]))

    def action(self, store, session, route, body=ITEM):
        return store.mutate(route,session,body,[])

    def refusal(self, status, action):
        with self.assertRaises(storage.WorkspaceError) as error:
            action()
        self.assertEqual(error.exception.status,status)

    def inventory(self, store, session):
        player = store.get_state(session)["players"][session["actor"]]
        return player["points"], player["inventory"].get("AIM-120D",0)

    def report(self, order, result, version=3):
        self.receipt.write_bytes(f"BF{version} {order} {result}\n".encode("ascii"))

    def mark(self, order, version=3):
        self.guard.write_bytes(f"BF{version} {order} APPLYING\n".encode("ascii"))

    def ledger(self, store, action):
        with store.connect() as db:
            return [json.loads(row[0]) for row in db.execute("SELECT data FROM workspace_ledger WHERE action=?",(action,))]

    def test_normal_catalog_and_private_opt_in_delivery(self):
        store = self.store()
        demo = self.sign(store)
        state = store.get_state(demo)
        self.assertEqual(state["delivery"],{"status":"idle","item":"AIM-120D","order_id":None,"airfield":"Mineralnye Vody"})
        self.assertEqual(state["munition_catalog"]["AIM-120D"]["cost_points"],4)
        self.assertEqual(state["munition_catalog"]["AIM-120D"]["compatible"],["F-16C_50"])
        self.assertEqual(state["munition_catalog"]["AIM-120D"]["recording_profile"],"viper-d-recording")
        self.assertNotIn("AIM-120C",state["munition_catalog"])
        self.assertIn("AIM-260",state["munition_catalog"])
        professor = self.sign(store,"professor")
        red = self.sign(store,"other-red")
        for session in (None,professor,red):
            seen = store.get_state(session)
            self.assertNotIn("delivery",seen)
            self.assertIn("AIM-120D",seen["munition_catalog"])
            self.assertNotIn("R-73",seen["munition_catalog"])
            if session:
                self.refusal(403,lambda: self.action(store,session,SEND))
        self.refusal(403,lambda: self.action(store,red,BUY))
        self.assertNotIn("delivery",self.store(account="other-red").get_state(red))
        self.assertNotIn("delivery",self.store(catalog={}).get_state(demo))
        disabled = self.store(enabled=False)
        self.assertNotIn("delivery",disabled.get_state(demo))
        self.refusal(403,lambda: self.action(disabled,demo,SEND))
        self.refusal(409,lambda: self.action(store,demo,SEND))
        self.action(disabled,professor,BUY)
        self.action(disabled,professor,"/api/armory/mount")
        planned = disabled.get_state(professor)["players"][professor["actor"]]["planned_loadout"]
        self.assertEqual(planned,{"AIM-120D":1})
        listing = self.action(disabled,professor,"/api/marketplace/list",
            {"munition":"AIM-120D","quantity":1,"price_points":3})["listing"]
        self.action(disabled,demo,"/api/marketplace/buy",{"listing_id":listing["id"]})
        self.assertEqual(self.inventory(disabled,professor),(11,0))
        self.assertEqual(self.inventory(disabled,demo),(9,1))
        self.refusal(400,lambda: self.action(store,demo,SEND,{"munition":"AIM-120D","quantity":2}))
        self.refusal(400,lambda: self.action(store,demo,SEND,{"munition":"AIM-120C"}))
        self.assertFalse(self.request.exists())

    def test_profile_must_be_fresh_and_exact_for_private_dispatch(self):
        store = self.store()
        session = self.sign(store)
        self.capability.unlink()
        self.action(store,session,BUY)  # An ordinary purchase is not a simulator mutation.
        cases = [None, (b"BF2 VIPER_D_READY\n", 0), (b"BF3 VIPER_D_READY\r\n", 0),
                 (b"BF3 VIPER_D_READY\n", 11), (b"BF3 VIPER_D_READY\n", -15)]
        for state in cases:
            with self.subTest(state=state):
                if state is not None:
                    value, age = state
                    self.pulse(value, age=age)
                self.assertNotIn("delivery",store.get_state(session))
                self.refusal(409,lambda: self.action(store,session,SEND))
                self.assertFalse(self.request.exists())
                self.assertEqual(self.inventory(store,session),(8,1))
                self.assertFalse(self.ledger(store,"delivery_escrow"))
        self.pulse()
        self.assertEqual(store.get_state(session)["delivery"]["status"],"idle")

    def test_vaziani_requires_exact_scope_and_persists_it(self):
        live = self.store(airfield="Vaziani")
        session = self.sign(live)
        self.action(live,session,BUY)
        for bad_lease in (b"BF3 VIPER_D_READY\n", b"BF3 VIPER_D_READY VAZIANI\r\n",
                          b"BF3 VIPER_D_READY vaziani\n", b"BF3 VIPER_D_READY KOBULETI\n"):
            self.pulse(bad_lease)
            self.assertNotIn("delivery",live.get_state(session))
            self.refusal(409,lambda: self.action(live,session,SEND))
        self.assertFalse(self.request.exists())
        self.assertFalse(self.ledger(live,"delivery_escrow"))
        self.pulse(b"BF3 VIPER_D_READY VAZIANI\n")
        for unsupported in ("Batumi", "VAZIANI", "Vaziani ", "", None):
            bad = self.store(airfield=unsupported)
            self.assertNotIn("delivery",bad.get_state(session))
            self.refusal(403,lambda: self.action(bad,session,SEND))
        original = self.store()
        self.assertNotIn("delivery",original.get_state(session))
        self.refusal(409,lambda: self.action(original,session,SEND))
        self.assertEqual(live.get_state(session)["delivery"],
            {"status":"idle","item":"AIM-120D","order_id":None,"airfield":"Vaziani"})
        sent = self.action(live,session,SEND)["delivery"]
        self.assertEqual(sent["airfield"],"Vaziani")
        self.assertEqual(sent["status"],"pending")
        order = sent["order_id"]
        self.assertEqual(self.request.read_bytes(),f"BF3 {order} AIM-120D\n".encode("ascii"))
        with live.connect() as db:
            self.assertEqual(live._read(db)["delivery"]["airfield"],"Vaziani")
        self.mark(order)
        self.report("0"*32,"READY 0 1 verified")
        self.assertEqual(self.store(airfield="Vaziani").get_state(session)["delivery"]["status"],"pending")
        self.report(order,"READY 0 1 verified")
        self.assertNotIn("delivery",self.store().get_state(session))
        self.assertFalse(self.ledger(live,"delivery_ready"))
        self.assertEqual(self.store(airfield="Vaziani").get_state(session)["delivery"],
            {"status":"ready","item":"AIM-120D","order_id":order,"airfield":"Vaziani"})
        self.assertEqual(self.inventory(live,session),(8,0))
        self.assertEqual(len(self.ledger(live,"delivery_ready")),1)

    def test_legacy_bf3_order_without_airfield_only_reconciles_in_legacy_profile(self):
        default = self.store()
        session = self.sign(default)
        self.action(default,session,BUY)
        order = self.action(default,session,SEND)["delivery"]["order_id"]
        with default.connect(write=True) as db:
            state = default._read(db)
            del state["delivery"]["airfield"]
            default._save(db,state)
        self.mark(order)
        self.report(order,"READY 0 1 verified")
        self.pulse(b"BF3 VIPER_D_READY VAZIANI\n")
        self.assertNotIn("delivery",self.store(airfield="Vaziani").get_state(session))
        self.assertFalse(self.ledger(default,"delivery_ready"))
        self.assertEqual(self.store().get_state(session)["delivery"],
            {"status":"ready","item":"AIM-120D","order_id":order,"airfield":"Mineralnye Vody"})

    def test_expired_between_escrow_and_publication_returns_one_item(self):
        store = self.store()
        session = self.sign(store)
        self.action(store,session,BUY)
        with patch.object(store,"_delivery_profile_ready",side_effect=[True, True, False]):
            view = self.action(store,session,SEND)["delivery"]
        self.assertEqual(view["status"],"rejected")
        self.assertFalse(self.request.exists())
        self.assertEqual(self.inventory(store,session),(8,1))
        self.assertEqual([row["refunded_units"] for row in self.ledger(store,"delivery_rejected")],[1])
        self.refusal(409,lambda: self.action(store,session,SEND))

    def test_serial_escrow_then_ready_without_second_merit_charge(self):
        store = self.store()
        session = self.sign(store)
        for _ in range(2):
            self.action(store,session,BUY)
        def send():
            try:
                return self.action(store,session,SEND)["delivery"]
            except storage.WorkspaceError as error:
                return error.status
        with ThreadPoolExecutor(max_workers=2) as pool:
            replies = [f.result() for f in (pool.submit(send),pool.submit(send))]
        self.assertIn(409,replies)
        accepted = [row for row in replies if isinstance(row,dict)]
        self.assertEqual(len(accepted),1)
        order = accepted[0]["order_id"]
        self.assertRegex(order,r"^[0-9a-f]{32}$")
        self.assertEqual(accepted[0]["status"],"pending")
        self.assertEqual(self.request.read_bytes(),f"BF3 {order} AIM-120D\n".encode("ascii"))
        self.assertEqual(self.inventory(store,session),(4,1))
        self.assertEqual(self.ledger(store,"delivery_escrow"),
            [{"order_id":order,"item":"AIM-120D","quantity":1,"merits_charged":0}])
        self.report("0"*32,"READY 0 1 verified")
        self.assertEqual(store.get_state(session)["delivery"]["status"],"pending")
        self.mark(order)
        self.report(order,"READY 0 1 verified",version=1)
        self.assertEqual(store.get_state(session)["delivery"]["status"],"pending")
        self.report(order,"READY 0 1 verified",version=2)
        self.assertEqual(store.get_state(session)["delivery"]["status"],"pending")
        self.report(order,"APPLYING 0 -1 prewrite")
        self.assertEqual(store.get_state(session)["delivery"]["status"],"pending")
        self.capability.unlink()  # A delayed poll must still settle a completed native operation.
        self.report(order,"READY 0 1 verified")
        restarted = self.store()
        self.assertEqual(restarted.get_state(session)["delivery"]["status"],"ready")
        self.assertEqual(self.inventory(restarted,session),(4,1))
        self.assertEqual(len(self.ledger(restarted,"delivery_ready")),1)
        self.refusal(409,lambda: self.action(restarted,session,SEND))
        self.assertEqual(self.request.read_bytes(),f"BF3 {order} AIM-120D\n".encode("ascii"))

    def test_python_to_actual_lua_consumer_delivery_wire(self):
        lua = os.environ.get("BATTLEFRONT_TEST_LUA") or shutil.which("lua5.1")
        if not lua:
            self.skipTest("Set BATTLEFRONT_TEST_LUA or install lua5.1 for the cross-runtime fixture")
        store = self.store()
        token = store.login("demo-blue",self.passwords["demo-blue"])
        session = store.session(token)
        self.assertEqual(self.inventory(store,session),(12,0))
        self.action(store,session,BUY)
        self.assertEqual(self.inventory(store,session),(8,1))
        request = self.action(store,session,SEND)["delivery"]
        order = request["order_id"]
        wire = f"BF3 {order} AIM-120D\n".encode("ascii")
        self.assertEqual(request["status"],"pending")
        self.assertEqual(self.request.read_bytes(),wire)
        self.assertFalse(self.receipt.exists())
        self.assertEqual(self.inventory(store,session),(8,0))
        process = subprocess.run([lua, str(ROOT/"scripts/verify_delivery_wire.lua"),
                                  str(ROOT/"server/BattlefrontDelivery.lua"), self.lane.as_posix()],
                                 cwd=ROOT, timeout=20, capture_output=True, text=True)
        self.assertEqual(process.returncode,0,process.stdout+process.stderr)
        self.assertIn("WIRE: Lua 5.1 verified stock 0 -> 1 and one native call; duplicate tick/restart did not apply again",
                      process.stdout)
        self.assertEqual(self.request.read_bytes(),wire)
        self.assertEqual(self.receipt.read_bytes(),f"BF3 {order} READY 0 1 verified\n".encode("ascii"))
        self.assertEqual((self.lane/"battlefront_delivery.applying").read_bytes(),
                         f"BF3 {order} APPLYING\n".encode("ascii"))
        restarted = self.store()
        self.assertEqual(restarted.get_state(restarted.session(token))["delivery"],
                         {"status":"ready","item":"AIM-120D","order_id":order,"airfield":"Mineralnye Vody"})
        self.assertEqual(self.inventory(restarted,restarted.session(token)),(8,0))
        self.assertEqual(self.ledger(restarted,"delivery_ready"),
            [{"order_id":order,"item":"AIM-120D","reason":"verified","before":0,"after":1,"refunded_units":0}])
        self.assertEqual(len(self.ledger(restarted,"delivery_escrow")),1)
        self.refusal(409,lambda: self.action(restarted,restarted.session(token),SEND))

    def test_explicit_prewrite_rejection_returns_one_item_without_cm_change(self):
        store = self.store()
        session = self.sign(store)
        self.action(store,session,BUY)
        order = self.action(store,session,SEND)["delivery"]["order_id"]
        self.assertEqual(self.inventory(store,session),(8,0))
        self.report(order,"REJECTED 1 1 stock_not_zero")
        restarted = self.store()
        self.assertEqual(restarted.get_state(session)["delivery"]["status"],"rejected")
        self.assertEqual(self.inventory(restarted,session),(8,1))
        self.assertEqual(self.inventory(self.store(),session),(8,1))
        self.assertEqual([row["refunded_units"] for row in self.ledger(restarted,"delivery_rejected")],[1])
        self.refusal(409,lambda: self.action(restarted,session,SEND))

    def test_unverified_ready_delta_leaves_item_escrowed(self):
        store = self.store()
        session = self.sign(store)
        self.action(store,session,BUY)
        order = self.action(store,session,SEND)["delivery"]["order_id"]
        self.mark(order)
        self.report(order,"READY 1 2 verified")
        self.assertEqual(store.get_state(session)["delivery"]["status"],"review")
        self.report(order,"REJECTED 1 1 stock_not_zero")
        self.assertEqual(self.store().get_state(session)["delivery"]["status"],"review")
        self.assertEqual(self.inventory(store,session),(8,0))
        self.assertFalse(self.ledger(store,"delivery_rejected"))
        self.refusal(409,lambda: self.action(store,session,SEND))

    def test_receipt_cannot_refund_after_apply_marker(self):
        store = self.store()
        session = self.sign(store)
        self.action(store,session,BUY)
        order = self.action(store,session,SEND)["delivery"]["order_id"]
        # The Lua guard prevents a refund even if the companion never read the intermediate receipt.
        self.mark(order)
        self.report(order,"REJECTED -1 -1 stock_unavailable")
        self.assertEqual(self.store().get_state(session)["delivery"]["status"],"review")
        self.assertEqual(self.inventory(store,session),(8,0))

    def test_ready_requires_matching_apply_guard(self):
        store = self.store()
        session = self.sign(store)
        self.action(store,session,BUY)
        order = self.action(store,session,SEND)["delivery"]["order_id"]
        self.mark("0"*32)
        self.report(order,"READY 0 1 verified")
        self.assertEqual(self.store().get_state(session)["delivery"]["status"],"review")
        self.assertEqual(self.inventory(store,session),(8,0))
        self.assertFalse(self.ledger(store,"delivery_ready"))

    def test_legacy_escrow_is_never_reinterpreted_or_refunded(self):
        store = self.store()
        session = self.sign(store)
        self.action(store,session,BUY)
        prior = {"order_id":"1"*32,"actor":session["actor"],"item":"R-73","status":"pending",
                 "armed_at":int(time.time()),"created_at":storage.iso_now()}
        with store.connect(write=True) as db:
            state = store._read(db)
            state["delivery"] = prior
            store._save(db,state)
        self.request.write_bytes(f"BF1 {prior['order_id']} R-73\n".encode("ascii"))
        self.report(prior["order_id"],"REJECTED -1 -1 stock_unavailable",version=1)
        restarted = self.store()
        self.assertNotIn("delivery",restarted.get_state(session))
        self.refusal(409,lambda: self.action(restarted,session,SEND))
        self.assertEqual(self.inventory(restarted,session),(8,1))
        with restarted.connect() as db:
            saved = restarted._read(db)
            self.assertEqual(saved["delivery"],prior)
            self.assertNotIn("R-73",saved["players"][session["actor"]]["inventory"])
        self.assertFalse(self.ledger(restarted,"delivery_rejected"))

    def test_legacy_stock_aim120c_escrow_remains_untouched(self):
        store = self.store()
        session = self.sign(store)
        self.action(store,session,BUY)
        prior = {"order_id":"2"*32,"actor":session["actor"],"item":"AIM-120C","protocol":2,
                 "status":"pending","armed_at":int(time.time()),"created_at":storage.iso_now()}
        with store.connect(write=True) as db:
            state = store._read(db)
            state["delivery"] = prior
            store._save(db,state)
        self.request.write_bytes(f"BF2 {prior['order_id']} AIM-120C\n".encode("ascii"))
        self.report(prior["order_id"],"REJECTED -1 -1 stock_unavailable",version=2)
        restarted = self.store()
        self.assertNotIn("delivery",restarted.get_state(session))
        self.refusal(409,lambda: self.action(restarted,session,SEND))
        self.assertEqual(self.inventory(restarted,session),(8,1))
        with restarted.connect() as db:
            self.assertEqual(restarted._read(db)["delivery"],prior)
        self.assertFalse(self.ledger(restarted,"delivery_rejected"))

    def test_armed_interruption_is_not_republished_or_refunded(self):
        store = self.store()
        session = self.sign(store)
        self.action(store,session,BUY)
        with patch.object(store,"_publish_delivery_request",side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt): self.action(store,session,SEND)
        self.assertFalse(self.request.exists())
        self.assertEqual(self.store().get_state(session)["delivery"]["status"],"pending")
        with patch.object(storage.time,"time",return_value=time.time()+31):
            restarted = self.store()
            self.assertEqual(restarted.get_state(session)["delivery"]["status"],"review")
        self.assertFalse(self.request.exists())
        self.assertEqual(self.inventory(restarted,session),(8,0))
        self.assertEqual(len(self.ledger(restarted,"delivery_escrow")),1)

    def test_lane_collisions_cannot_overwrite_files_or_charge_items(self):
        store = self.store()
        session = self.sign(store)
        self.action(store,session,BUY)
        for file in (self.request,self.receipt,self.guard):
            file.write_bytes(b"BF1 stale local fixture")
            self.refusal(409,lambda: self.action(store,session,SEND))
            self.assertEqual(file.read_bytes(),b"BF1 stale local fixture")
            self.assertEqual(self.inventory(store,session),(8,1))
            file.unlink()

    @contextmanager
    def daemon(self, port, airfield=None):
        origin = f"http://127.0.0.1:{port}"
        env = {key:value for key,value in os.environ.items() if not key.startswith("BF_")}
        env.update({"BF_WORKSPACE":"1","BF_BIND":"127.0.0.1","PORT":str(port),"BF_WORKSPACE_ORIGIN":origin,
                    "BF_WORKSPACE_DB":str(self.db),"BF_WORKSPACE_ACCOUNTS_FILE":str(self.accounts_path),
                    "BF_DCS_DELIVERY_DIR":str(self.lane),"BF_DCS_DELIVERY_ACCOUNT":"demo-blue"})
        if airfield is not None:
            env["BF_DCS_DELIVERY_AIRFIELD"] = airfield
        with (self.base/"http.log").open("ab") as log:
            proc=subprocess.Popen([sys.executable,str(ROOT/"web/server.py")],env=env,cwd=ROOT,stdout=log,stderr=log)
            try:
                for _ in range(60):
                    if proc.poll() is not None:
                        self.fail((self.base/"http.log").read_text(errors="replace"))
                    try:
                        Browser(origin).get("/healthz")
                        break
                    except URLError:
                        time.sleep(.05)
                else:
                    self.fail("HTTP fixture not ready")
                yield origin
            finally:
                proc.terminate()
                proc.wait(timeout=10)

    def test_http_auth_csrf_scope_and_restart(self):
        self.assertIn(SEND,render_gateway.WRITE)
        self.assertNotIn(SEND,render_gateway.READ)
        with socket.socket() as sock:
            sock.bind(("127.0.0.1",0))
            port=sock.getsockname()[1]
        self.pulse(b"BF3 VIPER_D_READY VAZIANI\n")
        with self.daemon(port, airfield="Vaziani") as origin:
            guest,professor,blue = (Browser(origin) for _ in range(3))
            self.assertNotIn("delivery",guest.state())
            guest.post(SEND,ITEM,expected=401)
            professor.login("professor",self.passwords["professor"])
            self.assertNotIn("delivery",professor.state())
            professor.post(BUY,ITEM)
            professor.post(SEND,ITEM,expected=403)
            pilot_id = blue.login("demo-blue",self.passwords["demo-blue"])
            self.assertEqual(blue.state()["delivery"]["status"],"idle")
            self.assertEqual(blue.state()["delivery"]["airfield"],"Vaziani")
            blue.post(BUY,ITEM)
            blue.post(SEND,ITEM,csrf=False,expected=403)
            blue.post(SEND,ITEM,headers={"Origin":"https://different.invalid"},expected=403)
            blue.post(SEND,{"munition":"AIM-120D","player_id":pilot_id},expected=400)
            self.assertFalse(self.request.exists())
            order = blue.post(SEND,ITEM)[1]["delivery"]["order_id"]
            self.assertEqual(blue.state()["players"][pilot_id]["points"],8)
            self.assertNotIn("AIM-120D",blue.state()["players"][pilot_id]["inventory"])
        self.report(order,"REVIEW 0 -1 interrupted")
        with self.daemon(port, airfield="Vaziani"):
            self.assertEqual(blue.state()["delivery"]["status"],"review")
            self.assertEqual(blue.state()["players"][pilot_id]["points"],8)
            self.assertNotIn("AIM-120D",blue.state()["players"][pilot_id]["inventory"])
            blue.post(SEND,ITEM,expected=409)


if __name__ == "__main__":
    unittest.main()
