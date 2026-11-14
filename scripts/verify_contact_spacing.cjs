const assert = require('node:assert/strict');
const Viewer = require('../web/tacview.js');

class Pos {
  constructor(x=0,y=0,z=0) { Object.assign(this,{x,y,z}); }
  set(x,y,z) { Object.assign(this,{x,y,z}); return this; }
  copy(p) { return this.set(p.x,p.y,p.z); }
}

const origin = new Pos(25,14,-38), assigned=[];
for (let i=0;i<60;i++) {
  const r=.53+(i%8)*.62;
  const p=Viewer.placeGlyph(origin,assigned,new Pos(),Math.max(1.2,r*2.35),r);
  p.glyphRadius=r;
  for(const prev of assigned) assert(Math.hypot(p.x-prev.x,p.z-prev.z)+1e-6>=Math.max(1.2,(r+prev.glyphRadius)*1.13));
  assigned.push(p);
}
assert.deepEqual(origin,new Pos(25,14,-38));
console.log('CONTACT SPACING: 60 coincident mixed-size glyphs placed without overlap; coordinates untouched');
