import http.server
import socketserver
import json
import os
import sqlite3
import sys
import time
import re
import tempfile
import secrets
import base64
import hmac
import hashlib
from collections import deque
from threading import Lock, RLock
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import math
import html
import traceback
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.cookies import SimpleCookie, CookieError
from urllib.parse import urlsplit, parse_qs, urlencode

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "server", "persistence")))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "server")))
from inventory_manager import InventoryManager
from campaign_manager import CampaignManager
from telemetry_engine import TelemetryEngine

PORT = int(os.environ.get("PORT", 8088))
WEB_DIR = os.path.dirname(__file__)
WORKSPACE = os.environ.get("BF_WORKSPACE") == "1"
DEMO = not WORKSPACE and os.environ.get("BF_DEMO") == "1"
DEMO_PASSWORD = os.environ.get("BF_DEMO_PASSWORD") if DEMO or WORKSPACE else None
WORKSPACE_ORIGIN = os.environ.get("BF_WORKSPACE_ORIGIN", "").rstrip("/")
if WORKSPACE and WORKSPACE_ORIGIN:
    parsed_origin = urlsplit(WORKSPACE_ORIGIN)
    if (parsed_origin.scheme not in ("https", "http") or not parsed_origin.hostname or parsed_origin.username
        or parsed_origin.path or parsed_origin.query or parsed_origin.fragment
        or (parsed_origin.scheme == "http" and parsed_origin.hostname not in ("127.0.0.1", "localhost", "::1"))):
        raise ValueError("BF_WORKSPACE_ORIGIN must be an HTTPS origin or a loopback development origin")
TRACK_KEY = secrets.token_bytes(32)
STATIC = {"/", "/index.html", "/dist/companion.js", "/dist/tailwind.css", "/tacview.js",
          "/caucasus_terrain.js", "/sectors.json", "/vendor/three.min.js",
          "/vendor/OrbitControls.js", "/vendor/GLTFLoader.js"}
STATIC.update({"/airframes.js", "/terrain/caucasus-height.png", "/terrain/caucasus-relief.jpg"})
model_manifest = Path(WEB_DIR) / "models/vendor/manifest.json"
if model_manifest.is_file():
    STATIC.update({"/models/vendor/manifest.json", "/models/vendor/credits.html", "/models/vendor/flightgear-source.zip"})
    for asset in json.loads(model_manifest.read_text(encoding="utf-8")).values():
        path = asset.get("file", "")
        if re.fullmatch(r"/models/vendor/[a-z0-9-]+\.glb", path):
            STATIC.add(path)
    if (model_manifest.parent / "su-35-license.txt").is_file():
        STATIC.add("/models/vendor/su-35-license.txt")
READ_ROUTES = {"/api/state", "/api/campaign", "/api/upgrades", "/api/telemetry",
               "/api/weather", "/api/app-telemetry", "/api/auth/oauth/status", "/mcp", "/mcp/app"}
DEMO_ACTIONS = {"/api/player/set_callsign", "/api/demo/grant_merits", "/api/requisition",
                "/api/marketplace/list", "/api/marketplace/buy", "/api/armory/mount",
                "/api/operations/join", "/api/operations/leave", "/api/operations/propose",
                "/api/operations/command", "/api/operations/launch", "/api/upgrades/purchase",
                "/api/app-telemetry"}
WORKSPACE_ACTIONS = (DEMO_ACTIONS - {"/api/demo/grant_merits", "/api/upgrades/purchase"}) | {
    "/api/marketplace/cancel", "/api/workspace/login", "/api/workspace/logout", "/api/dcs/deliver",
    "/api/workspace/signup", "/api/dcs/link/start", "/api/dcs/link/finish"}
OAUTH_CLIENT_ID = os.environ.get("BF_OAUTH_CLIENT_ID", "").strip()
OAUTH_CLIENT_SECRET = os.environ.get("BF_OAUTH_CLIENT_SECRET", "").strip()
OAUTH_REDIRECT_URI = os.environ.get("BF_OAUTH_REDIRECT_URI", "").strip()
OAUTH_STATES = {}
APP_LOG_LOCK = Lock()
APP_LOGS = deque(maxlen=200)
WEATHER_LOCK = Lock()
WEATHER_CACHE = {"ts": 0.0, "data": None}
CALLSIGN = re.compile(r"[A-Za-z0-9 _-]{1,24}")
SESSIONS = {}
STATE_LOCK = RLock()
LOGIN_LOCK = Lock()
LOGIN_TIMES = deque()
SIGNUP_TIMES = deque()
if WORKSPACE:
    from workspace_store import DELIVERY_AIRFIELD, WorkspaceError, WorkspaceStore, SESSION_SECONDS
    database = os.environ.get("BF_WORKSPACE_DB", str(Path.home() / ".local/state/battlefront/workspace.sqlite3"))
    accounts = os.environ.get("BF_WORKSPACE_ACCOUNTS_FILE")
    default_catalog = Path(WEB_DIR).parent / "server/demo_catalog.json"
    catalog = json.loads(Path(os.environ.get("BF_WORKSPACE_CATALOG", default_catalog)).read_text(encoding="utf-8"))
    workspace = WorkspaceStore(database, accounts, catalog,
        delivery_dir=os.environ.get("BF_DCS_DELIVERY_DIR"),
        delivery_account=os.environ.get("BF_DCS_DELIVERY_ACCOUNT"),
        delivery_airfield=os.environ.get("BF_DCS_DELIVERY_AIRFIELD", DELIVERY_AIRFIELD),
        link_dir=os.environ.get("BF_DCS_LINK_DIR"),
        linked_delivery_pilot_file=os.environ.get("BF_DCS_DELIVERY_LINK_PILOT_FILE"),
        linked_delivery_merits=int(os.environ.get("BF_DCS_LINK_DEMO_MERITS", "0")),
        delivery_batch=os.environ.get("BF_DCS_DELIVERY_BATCH") == "1")
    planning_sectors = json.loads((Path(WEB_DIR) / "sectors.json").read_text(encoding="utf-8"))
elif DEMO:
    demo_root = tempfile.TemporaryDirectory(prefix="battlefront-demo-")
    os.environ["DCS_STATE_LUA_PATH"] = str(Path(demo_root.name) / "disabled.lua")
    catalog = json.loads((Path(WEB_DIR).parent / "server/demo_catalog.json").read_text(encoding="utf-8"))
else:
    mgr = InventoryManager()
    campaign_mgr = CampaignManager()


def create_demo_session():
    token = secrets.token_urlsafe(24)
    root = tempfile.TemporaryDirectory(dir=demo_root.name)
    inv = InventoryManager(str(Path(root.name) / "inventory.json"))
    camp = CampaignManager(str(Path(root.name) / "campaign.json"))
    inventory = inv.load_data()
    inventory["munition_catalog"] = catalog
    inventory["players"]["demo_supply"] = {
        "name": "Demo Supply", "callsign": "Demo Supply", "side": 2,
        "points": 0, "stats": {}, "inventory": {"AIM-120D": 12, "AGM-88C": 8},
    }
    inv.save_data(inventory)
    inv.list_for_sale("demo_supply", "AIM-120D", 2, 7)
    inv.list_for_sale("demo_supply", "AGM-88C", 1, 5)
    session = {"root": root, "inv": inv, "camp": camp, "seen": time.monotonic(), "pilot": None, "writes": 0}
    SESSIONS[token] = session
    return token, session

telemetry_engine = TelemetryEngine()

def anonymize_live_tracks(data):
    # The source IDs may contain simulator unit names. The classroom viewer
    # needs stable keys, not the original identifiers.
    for category in ("units", "missiles"):
        data[category] = [
            {**row, "id": hmac.new(TRACK_KEY, row["id"].encode(), hashlib.sha256).hexdigest()[:16]}
            for row in data[category]
        ]


def record_app_event(kind, path, status=200, detail="", ms=0.0):
    entry = {
        "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "kind": str(kind)[:24],
        "path": str(path)[:120],
        "status": int(status),
        "ms": round(float(ms), 1),
        "detail": str(detail)[:400],
    }
    with APP_LOG_LOCK:
        APP_LOGS.append(entry)


def fetch_caucasus_weather():
    now = time.monotonic()
    with WEATHER_LOCK:
        if WEATHER_CACHE["data"] and now - WEATHER_CACHE["ts"] < 300:
            return WEATHER_CACHE["data"]
    url = ("https://api.open-meteo.com/v1/forecast?latitude=43.45&longitude=39.95"
           "&current=temperature_2m,wind_speed_10m,wind_direction_10m,weather_code")
    payload = {"source": "Open-Meteo", "location": "Sochi / Caucasus", "live": False,
               "temperature_c": None, "wind_kt": None, "wind_deg": None, "summary": "Unavailable"}
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Battlefront/1.0"})
        with urllib.request.urlopen(req, timeout=2.5) as resp:
            raw = json.loads(resp.read(16384).decode("utf-8"))
        cur = raw.get("current") or {}
        wind_kmh = cur.get("wind_speed_10m")
        payload = {
            "source": "Open-Meteo",
            "location": "Sochi / Caucasus",
            "live": True,
            "temperature_c": cur.get("temperature_2m"),
            "wind_kt": round(wind_kmh * 0.539957, 1) if isinstance(wind_kmh, (int, float)) else None,
            "wind_deg": cur.get("wind_direction_10m"),
            "weather_code": cur.get("weather_code"),
            "updated": cur.get("time"),
        }
    except (OSError, ValueError, urllib.error.URLError):
        pass
    with WEATHER_LOCK:
        WEATHER_CACHE["ts"] = now
        WEATHER_CACHE["data"] = payload
    return payload


MCP_TOOLS = [
    {
        "name": "get_theater_status",
        "description": "Get live or recorded Caucasus theater sector counts, coalition status, and active aircraft count.",
        "inputSchema": {"type": "object", "properties": {"replay": {"type": "boolean"}}},
        "_meta": {"ui": {"resourceUri": "ui://battlefront/theater"}},
    },
    {
        "name": "get_sector_threat_picture",
        "description": "Inspect a Caucasus sector's coalition control and nearby aircraft contacts.",
        "inputSchema": {"type": "object", "properties": {"sector": {"type": "string"}}},
    },
    {
        "name": "list_ordnance_orders",
        "description": "List munition catalog items and active player exchange orders.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "propose_flight_plan",
        "description": "Propose a companion flight plan for a target sector (persists in SQLite when authenticated).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target_sector": {"type": "string"},
                "username": {"type": "string"},
                "password": {"type": "string"},
            },
            "required": ["target_sector"],
        },
    },
]

class BattlefrontHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    session_cookie = None
    workspace_cookie = None

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        if urlsplit(getattr(self, "path", "")).path == "/mcp/app":
            self.send_header("X-Frame-Options", "SAMEORIGIN")
        else:
            self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        if self.session_cookie:
            secure = "; Secure" if self.headers.get("X-Forwarded-Proto") == "https" else ""
            self.send_header("Set-Cookie", f"bf_demo={self.session_cookie}; Path=/; HttpOnly; SameSite=Strict{secure}")
        if self.workspace_cookie is not None:
            secure = "; Secure" if WORKSPACE_ORIGIN.startswith("https://") or self.headers.get("X-Forwarded-Proto") == "https" else ""
            age = SESSION_SECONDS if self.workspace_cookie else 0
            self.send_header("Set-Cookie", f"bf_workspace={self.workspace_cookie}; Path=/; Max-Age={age}; HttpOnly; SameSite=Strict{secure}")
        super().end_headers()

    def _authorized(self):
        if not DEMO_PASSWORD:
            return True
        expected = b"Basic " + base64.b64encode(f"professor:{DEMO_PASSWORD}".encode())
        supplied = self.headers.get("Authorization", "").encode()
        if hmac.compare_digest(supplied, expected):
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Battlefront access"' if WORKSPACE else 'Basic realm="Battlefront classroom demo"')
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def _managers(self, create=True):
        if not DEMO:
            return mgr, campaign_mgr, None
        now = time.monotonic()
        for key, row in list(SESSIONS.items()):
            if now - row["seen"] > 6 * 3600:
                SESSIONS.pop(key)["root"].cleanup()
        jar = SimpleCookie()
        try:
            jar.load(self.headers.get("Cookie", ""))
        except CookieError:
            pass
        token = jar["bf_demo"].value if "bf_demo" in jar else None
        session = SESSIONS.get(token)
        if not session:
            if not create or len(SESSIONS) >= 64:
                raise ValueError("Demo session capacity reached; try again in a new window later.")
            self.session_cookie, session = create_demo_session()
        session["seen"] = now
        return session["inv"], session["camp"], session

    def _static(self, *, head=False):
        if self.path not in STATIC and (WORKSPACE or DEMO or self.path != "/models/f16.glb"):
            self.send_error(404)
        elif head:
            super().do_HEAD()
        else:
            super().do_GET()

    def do_HEAD(self):
        if WORKSPACE and urlsplit(self.path).path == "/healthz":
            self._workspace_health(head=True)
            return
        if not self._authorized():
            return
        if self.path != urlsplit(self.path).path:
            self.path = urlsplit(self.path).path
        self._static(head=True)

    def do_GET(self):
        started = time.monotonic()
        if WORKSPACE and urlsplit(self.path).path == "/healthz":
            self._workspace_health()
            return
        if not self._authorized():
            return
        request = urlsplit(self.path)
        self.path = request.path
        self.view_query = request.query if self.path in ("/api/telemetry", "/api/campaign", "/api/auth/oauth/callback") else ""
        try:
            if self.path == "/api/weather":
                self._send_json(fetch_caucasus_weather())
                return
            if self.path == "/api/app-telemetry":
                with APP_LOG_LOCK:
                    events = list(APP_LOGS)[-100:]
                errors = sum(1 for e in events if e["status"] >= 400)
                avg_ms = round(sum(e["ms"] for e in events) / len(events), 1) if events else 0.0
                self._send_json({"events": list(reversed(events)), "summary": {"total": len(events), "errors": errors, "avg_ms": avg_ms}})
                return
            if self.path == "/api/auth/oauth/status":
                enabled = bool(OAUTH_CLIENT_ID and OAUTH_CLIENT_SECRET)
                self._send_json({"enabled": enabled, "provider": "google", "login_url": "/api/auth/oauth/login"})
                return
            if self.path == "/api/auth/oauth/login":
                self._oauth_login()
                return
            if self.path == "/api/auth/oauth/callback":
                self._oauth_callback()
                return
            if self.path == "/mcp":
                self._send_json({
                    "name": "battlefront-mcp",
                    "version": "1.0.0",
                    "protocolVersion": "2025-03-26",
                    "transport": "streamable-http",
                    "tools": MCP_TOOLS,
                    "app_url": "/mcp/app",
                })
                return
            if self.path == "/mcp/app":
                self._send_html(self._mcp_app_html())
                return
            if self.path in STATIC and self.path not in ("/", "/index.html"):
                self._static()
                return
            if WORKSPACE and self.path in ("/api/state", "/api/campaign", "/api/upgrades"):
                self._workspace_read()
                return
            with STATE_LOCK:
                self._get_state()
        except Exception:
            record_app_event("error", self.path, 500, traceback.format_exc()[-380:], (time.monotonic() - started) * 1000)
            self._send_json({"success": False, "error": "Internal server error."}, 500)

    def _get_state(self):
        try:
            mode = parse_qs(self.view_query,max_num_fields=4)
        except ValueError:
            mode = {}
        replay_only = mode.get('replay') == ['1']
        if self.path == "/api/telemetry":
            cursor = None
            if mode:
                try:
                    raw = float(mode.get('t',['nan'])[0])
                    if math.isfinite(raw) and 0 <= raw <= 86400:
                        cursor = raw
                except ValueError:
                    pass
            data = telemetry_engine.get_tactical_state(cursor, replay_only=replay_only)
            if (DEMO or WORKSPACE) and data["is_live_dcs"]:
                anonymize_live_tracks(data)
            data["assets"] = "procedural" if DEMO else "private"
            self._send_json(data)
        elif not WORKSPACE and (self.path in READ_ROUTES or (not DEMO and self.path.startswith("/api/player/"))):
            try:
                inv, camp, _ = self._managers()
            except ValueError as e:
                self._send_json({"error": str(e)}, 503)
                return
            if self.path == "/api/state":
                data = inv.load_data()
            elif self.path == "/api/campaign":
                data = camp.get_campaign_status()
                live = None if replay_only else telemetry_engine.read_live(time.time())
                data["live_snapshot"] = live[1].get("campaign") if live else None
                data["campaign_scope"] = "isolated_workspace" if DEMO else "companion_workspace"
            elif self.path == "/api/upgrades":
                data = camp.get_airframe_upgrades()
            else:
                data = inv.get_player(self.path.split("/")[-1])
            self._send_json(data)
        else:
            if DEMO and self.path in ("/", "/index.html"):
                try:
                    self._managers()
                except ValueError as e:
                    self._send_json({"error": str(e)}, 503)
                    return
            self._static()

    def do_POST(self):
        started = time.monotonic()
        if not self._authorized():
            return
        self.path = urlsplit(self.path).path
        try:
            if self.path == "/mcp":
                self._handle_mcp_post()
                return
            if self.path == "/api/app-telemetry":
                self._handle_app_telemetry_post()
                return
            if WORKSPACE:
                self._workspace_write()
                return
            with STATE_LOCK:
                self._post_state()
        except Exception:
            record_app_event("error", self.path, 500, traceback.format_exc()[-380:], (time.monotonic() - started) * 1000)
            self._send_json({"success": False, "error": "Internal server error."}, 500)

    def _workspace_token(self):
        jar = SimpleCookie()
        try:
            jar.load(self.headers.get("Cookie", ""))
        except CookieError:
            return None
        return jar["bf_workspace"].value if "bf_workspace" in jar else None

    def _workspace_health(self, head=False):
        try:
            healthy = workspace.check_health()
        except (sqlite3.Error, ValueError, TypeError, KeyError):
            healthy = False
        body = b'{"status":"ok"}' if healthy else b'{"status":"unavailable"}'
        self.send_response(200 if healthy else 503)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def _workspace_sectors(self, replay=False):
        # Projection is read-only and provenance-tagged. The planning map
        # describes locations, not current ownership or available DCS funds.
        with STATE_LOCK:
            live = None if replay else telemetry_engine.read_live(time.time())
        projection = live[1].get("campaign") if live else None
        return (projection["sectors"], projection) if projection else (planning_sectors, None)

    def _workspace_read(self):
        session = workspace.session(self._workspace_token())
        if self.path == "/api/state":
            self._send_json(workspace.get_state(session))
        elif self.path == "/api/upgrades":
            self._send_json({})
        else:
            try:
                replay = parse_qs(self.view_query, max_num_fields=4).get("replay") == ["1"]
            except ValueError:
                replay = False
            sectors, projection = self._workspace_sectors(replay)
            self._send_json(workspace.get_campaign(session, sectors, projection))

    def _workspace_origin_ok(self):
        fetch_site = self.headers.get("Sec-Fetch-Site")
        if fetch_site not in (None, "same-origin", "none"):
            return False
        origin = self.headers.get("Origin", "")
        if WORKSPACE_ORIGIN:
            return origin == WORKSPACE_ORIGIN
        try:
            parsed = urlsplit(origin)
        except ValueError:
            return False
        return (parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost", "::1")
                and parsed.netloc == self.headers.get("Host") and origin == "http://" + parsed.netloc)

    def _workspace_write(self):
        if self.path not in WORKSPACE_ACTIONS:
            self._send_json({"success": False, "error": "Unknown workspace action."}, 404)
            return
        try:
            if not self._workspace_origin_ok():
                raise WorkspaceError("Workspace writes require the companion site origin.", 403)
            if self.headers.get_content_type() != "application/json":
                raise WorkspaceError("Expected application/json.", 415)
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                raise WorkspaceError("Invalid request length.")
            if not 0 < length <= 8192:
                raise WorkspaceError("Request body too large or empty.", 413)
            try:
                body = json.loads(self.rfile.read(length))
            except (ValueError, RecursionError):
                raise WorkspaceError("Invalid JSON.")
            if not isinstance(body, dict) or any(type(v) not in (str, int, type(None)) for v in body.values()):
                raise WorkspaceError("Expected a JSON object with scalar fields.")
            if self.path in ("/api/workspace/login", "/api/workspace/signup"):
                signup = self.path == "/api/workspace/signup"
                with LOGIN_LOCK:
                    times, limit = (SIGNUP_TIMES, 12) if signup else (LOGIN_TIMES, 60)
                    now = time.monotonic()
                    while times and now - times[0] > 60:
                        times.popleft()
                    if len(times) >= limit:
                        raise WorkspaceError("Authentication busy. Try again shortly.", 429)
                    times.append(now)
                authenticate = workspace.signup if signup else workspace.login
                self.workspace_cookie = authenticate(body.get("username"), body.get("password"))
                self._send_json({"success": True})
                return
            token = self._workspace_token()
            session = workspace.session(token)
            if not session:
                raise WorkspaceError("Sign in to change the workspace.", 401)
            supplied = self.headers.get("X-BF-CSRF", "")
            if not hmac.compare_digest(supplied.encode(), session["csrf"].encode()):
                raise WorkspaceError("Missing or invalid workspace request token.", 403)
            if self.path == "/api/workspace/logout":
                workspace.logout(token)
                self.workspace_cookie = ""
                result = {"success": True}
            elif self.path == "/api/dcs/link/start":
                result = workspace.start_link(session)
            elif self.path == "/api/dcs/link/finish":
                result = workspace.finish_link(session, body.get("code"))
            else:
                sectors, _ = self._workspace_sectors() if self.path == "/api/operations/propose" else ([], None)
                result = workspace.mutate(self.path, session, body, sectors)
            self._send_json(result)
        except WorkspaceError as e:
            self._send_json({"success": False, "error": str(e)}, e.status)

    def _post_state(self):
        if self.path == "/api/telemetry/push" or (DEMO and self.path not in DEMO_ACTIONS):
            self.send_error(404)
            return
        if DEMO and self.headers.get("Sec-Fetch-Site") in ("cross-site", "same-site"):
            self.send_error(403)
            return
        if self.headers.get_content_type() != "application/json":
            self.send_error(415)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 8192:
                self.send_error(413)
                return
            req_data = json.loads(self.rfile.read(length))
            if not isinstance(req_data, dict) or any(type(v) not in (str, int, float, bool, type(None)) for v in req_data.values()):
                raise ValueError("Expected a JSON object with scalar fields")
            for key, lo, hi in (("side", 1, 2), ("quantity", 1, 50), ("price_points", 1, 10000),
                                 ("amount", 1, 100), ("track_id", 1, 2), ("slot_index", 0, 20)):
                if key in req_data and not lo <= int(req_data[key]) <= hi:
                    raise ValueError(f"Invalid {key}")
            if self.path == "/api/player/set_callsign":
                callsign = req_data.get("callsign")
                if not isinstance(callsign, str) or not CALLSIGN.fullmatch(callsign.strip()):
                    raise ValueError("Use 1–24 letters, digits, spaces, underscores or hyphens")
                if re.sub(r"[^a-z0-9_]", "_", callsign.strip().lower()) == "demo_supply":
                    raise ValueError("Choose a different callsign")
            for key in ("munition", "listing_id", "airframe_key", "target_sector", "player_id", "seller_id", "buyer_id"):
                if key in req_data and (not isinstance(req_data[key], str) or len(req_data[key]) > 100):
                    raise ValueError(f"Invalid {key}")
            if "target_sector" in req_data and not re.fullmatch(r"[A-Za-z0-9 &.,_-]{1,100}", req_data["target_sector"]):
                raise ValueError("Invalid target sector")
            mgr, campaign_mgr, session = self._managers(create=not DEMO)
            if session:
                if session["writes"] >= 300:
                    self.send_error(429)
                    return
                session["writes"] += 1
                if self.path != "/api/player/set_callsign":
                    if not session["pilot"]:
                        self._send_json({"error": "Choose a callsign first"}, 403)
                        return
                    for k in ("player_id", "seller_id", "buyer_id"):
                        req_data[k] = session["pilot"]
        except (ValueError, TypeError, OverflowError) as e:
            self._send_json({"success": False, "error": str(e)}, 400)
            return

        if self.path == "/api/requisition":
            player_id = req_data.get("player_id", "quenc")
            munition = req_data.get("munition")
            res = mgr.buy_munition(player_id, munition)
            self._send_json(res)
        elif self.path == "/api/marketplace/list":
            seller_id = req_data.get("seller_id", "quenc")
            munition = req_data.get("munition")
            qty = int(req_data.get("quantity", 1))
            price = int(req_data.get("price_points", 5))
            res = mgr.list_for_sale(seller_id, munition, qty, price)
            self._send_json(res)
        elif self.path == "/api/marketplace/buy":
            buyer_id = req_data.get("buyer_id", "quenc")
            listing_id = req_data.get("listing_id")
            res = mgr.buy_from_market(buyer_id, listing_id)
            self._send_json(res)
        elif self.path == "/api/kill_event":
            player_id = req_data.get("player_id")
            kill_type = req_data.get("kill_type", "a2a_kill")
            res = mgr.award_kill(player_id, kill_type)
            self._send_json(res)
        elif self.path == "/api/assist_event":
            player_id = req_data.get("player_id")
            assist_type = req_data.get("assist_type", "datalink_assist")
            res = mgr.award_assist(player_id, assist_type)
            self._send_json(res)
        elif self.path == "/api/operations/join":
            player_id = req_data.get("player_id", "quenc")
            side = int(req_data.get("side", 2))
            slot_idx = int(req_data.get("slot_index", 0))
            res = campaign_mgr.join_operation_slot(player_id, side, slot_idx)
            self._send_json(res)
        elif self.path == "/api/operations/leave":
            player_id = req_data.get("player_id", "quenc")
            side = int(req_data.get("side", 2))
            res = campaign_mgr.leave_operation_slot(player_id, side)
            self._send_json(res)
        elif self.path == "/api/operations/propose":
            player_id = req_data.get("player_id", "quenc")
            side = int(req_data.get("side", 2))
            target_sector = req_data.get("target_sector", "Novorossiysk Oil Refinery")
            res = campaign_mgr.propose_operation(player_id, side, target_sector)
            self._send_json(res)
        elif self.path == "/api/operations/command":
            player_id = req_data.get("player_id", "quenc")
            side = int(req_data.get("side", 2))
            res = campaign_mgr.assume_command(player_id, side)
            self._send_json(res)
        elif self.path == "/api/armory/mount":
            player_id = req_data.get("player_id", "quenc")
            munition = req_data.get("munition")
            player = mgr.get_player(player_id)
            owned = player.get("inventory", {}).get(munition, 0)
            if owned > 0:
                self._send_json({"success": True, "message": f"Mounted 1x {munition} on aircraft.", "munition": munition})
            else:
                self._send_json({"success": False, "error": f"You do not have any {munition} in depot inventory."})
        elif self.path == "/api/operations/launch":
            player_id = req_data.get("player_id", "quenc")
            side = int(req_data.get("side", 2))
            state = campaign_mgr.load_state()
            op = state.get("operations", {}).get(str(side))
            if op:
                op["status"] = "ACTIVE"
                op["departure_timestamp"] = time.strftime("%Y-%m-%d %H:%M:%S")
                campaign_mgr.save_state(state)
                self._send_json({"success": True, "operation": op, "message": "Flight package launched and cleared hot."})
            else:
                self._send_json({"success": False, "error": "No active operation to launch."})
        elif self.path == "/api/campaign/test_collapse":
            side = int(req_data.get("side", 1))
            res = campaign_mgr.trigger_economic_collapse_test(side)
            self._send_json(res)
        elif self.path == "/api/campaign/test_restore":
            side = int(req_data.get("side", 1))
            res = campaign_mgr.restore_economic_solvency_test(side)
            self._send_json(res)
        elif self.path == "/api/upgrades/purchase":
            side = int(req_data.get("side", 2))
            airframe_key = req_data.get("airframe_key")
            track_id = int(req_data.get("track_id", 1))
            res = campaign_mgr.purchase_airframe_upgrade(side, airframe_key, track_id)
            self._send_json(res)
        elif self.path == "/api/demo/grant_merits":
            player_id = req_data.get("player_id", "quenc")
            amount = int(req_data.get("amount", 25))
            data = mgr.load_data()
            if player_id not in data["players"]:
                mgr.get_player(player_id)
                data = mgr.load_data()
            data["players"][player_id]["points"] = data["players"][player_id].get("points", 0) + amount
            mgr.save_data(data)
            self._send_json({"success": True, "new_balance": data["players"][player_id]["points"], "awarded": amount})
        elif self.path == "/api/player/set_callsign":
            raw_callsign = req_data.get("callsign", "Pilot").strip()
            player_id = re.sub(r"[^a-z0-9_]", "_", raw_callsign.lower())
            if session:
                session["pilot"] = player_id
            data = mgr.load_data()
            if player_id not in data["players"]:
                data["players"][player_id] = {
                    "callsign": raw_callsign,
                    "name": raw_callsign,
                    "side": int(req_data.get("side", 2)),
                    "points": 100, # 100 Starter Merits for grading demo
                    "stats": {"a2a_kills": 0, "a2g_kills": 0, "sorties": 0, "losses": 0},
                    "inventory": {"AIM-120D": 2, "AGM-88C": 1}
                }
                mgr.save_data(data)
            self._send_json({"success": True, "player": data["players"][player_id], "player_id": player_id})
        else:
            self.send_response(404)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

    def _send_html(self, body_text, status=200):
        raw = body_text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _oauth_login(self):
        if not (OAUTH_CLIENT_ID and OAUTH_CLIENT_SECRET):
            self._send_json({
                "success": False,
                "error": "OAuth 2.0 is not configured on this host. Set BF_OAUTH_CLIENT_ID and BF_OAUTH_CLIENT_SECRET.",
            }, 501)
            return
        state = secrets.token_urlsafe(24)
        OAUTH_STATES[state] = time.monotonic()
        for k, ts in list(OAUTH_STATES.items()):
            if time.monotonic() - ts > 600:
                OAUTH_STATES.pop(k, None)
        redirect = OAUTH_REDIRECT_URI or ((WORKSPACE_ORIGIN or f"http://127.0.0.1:{PORT}") + "/api/auth/oauth/callback")
        query = urlencode({
            "client_id": OAUTH_CLIENT_ID,
            "redirect_uri": redirect,
            "response_type": "code",
            "scope": "openid email profile",
            "state": state,
            "prompt": "select_account",
        })
        self.send_response(302)
        self.send_header("Location", f"https://accounts.google.com/o/oauth2/v2/auth?{query}")
        self.end_headers()

    def _oauth_callback(self):
        qs = parse_qs(self.view_query, max_num_fields=12)
        state = (qs.get("state") or [""])[0]
        code = (qs.get("code") or [""])[0]
        if not (OAUTH_CLIENT_ID and OAUTH_CLIENT_SECRET) or not state or state not in OAUTH_STATES:
            self._send_json({"success": False, "error": "Invalid or expired OAuth state."}, 400)
            return
        OAUTH_STATES.pop(state, None)
        redirect = OAUTH_REDIRECT_URI or ((WORKSPACE_ORIGIN or f"http://127.0.0.1:{PORT}") + "/api/auth/oauth/callback")
        token_req = urllib.request.Request(
            "https://oauth2.googleapis.com/token",
            data=urlencode({
                "code": code,
                "client_id": OAUTH_CLIENT_ID,
                "client_secret": OAUTH_CLIENT_SECRET,
                "redirect_uri": redirect,
                "grant_type": "authorization_code",
            }).encode("utf-8"),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        with urllib.request.urlopen(token_req, timeout=5) as resp:
            tokens = json.loads(resp.read(16384).decode("utf-8"))
        user_req = urllib.request.Request(
            "https://openidconnect.googleapis.com/v1/userinfo",
            headers={"Authorization": f"Bearer {tokens.get('access_token', '')}"},
        )
        with urllib.request.urlopen(user_req, timeout=5) as resp:
            profile = json.loads(resp.read(16384).decode("utf-8"))
        record_app_event("oauth", "/api/auth/oauth/callback", 302, profile.get("email", "verified"))
        self.send_response(302)
        self.send_header("Location", "/?oauth=ok")
        self.end_headers()

    def _handle_app_telemetry_post(self):
        if WORKSPACE and not self._workspace_origin_ok():
            self._send_json({"success": False, "error": "Same-origin required."}, 403)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json({"success": False, "error": "Invalid length."}, 400)
            return
        if not 0 < length <= 1024:
            self._send_json({"success": False, "error": "Invalid telemetry payload."}, 413)
            return
        body = json.loads(self.rfile.read(length))
        if not isinstance(body, dict):
            self._send_json({"success": False, "error": "Invalid JSON object."}, 400)
            return
        record_app_event("ui", body.get("event", "interaction"), 200, body.get("detail", ""))
        self._send_json({"success": True})

    def _mcp_app_html(self):
        with STATE_LOCK:
            tactical = telemetry_engine.get_tactical_state(None, replay_only=False)
        if not tactical.get("units"):
            with STATE_LOCK:
                tactical = telemetry_engine.get_tactical_state(None, replay_only=True)
        if WORKSPACE:
            session = workspace.session(self._workspace_token())
            st = workspace.get_state(session)
            sectors, _ = self._workspace_sectors(False)
            orders = st.get("marketplace", [])
        else:
            sectors = []
            orders = []
        rows = "".join(
            f"<tr><td>{html.escape(str(u.get('callsign','')))}</td>"
            f"<td>{'BLUFOR' if u.get('side')==2 else 'REDFOR'}</td>"
            f"<td>{html.escape(str(u.get('type','')))}</td>"
            f"<td>{int(u.get('alt',0))} m</td></tr>"
            for u in tactical.get("units", [])[:12]
        ) or "<tr><td colspan='4'>No active aircraft tracks</td></tr>"
        sec_rows = "".join(
            f"<tr><td>{html.escape(str(s.get('name','')))}</td>"
            f"<td>{'BLUFOR' if s.get('side')==2 else 'REDFOR'}</td></tr>"
            for s in sectors[:10]
        ) or "<tr><td colspan='2'>Caucasus sectors loaded in workspace</td></tr>"
        return (
            "<!doctype html><html><head><meta charset='utf-8'><title>Battlefront MCP App</title>"
            "<style>body{font-family:system-ui,sans-serif;margin:16px;background:#f7f6f1;color:#1b1d19}"
            "h2{margin:0 0 8px;font-size:15px}table{width:100%;border-collapse:collapse;margin-bottom:16px;background:#fff}"
            "th,td{border:1px solid #d4d3c8;padding:6px 8px;text-align:left;font-size:12px}th{background:#ecebe2}</style></head>"
            f"<body><h2>Battlefront MCP Theater Snapshot ({'LIVE' if tactical.get('is_live_dcs') else 'REPLAY'})</h2>"
            f"<table><thead><tr><th>Callsign</th><th>Coalition</th><th>Airframe</th><th>Altitude</th></tr></thead><tbody>{rows}</tbody></table>"
            f"<h2>Sectors &amp; Open Exchange Orders ({len(orders)})</h2>"
            f"<table><thead><tr><th>Sector</th><th>Control</th></tr></thead><tbody>{sec_rows}</tbody></table></body></html>"
        )

    def _handle_mcp_post(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json({"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Content-Length"}}, 400)
            return
        if not 0 < length <= 16384:
            self._send_json({"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Body size out of range"}}, 413)
            return
        req = json.loads(self.rfile.read(length))
        rpc_id = req.get("id")
        method = req.get("method", "")
        params = req.get("params") or {}
        if method == "initialize":
            result = {
                "protocolVersion": "2025-03-26",
                "capabilities": {"tools": {}, "resources": {}},
                "serverInfo": {"name": "battlefront-mcp", "version": "1.0.0"},
            }
            self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": result})
            return
        if method in ("notifications/initialized", "ping"):
            self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": {}})
            return
        if method == "tools/list":
            self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": {"tools": MCP_TOOLS}})
            return
        if method == "resources/list":
            self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": {"resources": [
                {"uri": "ui://battlefront/theater", "name": "Battlefront Theater Board", "mimeType": "text/html;profile=mcp-app"}
            ]}})
            return
        if method == "resources/read":
            uri = params.get("uri")
            if uri != "ui://battlefront/theater":
                self._send_json({"jsonrpc": "2.0", "id": rpc_id, "error": {"code": -32602, "message": "Unknown resource URI"}}, 404)
                return
            self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": {
                "contents": [{"uri": uri, "mimeType": "text/html;profile=mcp-app", "text": self._mcp_app_html()}]
            }})
            return
        if method == "tools/call":
            name = params.get("name", "")
            args = params.get("arguments") or {}
            record_app_event("mcp", f"/mcp:{name}", 200, json.dumps({k: v for k, v in args.items() if k != "password"}))
            if name == "get_theater_status":
                use_replay = bool(args.get("replay", False))
                with STATE_LOCK:
                    tactical = telemetry_engine.get_tactical_state(None, replay_only=use_replay)
                sectors, _ = self._workspace_sectors(use_replay) if WORKSPACE else ([], None)
                blue = sum(1 for s in sectors if s.get("side") == 2)
                red = sum(1 for s in sectors if s.get("side") == 1)
                summary = {
                    "live_dcs": bool(tactical.get("is_live_dcs")),
                    "blue_sectors": blue,
                    "red_sectors": red,
                    "active_aircraft": len(tactical.get("units", [])),
                    "active_missiles": len(tactical.get("missiles", [])),
                    "app_iframe_url": "/mcp/app",
                }
                self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": {
                    "content": [{"type": "text", "text": json.dumps(summary)}],
                    "_meta": {"ui": {"resourceUri": "ui://battlefront/theater"}},
                }})
                return
            if name == "get_sector_threat_picture":
                sector_q = str(args.get("sector", "")).strip().lower()
                with STATE_LOCK:
                    tactical = telemetry_engine.get_tactical_state(None, replay_only=False)
                if not tactical.get("units"):
                    with STATE_LOCK:
                        tactical = telemetry_engine.get_tactical_state(None, replay_only=True)
                sectors, _ = self._workspace_sectors(False) if WORKSPACE else ([], None)
                matched = [s for s in sectors if not sector_q or sector_q in str(s.get("name", "")).lower()]
                payload = {
                    "sectors": matched[:10],
                    "contacts": [{"callsign": u.get("callsign"), "side": u.get("side"), "type": u.get("type"), "alt": u.get("alt")}
                                 for u in tactical.get("units", [])[:15]],
                }
                self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": {"content": [{"type": "text", "text": json.dumps(payload)}]}})
                return
            if name == "list_ordnance_orders":
                if WORKSPACE:
                    st = workspace.get_state(workspace.session(self._workspace_token()))
                else:
                    inv, _, _ = self._managers()
                    st = inv.load_data()
                payload = {"orders": st.get("marketplace", []), "catalog_keys": list((st.get("munition_catalog") or {}).keys())}
                self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": {"content": [{"type": "text", "text": json.dumps(payload)}]}})
                return
            if name == "propose_flight_plan":
                target = str(args.get("target_sector", "")).strip()
                if not target:
                    self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": {"isError": True, "content": [{"type": "text", "text": "target_sector is required"}]}})
                    return
                if WORKSPACE:
                    token = self._workspace_token()
                    if not token and args.get("username") and args.get("password"):
                        token = workspace.login(args.get("username"), args.get("password"))
                    session = workspace.session(token) if token else None
                    if not session:
                        self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": {"isError": True, "content": [{"type": "text", "text": "Provide valid workspace username and password to persist flight plan."}]}})
                        return
                    sectors, _ = self._workspace_sectors()
                    res = workspace.mutate("/api/operations/propose", session, {"side": session["side"], "target_sector": target}, sectors)
                    self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": {"content": [{"type": "text", "text": json.dumps(res)}]}})
                    return
                inv, camp, _ = self._managers()
                res = camp.propose_operation(2, target)
                self._send_json({"jsonrpc": "2.0", "id": rpc_id, "result": {"content": [{"type": "text", "text": json.dumps(res)}]}})
                return
            self._send_json({"jsonrpc": "2.0", "id": rpc_id, "error": {"code": -32601, "message": "Unknown tool"}}, 404)
            return
        self._send_json({"jsonrpc": "2.0", "id": rpc_id, "error": {"code": -32601, "message": "Unknown MCP method"}}, 404)

    def _send_json(self, data, status=200):
        if getattr(self, "path", "") not in ("/api/telemetry", "/api/app-telemetry") or status >= 400:
            record_app_event("api", getattr(self, "path", ""), status, data.get("error", "") if isinstance(data, dict) else "")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

if __name__ == "__main__":
    class ReusableTCPServer(http.server.ThreadingHTTPServer):
        allow_reuse_address = True
        request_queue_size = 64

        def get_request(self):
            conn, addr = super().get_request()
            conn.settimeout(5)
            return conn, addr

    server_address = (os.environ.get("BF_BIND", "127.0.0.1") if WORKSPACE else "127.0.0.1", PORT)
    with ReusableTCPServer(server_address, BattlefrontHandler) as httpd:
        mode = "persistent workspace" if WORKSPACE else "isolated demo" if DEMO else "private companion"
        print(f"Battlefront {mode} · http://{server_address[0]}:{PORT}/", flush=True)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down server.")
