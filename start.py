"""Build the React app, prepare a local SQLite workspace, and run Battlefront."""
import argparse
import gzip
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parent


def main():
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--no-build',action='store_true',help='use already built frontend assets')
    cli.add_argument('--port',type=int)
    args=cli.parse_args()
    os.chdir(ROOT)
    settings=os.environ.copy()
    settings_file=ROOT/'.env'
    if settings_file.is_file():
        for row in settings_file.read_text('utf-8-sig').splitlines():
            if row.strip().startswith('#') or '=' not in row: continue
            key,value=row.split('=',1)
            if key.strip(): settings.setdefault(key.strip(),value.strip().strip('"').strip("'"))
    if args.port: settings['PORT']=str(args.port)
    defaults={'PORT':'8088','BF_BIND':'127.0.0.1','BF_WORKSPACE':'1','BF_WORKSPACE_DB':'.battlefront/workspace.sqlite3',
              'BF_WORKSPACE_ACCOUNTS_FILE':'.battlefront/accounts.json','BF_LIVE_CAMPAIGN_ONLY':'1'}
    for key,value in defaults.items(): settings.setdefault(key,value)
    settings.setdefault('BF_WORKSPACE_ORIGIN',f'http://127.0.0.1:{settings["PORT"]}')
    for key in ('BF_WORKSPACE_DB','BF_WORKSPACE_ACCOUNTS_FILE'):
        path=Path(settings[key]).resolve()
        path.parent.mkdir(exist_ok=True,parents=True)
        settings[key]=str(path)
    local_bundle=ROOT/'data/fleet-replay.ndjson.gz'
    if not settings.get('BF_REPLAY_FILE') and local_bundle.is_file():
        local=ROOT/'.battlefront/fleet-replay.ndjson'
        local.parent.mkdir(exist_ok=True)
        if not local.exists() or local.stat().st_mtime_ns<local_bundle.stat().st_mtime_ns:
            temp=local.with_suffix('.pending')
            with gzip.open(local_bundle,'rb') as compressed,temp.open('wb') as output:
                shutil.copyfileobj(compressed,output)
            temp.replace(local)
        settings['BF_REPLAY_FILE']=str(local)
    if not args.no_build:
        npm='npm.cmd' if os.name=='nt' else 'npm'
        if not shutil.which(npm): raise SystemExit('Install Node.js 22+ (npm is needed to build the frontend).')
        for command in ('ci','run'):
            subprocess.run([npm,'--prefix','frontend',command]+(['build'] if command=='run' else []),check=True)
    if not (ROOT/'web/dist/companion.js').is_file(): raise SystemExit('Frontend is missing; run python start.py without --no-build.')
    if settings.get('BF_WORKSPACE')=='1' and not Path(settings['BF_WORKSPACE_ACCOUNTS_FILE']).is_file():
        for handle,callsign,role in [('professor','Professor','admin'),('wingman','Wingman','member')]:
            subprocess.run([sys.executable,'scripts/provision_workspace_account.py','--file',settings['BF_WORKSPACE_ACCOUNTS_FILE'],
                            '--username',handle,'--callsign',callsign,'--side','blue','--role',role,
                            '--starter-merits','24','--generate'],check=True,env=settings)
    print(f'Local workspace: http://127.0.0.1:{settings["PORT"]}/ · recording: /?replay=1',flush=True)
    try: return subprocess.call([sys.executable,'-u','web/server.py'],env=settings)
    except KeyboardInterrupt: return 0


if __name__=='__main__': raise SystemExit(main())
