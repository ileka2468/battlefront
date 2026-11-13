/** Three.js render interpolation for live DCS and explicitly labeled recorded flights. */
// The exporter samples at ~4 Hz, but the camera and tracks need a continuous
// clock. Spend a small bounded latency budget to ride through delivery jitter
// instead of retargeting each 60 Hz animation on the most recent HTTP arrival.
class LiveSnapshotClock {
  constructor() { this.reset(); }

  reset() {
    this.latest=null;
    this.playhead=null;
    this.lastDraw=null;
    this.interval=.25;
    this.delay=.52;
    this.jitter=0;
    this.rate=1;
    this.delivery=[];
    this.held=false;
  }

  observe(sim, stamp, sequence, received, reportedAge, roundTrip=0) {
    if (![sim,sequence,received].every(Number.isFinite)) return;
    const halfTrip=Math.min(.35,Math.max(0,roundTrip*.5));
    const age=Math.min(1.2,Math.max(0,Number(reportedAge)||0)+halfTrip);
    if (this.latest && sim <= this.latest.sim) return;
    if (this.latest) {
      const simStep=sim-this.latest.sim;
      const stampStep=stamp-this.latest.stamp;
      const seqStep=Math.max(1,sequence-this.latest.sequence);
      if (Number.isFinite(stampStep) && stampStep>.03 && stampStep<3) {
        const measured=simStep/stampStep;
        if (measured>.5 && measured<2) this.rate+=.10*(measured-this.rate);
        this.jitter+=.15*(Math.min(.25,Math.abs(received-this.latest.received-stampStep))-this.jitter);
      }
      const nominal=(Number.isFinite(stampStep) && stampStep>0 ? stampStep : simStep/this.rate)/seqStep;
      if (nominal>.08 && nominal<.65) this.interval+=.15*(nominal-this.interval);
    }
    this.delivery.push(age);
    if (this.delivery.length>20) this.delivery.shift();
    const ordered=[...this.delivery].sort((a,b)=>a-b);
    const p90=ordered[Math.floor((ordered.length-1)*.9)];
    this.delay=Math.max(.42,Math.min(1.15,this.interval+p90+Math.min(.22,this.jitter*1.4)+.065));
    this.latest={sim,stamp,sequence,received,age};
  }

  advance(wall) {
    if (!this.latest) return null;
    const {sim,received,age}=this.latest;
    const desired=sim+(wall-received+age-this.delay)*this.rate;
    const cap=sim+.28;
    const dt=this.lastDraw==null ? 0 : Math.max(0,wall-this.lastDraw);
    this.lastDraw=wall;
    if (this.playhead==null || (dt>1.25 && !this.held)) this.playhead=Math.min(cap,desired);
    else if (!this.held) {
      const drift=desired-this.playhead;
      const rateScale=Math.max(.76,Math.min(1.26,1+drift*1.7));
      this.playhead=Math.min(cap,this.playhead+Math.min(dt,.25)*this.rate*rateScale);
    }
    return this.playhead;
  }
}

function addLivePose(record,time,x,y,z,heading,pitch,roll,reset=false) {
  const poses=record.livePoses ??= [];
  const last=poses[poses.length-1];
  if (reset || (last && (time<last[0] || Math.hypot(x-last[1],y-last[2],z-last[3])>30))) poses.length=0;
  else if (last && time===last[0]) poses.pop();
  poses.push([time,x,y,z,heading,pitch,roll]);
  if (poses.length>16) poses.shift();
}

function sampleLivePose(record,time,out,allowLead=true) {
  const poses=record.livePoses;
  if (!poses?.length || time==null) return false;
  let from=poses[0], to=from, mix=0;
  if (poses.length>1 && time>from[0]) {
    let i=poses.length-1;
    while (i>1 && poses[i-1][0]>time) i--;
    to=poses[i]; from=poses[i-1];
    const step=to[0]-from[0];
    // Don't project an old velocity through a long missing interval. Allow
    // only 280ms of viewer-side drift when a normal update is running late.
    if (step>0) {
      const extra=allowLead && step<.85 ? Math.min(.28,step*1.5) : 0;
      mix=Math.max(0,Math.min(1+extra/step,(time-from[0])/step));
    }
  }
  out.set(from[1]+(to[1]-from[1])*mix, from[2]+(to[2]-from[2])*mix, from[3]+(to[3]-from[3])*mix);
  const attitude=Math.min(1,mix);
  record.currentHeading=TacviewVisualizer.mixAngle(from[4],to[4],attitude);
  record.currentPitch=from[5]+(to[5]-from[5])*attitude;
  record.currentRoll=TacviewVisualizer.mixAngle(from[6],to[6],attitude);
  return true;
}

class TacviewVisualizer {
  constructor(containerId) {
    this.container = document.getElementById(containerId);
    if (!this.container) return;

    this.scene = null;
    this.camera = null;
    this.renderer = null;
    this.controls = null;
    this.clock = new THREE.Clock();

    this.airframeCache = new Map();
    this.fleetTemplates = new Map();
    this.fleetPending = new Map();
    this.fleetUnavailable = new Set();
    this.fleetRetryAt = new Map();
    this.assetQueue = [];
    this.activeModelLoads = 0;
    this.missileCache = new Map();
    this.contactTextures = new Map();
    this.replay = null;
    this.speed = 4;
    this.seekPending = false;
    this.followNextLaunch = false;
    this.cameraPreset = "engagement";
    this.didFrameContacts = false;

    this.aircraftUnits = new Map(); // id -> { mesh, line, shadow, label, data, currentPos, targetPos, heading, pitch, roll, speed_kts }
    this.missileMeshes = new Map(); // id -> { mesh, trail, history, currentPos, targetPos, heading, speed_kts }
    this.sectorMarkers = [];
    this.sectorReadouts = new Map();
    this.campaignKey = null;

    this.selectedUnitId = null;
    this.trackedUnitId = null;
    this.trackedMissileId = null;

    this.snapshotInterval = 0.6;
    this.lastSnapshotAt = 0;
    this.liveClock = new LiveSnapshotClock();
    this.snapshotKey = null;
    this.trackMode = null;
    this.telemetryTimer = null;
    this.dataSource = "INITIALIZING...";
    this.telemetryMode = null;
    this.terrain = null;

    this.init();
  }

  init() {
    const width = this.container.clientWidth || 900;
    const height = this.container.clientHeight || 550;

    // 1. Scene
    this.scene = new THREE.Scene();
    this.scene.background = new THREE.Color(0x78929e).convertSRGBToLinear();
    this.scene.fog = new THREE.FogExp2(this.scene.background, 0.0017);
    this.buildSky();

    // 2. Camera
    this.camera = new THREE.PerspectiveCamera(43, width / height, .04, 2400);
    this.camera.position.set(-190, 44, 58);

    // 3. Renderer
    this.renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false, powerPreference: "high-performance" });
    this.renderer.setSize(width, height);
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 1.6));
    this.renderer.outputEncoding = THREE.sRGBEncoding;
    this.container.appendChild(this.renderer.domElement);

    // 4. OrbitControls
    if (typeof THREE.OrbitControls !== "undefined") {
      this.controls = new THREE.OrbitControls(this.camera, this.renderer.domElement);
      this.controls.enableDamping = true;
      this.controls.dampingFactor = 0.08;
      this.controls.maxPolarAngle = Math.PI / 2 - 0.01; // Prevent camera clipping through ground
      this.controls.minDistance = 1.6;
      this.controls.maxDistance = 1400;
      this.controls.target.set(-96, 14, -15);
    }

    // 5. Lighting
    const ambientLight = new THREE.HemisphereLight(0xdde8f8, 0x645a49, .82);
    this.scene.add(ambientLight);

    const sunLight = new THREE.DirectionalLight(0xfff0dc, 1.35);
    sunLight.position.set(-170, 265, 120);
    this.scene.add(sunLight);

    const fillLight = new THREE.DirectionalLight(0xc1d3dc, 0.22);
    fillLight.position.set(-180, 150, -180);
    this.scene.add(fillLight);

    // 6. Build 3D Caucasus Topographic Mountain Terrain & Water
    this.terrain = new CaucasusTerrain(this.scene);
    this.terrain.ready.then(() => {
      const badge = document.getElementById("tacviewMapSource");
      if (badge) badge.textContent = this.terrain.dem ? "CAUCASUS · MAPZEN ELEVATION" : "CAUCASUS · ILLUSTRATIVE FALLBACK";
      this.buildTacticalFrontline();
      this.loadSectors();
    });
    this.bindAirspaceControls();

    // 8. Event Listeners & Keyboard Shortcuts
    this.raycaster = new THREE.Raycaster();
    this.mouse = new THREE.Vector2();
    this.pickPoint = new THREE.Vector3();
    this.followDelta = new THREE.Vector3();
    this.depthProbe = new THREE.Vector3();
    const canvas = this.renderer.domElement;
    canvas.addEventListener("pointerdown", e => {
      if (e.isPrimary && e.button === 0) this.primaryPress = {id:e.pointerId,x:e.clientX,y:e.clientY,dragged:false};
      else if (this.primaryPress) this.primaryPress.dragged = true;
    });
    canvas.addEventListener("pointermove", e => {
      const press = this.primaryPress;
      if (press?.id === e.pointerId && Math.hypot(e.clientX-press.x,e.clientY-press.y)>5) press.dragged=true;
      if (e.pointerType === "mouse" && !press) {
        const rect = canvas.getBoundingClientRect();
        this.camera.updateMatrixWorld();
        canvas.style.cursor = this.nearestContact(e.clientX, e.clientY, rect) ? "pointer" : "";
      }
    });
    canvas.addEventListener("pointerleave", () => { canvas.style.cursor = ""; });
    canvas.addEventListener("pointercancel", () => { this.primaryPress=null; });
    canvas.addEventListener("pointerup", e => {
      const press = this.primaryPress;
      if (press?.id !== e.pointerId) return;
      this.primaryPress=null;
      if (!press.dragged && Math.hypot(e.clientX-press.x,e.clientY-press.y)<=5) this.onSceneClick(e);
    });
    window.addEventListener("resize", () => this.onResize());
    window.addEventListener("keydown", (e) => this.onKeyDown(e));

    // 9. Start Telemetry Loop & 60 FPS Render Loop
    this.startTelemetryPolling();
    this.animate();
  }

  getElevation(x, z) {
    return this.terrain.ground(x, z);
  }

  buildSky() {
    const mesh = new THREE.Mesh(new THREE.SphereGeometry(1200,24,14),new THREE.ShaderMaterial({
      side:THREE.BackSide, depthTest:false, depthWrite:false,
      uniforms:{
        haze:{value:this.scene.background},
        upper:{value:new THREE.Color(0x4d6e86).convertSRGBToLinear()},
        low:{value:new THREE.Color(0xbac6c5).convertSRGBToLinear()}
      },
      vertexShader:`varying vec3 eyeRay; void main(){eyeRay=position;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.);}`,
      fragmentShader:`varying vec3 eyeRay;uniform vec3 haze,upper,low;
        void main(){float h=normalize(eyeRay).y;
          vec3 color=mix(haze,mix(low,upper,smoothstep(.02,.62,h)),smoothstep(-.13,.055,h));
          gl_FragColor=vec4(color,1.);
          #include <encodings_fragment>
        }`
    }));
    mesh.renderOrder=-100;
    this.sky=mesh;
    this.scene.add(mesh);
  }

  buildTacticalFrontline() {
    // Amber frontline demarcation along X = -165,000 (Z = 0 in Three.js)
    const points = [];
    for (let x = -380; x <= 380; x += 2) {
      const y = this.getElevation(x, 0) + 0.3;
      points.push(new THREE.Vector3(x, y, 0));
    }
    const frontlineGeom = new THREE.BufferGeometry().setFromPoints(points);
    const frontlineMat = new THREE.LineDashedMaterial({
      color: 0xaf8c54,
      transparent: true, opacity: 0.62,
      dashSize: 4,
      gapSize: 3,
      linewidth: 2
    });
    const frontline = new THREE.Line(frontlineGeom, frontlineMat);
    frontline.computeLineDistances();
    this.scene.add(frontline);
  }

  async loadSectors() {
    try {
      const res = await fetch("/sectors.json");
      if (!res.ok) return;
      const sectors = await res.json();

      sectors.forEach((sec) => {
        const groundY = this.getElevation(
          (sec.z - 540000) * 0.001,
          -(sec.x - (-165000)) * 0.001
        );
        const pos = this.dcsToThree(sec.x, sec.z, 0);
        pos.y = groundY;

        const ringColor = sec.side === 2 ? 0x0ea5e9 : 0xf43f5e;
        const ringGeom = new THREE.RingGeometry(2.55, 3.05, 32);
        const ringMat = new THREE.MeshBasicMaterial({
          color: ringColor,
          side: THREE.DoubleSide,
          transparent: true,
          opacity: 0.65
        });
        const ring = new THREE.Mesh(ringGeom, ringMat);
        ring.rotation.x = Math.PI / 2;
        ring.position.set(pos.x, pos.y + 0.25, pos.z);
        this.scene.add(ring);

        // Center beacon post
        const beaconGeom = new THREE.CylinderGeometry(0.42, 0.42, 2, 12);
        const beaconMat = new THREE.MeshBasicMaterial({ color: ringColor });
        const beacon = new THREE.Mesh(beaconGeom, beaconMat);
        beacon.position.set(pos.x, pos.y + 1, pos.z);
        this.scene.add(beacon);

        // Sector Name Sprite
        const sprite = this.createTacticalTextSprite(sec.name, sec.side === 2 ? "#38bdf8" : "#f43f5e", 11);
        sprite.position.set(pos.x, pos.y + 5, pos.z);
        sprite.scale.set(24, 6, 1);
        this.sectorMarkers.push(sprite);
        this.scene.add(sprite);
        this.sectorReadouts.set(sec.id,{original:sec,ring,beacon,sprite});
      });
      this.applySectorOwnership();
    } catch (e) {
      console.warn("Could not load sectors.json for 3D Tacview:", e);
    }
  }

  applySectorOwnership() {
    const current=new Map((this.campaign?.sectors||[]).map(s=>[s.id,s]));
    for(const [id,r] of this.sectorReadouts){
      const s=current.get(id)||r.original;
      const tm=s.side===2?"#38bdf8":s.side===1?"#f43f5e":"#e7ba71";
      r.ring.material.color.set(tm); r.beacon.material.color.set(tm);
      const name=current.has(id)?`${s.name}\n${s.status} · LEVEL ${s.level}`:s.name;
      if(r.text!==name || r.sprite.userData.color!==tm){
        r.text=name; r.sprite.userData.color=tm;
        this.updateTextSprite(r.sprite,name);
      }
    }
  }

  updateCampaign(campaign) {
    const key=JSON.stringify(campaign??null);
    if (key===this.campaignKey) return;
    this.campaignKey=key;
    this.campaign=campaign || null;
    this.applySectorOwnership();
    window.setBattlefrontCampaignSnapshot?.(this.campaign);
  }

  // ============================================================================
  // 3D MODELS: SHARED FULL-FIDELITY AIRFRAME TEMPLATES AND TRACK GLYPHS
  // ============================================================================

  normalizedTemplate(model) {
    const bounds = new THREE.Box3().setFromObject(model);
    const sphere = bounds.getBoundingSphere(new THREE.Sphere());
    const fit = new THREE.Group();
    const k = 1 / Math.max(.01,sphere.radius);
    fit.scale.setScalar(k);
    fit.position.copy(sphere.center).multiplyScalar(-k);
    fit.add(model);
    const root = new THREE.Group();
    root.add(fit);
    root.rotation.order = "YXZ";
    root.userData = {...model.userData};
    return root;
  }

  makeAircraftMesh(u) {
    const profile = BattlefrontAirframes.keyFor(u.type);
    this.ensureFleetDetail(profile);
    const template = this.fleetTemplates.get(profile);
    let model;
    if (template) model = template.clone(true);
    else if (this.fleetPending.has(profile) && !this.fleetRetryAt.has(profile)) {
      // Mark tracks before the first GLB arrives, but don't substitute a low-poly aircraft
      // for a detailed one. Shared glyph geometry is also cheap on cold-cache connections.
      this.aircraftLoadingGlyph ??= new THREE.SphereGeometry(.16, 8, 6);
      this.aircraftLoadingColors ??= [0xd4e5ed,0xf67985,0x59b4fb].map(color=>new THREE.MeshBasicMaterial({color}));
      model = new THREE.Group();
      model.add(new THREE.Mesh(this.aircraftLoadingGlyph, this.aircraftLoadingColors[u.side] ?? this.aircraftLoadingColors[0]));
      model.userData.loading = true;
    } else model = this.getRepresentativeTemplate(u).clone(true);
    model.userData.unitId = u.id;
    this.scene.add(model);
    return model;
  }

  getRepresentativeTemplate({type,side,category}) {
    const key = [type,side,category].join("|");
    if (!this.airframeCache.has(key))
      this.airframeCache.set(key,this.normalizedTemplate(BattlefrontAirframes.aircraft(type,side,category)));
    return this.airframeCache.get(key);
  }

  removeAircraftMesh(mesh) { this.scene.remove(mesh); }

  replaceAircraftMesh(contact, template) {
    const previous = contact.mesh;
    const next = template.clone(true);
    next.userData.unitId = contact.data.id;
    next.position.copy(previous.position);
    next.rotation.copy(previous.rotation);
    next.scale.copy(previous.scale);
    this.scene.remove(previous);
    this.scene.add(next);
    contact.mesh = next;
  }

  ensureFleetDetail(profile) {
    if (!profile || this.fleetTemplates.has(profile) || this.fleetPending.has(profile) ||
        this.fleetUnavailable.has(profile) || !THREE.GLTFLoader ||
        (this.fleetRetryAt.get(profile) ?? 0) > performance.now()) return;
    this.fleetPending.set(profile, true);
    this.assetQueue.push(profile);
    this.drainModelQueue();
  }

  drainModelQueue() {
    // Load only active families, and keep concurrent downloads bounded so a
    // cold browser doesn't starve the polling connection during a large event.
    while (this.activeModelLoads < 3 && this.assetQueue.length) {
      const profile = this.assetQueue.shift();
      ++this.activeModelLoads;
      this.getImportedTemplate(profile).then(template => {
        this.fleetRetryAt.delete(profile);
        if (template) this.fleetTemplates.set(profile,template);
        else this.fleetUnavailable.add(profile);
        this.promoteFleet(profile,template);
      }).catch(err => {
        this.fleetRetryAt.set(profile,performance.now()+15000);
        this.promoteFleet(profile,null);
        console.warn("Airframe model unavailable:",profile,err.message);
      }).finally(() => {
        this.fleetPending.delete(profile);
        --this.activeModelLoads;
        this.drainModelQueue();
      });
    }
  }

  promoteFleet(profile, template) {
    for (const contact of this.aircraftUnits.values()) {
      if (BattlefrontAirframes.keyFor(contact.data.type) !== profile) continue;
      if (template || contact.mesh.userData.loading)
        this.replaceAircraftMesh(contact, template ?? this.getRepresentativeTemplate(contact.data));
    }
    const selected = this.aircraftUnits.get(this.selectedUnitId);
    if (selected && BattlefrontAirframes.keyFor(selected.data.type) === profile) this.renderTargetHUD(selected.data);
  }

  async getImportedTemplate(profile) {
    this.modelManifest ??= fetch("/models/vendor/manifest.json").then(res => {
      if (!res.ok) throw new Error(`Model manifest HTTP ${res.status}`);
      return res.json();
    }).catch(err => { this.modelManifest=null; throw err; });
    const manifest = await this.modelManifest;
    const item = manifest?.[profile];
    if (!item || !/^\/models\/vendor\/[a-z0-9-]+\.glb$/.test(item.file)) return null;
    const model = await new Promise((resolve,reject) => new THREE.GLTFLoader().load(item.file,g=>resolve(g.scene),undefined,reject));
    if (item.turn) model.rotation.y = THREE.MathUtils.degToRad(item.turn);
    if (profile === "UH-60" || profile === "Mi-24") {
      const bounds = new THREE.Box3().setFromObject(model);
      const size = bounds.getSize(new THREE.Vector3());
      const rotor = new THREE.Mesh(new THREE.BoxGeometry(.16,.04,size.z*.88),
        new THREE.MeshStandardMaterial({color:0x181d22,roughness:.8}));
      const cross = rotor.clone(); cross.rotation.y = Math.PI/2;
      rotor.position.set(0,bounds.max.y*.86,bounds.max.z*.42);
      cross.position.copy(rotor.position); model.add(rotor,cross);
    }
    model.userData = {profile,displayName:BattlefrontAirframes.profiles[profile]?.name ?? profile,
      representative:true,downloaded:true};
    // Object3D.clone shares the imported geometry/materials across contacts;
    // no mesh swaps are driven by zoom, view mode, or selection.
    return this.normalizedTemplate(model);
  }

  dcsToThree(dcsX, dcsZ, altMeters) {
    return { x: (dcsZ - 540000) * .001, y: altMeters * .0025, z: -(dcsX + 165000) * .001 };
  }

  // ============================================================================
  // TELEMETRY & 60 FPS CONTINUOUS DEAD-RECKONING ENGINE
  // ============================================================================

  replayTime() {
    if (!this.replay) return 0;
    return this.replay.anchor + (performance.now() - this.replay.wall) * this.speed / 1000;
  }

  jumpReplay(seconds, follow = false) {
    if (!this.replay) return;
    this.replay.anchor=Math.max(0,Math.min(this.replay.duration-.01,Number(seconds)||0));
    this.replay.wall=performance.now();
    this.seekPending=true;
    this.followNextLaunch=follow;
    if (!follow && this.trackedMissileId != null) this.closeTargetHUD();
  }

  bindAirspaceControls() {
    const on=(id,type,fn)=>document.getElementById(id)?.addEventListener(type,fn);
    this.forceReplay=new URLSearchParams(location.search).get("replay")==="1";
    const modeLink=document.getElementById("bf-campaign-mode");
    if(modeLink && this.forceReplay){
      modeLink.href="/"; modeLink.textContent="Open live campaign";
    }
    on("bf-replay-seek","input",e=>this.jumpReplay(e.target.value));
    on("bf-replay-restart","click",()=>{this.setCameraPreset("engagement");this.jumpReplay(0);});
    on("bf-replay-speed","change",e=>{
      if (!this.replay) return;
      this.replay.anchor=this.replayTime(); this.replay.wall=performance.now();
      this.speed=Number(e.target.value);
    });
    on("bf-missile-jump","click",()=>{
      if (this.missileMeshes.size) { this.trackNextMissile(); return; }
      if (!this.replay || this.replay.first_missile==null) return;
      this.speed=2; document.getElementById("bf-replay-speed").value="2";
      this.jumpReplay(this.replay.first_missile+.15,true);
    });
    on("bf-show-details","change",e=>{this.showAllLabels=e.target.checked;});
    on("bf-view-fullscreen","click",()=>{
      const pane=document.getElementById("tacviewTab");
      if(document.fullscreenElement) document.exitFullscreen();
      else pane?.requestFullscreen?.().catch(()=>{});
    });
  }

  startTelemetryPolling() {
    const fetchTelemetry = async () => {
      const started=performance.now();
      try {
        const timestamp=this.replayTime() % 86400;
        const res = await fetch(`/api/telemetry?t=${timestamp.toFixed(3)}${this.forceReplay?"&replay=1":""}`, {cache:"no-store", signal: AbortSignal.timeout(4000)});
        if (!res.ok) throw new Error(String(res.status));
        const data=await res.json();
        this.updateTacticalState(data,(performance.now()-started)/1000);
      } catch (err) {
        if (this.telemetryMode === "live") this.liveClock.held=true;
        const badge = document.getElementById("tacviewDataSourceBadge");
        if (badge) {
          badge.textContent = "Feed disconnected · showing last snapshot";
          badge.dataset.status = this.telemetryMode === "live" ? "delayed" : "disconnected";
        }
        // Keep the map and flight tracks, but mark the finance readout stale.
        // Clear its event key so an identical snapshot can restore live status.
        if (this.campaignKey != null) {
          this.campaignKey = undefined;
          window.setBattlefrontCampaignSnapshot?.(null);
        }
        console.warn("Airspace update:",err);
      } finally {
        // Keep one request in flight. Account for HTTP duration instead of
        // adding the full socket delay to every polling interval.
        const cadence=document.hidden ? 1000 : this.replay && this.speed===0 ? 500 : this.forceReplay ? 220 : 190;
        this.telemetryTimer = setTimeout(fetchTelemetry,Math.max(30,cadence-(performance.now()-started)));
      }
    };
    fetchTelemetry();
  }

  updateReadouts(data) {
    const blue=data.units.filter(u=>u.side===2).length, red=data.units.filter(u=>u.side===1).length;
    const put=(id,v)=>{const el=document.getElementById(id); if(el) el.textContent=v;};
    put("bf-blue-count",blue);
    put("bf-red-count",red);
    put("bf-missile-count",data.missiles?.length||0);
    const timeline=document.getElementById("bf-replay-controls");
    if (timeline) timeline.hidden=!data.playback;
    if(data.playback){
      if(!this.replay) {
        this.replay={...data.playback,anchor:0,wall:performance.now()};
        if(data.units.length < 12) this.speed=1;
        document.getElementById("bf-replay-speed").value=String(this.speed);
      }
      const seek=document.getElementById("bf-replay-seek");
      if(seek) {seek.max=Math.max(0,data.playback.duration-.01); if (document.activeElement!==seek) seek.value=data.playback.cursor;}
      put("bf-replay-time",`${Math.floor(data.playback.cursor/60)}:${String(Math.floor(data.playback.cursor%60)).padStart(2,"0")}`);
    } else this.replay=null;
    const follow=document.getElementById("bf-missile-jump");
    if(follow){
      const active=data.missiles?.length>0;
      follow.disabled=!active && data.playback?.first_missile==null;
      follow.textContent=active?"Follow missile":data.playback?.first_missile!=null?"Jump to missile launch":"No active missiles";
    }
  }

  updateTacticalState(data,roundTrip=0) {
    if (!data || !Array.isArray(data.units)) return;
    const previousMode = this.telemetryMode;
    this.telemetryMode = data.telemetry_mode ?? (data.is_live_dcs ? "live" : data.playback ? "replay" : "sample");
    const live=this.telemetryMode==="live";
    const held=live && (data.live_status==="delayed" || !data.is_live_dcs);
    this.liveClock.held=held;
    this.dataSource = data.data_source || "Telemetry";
    this.updateCampaign(data.is_live_dcs && data.live_status !== "delayed" ? data.campaign : null);
    const badge = document.getElementById("tacviewDataSourceBadge");
    if (badge) {
      const age = data.sample_age == null ? "" : ` · ${data.sample_age.toFixed(1)}s old`;
      badge.textContent = `${this.dataSource} · ${data.units.length} aircraft${age}`;
      badge.dataset.live = String(data.is_live_dcs === true);
      badge.dataset.status = data.live_status ?? this.telemetryMode;
    }
    this.updateReadouts(data);
    const frameKey = data.frame_id ?? data.timestamp;
    if (previousMode === this.telemetryMode && frameKey === this.snapshotKey && !this.seekPending) return;
    const oldKey = String(this.snapshotKey).split(":");
    const newKey = String(frameKey).split(":");
    const discontinuity = this.seekPending || previousMode !== this.telemetryMode || (newKey.length >= 2 &&
      (oldKey[0] !== newKey[0] || oldKey[2] !== newKey[2] || Number(newKey[1])<Number(oldKey[1]))) ||
      (live && this.liveClock.latest && data.sim_time != null && data.sim_time < this.liveClock.latest.sim-.03);
    this.seekPending=false;
    this.snapshotKey = frameKey;
    const now = performance.now() / 1000;
    if (discontinuity || (live && data.live_status==="waiting")) this.liveClock.reset();
    this.liveClock.held=held;
    const liveTime=live && Number.isFinite(data.sim_time) ? data.sim_time : null;
    if (liveTime!=null) {
      const stamp=Number.isFinite(data.capture_timestamp) ? data.capture_timestamp : data.timestamp-data.sample_age;
      this.liveClock.observe(liveTime,stamp,Number(newKey[1]),now,data.sample_age,roundTrip);
    }
    this.snapshotInterval = Math.max(.12, Math.min(.8, now - (this.lastSnapshotAt || now - .25)));
    this.lastSnapshotAt = now;
    const currentIds = new Set();
    for (const u of data.units) {
      currentIds.add(u.id);
      const pos = this.dcsToThree(u.x, u.z, u.alt);
      let record = this.aircraftUnits.get(u.id);
      if (!record) {
        record = this.createAircraftInstance(u, pos);
        this.aircraftUnits.set(u.id, record);
      } else if (u.side !== record.data.side || u.type !== record.data.type) {
        this.removeAircraftMesh(record.mesh);
        record.mesh = this.makeAircraftMesh(u);
        record.marker.material.color.setHex(u.side === 2 ? 0x8ed6ff : 0xff9f92);
      }
      // An already-present contact can recover from a transient asset error.
      if (!record.mesh.userData.downloaded) this.ensureFleetDetail(BattlefrontAirframes.keyFor(u.type));
      record.data = u;
      record.startPos.copy(record.currentPos);
      record.targetPos.set(pos.x, pos.y, pos.z);
      record.startHeading = record.currentHeading;
      record.targetHeading = u.heading;
      record.startPitch = record.currentPitch;
      record.targetPitch = u.pitch || 0;
      record.startRoll = record.currentRoll;
      record.targetRoll = u.roll || 0;
      if (liveTime!=null) addLivePose(record,liveTime,pos.x,pos.y,pos.z,u.heading,u.pitch||0,u.roll||0,discontinuity);
      if (discontinuity) {
        record.startPos.copy(record.targetPos);
        record.startHeading = record.targetHeading;
        record.startPitch = record.targetPitch;
        record.startRoll = record.targetRoll;
      }
      const label = `${u.callsign}
${Math.round(u.alt * 3.28084 / 100) * 100}ft · ${Math.round(u.speed_kts / 5) * 5}kt`;
      if ((this.showAllLabels || u.id === this.selectedUnitId) && record.lastLabel !== label) {
        this.updateTextSprite(record.label,label); record.lastLabel=label;
      }
      this.pushPath(record.path, record.targetPos, discontinuity, 24);
      if (discontinuity) record.currentPos.copy(record.targetPos);
    }
    for (const [id, record] of this.aircraftUnits.entries()) {
      if (currentIds.has(id)) continue;
      this.removeAircraftMesh(record.mesh);
      this.scene.remove(record.marker);
      record.marker.material.dispose(); // the team marker map is shared across tracks
      for (const item of [record.line, record.shadow, record.label, record.path.line]) {
        this.scene.remove(item);
        item.geometry?.dispose();
        item.material.map?.dispose();
        item.material.dispose();
      }
      this.aircraftUnits.delete(id);
      if (id === this.selectedUnitId) this.closeTargetHUD();
      if (id === this.trackedUnitId) this.trackedUnitId = null;
    }
    this.sortedAircraft = Array.from(this.aircraftUnits.entries()).sort(([a], [b]) => String(a).localeCompare(String(b)));
    this.updateContacts();
    this.updateMissiles(data.missiles || [], discontinuity,liveTime);
    if (this.followNextLaunch && this.missileMeshes.size) {
      this.followNextLaunch=false; this.trackNextMissile();
    }
    if (!this.didFrameContacts && this.aircraftUnits.size) {
      this.didFrameContacts=true;
      if (this.cameraPreset==="engagement") this.placeEngagement();
    }
    if (this.selectedUnitId && this.aircraftUnits.has(this.selectedUnitId)) {
      this.renderTargetHUD(this.aircraftUnits.get(this.selectedUnitId).data);
    }
  }

  updateContacts() {
    const tray = document.getElementById("tacviewContacts");
    if (!tray) return;
    const key = JSON.stringify(this.sortedAircraft.map(([id, r]) => [id, r.data.callsign]));
    if (key === this.contactsKey) return;
    this.contactsKey = key;
    tray.replaceChildren();
    const label = document.createElement("strong");
    label.textContent = this.sortedAircraft.length ? "CONTACTS" : "NO AIRCRAFT REPORTED";
    tray.append(label);
    for (const [id, r] of this.sortedAircraft) {
      const button = document.createElement("button");
      button.type = "button";
      button.dataset.side = r.data.side;
      button.textContent = r.data.callsign;
      button.onclick = () => this.trackCamera(id);
      tray.append(button);
    }
  }

  createAircraftInstance(u, pos) {
    const mesh = this.makeAircraftMesh(u);
    const teamColor = u.side === 2 ? 0x59b4fb : 0xf67985;
    const marker = this.makeContactMarker("aircraft",u.side === 2 ? 0x8ed6ff : 0xff9f92);
    // Glyph -> true geographic point at the reported altitude -> ground.
    const lineGeom = new THREE.BufferGeometry();
    lineGeom.setAttribute("position", new THREE.BufferAttribute(new Float32Array(9), 3));
    const line = new THREE.Line(lineGeom, new THREE.LineBasicMaterial({
      color: teamColor, transparent: true, opacity: .58
    }));
    line.frustumCulled = false;
    this.scene.add(line);
    const shadow = new THREE.Mesh(new THREE.RingGeometry(.45, .72, 24),
      new THREE.MeshBasicMaterial({color: teamColor, side: THREE.DoubleSide}));
    shadow.rotation.x = -Math.PI/2;
    this.scene.add(shadow);
    const label = this.createTacticalTextSprite("", u.side === 2 ? "#a3d7ff" : "#ffbdc5", 17);
    label.userData.unitId = u.id;
    label.scale.set(19, 4.75, 1);
    this.scene.add(label);

    const p = new THREE.Vector3(pos.x, pos.y, pos.z);
    return {
      mesh, marker, line, shadow, label, data: u, path: this.makePath(teamColor, .69, 28),
      currentPos: p, startPos: p.clone(), targetPos: p.clone(), displayPos: p.clone(),
      currentHeading: u.heading, startHeading: u.heading, targetHeading: u.heading,
      currentPitch: u.pitch || 0, startPitch: u.pitch || 0, targetPitch: u.pitch || 0,
      currentRoll: u.roll || 0, startRoll: u.roll || 0, targetRoll: u.roll || 0
    };
  }

  // Keep a 5.2 km gap on the display only (each 3D glyph fits a radius-2.35 sphere).
  // Stable placement order plus hex-grid search handles even coincident positions.
  static placeGlyph(anchor, occupied, out, gap = 5.2, radius = null) {
    const available = (x, z) => occupied.every(p => {
      const separation = radius == null ? gap : Math.max(1.2, (radius + (p.glyphRadius ?? radius)) * 1.13);
      return (p.x-x)**2+(p.z-z)**2 >= separation**2 - 1e-8;
    });
    if (available(anchor.x, anchor.z)) return out.copy(anchor);
    for (let ring = 1; ; ring++) {
      for (let a = -ring; a <= ring; a++) {
        for (let b = -ring; b <= ring; b++) {
          if (Math.max(Math.abs(a), Math.abs(b), Math.abs(a+b)) !== ring) continue;
          const x = anchor.x + gap * (a + b * .5);
          const z = anchor.z + gap * b * Math.sqrt(.75);
          if (available(x,z)) return out.set(x,anchor.y,z);
        }
      }
    }
  }

  static mixAngle(from, to, t) {
    return from + (((to-from+180)%360+360)%360-180)*t;
  }


  onResize() {
    if (!this.renderer || !this.camera || !this.container) return;
    this.camera.aspect = (this.container.clientWidth || 900) / (this.container.clientHeight || 550);
    this.camera.updateProjectionMatrix();
  }
}
