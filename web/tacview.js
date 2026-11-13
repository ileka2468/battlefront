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


  onResize() {
    if (!this.renderer || !this.camera || !this.container) return;
    this.camera.aspect = (this.container.clientWidth || 900) / (this.container.clientHeight || 550);
    this.camera.updateProjectionMatrix();
  }
}
