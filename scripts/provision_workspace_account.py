"""Provision an externally stored Battlefront workspace account."""

import argparse
import getpass
import json
import os
from pathlib import Path
import secrets
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "server/persistence"))
from workspace_store import CALLSIGN, USERNAME, credential, read_accounts


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--file", type=Path, required=True, help="Private credential path outside the checkout")
    cli.add_argument("--username", required=True)
    cli.add_argument("--callsign", required=True)
    cli.add_argument("--side", choices=("red", "blue"), required=True)
    cli.add_argument("--role", choices=("member", "commander", "admin"), default="member")
    cli.add_argument("--starter-merits", type=int, default=4)
    cli.add_argument("--generate", action="store_true", help="Generate and print a high-entropy password once")
    cli.add_argument("--replace-password", action="store_true", help="Rotate, preserving pilot ID, side and existing inventory")
    args = cli.parse_args()
    name, callsign = args.username.lower(), args.callsign.strip()
    location = args.file.expanduser().resolve()
    if ROOT == location or ROOT in location.parents:
        cli.error("Store account credentials outside the repository")
    if not USERNAME.fullmatch(name) or not CALLSIGN.fullmatch(callsign) or not 0 <= args.starter_merits <= 100:
        cli.error("Invalid account handle, callsign or starter merits")
    accounts = read_accounts(location)
    current = accounts.get(name)
    side = 1 if args.side == "red" else 2
    if bool(current) != args.replace_password:
        cli.error("Confirm rotation with --replace-password; new accounts omit that flag")
    if current and current["side"] != side:
        cli.error("Existing players cannot change coalition")
    if any(row["callsign"].casefold() == callsign.casefold() and name != handle for handle, row in accounts.items()):
        cli.error("Callsign already reserved")
    password = secrets.token_urlsafe(24) if args.generate else getpass.getpass("Account password: ")
    if not 16 <= len(password) <= 256:
        cli.error("Use at least 16 characters for a workspace password")
    if not args.generate and password != getpass.getpass("Confirm account password: "):
        cli.error("Passwords do not match")
    salt = secrets.token_hex(16)
    accounts[name] = {
        "id": current["id"] if current else "acct_" + secrets.token_hex(16),
        "side": side, "role": args.role, "callsign": callsign,
        "salt": salt, "password_hash": credential(password, salt),
        "starter_merits": current.get("starter_merits", 4) if current else args.starter_merits,
    }
    location.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=".workspace-accounts-", dir=location.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            json.dump(accounts, file, indent=2)
            file.write(chr(10))
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary, location)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"Provisioned {name} ({args.side}, {args.role}). Restart the companion to reload accounts.")
    if args.generate:
        print(f"One-time display of password for {name}: {password}")


if __name__ == "__main__":
    main()
