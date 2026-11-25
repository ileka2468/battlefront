"""BF4 checks using only synthetic native files and a temporary SQLite workspace."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import tempfile
import unittest
from unittest.mock import patch

from server.persistence import workspace_store as ws


ITEM = {"munition": "AIM-120D"}
SEND, BUY = "/api/dcs/deliver", "/api/requisition"
ROOT = Path(__file__).resolve().parents[1]


class BatchDelivery(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="bf4-journal-fixture-")
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name).resolve()
        self.lane = self.root / "dcs"
        self.lane.mkdir(mode=0o700)
        self.db = self.root / "workspace.sqlite3"
        self.accounts = self.root / "accounts.json"
        self.catalog = json.loads((ROOT / "server/demo_catalog.json").read_text(encoding="utf-8"))
        self.password = "synthetic BF4 fixture passphrase"
        self.write_accounts()

    def write_accounts(self):
        salt = "ba" * 16
        rows = {}
        for label, identifier in (("pilot", "a"), ("other", "b")):
            rows[label] = dict(id="acct_" + identifier * 32, callsign=label, side=2, role="member",
                               salt=salt, password_hash=ws.credential(self.password, salt), starter_merits=80)
        self.accounts.write_text(json.dumps(rows), encoding="utf-8")
        self.accounts.chmod(0o600)

    def store(self, *, batch=True, airfield="Vaziani"):
        return ws.WorkspaceStore(self.db, self.accounts, self.catalog, delivery_dir=self.lane,
                                 delivery_account="pilot", delivery_airfield=airfield, delivery_batch=batch)

    def file(self, name):
        return self.lane / name

    def pulse(self, version=4):
        self.file(ws.DELIVERY_CAPABILITY).write_bytes(f"BF{version} VIPER_D_READY VAZIANI\n".encode())

    def act(self, store, s, route, qty=None):
        return store.mutate(route, s, ITEM if qty is None else {**ITEM, "quantity": qty}, [])

    def buy(self, store, s, qty):
        for _ in range(qty):
            self.act(store, s, BUY)

    def sign(self, store, who="pilot"):
        return store.session(store.login(who, self.password))

    def pending(self, store, s, qty):
        return self.act(store, s, SEND, qty)["delivery"]["order_id"]

    def native(self, key, result, *, version=4, guard=True):
        if guard:
            self.file(ws.DELIVERY_GUARD).write_bytes(f"BF{version} {key} APPLYING\n".encode())
        self.file(ws.DELIVERY_RECEIPT).write_bytes(f"BF{version} {key} {result}\n".encode())

    def proof(self, store, key):
        with store.connect() as db:
            record = db.execute("SELECT order_state, request, guard, receipt FROM workspace_delivery_history WHERE order_id=?",
                                (key,)).fetchone()
        return (json.loads(record[0]), *record[1:])

    def owned(self, store, s):
        player = store.get_state(s)["players"][s["actor"]]
        return player["points"], player["inventory"].get("AIM-120D", 0)

    def refusal(self, status, action):
        with self.assertRaises(ws.WorkspaceError) as e:
            action()
        self.assertEqual(e.exception.status, status)

    def test_migrate_confirmed_bf3_and_send_exact_batch_then_repeat(self):
        self.pulse(3)
        legacy = self.store(batch=False)
        pilot = self.sign(legacy)
        self.buy(legacy, pilot, 6)
        old = self.pending(legacy, pilot, None)
        self.native(old, "READY 0 1 verified", version=3)
        self.assertEqual(legacy.get_state(pilot)["delivery"]["status"], "ready")
        original = tuple(self.file(name).read_bytes() for name in ws.DELIVERY_JOURNAL)
        batch = self.store()
        self.assertFalse(batch.get_state(pilot)["delivery"]["can_send"])
        self.pulse()
        delivery = batch.get_state(pilot)["delivery"]
        self.assertEqual((delivery["quantity"], delivery["max_quantity"], delivery["can_send"]), (1, 6, True))
        key = self.pending(batch, pilot, 3)
        self.assertNotEqual(key, old)
        self.assertEqual(self.proof(batch, old)[1:], original)
        self.assertEqual(self.file(ws.DELIVERY_HISTORY).joinpath(old+".retired").read_bytes(), f"BF4 {old} RETIRED\n".encode())
        self.assertEqual(self.file(ws.DELIVERY_REQUEST).read_bytes(), f"BF4 {key} AIM-120D 3\n".encode())
        self.assertEqual(self.owned(batch, pilot), (56, 2))
        self.native(key, "APPLYING 1 -1 prewrite")
        middle = batch.get_state(pilot)["delivery"]
        self.assertEqual((middle["status"], middle["quantity"], middle["can_send"]), ("pending", 3, False))
        self.native(key, "READY 1 4 verified")
        latest = batch.get_state(pilot)["delivery"]
        self.assertEqual((latest["status"], latest["quantity"], latest["can_send"]), ("ready", 3, True))
        second = self.pending(batch, pilot, 2)
        self.assertNotIn(second, (old, key))
        self.assertEqual(self.proof(batch, key)[0]["quantity"], 3)
        self.assertEqual(self.owned(batch, pilot), (56, 0))
        self.assertNotIn("delivery", batch.get_state(None))
        other = self.sign(batch, "other")
        self.assertNotIn("delivery", batch.get_state(other))
        self.refusal(403, lambda: self.pending(batch, other, 1))

    def test_stock_limit_refunds_exact_quantity_once_and_is_retirable(self):
        self.pulse()
        store = self.store()
        s = self.sign(store)
        self.buy(store, s, 6)
        key = self.pending(store, s, 6)
        self.assertEqual(self.owned(store, s), (56, 0))
        self.native(key, "REJECTED 8 8 stock_limit", guard=False)
        self.assertEqual(self.owned(store, s), (56, 6))
        self.assertEqual(self.owned(self.store(), s), (56, 6))
        self.assertTrue(store.get_state(s)["delivery"]["can_send"])
        retry = self.pending(store, s, 4)
        self.assertNotEqual(key, retry)
        self.assertEqual(self.proof(store, key)[2], None)
        self.assertEqual(self.owned(store, s), (56, 2))
        with store.connect() as db:
            log = db.execute("SELECT data FROM workspace_ledger WHERE action='delivery_rejected'").fetchall()
        self.assertEqual([json.loads(row[0])["refunded_units"] for row in log], [6])

    def test_bad_receipts_cannot_retire_or_refund(self):
        self.pulse()
        store = self.store()
        s = self.sign(store)
        self.buy(store, s, 4)
        key = self.pending(store, s, 3)
        self.native(key, "READY 11 14 verified")
        last = store.get_state(s)["delivery"]
        self.assertEqual((last["status"], last["quantity"], last["can_send"]), ("review", 3, False))
        self.refusal(409, lambda: self.pending(store, s, 1))
        self.assertEqual(self.owned(store, s), (64, 1))
        self.assertFalse(any(self.file(ws.DELIVERY_HISTORY).iterdir()))

    def test_mismatched_bytes_refused_and_cleanup_resumes_after_partial_removal(self):
        self.pulse()
        store = self.store()
        s = self.sign(store)
        self.buy(store, s, 4)
        key = self.pending(store, s, 2)
        self.native(key, "READY 2 4 verified")
        self.assertTrue(store.get_state(s)["delivery"]["can_send"])
        self.file(ws.DELIVERY_RECEIPT).write_bytes(b"wrong receipt")
        self.assertFalse(store.get_state(s)["delivery"]["can_send"])
        self.refusal(409, lambda: self.pending(store, s, 1))
        self.native(key, "READY 2 4 verified")
        exact = tuple(self.file(name).read_bytes() for name in ws.DELIVERY_JOURNAL)
        original_unlink = Path.unlink
        def interrupted(path, *args, **kwargs):
            if path == self.file(ws.DELIVERY_GUARD):
                raise OSError("fixture abort after request removal")
            return original_unlink(path, *args, **kwargs)
        with patch.object(Path, "unlink", interrupted):
            self.refusal(503, lambda: self.pending(store, s, 1))
        self.assertFalse(self.file(ws.DELIVERY_REQUEST).exists())
        self.assertTrue(self.file(ws.DELIVERY_GUARD).exists())
        self.assertEqual(self.proof(store, key)[1:], exact)
        self.assertEqual(self.owned(store, s), (64, 2))
        self.assertTrue(self.store().get_state(s)["delivery"]["can_send"])
        one = self.pending(self.store(), s, 1)
        self.assertNotEqual(key, one)
        self.assertEqual(self.owned(store, s), (64, 1))

    def test_exact_qty_capability_and_concurrent_submission(self):
        self.pulse(3)
        store = self.store()
        s = self.sign(store)
        self.buy(store, s, 6)
        self.assertNotIn("delivery", store.get_state(s))
        self.refusal(409, lambda: self.pending(store, s, 3))
        self.pulse()
        self.assertFalse(self.store(airfield="Mineralnye Vody")._delivery_profile_ready())
        for invalid in (True, "3", 0, -1, 7, 3.5):
            self.refusal(400, lambda: self.pending(store, s, invalid))
        def submit(_):
            try:
                return self.pending(store, s, 3)
            except ws.WorkspaceError as error:
                self.assertEqual(error.status, 409)
        with ThreadPoolExecutor(max_workers=4) as workers:
            keys = [key for key in workers.map(submit, range(4)) if key]
        self.assertEqual(len(keys), 1)
        self.assertEqual(self.owned(store, s), (56, 3))
        self.assertEqual(self.file(ws.DELIVERY_REQUEST).read_bytes(), f"BF4 {keys[0]} AIM-120D 3\n".encode())

    def test_unpublished_origin_refusal_refunds_but_requires_operator_review_to_rotate(self):
        self.pulse()
        store = self.store()
        s = self.sign(store)
        self.buy(store, s, 3)
        with patch.object(store, "_publish_delivery_request", return_value=False):
            order = self.act(store, s, SEND, 3)["delivery"]
        self.assertEqual((order["status"], order["quantity"], order["can_send"]), ("rejected", 3, False))
        self.assertEqual(self.owned(store, s), (68, 3))
        self.assertFalse(self.file(ws.DELIVERY_REQUEST).exists())
        self.refusal(409, lambda: self.pending(store, s, 1))

    def test_local_retake_preserves_old_balance_inventory_and_grants_new_approved_link(self):
        self.pulse()
        link = self.root / "pairing"
        link.mkdir(mode=0o700)
        ucid = "d1" * 16
        pilot_file = self.root / "approved.ucid"
        pilot_file.write_bytes((ucid + "\n").encode())
        pilot_file.chmod(0o600)
        store = ws.WorkspaceStore(self.db, self.accounts, self.catalog, delivery_dir=self.lane,
                                  delivery_airfield="Vaziani", link_dir=link, linked_delivery_pilot_file=pilot_file,
                                  linked_delivery_merits=50, delivery_batch=True)

        def pair(label):
            token = store.signup(label, self.password)
            s = store.session(token)
            code = store.start_link(s)["code"]
            (link / (code + ".pair")).write_bytes(f"BFPAIR1 {code} {ucid} 2\n".encode())
            self.assertEqual(store.finish_link(s, code)["status"], "linked")
            return store.session(token)

        old = pair("old-recording")
        self.buy(store, old, 3)
        previous = self.pending(store, old, 2)
        self.refusal(409, lambda: store.retire_linked_delivery_for_retake(old["actor"]))
        self.native(previous, "READY 1 3 verified")
        self.assertEqual(self.owned(store, old), (38, 1))
        self.refusal(409, lambda: store.retire_linked_delivery_for_retake("acct_" + "e" * 32))
        expected = tuple(self.file(name).read_bytes() for name in ws.DELIVERY_JOURNAL)
        store.retire_linked_delivery_for_retake(old["actor"])
        self.assertEqual(self.proof(store, previous)[1:], expected)
        self.assertEqual(self.owned(store, old), (38, 1))
        self.assertNotIn("delivery", store.get_state(old))
        self.refusal(409, lambda: store.retire_linked_delivery_for_retake(old["actor"]))
        new = pair("new-recording")
        self.assertNotEqual(old["actor"], new["actor"])
        self.assertEqual(self.owned(store, self.sign(store, "old-recording")), (38, 1))
        self.assertEqual(self.owned(store, new), (50, 0))
        self.assertTrue(store.get_state(new)["delivery"]["can_send"])
        self.assertTrue(store._delivery_lane_empty())
        with store.connect() as db:
            aliases = db.execute("SELECT dcs_owner FROM workspace_signups WHERE id=?", (old["actor"],)).fetchone()
            self.assertEqual(aliases[0], "retired:" + old["actor"])
            self.assertEqual(db.execute("SELECT COUNT(*) FROM workspace_ledger WHERE action='dcs_link_retired'").fetchone()[0], 1)


if __name__ == "__main__":
    unittest.main()
