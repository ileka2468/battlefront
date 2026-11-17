# Battlefront companion frontend

React owns the application shell, workspace tabs, forms, and data fetched from the existing Python API. Tailwind is compiled locally. The Three.js adapter in `web/tacview.js` owns only the canvas and fast-changing telemetry DOM inside the Airspace panel. It keeps running when navigating away; returning to Airspace retains the same canvas and camera.

From the Battlefront root:

```powershell
npm.cmd --prefix frontend ci
npm.cmd --prefix frontend run build
```

The generated `web/dist/companion.js` and `web/dist/tailwind.css` are served by `web/server.py` alongside the local Three.js and model assets. The release does not load the former `web/app.js` or `web/styles.css`. The default route reads live Battlefront; `/?replay=1` requests the recorded 20v20 run explicitly. Classroom actions do not modify the DCS mission.
