"""Durable web companion state and a fixed, optional simulator delivery lane."""

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
DELIVERY_ITEM = "AIM-120D"
DELIVERY_SIDE = 2
DELIVERY_VERSION = 3
DELIVERY_AIRFIELD = "Mineralnye Vody"
DELIVERY_REQUEST = "battlefront_delivery.request"
DELIVERY_RECEIPT = "battlefront_delivery.receipt"
DELIVERY_GUARD = "battlefront_delivery.applying"
DELIVERY_CAPABILITY = "battlefront_delivery.capability"
DELIVERY_CAPABILITY_CONTENT = b"BF3 VIPER_D_READY\n"
DELIVERY_CAPABILITY_MAX_AGE = 10
DELIVERY_PROFILE = "viper-d-recording"
RECEIPT = re.compile(
    rb"BF3 ([0-9a-f]{32}) (APPLYING|READY|REJECTED|REVIEW) "
    rb"(-1|0|[1-9][0-9]{0,8}) (-1|0|[1-9][0-9]{0,8}) ([a-z][a-z0-9_]{0,39})\n",
)


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
    def __init__(self, db_path, accounts_path, catalog, *, delivery_dir=None, delivery_account=None):
        self.path = Path(db_path).resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.accounts = read_accounts(accounts_path)
        self.by_id = {a["id"]: a for a in self.accounts.values()}
        self.catalog = dict(catalog)
        self.delivery_dir, self.delivery_actor = None, None
        configured = self.accounts.get(delivery_account or "")
        spec = self.catalog.get(DELIVERY_ITEM, {})
        if (configured and configured["side"] == DELIVERY_SIDE and delivery_dir
                and spec.get("coalition") == "BLUFOR" and "F-16C_50" in (spec.get("compatible") or [])
                and spec.get("recording_profile") == DELIVERY_PROFILE):
            try:
                directory = Path(delivery_dir)
                if directory.is_absolute() and directory.resolve(strict=True).is_dir():
                    self.delivery_dir = directory.resolve(strict=True)
                    self.delivery_actor = configured["id"]
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
            """)
            db.execute("INSERT OR IGNORE INTO workspace_state VALUES (1,?)",
                (json.dumps(dict(players={}, listings={}, trades=[], operations={}, previous_plans=[], commanders={})),))
        if self.delivery_actor:
            self.reconcile_delivery()

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

    def _delivery_eligible(self, actor, side):
        return self.delivery_actor is not None and actor == self.delivery_actor and side == DELIVERY_SIDE

    @staticmethod
    def _current_delivery(order):
        # Earlier demo escrow entries are never reclassified as AIM-120D orders.
        return bool(order and order.get("item") == DELIVERY_ITEM and order.get("protocol") == DELIVERY_VERSION)

    def _delivery_path(self, name):
        directory = self.delivery_dir
        if directory is None or not directory.is_dir() or directory.resolve(strict=True) != directory:
            raise OSError("Simulator delivery directory unavailable")
        return directory / name

    def _read_delivery_file(self, name, *, max_age=None):
        path = self._delivery_path(name)
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
        try:
            return self._read_delivery_file(DELIVERY_CAPABILITY, max_age=DELIVERY_CAPABILITY_MAX_AGE) == DELIVERY_CAPABILITY_CONTENT
        except (OSError, RuntimeError):
            return False

    def _delivery_lane_empty(self):
        return all(self._read_delivery_file(name) is None
                   for name in (DELIVERY_REQUEST, DELIVERY_RECEIPT, DELIVERY_GUARD))

    @staticmethod
    def _delivery_request(order):
        return f"BF{DELIVERY_VERSION} {order['order_id']} {DELIVERY_ITEM}\n".encode("ascii")

    @staticmethod
    def _delivery_guard(order):
        return f"BF{DELIVERY_VERSION} {order['order_id']} APPLYING\n".encode("ascii")

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
            if hasattr(os, "O_DIRECTORY"):
                dir_fd = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(dir_fd)
                finally:
                    os.close(dir_fd)
            return True
        finally:
            Path(temporary).unlink(missing_ok=True)

    @staticmethod
    def _delivery_view(order):
        return {"status": order["status"] if order else "idle", "item": DELIVERY_ITEM,
                "order_id": order["order_id"] if order else None, "airfield": DELIVERY_AIRFIELD}

    def _finish_delivery(self, db, state, order, status, reason, before=None, after=None):
        if status == "rejected":
            player = state["players"].get(order["actor"])
            if not player or player.get("side") != DELIVERY_SIDE:
                status, reason = "review", "escrow_owner_unavailable"
            else:
                inventory = player["inventory"]
                inventory[DELIVERY_ITEM] = inventory.get(DELIVERY_ITEM, 0) + 1
        order.update(status=status, reason=reason, before=before, after=after)
        self._save(db, state)
        self._record(db, order["actor"], "delivery_" + status, {
            "order_id": order["order_id"], "item": DELIVERY_ITEM, "reason": reason,
            "before": before, "after": after, "refunded_units": int(status == "rejected")})

    def reconcile_delivery(self):
        """Settle a private receipt or publish one never-attempted staged request."""
        if not self.delivery_actor:
            return
        claim = None
        with self.connect(write=True) as db:
            state = self._read(db)
            order = state.get("delivery")
            if not self._current_delivery(order) or order["actor"] != self.delivery_actor or order["status"] != "pending":
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
                receipt = RECEIPT.fullmatch(raw or b"")
                if receipt is None or receipt[1].decode("ascii") != order["order_id"]:
                    return
                _, status, lo, hi, code = (part.decode("ascii") for part in receipt.groups())
                before, after = int(lo), int(hi)
                armed = guard == self._delivery_guard(order)
                if status == "APPLYING" and (before, after, code) == (0, -1, "prewrite"):
                    if not armed:
                        return     # Guard must precede APPLYING; incomplete visibility cannot confirm a write.
                    if not order.get("applying_seen"):
                        order["applying_seen"] = True
                        self._save(db, state)
                    return
                if status == "READY" and armed and (before, after, code) == (0, 1, "verified"):
                    self._finish_delivery(db, state, order, "ready", code, before, after)
                elif (status == "REJECTED" and guard is None and not order.get("applying_seen")
                      and ((code in ("invalid_setup", "stock_unavailable") and before == after == -1)
                           or (code == "stock_not_zero" and before == after and before > 0))):
                    self._finish_delivery(db, state, order, "rejected", code, before, after)
                else:
                    self._finish_delivery(db, state, order, "review",
                                          code if status == "REVIEW" else "unverified_receipt", before, after)
            elif request is not None or int(time.time()) - armed_at >= 30:
                self._finish_delivery(db, state, order, "review", "publication_uncertain")
        if claim:
            with self.connect(write=True) as db:
                state = self._read(db)
                order = state.get("delivery")
                if (not self._current_delivery(order) or order["actor"] != self.delivery_actor
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

    def _send_to_dcs(self, session, body):
        actor, side = session["actor"], session["side"]
        if not self._delivery_eligible(actor, side):
            raise WorkspaceError("Simulator delivery is not enabled for this account.", 403)
        if body != {"munition": DELIVERY_ITEM}:
            raise WorkspaceError(f"Only one {DELIVERY_ITEM} from your companion armory can be sent.", 400)
        self.reconcile_delivery()
        with self.connect(write=True) as db:
            if not db.execute("SELECT 1 FROM workspace_sessions WHERE hash=? AND expires>?",
                              (session["hash"], int(time.time()))).fetchone():
                raise WorkspaceError("Sign in to request simulator delivery.", 401)
            state = self._read(db)
            player = state["players"].get(actor)
            if not player or player["side"] != side:
                raise WorkspaceError("Pilot account unavailable.", 403)
            if state.get("delivery"):
                raise WorkspaceError("This recording lane already has an order.", 409)
            if not self._delivery_profile_ready():
                raise WorkspaceError("The AIM-120D recording profile is not ready in DCS.", 409)
            inventory = player["inventory"]
            if inventory.get(DELIVERY_ITEM, 0) < 1:
                raise WorkspaceError(f"Requisition one {DELIVERY_ITEM} in the companion armory first.", 409)
            try:
                occupied = not self._delivery_lane_empty()
            except (OSError, RuntimeError):
                raise WorkspaceError("The simulator recording lane is unavailable.", 503)
            if occupied:
                raise WorkspaceError("The simulator recording lane is not empty.", 409)
            inventory[DELIVERY_ITEM] -= 1
            if not inventory[DELIVERY_ITEM]:
                del inventory[DELIVERY_ITEM]
                player["planned_loadout"].pop(DELIVERY_ITEM, None)
            order = {"order_id": secrets.token_hex(16), "actor": actor, "item": DELIVERY_ITEM,
                     "protocol": DELIVERY_VERSION, "status": "pending", "armed_at": None, "created_at": iso_now()}
            state["delivery"] = order
            self._save(db, state)
            self._record(db, actor, "delivery_escrow", {"order_id": order["order_id"],
                "item": DELIVERY_ITEM, "quantity": 1, "merits_charged": 0})
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
        with self.connect() as db:
            state = self._read(db)
        players = {key: (row if key == actor else {k: row[k] for k in ("callsign", "side", "stats")})
                   for key, row in state["players"].items()}
        listings = [row for row in state["listings"].values() if row["side"] == side]
        # Display names can change; ownership continues to use immutable actor keys.
        for row in listings:
            row["seller_callsign"] = players[row["seller"]]["callsign"]
        trades = [row for row in state["trades"] if row["side"] == side]
        result = {"workspace": {"mode": "production", "player_id": actor, "authenticated": actor is not None,
                              "csrf": session["csrf"] if session else None,
                              "can_command": session["can_command"] if session else False},
                "currency_name": "Companion Merits", "currency_symbol": "CM", "munition_catalog": self.catalog,
                "players": players, "marketplace": listings, "trade_history": trades}
        if eligible:
            order = state.get("delivery")
            # Old versions and other pilots' receipts stay private and untouched.
            if ((not order and self._delivery_profile_ready())
                    or (self._current_delivery(order) and order["actor"] == actor)):
                result["delivery"] = self._delivery_view(order)
        return result

    def get_campaign(self, session, sectors, projection):
        with self.connect() as db:
            state = self._read(db)
        side = str(session["side"]) if session else None
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
