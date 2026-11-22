/** Deterministic comparison of arrival retargeting and sim-time buffering at 60 draw steps/s. */
const assert=require('node:assert/strict');
const path=require('node:path');
const fs=require('node:fs');

const filename=process.argv[2] || '../web/tacview.js';
const resolved=filename.startsWith('..') ? path.resolve(__dirname,filename) : path.resolve(filename);
const Renderer=require(resolved);
const period=.257;
const baseline=typeof Renderer.LiveSnapshotClock !== 'function';
const jitter=[.035,.24,.09,.19,.07,.32,.12,.27,.055,.085,.18,.105,.31,.045,.13,.205];
const timeline=Array.from({length:92},(_,i)=>({sim:i*period,i,arrive:i*period+jitter[i%jitter.length]}))
  .filter(({i})=>!([40,41,57,58,59].includes(i)))
  .sort((a,b)=>a.arrive-b.arrive);
const track={}, vector={x:0,y:0,z:0,set(x,y,z){this.x=x;this.y=y;this.z=z;}};
let heldSamples=0, widestLead=0, previous=0, good=0, worst=0;
let age=0, peakLag=0, lastI=-1, observer=0;
const clock=baseline ? null : new Renderer.LiveSnapshotClock();
const old={start:0,end:0,interval:.6,receipt:0};
function oldAt(now) { const t=Math.max(0,Math.min(1,(now-old.receipt)/old.interval)); return old.start+(old.end-old.start)*t; }

for(let draw=0; draw<1320; draw++) {
  const now=draw/60;
  while(observer<timeline.length && timeline[observer].arrive<=now) {
    const n=timeline[observer++];
    if(n.i<=lastI) continue; // the server always returns the newest monotonic frame
    if(baseline) {
      old.start=oldAt(n.arrive); old.end=n.sim;
      old.interval=Math.max(.12,Math.min(.8,n.arrive-(old.receipt||n.arrive-.25))); old.receipt=n.arrive;
    } else {
      const roundTrip=.076;
      const sampleAge=Math.max(0,n.arrive-n.sim-roundTrip/2);
      clock.observe(n.sim,10000+n.sim,n.i,n.arrive,sampleAge,roundTrip);
      Renderer.addLivePose(track,n.sim,n.sim,3,n.sim*.12,350,0,0);
    }
    lastI=n.i;
  }
  const value=baseline ? oldAt(now) : (Renderer.sampleLivePose(track,clock.advance(now),vector) ? vector.x : 0);
  if(draw>120) { // allow both implementations the same buffer warm-up
    const speed=(value-previous)*60;
    if (speed<.03) heldSamples++;
    if(speed>=.75 && speed<=1.25) good++;
    worst=Math.max(worst,speed);
    widestLead=Math.max(widestLead,value-lastI*period);
    peakLag=Math.max(peakLag,lastI*period-value);
  }
  previous=value;
}

const outcome=`60Hz fixed scene: ${heldSamples} stalled positions; ${good} near-steady steps; peak speed ${worst.toFixed(2)}x`;
if(baseline) {
  assert(fs.readFileSync(resolved,'utf8').includes('now - (this.lastSnapshotAt || now - .25)'));
  assert(heldSamples>100);
  console.log('BASELINE:',outcome);
  process.exitCode=1;
} else {
  assert(heldSamples<60);
  assert(good>1000);
  assert(widestLead<=.28001);
  assert(peakLag<1.15);
  const last=clock.advance(22.02);
  clock.held=true;
  assert.equal(clock.advance(24),last,'server status delayed must freeze visual motion');
  clock.reset(); assert.equal(clock.advance(24),null);
  const angular={};
  Renderer.addLivePose(angular,1,0,0,0,350,0,0);
  Renderer.addLivePose(angular,1.25,1,0,0,10,0,0);
  assert(Renderer.sampleLivePose(angular,1.125,vector)); assert.equal(angular.currentHeading,360);
  Renderer.sampleLivePose(angular,1.4,vector,false); assert.equal(vector.x,1,'parked track never projects');
  Renderer.sampleLivePose(angular,2,vector); assert(vector.x<=2.120001,'bounded source-time coast');
  Renderer.addLivePose(angular,.1,-5,0,0,40,0,0,true);
  assert.equal(angular.livePoses.length,1,'restarts/replay seeks must discard stale motion');
  console.log('BUFFERED:',outcome+`; max visual lead ${widestLead.toFixed(3)}s of fixed unit motion`);
  console.log('CONTROL: delayed freezes; angular wrap interpolates; grounded and restarted tracks never drift');
}
