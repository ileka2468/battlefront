# Battlefront · DCS Campaign Companion

A React/Tailwind tactical viewer with a Python API, a shared SQLite player workspace, and a read-only feed from an actual DCS Caucasus campaign. The public viewer does not need a DCS client or a companion account.

## Run it after cloning

Install **Python 3.12+** and **Node.js 22+**, then run:

```sh
git clone https://github.com/ileka2468/battlefront.git
cd battlefront
python start.py
```

Open <http://127.0.0.1:8088/>. The script installs the locked frontend dependencies, builds React/Tailwind, provisions a local grading account (`professor`, random password printed once), and starts the backend. SQLite creates its schema and loads the catalog automatically on first start. Nothing in this local workflow connects to production or spends its currency. If a local port is occupied, use `python start.py --port 8089`. See [`.env.example`](.env.example) for optional overrides.

To see airspace without DCS, select **20v20 replay**. It is a recorded 40-aircraft simulation with its own time controls, not synthetic live data. The live view explicitly waits for DCS when no live feed is configured. To reset **only a local clone**, stop the app and move its `.battlefront/` folder aside before restarting.

## What each system owns

| System | Source of truth |
| --- | --- |
| Airspace, campaign sectors, coalition treasury, blueprint unlocks | The DCS mission and its read-only export. No browser endpoint runs a mission command. |
| Armory inventory, requisitions, listings/trades, Combat Merits, flight plans | A single shared SQLite workspace. Signed-in pilots retain changes across browsers and restarts. Flight plans and loadout choices are companion records, not automatic DCS slot or loadout commands. |
| Research | The DCS director can buy from its coalition's own budget. Pilots can also buy via the real F10 menu. Both paths debit the same ledger. |

Account files provide server-assigned identity and coalition; online writes require an authenticated session and same-origin CSRF checks. The tracked catalog is in `server/demo_catalog.json`; the persistent schema and migration code are in `server/persistence/`. Local credentials, the live DB, server logs, DCS save data, and production deployment secrets are not in Git.

## CI/CD and release runbook

1. Push a change or open a PR. [GitHub Actions](https://github.com/ileka2468/battlefront/actions) builds the frontend, compiles Python and Lua, checks the 3D assets and viewer, and runs the workspace/edge regression suite.
2. Render deploys **`main` only after GitHub checks pass** (`autoDeployTrigger: checksPass` in [`render.yaml`](render.yaml)). It builds and serves the browser app and proxies only allowlisted companion API routes to the fixed HTTPS origin, preserving same-origin cookies. Set `BF_ORIGIN_URL` in the Render dashboard, not in Git. The production gateway is stateless; the database and DCS export stay on the origin host, so Render redeploys cannot wipe inventory.
3. The DCS host is a separately administered dependency. Deploy its source and read-only snapshot publishers independently of Render. Keep the SQLite file, its credential-hash file, and the installed DCS save outside versioned code. A Render release never restarts DCS.
4. Verify `/healthz` for the gateway, `/api/state` for the persistent workspace, `/api/telemetry` for a live/advancing `frame_id`, and `/?replay=1` independently. A healthy gateway does not claim the DCS feed is live. If an origin URL rotates, update `BF_ORIGIN_URL` and redeploy; choose a named tunnel for a permanent origin.
5. Roll back a web release to the last healthy Render deploy or revert its Git commit. On the DCS host keep the pre-release save and mission engine files; restoring old mission code does not require discarding the new workspace database. Back up SQLite using its backup API, not a copy of a live WAL database.

## Useful checks

```sh
npm --prefix frontend ci
npm --prefix frontend run build
python -m unittest discover -s tests -v
node scripts/verify_contact_spacing.cjs
python scripts/verify_aircraft_assets.py
```

The viewer uses an adaptive presentation buffer instead of tying visible motion to Internet packet arrivals. Source freshness and live/replay state are reported independently. A drop in source telemetry is marked as delayed rather than disguised as live. Aircraft asset authors, licenses, and corresponding source are available from the in-app aircraft credits page.
