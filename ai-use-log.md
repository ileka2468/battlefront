# AI Use Log - Battlefront

Repo: https://github.com/ileka2468/battlefront
Branch: main

## What I wrote vs what AI generated

I wrote the frontend web app, UI layout, and the 3D Tacview viewer (frontend/src/main.jsx, web/tacview.js) myself. Some of the aircraft 3D models and asset setup also came from models I made for my Unity game.

AI generated most of the DCS campaign Lua files (mission/, server/Battlefront*.lua) and the Python backend/infra tooling (web/server.py, cloud/render_gateway.py, server/telemetry_engine.py, server/persistence/workspace_store.py, scripts/, tests/).

## What I kept, changed, and checked

Kept:
- Render gateway proxying to the persistent SQLite/DCS host
- PBKDF2 local login, CSRF checks, and 429 rate limiting
- /mcp endpoint (3 read tools + 1 write tool) and /mcp/app view
- /api/weather (Open-Meteo) and /api/app-telemetry

Verified by running npm run build, python -m compileall, python -m unittest discover -s tests -v (40 passed, 1 skipped without lua5.1 on Windows), scripts/verify_production_workspace.py, and local HTTP checks.

Rejected:
- Putting SQLite on Render's ephemeral disk (kept it on the DCS host instead)

## Challenged AI claim

AI initially set the local 20v20 replay to run at 4x speed with raw uninterpolated frames. When I tested /?replay=1 in the browser it looked choppy and moved way too fast, so I switched it to interpolated playback and set the default speed back to 1x.

## Secrets / redaction

No .env files, passwords, API keys, or session tokens are committed to Git or printed in logs. The professor login is submitted separately on D2L.
