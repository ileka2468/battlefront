"""Pull a checked Battlefront web release; never update credentials, state, or DCS."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
import zipfile

REPO = "ileka2468/battlefront"
TAG = "web-production"
ARCHIVE = "battlefront-web.tar.gz"
CHECKSUM = "battlefront-web.sha256"
SERVICE = "bf-classroom-preview.service"
FILES = (
    "web/index.html", "web/server.py", "web/tacview.js", "web/dist/companion.js",
    "web/dist/tailwind.css", "server/telemetry_engine.py", "server/persistence/workspace_store.py",
)
ASSET_HOSTS = frozenset({"release-assets.githubusercontent.com", "objects.githubusercontent.com", "github-releases.githubusercontent.com"})
MAX_ARCHIVE = 8 * 1024 * 1024
MAX_FILE = 4 * 1024 * 1024
MAX_EXPANDED = len(FILES) * MAX_FILE + 1024 * 1024
HASH_RE = re.compile(r"[a-f0-9]{64}")


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def asset_url(repo, file):
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*/[A-Za-z0-9_.-]+", repo)
        or repo.split("/")[-1] in (".", "..") or file not in (ARCHIVE, CHECKSUM)):
        raise ValueError("Expected owner/repository and a known Battlefront asset")
    return f"https://github.com/{repo}/releases/download/{TAG}/{file}"


def check_download_url(url, source):
    parts = urlsplit(url)
    if (parts.scheme != "https" or parts.username is not None or parts.password is not None
        or parts.port not in (None, 443) or parts.fragment or not parts.path.startswith("/")
        or not (url == source or parts.hostname in ASSET_HOSTS)):
        raise ValueError("GitHub redirected to an unexpected location")


class GitHubRedirect(HTTPRedirectHandler):
    max_redirections = 4

    def __init__(self, source):
        self.source = source

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_download_url(newurl, self.source)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Unexpected local readiness redirect")


def fetch(repo, asset, limit):
    source = asset_url(repo, asset)
    opener = build_opener(ProxyHandler({}), GitHubRedirect(source))
    headers = {"User-Agent": "BattlefrontOriginUpdater/1", "Accept": "application/octet-stream"}
    with opener.open(Request(source, headers=headers), timeout=12) as response:
        check_download_url(response.geturl(), source)
        raw = response.read(limit + 1)
    if len(raw) > limit:
        raise ValueError("Release asset exceeds its permitted size")
    return raw


def read_checksum(raw):
    result = re.fullmatch(rb"([a-f0-9]{64})  battlefront-web\.tar\.gz\n", raw)
    if not result:
        raise ValueError("Release checksum must be sha256sum output for battlefront-web.tar.gz")
    return result[1].decode("ascii")


def checked_archive(raw, expected):
    if len(raw) > MAX_ARCHIVE or not HASH_RE.fullmatch(expected) or sha256(raw) != expected:
        raise ValueError("Release assets do not match; leaving the existing web release unchanged")
    with gzip.GzipFile(fileobj=io.BytesIO(raw)) as compressed:
        contents = compressed.read(MAX_EXPANDED + 1)
    if len(contents) > MAX_EXPANDED:
        raise ValueError("Expanded release size exceeds its limit")
    data = {}
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:", ignore_zeros=True) as archive:
        for member in archive:
            name = member.name
            if (name not in FILES or name in data or member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE)
                or member.pax_headers or not 0 < member.size <= MAX_FILE):
                raise ValueError("Unexpected path, metadata or type in release archive")
            with archive.extractfile(member) as handle:
                item = handle.read(MAX_FILE + 1)
            if len(item) != member.size:
                raise ValueError("Truncated release member")
            if name.endswith(".py"):
                compile(item, name, "exec")
            data[name] = item
    if set(data) != set(FILES):
        raise ValueError("Release archive is missing one or more required files")
    return data


def sync_directory(directory):
    if os.name == "posix":
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def atomic(path, payload, mode=0o600):
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=".battlefront-release-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            if hasattr(os, "fchmod"):
                os.fchmod(handle.fileno(), mode)
            else:
                os.chmod(temporary, mode)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def location(root, name):
    if name not in FILES:
        raise ValueError("Not an allowlisted runtime path")
    path = root
    for part in name.split("/"):
        path /= part
        if path.is_symlink():
            raise ValueError("Release targets must not be symlinks")
    if not path.parent.is_dir() or (path.exists() and not path.is_file()):
        raise ValueError("Release target directory is missing or target is not a file")
    return path


def runtime_bytes(path):
    with path.open("rb") as handle:
        raw = handle.read(MAX_FILE + 1)
    if len(raw) > MAX_FILE:
        raise ValueError("Current runtime file exceeds backup size limit")
    return raw


def install_backup(root, state):
    stream = io.BytesIO()
    manifest = {}
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as backup:
        for name in FILES:
            source = location(root, name)
            if source.exists():
                mode = stat.S_IMODE(source.stat().st_mode) & 0o777
                manifest[name] = mode
                backup.writestr(name, runtime_bytes(source))
            else:
                manifest[name] = None
        backup.writestr("manifest.json", json.dumps(manifest))
    atomic(state / "previous-web.zip", stream.getvalue())


def restore(root, state, ready):
    with zipfile.ZipFile(state / "previous-web.zip") as backup:
        manifest = json.loads(backup.read("manifest.json"))
        if set(manifest) != set(FILES) or set(backup.namelist()) != {"manifest.json", *(p for p in FILES if manifest[p] is not None)}:
            raise ValueError("Rollback backup is incomplete")
        for name in FILES:
            path = location(root, name)
            mode = manifest[name]
            if mode is None:
                path.unlink(missing_ok=True)
                sync_directory(path.parent)
            elif type(mode) is int and 0 <= mode <= 0o777:
                atomic(path, backup.read(name), mode)
            else:
                raise ValueError("Rollback file mode is invalid")
    ready()
    (state / "pending").unlink()
    sync_directory(state)


def apply_release(root, state, data, digest, ready):
    if set(data) != set(FILES):
        raise ValueError("Incomplete release; nothing changed")
    with tempfile.TemporaryDirectory(prefix="staged-", dir=state) as directory:
        stage = Path(directory)
        for name, payload in data.items():
            staged = stage / name
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_bytes(payload)
        install_backup(root, state)
        atomic(state / "pending", (digest + "\n").encode("ascii"))
        try:
            for name in FILES:
                atomic(location(root, name), runtime_bytes(stage / name), 0o644)
            ready()
        except BaseException:
            restore(root, state, ready)
            print("Restored and restarted the previous web release", file=sys.stderr, flush=True)
            raise
        marker = {"digest": digest, "files": {name: sha256(data[name]) for name in FILES}}
        atomic(state / "installed.json", json.dumps(marker, sort_keys=True).encode())
        (state / "pending").unlink()
        sync_directory(state)


def installed(root, state, digest):
    try:
        marker = json.loads((state / "installed.json").read_text())
        if marker["digest"] != digest or set(marker["files"]) != set(FILES):
            return False
        return all(sha256(runtime_bytes(location(root, path))) == marker["files"][path] for path in FILES)
    except (OSError, KeyError, TypeError, ValueError):
        return False


def check_health(port):
    health = build_opener(ProxyHandler({}), NoRedirect())
    def fetch_json(path, limit):
        with health.open(f"http://127.0.0.1:{port}{path}", timeout=2) as handle:
            raw = handle.read(limit + 1)
            if handle.status != 200 or len(raw) > limit or handle.headers.get_content_type() != "application/json":
                raise ValueError("Unexpected origin readiness response")
        return json.loads(raw)
    if fetch_json("/healthz", 1024) != {"status": "ok"}:
        raise ValueError("Workspace database check failed")
    state = fetch_json("/api/state", 4 * 1024 * 1024)["workspace"]
    if not (state["mode"] == "production" and state["authenticated"] is False
            and state["player_id"] is None and state["csrf"] is None):
        raise ValueError("Origin does not serve anonymous production workspace state")


def restart(port):
    subprocess.run(["/usr/bin/systemctl", "--user", "restart", SERVICE], check=True, timeout=30)
    for _ in range(15):
        try:
            check_health(port)
            return
        except (OSError, ValueError, KeyError, TypeError):
            time.sleep(0.75)
    raise RuntimeError("Restarted web origin did not pass readiness")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=REPO)
    parser.add_argument("--root", type=Path, default=Path.home() / "battlefront-companion-v2")
    parser.add_argument("--state-dir", type=Path, default=Path.home() / ".local/state/battlefront-web-refresh")
    parser.add_argument("--port", type=int, default=8790)
    parser.add_argument("--check", action="store_true", help="Download and validate only; no origin or service changes")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("Invalid loopback health port")
    if args.check:
        digest = read_checksum(fetch(args.repo, CHECKSUM, 256))
        checked_archive(fetch(args.repo, ARCHIVE, MAX_ARCHIVE), digest)
        print(f"Verified web release {digest}; no origin changes")
        return

    import fcntl
    import pwd
    if pwd.getpwuid(os.geteuid()).pw_name != "dcs":
        raise RuntimeError("Install mode must run as the dcs user")
    os.umask(0o077)
    root, state = args.root.resolve(strict=True), args.state_dir.resolve()
    if state == root or root in state.parents:
        raise ValueError("Updater state must be kept outside the origin installation")
    for name in FILES:
        location(root, name)
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    if stat.S_IMODE(state.stat().st_mode) & 0o077:
        raise ValueError("Updater state directory must be private")
    requested_restart = lambda: restart(args.port)
    def interrupted(*_):
        raise InterruptedError("Web release updater was interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    with (state / "update.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Another web release check is already running")
            return
        if (state / "pending").exists():
            restore(root, state, requested_restart)
            print("Recovered a previously interrupted web update", flush=True)
        digest = read_checksum(fetch(args.repo, CHECKSUM, 256))
        if installed(root, state, digest):
            print("Web release unchanged")
            return
        data = checked_archive(fetch(args.repo, ARCHIVE, MAX_ARCHIVE), digest)
        apply_release(root, state, data, digest, requested_restart)
        print(f"Installed and verified web release {digest}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, KeyError, SyntaxError, tarfile.TarError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        print(f"Web release not installed: {error}", file=sys.stderr)
        raise SystemExit(1)
