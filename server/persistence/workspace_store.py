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

    def get_state(self, session):
        with self.connect() as db:
            state = self._read(db)
        actor, side = (session["actor"], session["side"]) if session else (None, None)
        players = {key: (row if key == actor else {k: row[k] for k in ("callsign", "side", "stats")})
                   for key, row in state["players"].items()}
        listings = [row for row in state["listings"].values() if row["side"] == side]
        # Display names can change; ownership continues to use immutable actor keys.
        for row in listings:
            row["seller_callsign"] = players[row["seller"]]["callsign"]
        trades = [row for row in state["trades"] if row["side"] == side]
        return {"workspace": {"mode": "production", "player_id": actor, "authenticated": actor is not None,
                              "csrf": session["csrf"] if session else None,
                              "can_command": session["can_command"] if session else False},
                "currency_name": "Companion Merits", "currency_symbol": "CM", "munition_catalog": self.catalog,
                "players": players, "marketplace": listings, "trade_history": trades}

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
