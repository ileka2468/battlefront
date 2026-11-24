"""Fixture-only tests for the production origin's release updater."""

import gzip
from http.server import BaseHTTPRequestHandler, HTTPServer
import io
import json
from pathlib import Path
import sys
import tarfile
from tempfile import TemporaryDirectory
from threading import Thread
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import refresh_web_release as release


def package(files, extra=()):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz", format=tarfile.GNU_FORMAT) as archive:
        for name, payload in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(payload)
            archive.addfile(member, io.BytesIO(payload))
        for member in extra:
            content = b"X" * member.size
            archive.addfile(member, io.BytesIO(content))
    return buffer.getvalue()


class ReleaseUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.work = TemporaryDirectory(prefix="battlefront-updater-test-")
        self.addCleanup(self.work.cleanup)
        self.base = Path(self.work.name)
        self.root, self.state = self.base / "origin", self.base / "updater"
        self.state.mkdir()
        self.old = {name: b"# prior release\n" for name in release.FILES}
        self.new = {name: b"# new release\n" for name in release.FILES}
        for name, contents in self.old.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
        self.database = self.root / "workspace.sqlite3"
        self.database.write_bytes(b"fixture; not a real database")
        self.archive = package(self.new)
        self.digest = release.sha256(self.archive)

    def runtime(self):
        return {name: (self.root / name).read_bytes() for name in release.FILES}

    def test_checksum_and_release_shape(self):
        supplied = f"{self.digest}  {release.ARCHIVE}\n".encode()
        self.assertEqual(release.read_checksum(supplied), self.digest)
        self.assertEqual(release.checked_archive(self.archive, self.digest), self.new)
        for wrong in (supplied.replace(b"tar.gz", b"x.gz"), supplied.replace(b"\n", b"\r\n"), b"broken"):
            with self.subTest(wrong=wrong), self.assertRaises(ValueError):
                release.read_checksum(wrong)
        with self.assertRaises(ValueError):
            release.checked_archive(self.archive, "0" * 64)
        self.assertEqual(self.runtime(), self.old)

    def test_routes_and_redirects_are_constrained(self):
        origin = release.asset_url(release.REPO, release.ARCHIVE)
        self.assertEqual(origin, "https://github.com/ileka2468/battlefront/releases/download/web-production/battlefront-web.tar.gz")
        release.check_download_url(origin, origin)
        release.check_download_url("https://release-assets.githubusercontent.com/github-production-release-asset/1/id?token=fixture", origin)
        for unexpected in (
            "http://release-assets.githubusercontent.com/file",
            "https://release-assets.githubusercontent.com:444/file",
            "https://release-assets.githubusercontent.com.invalid/file",
            "https://github.com/other/repo/releases/download/web-production/battlefront-web.tar.gz",
            "https://example.invalid/file",
        ):
            with self.subTest(unexpected=unexpected), self.assertRaises(ValueError):
                release.check_download_url(unexpected, origin)
        with self.assertRaises(ValueError):
            release.asset_url("example/..", release.ARCHIVE)

    def test_bad_archive_members_are_rejected_before_writes(self):
        missing = self.new.copy()
        missing.pop(release.FILES[0])
        archives = [
            package(missing),
            package({**self.new, "workspace.sqlite3": b"not a web runtime file"}),
            package(self.new, [tarfile.TarInfo(release.FILES[0])]),
        ]
        link = tarfile.TarInfo(release.FILES[0])
        link.type, link.linkname = tarfile.SYMTYPE, "test-target"
        archives.append(package(missing, [link]))
        concatenated = gzip.decompress(self.archive) + gzip.decompress(package({"unexpected.txt": b"extra"}))
        archives.append(gzip.compress(concatenated))
        for raw in archives:
            with self.assertRaises(ValueError):
                release.checked_archive(raw, release.sha256(raw))
        broken = {**self.new, "web/server.py": b"def :"}
        raw = package(broken)
        with self.assertRaises(SyntaxError):
            release.checked_archive(raw, release.sha256(raw))
        self.assertEqual(self.runtime(), self.old)
        self.assertFalse((self.state / "pending").exists())

    def test_install_then_verify_hashes_and_preserve_unrelated_file(self):
        scopes = []
        release.apply_release(self.root, self.state, self.new, self.digest,
                              lambda: scopes.append(self.runtime()))
        self.assertEqual(scopes, [self.new])
        self.assertTrue(release.installed(self.root, self.state, self.digest))
        self.assertFalse((self.state / "pending").exists())
        self.assertTrue((self.state / "previous-web.zip").is_file())
        self.assertEqual(self.database.read_bytes(), b"fixture; not a real database")
        (self.root / "web/index.html").write_text("out-of-band change")
        self.assertFalse(release.installed(self.root, self.state, self.digest))

    def test_rollback_on_failed_readiness_and_restore_interruption(self):
        scopes = []
        def ready():
            scopes.append(self.runtime())
            if len(scopes) == 1:
                raise RuntimeError("fixture readiness failure")
        with self.assertRaisesRegex(RuntimeError, "fixture readiness failure"):
            release.apply_release(self.root, self.state, self.new, self.digest, ready)
        self.assertEqual(scopes, [self.new, self.old])
        self.assertFalse((self.state / "pending").exists())
        self.assertFalse(release.installed(self.root, self.state, self.digest))
        release.install_backup(self.root, self.state)
        release.atomic(self.state / "pending", b"fixture")
        release.atomic(self.root / release.FILES[0], b"partial fixture update")
        release.restore(self.root, self.state, lambda: scopes.append(self.runtime()))
        self.assertEqual(scopes[-1], self.old)
        self.assertFalse((self.state / "pending").exists())
        self.assertEqual(self.database.read_bytes(), b"fixture; not a real database")

    def test_restart_command_is_fixed(self):
        with patch.object(release.subprocess, "run") as run, patch.object(release, "check_health") as ready:
            release.restart(8790)
        run.assert_called_once_with(["/usr/bin/systemctl", "--user", "restart", "bf-classroom-preview.service"],
                                    check=True, timeout=30)
        ready.assert_called_once_with(8790)

    def test_local_health_requires_real_anonymous_workspace(self):
        response = {"workspace": {"mode": "production", "authenticated": False, "player_id": None, "csrf": None}}
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                data = {"status": "ok"} if self.path == "/healthz" else response
                raw = json.dumps(data).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
        with HTTPServer(("127.0.0.1", 0), Handler) as local:
            thread = Thread(target=local.serve_forever, daemon=True)
            thread.start()
            try:
                release.check_health(local.server_address[1])
                response["workspace"]["authenticated"] = True
                with self.assertRaises(ValueError):
                    release.check_health(local.server_address[1])
            finally:
                local.shutdown()
                thread.join()


if __name__ == "__main__":
    unittest.main()
