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
from http.cookies import SimpleCookie, CookieError

sys.stdout.reconfigure(encoding='utf-8', errors='replace')
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "server", "persistence")))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "server")))
from inventory_manager import InventoryManager
from campaign_manager import CampaignManager
from telemetry_engine import TelemetryEngine
from workspace_store import WorkspaceError, WorkspaceStore, SESSION_SECONDS

PORT = int(os.environ.get("PORT", 8088))
WEB_DIR = os.path.dirname(__file__)
WORKSPACE = os.environ.get("BF_WORKSPACE") == "1"
DEMO = not WORKSPACE and os.environ.get("BF_DEMO") == "1"
DEMO_PASSWORD = os.environ.get("BF_DEMO_PASSWORD") if DEMO or WORKSPACE else None
WORKSPACE_ORIGIN = os.environ.get("BF_WORKSPACE_ORIGIN", "").rstrip("/")
if WORKSPACE_ORIGIN:
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
READ_ROUTES = {"/api/state", "/api/campaign", "/api/upgrades", "/api/telemetry"}
DEMO_ACTIONS = {"/api/player/set_callsign", "/api/demo/grant_merits", "/api/requisition",
                "/api/marketplace/list", "/api/marketplace/buy", "/api/armory/mount",
                "/api/operations/join", "/api/operations/leave", "/api/operations/propose",
                "/api/operations/command", "/api/operations/launch", "/api/upgrades/purchase"}
WORKSPACE_ACTIONS = (DEMO_ACTIONS - {"/api/demo/grant_merits", "/api/upgrades/purchase"}) | {
    "/api/marketplace/cancel", "/api/workspace/login", "/api/workspace/logout"}
CALLSIGN = re.compile(r"[A-Za-z0-9 _-]{1,24}")
SESSIONS = {}
STATE_LOCK = RLock()
LOGIN_LOCK = Lock()
LOGIN_TIMES = deque()
if WORKSPACE:
    database = os.environ.get("BF_WORKSPACE_DB", str(Path.home() / ".local/state/battlefront/workspace.sqlite3"))
    accounts = os.environ.get("BF_WORKSPACE_ACCOUNTS_FILE")
    default_catalog = Path(WEB_DIR).parent / "server/demo_catalog.json"
    catalog = json.loads(Path(os.environ.get("BF_WORKSPACE_CATALOG", default_catalog)).read_text(encoding="utf-8"))
    workspace = WorkspaceStore(database, accounts, catalog)
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

class BattlefrontHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_DIR, **kwargs)

    session_cookie = None
    workspace_cookie = None

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
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
        if WORKSPACE and urlsplit(self.path).path == "/healthz":
            self._workspace_health()
            return
        if not self._authorized():
            return
        request = urlsplit(self.path)
        self.path = request.path
        self.view_query = request.query if self.path in ("/api/telemetry","/api/campaign") else ""
        if self.path in STATIC and self.path not in ("/", "/index.html"):
            self._static()
            return
        if WORKSPACE and self.path in ("/api/state", "/api/campaign", "/api/upgrades"):
            self._workspace_read()
            return
        with STATE_LOCK:
            self._get_state()

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


    def _send_json(self, data, status=200):
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
