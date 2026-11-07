"""Publish DCS's fixed staging files using Linux atomic replacement, never Lua evaluation."""
import argparse
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import re
import tempfile
import time

PROFILE = Path.home() / '.wine/drive_c/DCS_configs/DCS.server1'
MEMBERS = (
    ('Scripts/battlefront_campaign_state.lua', 'state'),
    ('Logs/BattlefrontCampaign0.json', 'snapshot'),
    ('Logs/BattlefrontCampaign1.json', 'snapshot'),
)
COALITION = re.compile(rb'    \[([12])\] = \{ treasury = -?\d+\.\d{2}, (?:stock_flight_seconds = (\d{1,5}), )?unlocked = \{ (.*)\} \},')
UNLOCK = re.compile(rb'\["[a-zA-Z0-9_ -]+"\] = true, ')
SECTOR = re.compile(rb'''    \["([a-zA-Z0-9 ._/'&()\-]+)"\] = \{ side = [012], level = [123], status = "[A-Z_]+", holdTimer = \d+, holdingSide = [012] \},''')


def valid_state(data):
    lines = data.splitlines()
    if len(lines) != 30 or not data.endswith(b'\n'):
        return False
    if (lines[:3] != [b'-- Battlefront Campaign Persistent State', b'return {', b'  coalitions = {']
        or lines[5:7] != [b'  },', b'  sectors = {'] or lines[-2:] != [b'  }', b'}']):
        return False
    coal = [COALITION.fullmatch(line) for line in lines[3:5]]
    if (not all(coal) or {row[1] for row in coal} != {b'1', b'2'}
            or any((row[2] and int(row[2]) > 86400) or UNLOCK.sub(b'', row[3]) for row in coal)):
        return False
    sectors = [SECTOR.fullmatch(line) for line in lines[7:28]]
    return all(sectors) and len({row[1] for row in sectors}) == 21


def valid_snapshot(data):
    def finite(x):
        return type(x) in (int, float) and math.isfinite(x) and abs(x) <= 1_000_000_000
    try:
        obj = json.loads(data)
        campaign = obj['campaign']
        sides = campaign['coalitions']
        sectors = campaign['sectors']
        ids = {s['id'] for s in sectors}
        return (finite(obj['sim_time']) and campaign['mission'] == 'Battlefront Caucasus'
                and campaign['total_objectives'] == 21 and len(sectors) == 21 and len(ids) == 21
                and all(finite(s['x']) and finite(s['z']) and s['side'] in (0,1,2) for s in sectors)
                and set(sides) == {'1','2'} and all(finite(s['treasury']) for s in sides.values()))
    except (ValueError, TypeError, KeyError, AttributeError, OverflowError, RecursionError):
        return False


def read_current(path):
    before = path.stat()
    if not 0 < before.st_size < 32768 or not -1 <= time.time() - before.st_mtime < 12:
        return None
    data = path.read_bytes()
    after = path.stat()
    if (len(data), after.st_size, after.st_mtime_ns, after.st_ino) != (
            before.st_size, before.st_size, before.st_mtime_ns, before.st_ino):
        return None
    return before.st_mtime_ns, data


def publish(dest, data, source_stamp):
    try:
        old = dest.read_bytes()
        mode = dest.stat().st_mode & 0o777
    except FileNotFoundError:
        old, mode = None, 0o644
    if old == data:
        return
    temp = None
    try:
        with tempfile.NamedTemporaryFile(dir=dest.parent, prefix='.bf-publish-', delete=False) as f:
            temp = Path(f.name)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        temp.chmod(mode)
        # A publisher restarted mid-gap must not refresh an old snapshot's age.
        os.utime(temp, ns=(source_stamp, source_stamp))
        os.replace(temp,dest)
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)


@dataclass
class Publisher:
    done: dict
    announced: set

    def sample(self, checking=False):
        for member, kind in MEMBERS:
            dest = PROFILE / member
            try:
                candidate = read_current(dest.with_name(dest.name + '.tmp'))
                if not candidate or candidate[0] == self.done.get(member):
                    continue
                stamp, data = candidate
                validator = valid_state if kind == 'state' else valid_snapshot
                if not validator(data):
                    continue
                if not checking:
                    publish(dest,data,stamp)
                self.done[member] = stamp
                if kind not in self.announced:
                    print(f'{"VALID STAGING" if checking else "PUBLISHED"}: {kind} ({len(data)} bytes)', flush=True)
                    self.announced.add(kind)
            except FileNotFoundError:
                continue


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check',action='store_true')
    args = parser.parse_args()
    p = Publisher({},set())
    if args.check:
        p.sample(checking=True)
        raise SystemExit(0 if p.announced == {'state','snapshot'} else 1)
    while True:
        p.sample()
        time.sleep(.25)
