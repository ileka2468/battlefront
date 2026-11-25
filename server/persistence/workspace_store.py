"""Durable web companion state and a fixed, optional simulator delivery lane."""

import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone


USERNAME = re.compile(r"[a-z0-9][a-z0-9_.-]{1,31}")
CALLSIGN = re.compile(r"[A-Za-z0-9 _-]{1,24}")
TOKEN = re.compile(r"[A-Za-z0-9_-]{43}")
ACCOUNT_ID = re.compile(r"acct_[0-9a-f]{32}")
PBKDF2_ITERATIONS = 600_000
SESSION_SECONDS = 12 * 3600
PAIR_CODE = re.compile(r"[A-Z2-7]{12}")
PAIR_RECEIPT = re.compile(rb"BFPAIR1 ([A-Z2-7]{12}) ([0-9a-f]{32}) ([12])\n")
PAIR_LIFETIME = 300
PAIR_ROTATE_SECONDS = 10
PAIR_SPOOL_SCAN_LIMIT = 128
SIGNUP_LIMIT = 1000
DELIVERY_ITEM = "AIM-120D"
DELIVERY_SIDE = 2
DELIVERY_VERSION = 3
DELIVERY_BATCH_VERSION = 4
DELIVERY_BATCH_MAX = 6
DELIVERY_STOCK_MAX = 12
DELIVERY_AIRFIELD = "Mineralnye Vody"
DELIVERY_REQUEST = "battlefront_delivery.request"
DELIVERY_RECEIPT = "battlefront_delivery.receipt"
DELIVERY_GUARD = "battlefront_delivery.applying"
DELIVERY_CAPABILITY = "battlefront_delivery.capability"
DELIVERY_HISTORY = "battlefront_delivery.history"
DELIVERY_JOURNAL = (DELIVERY_REQUEST, DELIVERY_GUARD, DELIVERY_RECEIPT)
DELIVERY_CAPABILITY_CONTENT = b"BF3 VIPER_D_READY\n"
DELIVERY_AIRFIELD_CAPABILITIES = {
    DELIVERY_AIRFIELD: DELIVERY_CAPABILITY_CONTENT,
    "Vaziani": b"BF3 VIPER_D_READY VAZIANI\n",
}
DELIVERY_CAPABILITY_MAX_AGE = 10
DELIVERY_PROFILE = "viper-d-recording"
DELIVERY_ORDER_ID = re.compile(r"[0-9a-f]{32}")
RECEIPT = re.compile(
    rb"BF3 ([0-9a-f]{32}) (APPLYING|READY|REJECTED|REVIEW) "
    rb"(-1|0|[1-9][0-9]{0,8}) (-1|0|[1-9][0-9]{0,8}) ([a-z][a-z0-9_]{0,39})\n",
)
BATCH_RECEIPT = re.compile(RECEIPT.pattern.replace(b"BF3 ", b"BF4 ", 1))


class WorkspaceError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def credential(password, salt):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), PBKDF2_ITERATIONS).hex()


def private_location(raw, *, directory):
    if not raw:
        return None
    try:
        path = Path(raw)
        if not path.is_absolute() or path.resolve(strict=True) != path:
            return None
        info = path.lstat()
        check_type = stat.S_ISDIR if directory else stat.S_ISREG
        if not check_type(info.st_mode):
            return None
        if os.name == "posix" and (stat.S_IMODE(info.st_mode) & 0o077 or info.st_uid != os.getuid()):
            return None
        return path
    except (OSError, RuntimeError, TypeError, ValueError):
        return None


def native_owner(ucid):
    return hashlib.sha256(b"battlefront-dcs:" + ucid).hexdigest()


def trim_text(value, label, maximum=100):
    if not isinstance(value, str) or not 0 < len(value.strip()) <= maximum:
        raise WorkspaceError(f"Invalid {label}.")
    return value.strip()


def integer(value, label, minimum, maximum):
    if type(value) is not int or not minimum <= value <= maximum:
        raise WorkspaceError(f"Invalid {label}.")
    return value


def iso_now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def read_accounts(path):
    if not path or not Path(path).is_file():
        return {}
    path = Path(path)
    if os.name == "posix" and stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise ValueError("Workspace credential file must not be accessible to group/other users")
    rows = json.loads(path.read_text(encoding="utf-8"))
    seen_ids, seen_callsigns = set(), set()
    for name, row in rows.items():
        if (not USERNAME.fullmatch(name)
            or not ACCOUNT_ID.fullmatch(row["id"])
            or not CALLSIGN.fullmatch(row["callsign"])
            or row["id"] in seen_ids
            or row["callsign"].casefold() in seen_callsigns
            or row["role"] not in ("member", "commander", "admin")
            or type(row["side"]) is not int or row["side"] not in (1, 2)
            or type(row.get("starter_merits", 4)) is not int or not 0 <= row.get("starter_merits", 4) <= 100
            or not re.fullmatch(r"[0-9a-f]{32}", row["salt"])
            or not re.fullmatch(r"[0-9a-f]{64}", row["password_hash"])):
            raise ValueError("Invalid workspace account settings")
        seen_ids.add(row["id"])
        seen_callsigns.add(row["callsign"].casefold())
    return rows


class WorkspaceStore:
    def __init__(self, db_path, accounts_path, catalog, *, delivery_dir=None, delivery_account=None,
                 delivery_airfield=DELIVERY_AIRFIELD, link_dir=None, linked_delivery_pilot_file=None,
                 linked_delivery_merits=0, delivery_batch=False):
        self.path = Path(db_path).resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.accounts = read_accounts(accounts_path)
        self.by_id = {a["id"]: a for a in self.accounts.values()}
        self.catalog = dict(catalog)
        self.link_dir = private_location(link_dir, directory=True)
        self.delivery_dir, self.configured_delivery_actor = None, None
        self.linked_delivery_pilot_file = None
        self.linked_delivery_merits = integer(linked_delivery_merits, "linked demo merits", 0, 100)
        self.delivery_batch = delivery_batch is True
        self.delivery_protocol = DELIVERY_BATCH_VERSION if self.delivery_batch else DELIVERY_VERSION
        self.delivery_airfield = (delivery_airfield if isinstance(delivery_airfield, str)
                                  and delivery_airfield in DELIVERY_AIRFIELD_CAPABILITIES else None)
        configured = self.accounts.get(delivery_account or "")
        spec = self.catalog.get(DELIVERY_ITEM, {})
        if linked_delivery_pilot_file and self.link_dir and self.delivery_airfield == "Vaziani":
            self.linked_delivery_pilot_file = private_location(linked_delivery_pilot_file, directory=False)
        static_actor = (configured and configured["side"] == DELIVERY_SIDE and not linked_delivery_pilot_file)
        if ((static_actor or self.linked_delivery_pilot_file) and delivery_dir and self.delivery_airfield
                and spec.get("coalition") == "BLUFOR" and "F-16C_50" in (spec.get("compatible") or [])
                and spec.get("recording_profile") == DELIVERY_PROFILE):
            try:
                directory = Path(delivery_dir)
                if directory.is_absolute() and directory.resolve(strict=True).is_dir():
                    self.delivery_dir = directory.resolve(strict=True)
                    self.configured_delivery_actor = configured["id"] if static_actor else None
            except (OSError, RuntimeError, ValueError):
                pass   # Intentionally disabled when operator configuration is unavailable.
        # Initialize the SQLite file with owner-only access, including on a new installation.
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT, 0o600)
        os.close(fd)
        if os.name == "posix" and stat.S_IMODE(self.path.stat().st_mode) & 0o077:
            raise ValueError("Workspace database must not be accessible to group/other users")
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS workspace_state (
                    id INTEGER PRIMARY KEY CHECK (id=1), payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS workspace_sessions (
                    hash TEXT PRIMARY KEY, actor TEXT NOT NULL, revision TEXT NOT NULL,
                    csrf TEXT NOT NULL, expires INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS workspace_ledger (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, actor TEXT NOT NULL, action TEXT NOT NULL,
                    occurred TEXT NOT NULL, data TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS workspace_signups (
                    id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE, callsign TEXT NOT NULL,
                    salt TEXT NOT NULL, password_hash TEXT NOT NULL,
                    side INTEGER, dcs_owner TEXT UNIQUE,
                    CHECK ((side IS NULL AND dcs_owner IS NULL)
                        OR (side IS NOT NULL AND side IN (1,2) AND dcs_owner IS NOT NULL)));
                CREATE TABLE IF NOT EXISTS workspace_pairing (
                    actor TEXT PRIMARY KEY, code_hash TEXT NOT NULL UNIQUE, issued INTEGER NOT NULL, expires INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS workspace_delivery_history (
                    order_id TEXT PRIMARY KEY, order_state TEXT NOT NULL, request BLOB NOT NULL,
                    guard BLOB, receipt BLOB NOT NULL, retired_at TEXT NOT NULL);
            """)
            db.execute("INSERT OR IGNORE INTO workspace_state VALUES (1,?)",
                (json.dumps(dict(players={}, listings={}, trades=[], operations={}, previous_plans=[], commanders={})),))
        if self.delivery_dir:
            self.reconcile_delivery()

    @contextmanager
    def connect(self, *, write=False):
        db = sqlite3.connect(self.path.as_uri() + "?mode=rw", uri=True, timeout=8, isolation_level=None)
        db.row_factory = sqlite3.Row
        try:
            if self.delivery_batch:
                db.execute("PRAGMA synchronous=FULL")
            if write:
                db.execute("BEGIN IMMEDIATE")
            yield db
            if write:
                db.commit()
        except BaseException:
            if write:
                db.rollback()
            raise
        finally:
            db.close()

    def _read(self, db):
        return json.loads(db.execute("SELECT payload FROM workspace_state WHERE id=1").fetchone()["payload"])

    def _save(self, db, state):
        db.execute("UPDATE workspace_state SET payload=? WHERE id=1",
                   (json.dumps(state, ensure_ascii=False, separators=(",", ":")),))

    def _record(self, db, actor, action, data):
        db.execute("INSERT INTO workspace_ledger(actor,action,occurred,data) VALUES (?,?,?,?)",
                   (actor, action, iso_now(), json.dumps(data, ensure_ascii=False)))

    def _initialize_player(self, state, account):
        actor = account["id"]
        if actor in state["players"]:
            return
        base = account["callsign"]
        callsign = base
        if any(p["callsign"].casefold() == callsign.casefold() for p in state["players"].values()):
            callsign = base[:15] + "-" + actor[-8:]
        state["players"][actor] = {
            "callsign": callsign, "side": account["side"], "points": account.get("starter_merits", 4),
            "inventory": {}, "planned_loadout": {},
            "stats": {"a2a_kills": 0, "a2g_kills": 0, "sorties": 0, "losses": 0},
        }

    def signup(self, username, password):
        if not self.link_dir:
            raise WorkspaceError("Account signup is not enabled.", 404)
        username = trim_text(username, "username", 24).lower()
        if not USERNAME.fullmatch(username) or len(username) < 3:
            raise WorkspaceError("Use 3–24 letters, numbers, dots, underscores or hyphens.")
        if not isinstance(password, str) or not 12 <= len(password) <= 128 or not password.strip():
            raise WorkspaceError("Use a password between 12 and 128 characters.")
        try:
            salt = secrets.token_hex(16)
            digest = credential(password, salt)
        except UnicodeEncodeError:
            raise WorkspaceError("Invalid password.") from None
        actor = "acct_" + secrets.token_hex(16)
        with self.connect(write=True) as db:
            if username in self.accounts or db.execute(
                "SELECT 1 FROM workspace_signups WHERE username=?", (username,)
            ).fetchone():
                raise WorkspaceError("That username is unavailable.", 409)
            if db.execute("SELECT COUNT(*) FROM workspace_signups").fetchone()[0] >= SIGNUP_LIMIT:
                raise WorkspaceError("Signup capacity reached.", 503)
            db.execute("INSERT INTO workspace_signups VALUES (?,?,?,?,?,NULL,NULL)",
                       (actor, username, username.replace(".", "-"), salt, digest))
            self._record(db, actor, "signup", {})
            return self._create_session(db, actor, digest)

    def _create_session(self, db, actor, digest):
        now = int(time.time())
        token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        db.execute("DELETE FROM workspace_sessions WHERE expires <= ?", (now,))
        db.execute("""DELETE FROM workspace_sessions WHERE actor=? AND hash NOT IN (
                      SELECT hash FROM workspace_sessions WHERE actor=? ORDER BY expires DESC, rowid DESC LIMIT 7)""",
                   (actor, actor))
        db.execute("INSERT INTO workspace_sessions VALUES (?,?,?,?,?)",
                   (self.token_hash(token), actor, digest, csrf, now + SESSION_SECONDS))
        return token

    def login(self, username, password):
        username = trim_text(username, "account", 32).lower()
        if not isinstance(password, str) or not 1 <= len(password) <= 256 or not USERNAME.fullmatch(username):
            raise WorkspaceError("Invalid account credentials.", 401)
        account = self.accounts.get(username)
        if not account:
            with self.connect() as db:
                row = db.execute("SELECT * FROM workspace_signups WHERE username=?", (username,)).fetchone()
                account = dict(row) if row else None
        # Unknown usernames take the same password hashing path as known usernames.
        nonce = account["salt"] if account else "0" * 32
        expected = account["password_hash"] if account else "0" * 64
        try:
            valid = hmac.compare_digest(credential(password, nonce), expected)
        except UnicodeEncodeError:
            valid = False
        if not (valid and account):
            raise WorkspaceError("Invalid account credentials.", 401)
        actor = account["id"]
        with self.connect(write=True) as db:
            state = self._read(db)
            previous = state["players"].get(actor)
            if "dcs_owner" not in account and previous and previous["side"] != account["side"]:
                raise WorkspaceError("Account coalition conflicts with existing inventory. Ask the site administrator.", 403)
            if "dcs_owner" not in account and not previous:
                self._initialize_player(state, account)
                self._save(db, state)
                self._record(db, actor, "provision", {"side": account["side"], "merits": state["players"][actor]["points"]})
            return self._create_session(db, actor, expected)

    @staticmethod
    def token_hash(token):
        return hashlib.sha256(token.encode()).hexdigest()

    def session(self, token):
        if not isinstance(token, str) or not TOKEN.fullmatch(token):
            return None
        with self.connect() as db:
            row = db.execute("SELECT * FROM workspace_sessions WHERE hash=? AND expires>?",
                             (self.token_hash(token), int(time.time()))).fetchone()
            if not row:
                return None
            account = self.by_id.get(row["actor"])
            if not account:
                registered = db.execute("SELECT * FROM workspace_signups WHERE id=?", (row["actor"],)).fetchone()
                account = dict(registered) if registered else None
        if not account or not hmac.compare_digest(account["password_hash"], row["revision"]):
            return None
        return {"actor": row["actor"], "side": account["side"], "csrf": row["csrf"], "hash": row["hash"],
                "can_command": account.get("role") in ("commander", "admin"), "registered": "dcs_owner" in account}

    def check_health(self):
        with self.connect() as db:
            return isinstance(self._read(db)["players"], dict)

    def logout(self, token):
        with self.connect(write=True) as db:
            db.execute("DELETE FROM workspace_sessions WHERE hash=?", (self.token_hash(token),))

    def _pending_signup(self, db, session):
        if not self.link_dir or not session.get("registered"):
            raise WorkspaceError("DCS linking is not available for this account.", 403)
        now = int(time.time())
        if not db.execute("SELECT 1 FROM workspace_sessions WHERE hash=? AND actor=? AND expires>?",
                          (session["hash"], session["actor"], now)).fetchone():
            raise WorkspaceError("Sign in to link your DCS account.", 401)
        row = db.execute("SELECT * FROM workspace_signups WHERE id=?", (session["actor"],)).fetchone()
        if not row or row["dcs_owner"]:
            raise WorkspaceError("This account is already linked.", 409)
        return row, now

    def start_link(self, session):
        code = base64.b32encode(secrets.token_bytes(8)).decode("ascii")[:12]
        with self.connect(write=True) as db:
            row, now = self._pending_signup(db, session)
            prior = db.execute("SELECT issued FROM workspace_pairing WHERE actor=?", (row["id"],)).fetchone()
            if prior and now - prior["issued"] < PAIR_ROTATE_SECONDS:
                raise WorkspaceError("Wait a few seconds before requesting another code.", 429)
            db.execute("""INSERT INTO workspace_pairing VALUES (?,?,?,?) ON CONFLICT(actor)
                          DO UPDATE SET code_hash=excluded.code_hash, issued=excluded.issued, expires=excluded.expires""",
                       (row["id"], self.token_hash(code), now, now + PAIR_LIFETIME))
        self._prune_pairing_spool(now)
        return {"success": True, "code": code, "expires": now + PAIR_LIFETIME}

    def _prune_pairing_spool(self, now):
        if not private_location(self.link_dir, directory=True):
            return
        # Discard only expired, name-constrained local evidence. Bounded work
        # keeps signup/link independent of an operator's unrelated files.
        try:
            with os.scandir(self.link_dir) as entries:
                for index, entry in enumerate(entries):
                    if index >= PAIR_SPOOL_SCAN_LIMIT:
                        break
                    if not re.fullmatch(r"[A-Z2-7]{12}\.pair(?:\.tmp)?", entry.name):
                        continue
                    try:
                        info = entry.stat(follow_symlinks=False)
                        if (stat.S_ISREG(info.st_mode)
                                and (os.name != "posix" or info.st_uid == os.getuid())
                                and now - info.st_mtime > 2 * PAIR_LIFETIME):
                            Path(entry.path).unlink()
                    except OSError:
                        continue
        except OSError:
            pass

    def _pair_receipt(self, code, issued, now):
        if not private_location(self.link_dir, directory=True):
            raise WorkspaceError("The DCS linking bridge is offline.", 503)
        path = self.link_dir / (code + ".pair")
        try:
            if path.is_symlink():
                raise OSError("Unexpected pairing receipt")
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                         | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_BINARY", 0))
            with os.fdopen(fd, "rb") as stream:
                info = os.fstat(stream.fileno())
                if (not stat.S_ISREG(info.st_mode)
                        or (os.name == "posix" and info.st_uid != os.getuid())
                        or not issued - 1 <= info.st_mtime <= now + 1):
                    raise OSError("Unexpected pairing receipt")
                receipt = PAIR_RECEIPT.fullmatch(stream.read(64))
                if not receipt or receipt[1].decode("ascii") != code:
                    raise OSError("Unexpected pairing receipt")
        except FileNotFoundError:
            return None, None, None
        except OSError:
            raise WorkspaceError("No valid reply from DCS. Generate a new code.", 409) from None
        return path, native_owner(receipt[2]), int(receipt[3])

    def _linked_delivery_owner(self):
        path = private_location(self.linked_delivery_pilot_file, directory=False)
        if path is None:
            return None
        try:
            with path.open("rb") as stream:
                value = stream.read(34)
        except OSError:
            return None
        return native_owner(value[:-1]) if re.fullmatch(rb"[0-9a-f]{32}\n", value) else None

    def finish_link(self, session, raw_code):
        code = raw_code.strip().upper() if isinstance(raw_code, str) else ""
        if not PAIR_CODE.fullmatch(code):
            raise WorkspaceError("Enter the exact code displayed by the Companion.")
        with self.connect(write=True) as db:
            row, now = self._pending_signup(db, session)
            challenge = db.execute("SELECT * FROM workspace_pairing WHERE actor=?", (row["id"],)).fetchone()
            if not challenge or not hmac.compare_digest(challenge["code_hash"], self.token_hash(code)):
                raise WorkspaceError("That is not your current link code.", 409)
            if challenge["expires"] <= now:
                raise WorkspaceError("That code expired. Generate a new code.", 410)
            path, owner, side = self._pair_receipt(code, challenge["issued"], now)
            if path is None:
                return {"success": True, "status": "waiting"}
            duplicate = db.execute("SELECT 1 FROM workspace_signups WHERE dcs_owner=?", (owner,)).fetchone()
            db.execute("DELETE FROM workspace_pairing WHERE actor=?", (row["id"],))
            if not duplicate:
                award = (self.linked_delivery_merits if self.delivery_dir and side == DELIVERY_SIDE
                         and owner == self._linked_delivery_owner() else 0)
                db.execute("UPDATE workspace_signups SET side=?, dcs_owner=? WHERE id=?", (side, owner, row["id"]))
                state = self._read(db)
                self._initialize_player(state, {**dict(row), "side": side, "starter_merits": award})
                self._save(db, state)
                self._record(db, row["id"], "dcs_linked", {"side": side, "merits": award})
        try:
            path.unlink(missing_ok=True)
        except OSError:
            # A committed challenge is never usable again, even if cleanup fails.
            pass
        if duplicate:
            raise WorkspaceError("That DCS account is already linked. Sign in to its Companion account.", 409)
        return {"success": True, "status": "linked"}

    def _delivery_actor(self, db):
        if not self.delivery_dir:
            return None
        if self.configured_delivery_actor:
            return self.configured_delivery_actor
        owner = self._linked_delivery_owner()
        if owner:
            row = db.execute("SELECT id FROM workspace_signups WHERE dcs_owner=? AND side=2", (owner,)).fetchone()
            return row["id"] if row else None
        return None

    def _delivery_eligible(self, actor, side):
        if not actor or side != DELIVERY_SIDE or not self.delivery_dir:
            return False
        with self.connect() as db:
            return actor == self._delivery_actor(db)

    def _scoped_delivery(self, order):
        # Earlier demo escrow entries are never reclassified as AIM-120D orders.
        # BF3 orders created before per-airfield recording were Mineralnye Vody only.
        if not (isinstance(order, dict) and self.delivery_airfield and order.get("item") == DELIVERY_ITEM
                and order.get("airfield", DELIVERY_AIRFIELD) == self.delivery_airfield
                and isinstance(order.get("order_id"), str) and DELIVERY_ORDER_ID.fullmatch(order["order_id"])):
            return False
        protocol, qty = order.get("protocol"), order.get("quantity", 1)
        return type(protocol) is int and type(qty) is int and ((protocol == DELIVERY_VERSION and qty == 1)
               or (self.delivery_batch and self.delivery_airfield == "Vaziani"
                   and protocol == DELIVERY_BATCH_VERSION and "quantity" in order and 1 <= qty <= DELIVERY_BATCH_MAX))

    def _current_delivery(self, order):
        return self._scoped_delivery(order) and order["protocol"] == self.delivery_protocol

    def _delivery_path(self, name):
        directory = self.delivery_dir
        if directory is None or not directory.is_dir() or directory.resolve(strict=True) != directory:
            raise OSError("Simulator delivery directory unavailable")
        return directory / name

    def _read_delivery_file(self, name, *, max_age=None):
        return self._read_delivery_path(self._delivery_path(name), max_age=max_age)

    @staticmethod
    def _read_delivery_path(path, *, max_age=None):
        if path.is_symlink():
            raise OSError("Unsafe simulator delivery file")
        try:
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
                         | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_BINARY", 0))
        except FileNotFoundError:
            return None
        with os.fdopen(fd, "rb") as handle:
            details = os.fstat(handle.fileno())
            if not stat.S_ISREG(details.st_mode):
                raise OSError("Unsafe simulator delivery file")
            if max_age is not None and not 0 <= time.time() - details.st_mtime <= max_age:
                return None
            value = handle.read(257)
        if len(value) > 256:
            raise OSError("Unexpected simulator delivery file size")
        return value

    def _delivery_profile_ready(self):
        if self.delivery_batch:
            expected = b"BF4 VIPER_D_READY VAZIANI\n" if self.delivery_airfield == "Vaziani" else None
        else:
            expected = DELIVERY_AIRFIELD_CAPABILITIES.get(self.delivery_airfield)
        if expected is None:
            return False
        try:
            return self._read_delivery_file(DELIVERY_CAPABILITY, max_age=DELIVERY_CAPABILITY_MAX_AGE) == expected
        except (OSError, RuntimeError):
            return False

    def _delivery_lane_empty(self):
        return all(self._read_delivery_file(name) is None for name in DELIVERY_JOURNAL)

    @staticmethod
    def _delivery_request(order):
        protocol = order["protocol"]
        quantity = f" {order['quantity']}" if protocol == DELIVERY_BATCH_VERSION else ""
        return f"BF{protocol} {order['order_id']} {DELIVERY_ITEM}{quantity}\n".encode("ascii")

    @staticmethod
    def _delivery_guard(order):
        return f"BF{order['protocol']} {order['order_id']} APPLYING\n".encode("ascii")

    @staticmethod
    def _receipt_fields(order, raw):
        regex = BATCH_RECEIPT if order["protocol"] == DELIVERY_BATCH_VERSION else RECEIPT
        receipt = regex.fullmatch(raw or b"")
        if receipt and receipt[1].decode("ascii") == order["order_id"]:
            _, status, lo, hi, code = (part.decode("ascii") for part in receipt.groups())
            return status, int(lo), int(hi), code

    @staticmethod
    def _native_outcome(order, fields, guard, expected_guard):
        status, before, after, code = fields
        quantity = order.get("quantity", 1)
        batch = order["protocol"] == DELIVERY_BATCH_VERSION
        valid_before = (0 <= before <= DELIVERY_STOCK_MAX - quantity) if batch else before == 0
        if guard == expected_guard and valid_before:
            if status == "APPLYING" and after == -1 and code == "prewrite":
                return "applying"
            if (status == "READY" and after == before + quantity and code == "verified"
                    and order.get("applying_before", before) == before):
                return "ready"
        if status == "REJECTED" and guard is None and not order.get("applying_seen"):
            if code in ("invalid_setup", "stock_unavailable") and before == after == -1:
                return "rejected"
            if before == after and ((not batch and code == "stock_not_zero" and before > 0)
                    or (batch and code == "stock_limit" and before >= 0 and before + quantity > DELIVERY_STOCK_MAX)):
                return "rejected"
        return "review"

    @staticmethod
    def _sync_delivery_dir(path):
        if hasattr(os, "O_DIRECTORY"):
            dir_fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)

    def _history_directory(self, *, create=False):
        directory = self._delivery_path(DELIVERY_HISTORY)
        if create:
            try:
                directory.mkdir(mode=0o700)
            except FileExistsError:
                pass
            else:
                self._sync_delivery_dir(directory.parent)
        try:
            details = directory.lstat()
        except FileNotFoundError:
            return None
        if (not stat.S_ISDIR(details.st_mode) or directory.resolve(strict=True) != directory
                or (os.name == "posix" and (details.st_uid != os.getuid() or stat.S_IMODE(details.st_mode) != 0o700))):
            raise OSError("Unsafe simulator delivery history")
        return directory

    def _retired_seal(self, order_id):
        if not DELIVERY_ORDER_ID.fullmatch(order_id):
            raise OSError("Unexpected simulator delivery ID")
        directory = self._history_directory()
        return None if directory is None else self._read_delivery_path(directory / (order_id + ".retired"))

    @staticmethod
    def _retired_value(order_id):
        return f"BF4 {order_id} RETIRED\n".encode("ascii")

    def _seal_retired(self, order_id):
        directory = self._history_directory(create=True)
        if directory is None:
            raise OSError("Simulator delivery history unavailable")
        sentinel = directory / (order_id + ".retired")
        expected = self._retired_value(order_id)
        if self._read_delivery_path(sentinel) is None:
            fd, temporary = tempfile.mkstemp(prefix=".retiring-", dir=directory)
            try:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(expected)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.link(temporary, sentinel)
            finally:
                Path(temporary).unlink(missing_ok=True)
        if self._read_delivery_path(sentinel) != expected:
            raise OSError("Simulator delivery history seal mismatch")
        self._sync_delivery_dir(directory)

    def _journal_match(self, order, journal):
        request, guard, receipt = journal
        fields = self._receipt_fields(order, receipt)
        return (request == self._delivery_request(order) and fields is not None
                and fields[1:] == (order.get("before"), order.get("after"), order.get("reason"))
                and self._native_outcome(order, fields, guard, self._delivery_guard(order)) == order["status"])

    def _retirement_plan(self, db, order):
        # Locally refused pre-publication attempts refund inventory; unlike a
        # native terminal journal they confer no authority to rotate this lane.
        if (not self.delivery_batch or not self._scoped_delivery(order) or order.get("armed_at") is None
                or order["status"] not in ("ready", "rejected")):
            return None
        key = order["order_id"]
        encoded = json.dumps(order, sort_keys=True, separators=(",", ":"))
        row = db.execute("SELECT order_state, request, guard, receipt FROM workspace_delivery_history WHERE order_id=?",
                         (key,)).fetchone()
        current = tuple(self._read_delivery_file(name) for name in DELIVERY_JOURNAL)
        seal = self._retired_seal(key)
        if row is None:
            return (encoded, current, False) if seal is None and self._journal_match(order, current) else None
        recorded = tuple(row)[1:]
        if row[0] != encoded or not self._journal_match(order, recorded):
            return None
        if seal is None and current == recorded:
            return encoded, recorded, True
        if seal == self._retired_value(key) and all(file is None or file == saved for file, saved in zip(current, recorded)):
            return encoded, recorded, True
        return None

    def _retake_owner(self, db, actor, native_owner_key):
        if (self.configured_delivery_actor is not None or not native_owner_key
                or self._linked_delivery_owner() != native_owner_key or self._delivery_actor(db) != actor):
            raise WorkspaceError("The selected account is not the current approved linked BLUE pilot.", 409)

    def _retire_prior_delivery(self, session, quantity, *, retake=None):
        """Commit exact journal bytes before touching the live simulator directory."""
        with self.connect(write=True) as db:
            state = self._read(db)
            if retake is None:
                self._dispatch_player(db, state, session, quantity)
                actor = session["actor"]
            else:
                actor, owner = retake
                self._retake_owner(db, actor, owner)
            order = state.get("delivery")
            if not self._delivery_profile_ready():
                raise WorkspaceError("The AIM-120D recording profile is not ready in DCS.", 409)
            self._history_directory(create=True)
            if not order:
                if retake is not None:
                    raise WorkspaceError("The selected pilot has no verified terminal order to archive.", 409)
                return None
            plan = self._retirement_plan(db, order) if order.get("actor") == actor else None
            if plan is None:
                raise WorkspaceError("The previous delivery needs confirmation before starting another.", 409)
            encoded, journal, known = plan
            key = order["order_id"]
            if not known:
                db.execute("INSERT INTO workspace_delivery_history VALUES (?,?,?,?,?,?)",
                           (key, encoded, *journal, iso_now()))
        with self.connect(write=True) as db:
            if retake is not None:
                self._retake_owner(db, actor, owner)
            order = self._read(db).get("delivery")
            if not order or order.get("order_id") != key:
                raise WorkspaceError("Another delivery already started.", 409)
            plan = self._retirement_plan(db, order)
            if plan is None or not plan[2]:
                raise WorkspaceError("The previous delivery journal changed.", 409)
            self._seal_retired(key)
            # Withdraw the native request first. The permanent per-ID seal is
            # durable before this point, so a cached old request cannot replay.
            # Already-missing entries are permitted only with the exact seal
            # and SQLite archive; this resumes a partially completed cleanup.
            for name, saved in zip(DELIVERY_JOURNAL, plan[1]):
                present = self._read_delivery_file(name)
                if present is not None:
                    if present != saved:
                        raise WorkspaceError("The previous delivery journal changed.", 409)
                    path = self._delivery_path(name)
                    path.unlink()
                    self._sync_delivery_dir(path.parent)
        return key

    def retire_linked_delivery_for_retake(self, old_actor):
        """Trusted local maintenance only; never expose through mutate/HTTP."""
        if (not self.delivery_batch or self.delivery_airfield != "Vaziani" or self.linked_delivery_merits != 50
                or not isinstance(old_actor, str) or not ACCOUNT_ID.fullmatch(old_actor)):
            raise WorkspaceError("The exact approved recording account and its 50 CM policy are required.", 409)
        owner = self._linked_delivery_owner()
        try:
            key = self._retire_prior_delivery(None, None, retake=(old_actor, owner))
            with self.connect(write=True) as db:
                self._retake_owner(db, old_actor, owner)
                state = self._read(db)
                order = state.get("delivery") or {}
                if (order.get("order_id") != key or order.get("actor") != old_actor
                        or not self._retirement_plan(db, order) or not self._delivery_lane_empty()
                        or self._retired_seal(key) != self._retired_value(key)):
                    raise WorkspaceError("The archived recording lane is not ready for reassignment.", 409)
                result = db.execute("UPDATE workspace_signups SET dcs_owner=? WHERE id=? AND side=2 AND dcs_owner=?",
                                    ("retired:" + old_actor, old_actor, owner))
                if result.rowcount != 1:
                    raise WorkspaceError("The approved native link has changed.", 409)
                del state["delivery"]
                self._save(db, state)
                self._record(db, old_actor, "dcs_link_retired", {"native_owner_hash": owner, "order_id": key})
        except (OSError, RuntimeError) as exc:
            raise WorkspaceError("The authenticated delivery history is unavailable.", 503) from exc

    def _publish_delivery_request(self, order):
        target = self._delivery_path(DELIVERY_REQUEST)
        fd, temporary = tempfile.mkstemp(prefix=".battlefront-delivery-", dir=target.parent)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(self._delivery_request(order))
                handle.flush()
                os.fsync(handle.fileno())
            if not self._delivery_profile_ready():
                return False
            # Publishing a complete inode without replacing an existing request
            # means a prior operation cannot be lost or silently overwritten.
            os.link(temporary, target)
            self._sync_delivery_dir(target.parent)
            return True
        finally:
            Path(temporary).unlink(missing_ok=True)

    def _delivery_view(self, order, *, can_send=False):
        result = {"status": order["status"] if order else "idle", "item": DELIVERY_ITEM,
                  "order_id": order["order_id"] if order else None, "airfield": self.delivery_airfield}
        if self.delivery_batch:
            result.update(quantity=order.get("quantity", 1) if order else 0,
                          max_quantity=DELIVERY_BATCH_MAX, can_send=can_send)
        return result

    def _finish_delivery(self, db, state, order, status, reason, before=None, after=None):
        quantity = order.get("quantity", 1)
        if status == "rejected":
            player = state["players"].get(order["actor"])
            if not player or player.get("side") != DELIVERY_SIDE:
                status, reason = "review", "escrow_owner_unavailable"
            else:
                inventory = player["inventory"]
                inventory[DELIVERY_ITEM] = inventory.get(DELIVERY_ITEM, 0) + quantity
        order.update(status=status, reason=reason, before=before, after=after)
        self._save(db, state)
        self._record(db, order["actor"], "delivery_" + status, {
            "order_id": order["order_id"], "item": DELIVERY_ITEM, "reason": reason,
            "before": before, "after": after, "refunded_units": quantity if status == "rejected" else 0})

    def reconcile_delivery(self):
        """Settle a private receipt or publish one never-attempted staged request."""
        if not self.delivery_dir:
            return
        claim = None
        with self.connect(write=True) as db:
            state = self._read(db)
            order = state.get("delivery")
            if not self._current_delivery(order) or order["actor"] != self._delivery_actor(db) or order["status"] != "pending":
                return
            try:
                request = self._read_delivery_file(DELIVERY_REQUEST)
                raw = self._read_delivery_file(DELIVERY_RECEIPT)
                guard = self._read_delivery_file(DELIVERY_GUARD)
            except (OSError, RuntimeError):
                # Losing visibility of the lane is not proof that no item was delivered.
                return
            expected = self._delivery_request(order)
            armed_at = order["armed_at"]
            if armed_at is None:
                if request is not None or raw is not None or guard is not None:
                    self._finish_delivery(db, state, order, "review", "lane_occupied")
                    return
                if not self._delivery_profile_ready():
                    self._finish_delivery(db, state, order, "rejected", "recording_profile_unavailable")
                    return
                # Commit the intent first. A crash after this point never causes
                # another publish attempt for the same order.
                order["armed_at"] = int(time.time())
                claim = order["order_id"]
                self._save(db, state)
            elif request == expected:
                fields = self._receipt_fields(order, raw)
                if fields is None:
                    return
                status, before, after, code = fields
                expected_guard = self._delivery_guard(order)
                outcome = self._native_outcome(order, fields, guard, expected_guard)
                if status == "APPLYING" and self._native_outcome(order, fields, expected_guard, expected_guard) == "applying":
                    if outcome != "applying":
                        return     # Incomplete guard visibility cannot confirm any write.
                    if not order.get("applying_seen"):
                        order["applying_seen"] = True
                        if order["protocol"] == DELIVERY_BATCH_VERSION:
                            order["applying_before"] = before
                        self._save(db, state)
                    elif order.get("applying_before", before) != before:
                        self._finish_delivery(db, state, order, "review", "unverified_receipt", before, after)
                    return
                if outcome in ("ready", "rejected"):
                    self._finish_delivery(db, state, order, outcome, code, before, after)
                else:
                    self._finish_delivery(db, state, order, "review",
                                          code if status == "REVIEW" else "unverified_receipt", before, after)
            elif request is not None or int(time.time()) - armed_at >= 30:
                self._finish_delivery(db, state, order, "review", "publication_uncertain")
        if claim:
            with self.connect(write=True) as db:
                state = self._read(db)
                order = state.get("delivery")
                if (not self._current_delivery(order) or order["actor"] != self._delivery_actor(db)
                        or order["order_id"] != claim or order["status"] != "pending"):
                    return
                try:
                    if self._publish_delivery_request(order) is False:
                        if self._delivery_lane_empty():
                            self._finish_delivery(db, state, order, "rejected", "recording_profile_unavailable")
                        else:
                            self._finish_delivery(db, state, order, "review", "lane_occupied")
                except (OSError, RuntimeError):
                    # The directory entry might already have reached DCS.
                    # Keep the item in escrow and never retry the write.
                    self._finish_delivery(db, state, order, "review", "publication_uncertain")

    def _dispatch_player(self, db, state, session, quantity, *, inventory=True):
        actor, side = session["actor"], session["side"]
        if not db.execute("SELECT 1 FROM workspace_sessions WHERE hash=? AND expires>?",
                          (session["hash"], int(time.time()))).fetchone():
            raise WorkspaceError("Sign in to request simulator delivery.", 401)
        player = state["players"].get(actor)
        if not player or player["side"] != side or actor != self._delivery_actor(db):
            raise WorkspaceError("Pilot account unavailable.", 403)
        if inventory and player["inventory"].get(DELIVERY_ITEM, 0) < quantity:
            units = "one" if quantity == 1 else str(quantity)
            raise WorkspaceError(f"Requisition {units} {DELIVERY_ITEM} in the companion armory first.", 409)
        return player

    def _send_to_dcs(self, session, body):
        actor, side = session["actor"], session["side"]
        if not self._delivery_eligible(actor, side):
            raise WorkspaceError("Simulator delivery is not enabled for this account.", 403)
        if self.delivery_batch:
            if (set(body) not in ({"munition"}, {"munition", "quantity"}) or body.get("munition") != DELIVERY_ITEM):
                raise WorkspaceError(f"Only the {DELIVERY_ITEM} can be sent in this profile.", 400)
            quantity = integer(body.get("quantity", 1), "simulator quantity", 1, DELIVERY_BATCH_MAX)
        else:
            if body != {"munition": DELIVERY_ITEM}:
                raise WorkspaceError(f"Only one {DELIVERY_ITEM} from your companion armory can be sent.", 400)
            quantity = 1
        self.reconcile_delivery()
        retired = None
        if self.delivery_batch:
            try:
                retired = self._retire_prior_delivery(session, quantity)
            except (OSError, RuntimeError) as exc:
                raise WorkspaceError("The simulator delivery history is unavailable.", 503) from exc
        with self.connect(write=True) as db:
            state = self._read(db)
            player = self._dispatch_player(db, state, session, quantity, inventory=False)
            prior = state.get("delivery")
            if prior and (not self.delivery_batch or prior.get("order_id") != retired):
                raise WorkspaceError("This recording lane already has an order.", 409)
            if not self._delivery_profile_ready():
                raise WorkspaceError("The AIM-120D recording profile is not ready in DCS.", 409)
            inventory = player["inventory"]
            if inventory.get(DELIVERY_ITEM, 0) < quantity:
                raise WorkspaceError(f"Requisition {quantity if quantity != 1 else 'one'} {DELIVERY_ITEM} in the companion armory first.", 409)
            try:
                occupied = not self._delivery_lane_empty()
                if prior and self._retired_seal(retired) != self._retired_value(retired):
                    occupied = True
                for _ in range(8):
                    key = secrets.token_hex(16)
                    if (not self.delivery_batch or (self._retired_seal(key) is None and not db.execute(
                            "SELECT 1 FROM workspace_delivery_history WHERE order_id=?", (key,)).fetchone())):
                        break
                else:
                    raise OSError("No unused simulator delivery ID")
            except (OSError, RuntimeError):
                raise WorkspaceError("The simulator recording lane is unavailable.", 503)
            if occupied:
                raise WorkspaceError("The simulator recording lane is not empty.", 409)
            inventory[DELIVERY_ITEM] -= quantity
            if not inventory[DELIVERY_ITEM]:
                del inventory[DELIVERY_ITEM]
                player["planned_loadout"].pop(DELIVERY_ITEM, None)
            order = {"order_id": key, "actor": actor, "item": DELIVERY_ITEM,
                     "protocol": self.delivery_protocol, "airfield": self.delivery_airfield,
                     "status": "pending", "armed_at": None, "created_at": iso_now()}
            if self.delivery_batch:
                order["quantity"] = quantity
            state["delivery"] = order
            self._save(db, state)
            self._record(db, actor, "delivery_escrow", {"order_id": order["order_id"],
                "item": DELIVERY_ITEM, "quantity": quantity, "merits_charged": 0})
        self.reconcile_delivery()
        delivery = self.get_state(session)["delivery"]
        message = {"rejected": "Delivery did not start; the item is back in your armory.",
                   "ready": "Simulator delivery verified; ready to rearm.",
                   "review": "Delivery outcome needs review; the item remains in escrow."}.get(
            delivery["status"], "Delivery requested; item is held in escrow until confirmed.")
        return {"success": True, "delivery": delivery, "message": message}

    def get_state(self, session):
        actor, side = (session["actor"], session["side"]) if session else (None, None)
        eligible = self._delivery_eligible(actor, side)
        if eligible:
            self.reconcile_delivery()
        delivery = None
        with self.connect() as db:
            state = self._read(db)
            if eligible:
                order = state.get("delivery")
                own_order = self._scoped_delivery(order) and order["actor"] == actor
                ready = self._delivery_profile_ready() if not order or (self.delivery_batch and own_order) else False
                if (not order and ready) or own_order:
                    can_send = False
                    if self.delivery_batch and ready:
                        try:
                            self._history_directory()  # A malformed archive location is never dispatchable.
                            can_send = (self._retirement_plan(db, order) is not None if own_order
                                        else self._delivery_lane_empty())
                        except (OSError, RuntimeError):
                            pass
                    delivery = self._delivery_view(order, can_send=can_send)
        players = {key: (row if key == actor else {k: row[k] for k in ("callsign", "side", "stats")})
                   for key, row in state["players"].items()}
        listings = [row for row in state["listings"].values() if row["side"] == side]
        # Display names can change; ownership continues to use immutable actor keys.
        for row in listings:
            row["seller_callsign"] = players[row["seller"]]["callsign"]
        trades = [row for row in state["trades"] if row["side"] == side]
        result = {"workspace": {"mode": "production", "player_id": actor if side in (1, 2) else None,
                              "authenticated": actor is not None, "signup_enabled": self.link_dir is not None,
                              "link_required": bool(session and session.get("registered") and side is None),
                              "csrf": session["csrf"] if session else None,
                              "can_command": session["can_command"] if session else False},
                "currency_name": "Companion Merits", "currency_symbol": "CM", "munition_catalog": self.catalog,
                "players": players, "marketplace": listings, "trade_history": trades}
        if delivery is not None:
            result["delivery"] = delivery
        return result

    def get_campaign(self, session, sectors, projection):
        with self.connect() as db:
            state = self._read(db)
        side = str(session["side"]) if session and session["side"] in (1, 2) else None
        commanders = state["commanders"]
        return {
            "operations": {side: state["operations"][side]} if side in state["operations"] else {},
            "coalitions": {side: {"human_commander": commanders.get(side)}} if side else {},
            "previous_plans": [op for op in state["previous_plans"] if str(op["side"]) == side],
            "sectors": sectors,
            "sector_source": "live_dcs" if projection else "planning_map",
            "live_snapshot": projection,
            "campaign_scope": "persistent_companion",
        }

    def mutate(self, path, session, body, sectors):
        if path == "/api/dcs/deliver":
            return self._send_to_dcs(session, body)
        actor, side = session["actor"], session["side"]
        if "side" in body and (type(body["side"]) is not int or body["side"] != side):
            raise WorkspaceError("This operation is only available to your assigned coalition.", 403)
        if any(k in body and body[k] not in (None, "", actor) for k in ("player_id", "seller_id", "buyer_id")):
            raise WorkspaceError("This action must be made by the signed-in pilot.", 403)
        # Player, inventory, listing, money and audit entry commit together,
        # including when several server threads/processes share the durable file.
        with self.connect(write=True) as db:
            if not db.execute("SELECT 1 FROM workspace_sessions WHERE hash=? AND expires>?",
                              (session["hash"], int(time.time()))).fetchone():
                raise WorkspaceError("Sign in to change the workspace.", 401)
            state = self._read(db)
            player = state["players"].get(actor)
            if not player or player["side"] != side:
                raise WorkspaceError("Pilot account unavailable.", 403)
            data, audit = self._apply(path, state, actor, side, player, session["can_command"], body, sectors)
            self._save(db, state)
            self._record(db, actor, path.rsplit("/", 1)[1], audit)
        return {"success": True, **data}

    def _apply(self, path, state, actor, side, player, can_command, body, sectors):
        if path == "/api/player/set_callsign":
            name = trim_text(body.get("callsign"), "callsign", 24)
            if not CALLSIGN.fullmatch(name):
                raise WorkspaceError("Use letters, digits, spaces, underscores or hyphens for a callsign.")
            rivals = [p["callsign"].casefold() for key, p in state["players"].items() if key != actor]
            rivals.extend(a["callsign"].casefold() for key, a in self.by_id.items() if key != actor)
            if name.casefold() in rivals:
                raise WorkspaceError("That callsign is already in use.", 409)
            before = player["callsign"]
            player["callsign"] = name
            return {"player_id": actor, "player": player, "message": "Callsign updated."}, {"before": before, "after": name}
        inventory = player["inventory"]
        listings = state["listings"]
        if path in ("/api/requisition", "/api/marketplace/list", "/api/armory/mount"):
            item = trim_text(body.get("munition"), "item")
            spec = self.catalog.get(item)
            if not spec or spec.get("coalition") != ("REDFOR" if side == 1 else "BLUFOR"):
                raise WorkspaceError("Item unavailable for your coalition.", 403)
            if path == "/api/requisition":
                cost = integer(spec.get("cost_points"), "catalog price", 1, 10000)
                before = player["points"]
                if before < cost:
                    raise WorkspaceError(f"Insufficient Companion Merits: need {cost} CM.", 409)
                if inventory.get(item, 0) >= 1000:
                    raise WorkspaceError("Item storage limit reached.", 409)
                player["points"] -= cost
                inventory[item] = inventory.get(item, 0) + 1
                return {"message": "Item added to companion armory.", "new_balance": player["points"]}, {
                    "item": item, "quantity": 1, "cost": cost, "before": before, "after": player["points"]}
            if path == "/api/armory/mount":
                if inventory.get(item, 0) < 1:
                    raise WorkspaceError("You do not have this item in your companion armory.", 409)
                player["planned_loadout"][item] = 1
                return {"message": "Added to planned loadout. No DCS aircraft was changed."}, {"item": item}
            quantity = integer(body.get("quantity"), "quantity", 1, 50)
            price = integer(body.get("price_points"), "total asking price", 1, 10000)
            if inventory.get(item, 0) < quantity:
                raise WorkspaceError("Not enough stock for this listing.", 409)
            if sum(row["seller"] == actor for row in listings.values()) >= 20:
                raise WorkspaceError("Active listing limit reached.", 409)
            inventory[item] -= quantity
            if inventory[item] == 0:
                del inventory[item]
                player["planned_loadout"].pop(item, None)
            listing_id = "listing_" + secrets.token_hex(12)
            listing = {"id": listing_id, "seller": actor, "seller_callsign": player["callsign"], "side": side,
                       "item": item, "quantity": quantity, "price_points": price, "created_at": iso_now(), "status": "active"}
            listings[listing_id] = listing
            return {"message": "Listing posted; stock is held in escrow.", "listing": listing}, listing
        if path in ("/api/marketplace/buy", "/api/marketplace/cancel"):
            listing_id = trim_text(body.get("listing_id"), "listing")
            listing = listings.get(listing_id)
            if not listing or listing["side"] != side:
                raise WorkspaceError("Listing unavailable or already sold.", 404)
            item, quantity, price = listing["item"], listing["quantity"], listing["price_points"]
            if path.endswith("/cancel"):
                if listing["seller"] != actor:
                    raise WorkspaceError("Only the listing owner can cancel it.", 403)
                inventory[item] = inventory.get(item, 0) + quantity
                del listings[listing_id]
                return {"message": "Listing cancelled; stock returned to your inventory."}, listing
            if listing["seller"] == actor:
                raise WorkspaceError("You cannot buy your own listing.", 409)
            if player["points"] < price:
                raise WorkspaceError(f"Insufficient Companion Merits: need {price} CM.", 409)
            if inventory.get(item, 0) + quantity > 1000:
                raise WorkspaceError("Item storage limit reached.", 409)
            seller = state["players"][listing["seller"]]
            buyer_before, seller_before = player["points"], seller["points"]
            player["points"] -= price
            seller["points"] += price
            inventory[item] = inventory.get(item, 0) + quantity
            del listings[listing_id]
            trade = {"id": listing_id, "side": side, "buyer": actor, "seller": listing["seller"],
                     "item": item, "quantity": quantity, "price_points": price, "timestamp": iso_now()}
            state["trades"] = [trade, *state["trades"][:249]]
            audit = {**trade, "buyer_before": buyer_before, "buyer_after": player["points"],
                     "seller_before": seller_before, "seller_after": seller["points"]}
            return {"message": "Trade settled.", "trade": trade, "new_balance": player["points"]}, audit
        return self._operation(path, state, actor, side, player, can_command, body, sectors)

    def _operation(self, path, state, actor, side, player, can_command, body, sectors):
        side_key = str(side)
        ops, commanders = state["operations"], state["commanders"]
        op = ops.get(side_key)
        action = path.rsplit("/", 1)[1]
        if action == "command":
            if not can_command:
                raise WorkspaceError("Only assigned coalition commanders can take command.", 403)
            current = commanders.get(side_key)
            if current == actor:
                del commanders[side_key]
                return {"message": "Coalition command relinquished."}, {"side": side, "commander": None}
            if current in self.by_id:
                raise WorkspaceError("Your coalition already has a commander.", 409)
            commanders[side_key] = actor
            return {"message": "Coalition command assumed."}, {"side": side, "commander": actor}
        if action == "propose":
            target = trim_text(body.get("target_sector"), "target sector")
            if not any(row.get("name") == target and row.get("side") in (1, 2) and row["side"] != side for row in sectors):
                raise WorkspaceError("Choose an enemy sector from the campaign map.")
            if op and op["status"] == "PLANNED":
                raise WorkspaceError("This coalition has an open plan already.", 409)
            if op:
                state["previous_plans"] = [op, *state["previous_plans"][:49]]
            roles = [("Lead", "Flight lead"), ("Escort", "Escort wingman"),
                     ("Strike", "Strike flight"), ("Support", "Mission support")]
            op = {"id": "plan_" + secrets.token_hex(8), "name": f"Operation {target}", "side": side,
                  "status": "PLANNED", "target_sector": target, "target_quadrant": "Caucasus",
                  "coordinator": player["callsign"], "frequency": "Coordinate in DCS",
                  "created_at": iso_now(), "objective_desc": "Coalition briefing only. This plan does not launch a DCS flight.",
                  "slots": [{"role": key, "role_title": title, "airframes": "Confirm in DCS", "pilot": None}
                            for key, title in roles]}
            ops[side_key] = op
            return {"message": "Coalition flight plan proposed.", "operation": op}, {"plan": op["id"], "target": target}
        if not op:
            raise WorkspaceError("Your coalition has no current flight plan.", 404)
        if op["status"] != "PLANNED":
            raise WorkspaceError("This flight plan has already been scheduled.", 409)
        if action == "join":
            index = integer(body.get("slot_index"), "roster slot", 0, len(op["slots"]) - 1)
            slot = op["slots"][index]
            if slot["pilot"] and slot["pilot"] != actor:
                raise WorkspaceError("That slot is already assigned.", 409)
            if any(s["pilot"] == actor and s is not slot for s in op["slots"]):
                raise WorkspaceError("Leave your current slot before choosing another.", 409)
            slot["pilot"] = actor
            slot["pilot_callsign"] = player["callsign"]
            return {"message": "Roster slot reserved."}, {"plan": op["id"], "slot": index}
        if action == "leave":
            for index, slot in enumerate(op["slots"]):
                if slot["pilot"] == actor:
                    slot["pilot"] = None
                    slot.pop("pilot_callsign", None)
                    return {"message": "Roster slot released."}, {"plan": op["id"], "slot": index}
            raise WorkspaceError("You do not have a slot in this plan.", 409)
        if action == "launch":
            if not can_command or commanders.get(side_key) != actor:
                raise WorkspaceError("The current coalition commander must schedule this plan.", 403)
            if not any(slot["pilot"] for slot in op["slots"]):
                raise WorkspaceError("Reserve a roster slot first.", 409)
            op["status"] = "SCHEDULED"
            op["departure_timestamp"] = iso_now()
            return {"message": "Plan confirmed in the companion; no DCS flight was launched.", "operation": op}, {"plan": op["id"]}
        raise WorkspaceError("Unknown workspace action.", 404)
