"""Assemble the DCS 5.1 mission engine and companion export without deploying it."""
import argparse
import hashlib
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
MODULES=(
    'core/init','core/events','core/config','core/state',
    'systems/fortification','systems/sectors','systems/culling','systems/economy',
    'systems/research','systems/aircraft','systems/ewr','systems/test_ranges','systems/combat',
    'commands/map_markers','commands/f10','systems/ai_director','startup',
)


def source(path):
    return (ROOT/path).read_bytes().replace(b'\r\n',b'\n')


def assemble():
    out=[b'-- Battlefront generated engine. Modify sources under mission/ and server/.\n']
    for name in MODULES:
        module=f'mission/{name}.lua'
        out.extend((f'\n-- >>> BEGIN MODULE: {module} <<<\n'.encode(),source(module).rstrip(),
                    f'\n-- <<< END MODULE: {module} >>>\n'.encode()))
    out.extend((b'\n',source('server/BattlefrontCampaignExport.lua')))
    return b''.join(out)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,default=ROOT/'build/battlefront.lua')
    o=p.parse_args().output
    data=assemble();o.parent.mkdir(parents=True,exist_ok=True);o.write_bytes(data)
    print(f'DCS bundle: {o} ({len(data)} bytes, SHA-256 {hashlib.sha256(data).hexdigest()})')


if __name__=='__main__':main()
