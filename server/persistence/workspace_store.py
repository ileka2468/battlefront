"""Durable web companion state; no simulator side effects or trust in display names."""

import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
import time
from contextlib import contextmanager
from datetime import datetime, timezone


USERNAME = re.compile(r"[a-z0-9][a-z0-9_.-]{1,31}")
CALLSIGN = re.compile(r"[A-Za-z0-9 _-]{1,24}")
TOKEN = re.compile(r"[A-Za-z0-9_-]{43}")
ACCOUNT_ID = re.compile(r"acct_[0-9a-f]{32}")
PBKDF2_ITERATIONS = 600_000
SESSION_SECONDS = 12 * 3600


class WorkspaceError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def credential(password, salt):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), PBKDF2_ITERATIONS).hex()


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
    def __init__(self, db_path, accounts_path, catalog):
        self.path = Path(db_path).resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.accounts = read_accounts(accounts_path)
        self.by_id = {a["id"]: a for a in self.accounts.values()}
        self.catalog = catalog
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
            """)
            db.execute("INSERT OR IGNORE INTO workspace_state VALUES (1,?)",
                (json.dumps(dict(players={}, listings={}, trades=[], operations={}, previous_plans=[], commanders={})),))

    @contextmanager
    def connect(self, *, write=False):
        db = sqlite3.connect(self.path.as_uri() + "?mode=rw", uri=True, timeout=8, isolation_level=None)
        db.row_factory = sqlite3.Row
        try:
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

    def login(self, username, password):
        username = trim_text(username, "account", 32).lower()
        if not isinstance(password, str) or not 1 <= len(password) <= 256 or not USERNAME.fullmatch(username):
            raise WorkspaceError("Invalid account credentials.", 401)
        account = self.accounts.get(username)
        # Unknown usernames take the same password hashing path as known usernames.
        nonce = account["salt"] if account else "0" * 32
        expected = account["password_hash"] if account else "0" * 64
        valid = hmac.compare_digest(credential(password, nonce), expected)
        if not (valid and account):
            raise WorkspaceError("Invalid account credentials.", 401)
        actor, expires = account["id"], int(time.time()) + SESSION_SECONDS
        token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        with self.connect(write=True) as db:
            state = self._read(db)
            previous = state["players"].get(actor)
            if previous and previous["side"] != account["side"]:
                raise WorkspaceError("Account coalition conflicts with existing inventory. Ask the site administrator.", 403)
            if not previous:
                self._initialize_player(state, account)
                self._save(db, state)
                self._record(db, actor, "provision", {"side": account["side"], "merits": state["players"][actor]["points"]})
            db.execute("DELETE FROM workspace_sessions WHERE expires <= ?", (int(time.time()),))
            # Bound active sessions per identity without invalidating other browsers on every sign-in.
            db.execute("""DELETE FROM workspace_sessions WHERE actor=? AND hash NOT IN (
                          SELECT hash FROM workspace_sessions WHERE actor=? ORDER BY expires DESC, rowid DESC LIMIT 7)""",
                       (actor, actor))
            db.execute("INSERT INTO workspace_sessions VALUES (?,?,?,?,?)",
                       (self.token_hash(token), actor, expected, csrf, expires))
        return token

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
        if not account or not hmac.compare_digest(account["password_hash"], row["revision"]):
            return None
        return {"actor": row["actor"], "side": account["side"], "csrf": row["csrf"], "hash": row["hash"],
                "can_command": account["role"] in ("commander", "admin")}

    def check_health(self):
        with self.connect() as db:
            return isinstance(self._read(db)["players"], dict)

    def logout(self, token):
        with self.connect(write=True) as db:
            db.execute("DELETE FROM workspace_sessions WHERE hash=?", (self.token_hash(token),))

