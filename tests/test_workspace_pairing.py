import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pair_store", ROOT / "server/persistence/workspace_store.py")
store_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(store_module)
WorkspaceStore = store_module.WorkspaceStore
WorkspaceError = store_module.WorkspaceError
NATIVE_BLUE = "a" * 32
NATIVE_OTHER = "b" * 32
PASSWORD = "fixture password only"


class Pairing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.spool = self.root / "pair"
        self.spool.mkdir(mode=0o700)
        self.lane = self.root / "delivery"
        self.lane.mkdir(mode=0o700)
        self.approved = self.root / "pilot.ucid"
        self.approved.write_bytes((NATIVE_BLUE + "\n").encode())
        if os.name == "posix":
            self.approved.chmod(0o600)
        (self.lane / store_module.DELIVERY_CAPABILITY).write_bytes(b"BF3 VIPER_D_READY VAZIANI\n")
        self.catalog = json.loads((ROOT / "server/demo_catalog.json").read_text(encoding="utf-8"))

    def store(self, *, enabled=True, verified=True):
        return WorkspaceStore(self.root / "db", None, self.catalog, link_dir=self.spool if enabled else None,
                              delivery_dir=self.lane, delivery_airfield="Vaziani",
                              linked_delivery_pilot_file=self.approved if verified else None, linked_delivery_merits=25)

    def write_receipt(self, code, ucid, side):
        path = self.spool / (code + ".pair")
        path.write_bytes(f"BFPAIR1 {code} {ucid} {side}\n".encode())
        return path

    def test_default_disabled_and_no_ecosystem_privileges_before_link(self):
        inactive = self.store(enabled=False)
        self.assertFalse(inactive.get_state(None)["workspace"]["signup_enabled"])
        with self.assertRaises(WorkspaceError) as e:
            inactive.signup("pilot-new", PASSWORD)
        self.assertEqual(e.exception.status, 404)
        store = self.store()
        token = store.signup("pilot-new", PASSWORD)
        session = store.session(token)
        self.assertTrue(store.get_state(session)["workspace"]["link_required"])
        self.assertIsNone(store.get_state(session)["workspace"]["player_id"])
        self.assertNotIn("delivery", store.get_state(session))
        with self.assertRaises(WorkspaceError) as e:
            store.mutate("/api/requisition", session, {"munition": "AIM-120D"}, [])
        self.assertEqual(e.exception.status, 403)
        with self.assertRaises(WorkspaceError) as e:
            store.signup("Pilot-New", PASSWORD)
        self.assertEqual(e.exception.status, 409)
        self.assertNotIn(NATIVE_BLUE, repr(store.get_state(session)))

    def test_pair_scoped_to_real_identity_balance_persists_and_duplicate_denied(self):
        store = self.store()
        token = store.signup("first-pilot", PASSWORD)
        session = store.session(token)
        other_token = store.signup("other-pilot", PASSWORD)
        other = store.session(other_token)
        code = store.start_link(session)["code"]
        with self.assertRaises(WorkspaceError) as e:
            store.start_link(session)
        self.assertEqual(e.exception.status, 429)
        self.assertEqual(store.finish_link(session, code)["status"], "waiting")
        path = self.write_receipt(code, NATIVE_BLUE, 2)
        with self.assertRaises(WorkspaceError):
            store.finish_link(other, code)
        self.assertTrue(path.exists())
        self.assertEqual(store.finish_link(session, code.lower())["status"], "linked")
        self.assertFalse(path.exists())
        fresh = self.store()
        signed_in = fresh.session(fresh.login("first-pilot", PASSWORD))
        state = fresh.get_state(signed_in)
        self.assertEqual(state["players"][signed_in["actor"]]["points"], 25)
        self.assertEqual(state["delivery"]["airfield"], "Vaziani")
        self.assertFalse(state["workspace"]["link_required"])
        self.assertNotIn("delivery", fresh.get_state(fresh.session(other_token)))
        code2 = fresh.start_link(other)["code"]
        self.write_receipt(code2, NATIVE_BLUE, 2)
        with self.assertRaises(WorkspaceError) as e:
            fresh.finish_link(other, code2)
        self.assertEqual(e.exception.status, 409)
        self.assertTrue(fresh.get_state(other)["workspace"]["link_required"])
        self.assertFalse((self.spool / (code2 + ".pair")).exists())
        with self.assertRaises(WorkspaceError):
            fresh.finish_link(session, code)
        self.assertFalse((self.lane / store_module.DELIVERY_REQUEST).exists())

    def test_expired_malformed_and_other_pilot_do_not_inherit_demo_money(self):
        store = self.store()
        token = store.signup("not-approved", PASSWORD)
        session = store.session(token)
        code = store.start_link(session)["code"]
        path = self.write_receipt(code, NATIVE_OTHER, 0)
        with self.assertRaises(WorkspaceError):
            store.finish_link(session, code)
        self.assertTrue(path.exists())
        with store.connect(write=True) as db:
            db.execute("UPDATE workspace_pairing SET expires=0, issued=0")
        with self.assertRaises(WorkspaceError) as e:
            store.finish_link(session, code)
        self.assertEqual(e.exception.status, 410)
        other_code = store.start_link(session)["code"]
        self.write_receipt(other_code, NATIVE_OTHER, 2)
        store.finish_link(session, other_code)
        view = store.get_state(store.session(token))
        self.assertEqual(view["players"][session["actor"]]["points"], 0)
        self.assertNotIn("delivery", view)


if __name__ == "__main__":
    unittest.main()
