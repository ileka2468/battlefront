/** Mapzen elevation and baked hillshade in the sampled DCS Caucasus projection. */
class CaucasusTerrain {
  constructor(scene) {
    this.width = 780;
    this.height = 520;
    const geom = new THREE.PlaneGeometry(this.width, this.height, 390, 260);
    geom.rotateX(-Math.PI / 2);
    const pos = geom.attributes.position;
    const rgb = new Float32Array(pos.count * 3);
    const sand = new THREE.Color(0x667567);
    const lowland = new THREE.Color(0x394c40);
    const forest = new THREE.Color(0x283e36);
    const rock = new THREE.Color(0x59636a);
    const snow = new THREE.Color(0xc3cbd0);
    const seaFloor = new THREE.Color(0x0b1d27);
    const c = new THREE.Color();
    for (let i = 0; i < pos.count; i++) {
      const x = pos.getX(i), z = pos.getZ(i);
      const y = this.elevation(x, z);
      const s = this.inlandDistance(x, z);
      const detail = this.noise(x, z);
      pos.setY(i, y);
      if (s < 0) c.copy(seaFloor);
      else {
        c.copy(lowland).lerp(forest, this.smooth(-0.5, 0.65, detail));
        c.lerp(sand, (1 - this.smooth(0, 11, s)) * 0.7);
        c.lerp(rock, this.smooth(3, 10, y + detail));
        c.lerp(snow, this.smooth(9.5, 15, y + 0.7 * detail));
        c.multiplyScalar(0.93 + detail * 0.09);
      }
      c.toArray(rgb, i * 3);
    }
    geom.setAttribute("color", new THREE.BufferAttribute(rgb, 3));
    geom.computeVertexNormals();
    this.mesh = new THREE.Mesh(geom, new THREE.MeshStandardMaterial({
      vertexColors: true, roughness: 1, metalness: 0
    }));
    scene.add(this.mesh);

    // Opaque matte water with very low-contrast, continuous world-space ripples.
    // No direct-light specular term, transparency, grid texture or tiled normals.
    const waterGeom = new THREE.PlaneGeometry(this.width, this.height);
    waterGeom.rotateX(-Math.PI / 2);
    this.water = new THREE.Mesh(waterGeom, new THREE.ShaderMaterial({
      uniforms: {
        uTime: { value: 0 }, uDeep: { value: new THREE.Color(0x244955).convertSRGBToLinear() },
        uSoft: { value: new THREE.Color(0x436774).convertSRGBToLinear() }, uHaze: { value: scene.background }
      },
      vertexShader: [
        "varying vec3 vWorld; varying float vDepth;",
        "void main() {",
        " vWorld = (modelMatrix * vec4(position, 1.)).xyz;",
        " vec4 mv = modelViewMatrix * vec4(position, 1.);",
        " vDepth = -mv.z; gl_Position = projectionMatrix * mv;",
        "}"
      ].join("\n"),
      fragmentShader: [
        "uniform float uTime; uniform vec3 uDeep, uSoft, uHaze;",
        "varying vec3 vWorld; varying float vDepth;",
        "void main() {",
        " vec2 p = vWorld.xz;",
        " float broad = sin(dot(p, vec2(.021, .017))) * .5 + .5;",
        " float a = dot(p, vec2(.23, .59)) + sin(p.x * .061 + p.y * .07) * 1.6 + uTime * .55;",
        " float b = dot(p, vec2(-.49, .26)) + sin(p.y * .08) - uTime * .4;",
        " float fade = 1. - smoothstep(.28, 2.8, max(fwidth(a), fwidth(b)));",
        " float ripples = (sin(a) + .7 * sin(b)) * .075 * fade;",
        " vec3 col = mix(uDeep, uSoft, clamp(.26 + .35 * broad + ripples, 0., 1.));",
        " col = mix(uHaze, col, exp(-pow(max(0.,vDepth) * .0011, 2.)));",
        " gl_FragColor = vec4(col, 1.);",
        " #include <tonemapping_fragment>",
        " #include <encodings_fragment>",
        "}"
      ].join("\n"),
      extensions: { derivatives: true }
    }));
    scene.add(this.water);
    this.source = "illustrated fallback";
    this.ready = this.loadElevation(scene).catch((err) => {
      console.warn("Caucasus relief fallback:", err.message);
      return false;
    });
  }

  async loadElevation(scene) {
    const response = await fetch("/terrain/caucasus-height.png");
    if (!response.ok) throw new Error("elevation asset unavailable");
    const image = await createImageBitmap(await response.blob(), {colorSpaceConversion:"none"});
    const {width,height} = image;
    const canvas = document.createElement("canvas");
    canvas.width=width; canvas.height=height;
    const ctx=canvas.getContext("2d",{willReadFrequently:true});
    ctx.drawImage(image,0,0);
    image.close();
    const bytes=ctx.getImageData(0,0,width,height).data;
    const scale=.0025;
    const elevations=new Float32Array(width*height);
    for(let i=0;i<elevations.length;i++) elevations[i]=(bytes[i*4]*256+bytes[i*4+1]-32)*scale;
    const texture = await new Promise((resolve,reject)=>new THREE.TextureLoader()
      .load("/terrain/caucasus-relief.jpg",resolve,undefined,reject));
    texture.encoding = THREE.sRGBEncoding;
    texture.anisotropy = 8;
    this.dem = {width,height,elevations};
    const geom=new THREE.PlaneGeometry(this.width,this.height,600,400);
    geom.rotateX(-Math.PI/2);
    const pos=geom.getAttribute("position");
    for(let i=0;i<pos.count;i++) pos.setY(i,this.elevation(pos.getX(i),pos.getZ(i)));
    const mat=new THREE.MeshBasicMaterial({map:texture});
    scene.remove(this.mesh);
    this.mesh.geometry.dispose();
    this.mesh.material.dispose();
    this.mesh=new THREE.Mesh(geom,mat);
    scene.add(this.mesh);
    this.source="Mapzen DEM";
    return true;
  }

  sampleDEM(x,z) {
    const {width,height,elevations}=this.dem;
    const u=(x/this.width+.5)*(width-1), v=(z/this.height+.5)*(height-1);
    if (u<0||v<0||u>width-1||v>height-1) return -.055;
    const c=Math.min(width-2,Math.floor(u)), r=Math.min(height-2,Math.floor(v));
    const f=u-c,g=v-r,k=r*width+c;
    return (elevations[k]*(1-f)+elevations[k+1]*f)*(1-g)
      +(elevations[k+width]*(1-f)+elevations[k+width+1]*f)*g;
  }

  smooth(a, b, v) {
    const t = Math.max(0, Math.min(1, (v - a) / (b - a)));
    return t*t*(3-2*t);
  }

  noise(x, z) {
    return .54 * Math.sin(.09*x + .037*z) * Math.cos(.077*z)
      + .29 * Math.cos(.146*x - .161*z)
      + .12 * Math.sin(.31*x + .103*z) * Math.cos(.22*z)
      + .05 * Math.cos(.51*x + .4*z);
  }

  inlandDistance(x, z) {
    // Coast control points in the same theater projection as sector markers.
    const coast = [[-260,-373],[-184,-346],[-160,-330],[-125,-215],[-65,-158],
      [-15,-104],[35,-22],[65,48],[110,81],[154,75],[219,88],[260,100]];
    let j = 0;
    while (j < coast.length - 2 && z > coast[j+1][0]) j++;
    const [z0,x0] = coast[j], [z1,x1] = coast[j+1];
    const prev = coast[Math.max(0,j-1)], next = coast[Math.min(coast.length-1,j+2)];
    const t = Math.max(0, Math.min(1, (z-z0)/(z1-z0)));
    const m0 = (x1-prev[1])/(z1-prev[0]) * (z1-z0);
    const m1 = (next[1]-x0)/(next[0]-z0) * (z1-z0);
    const main = (2*t*t*t-3*t*t+1)*x0+(t*t*t-2*t*t+t)*m0
      +(-2*t*t*t+3*t*t)*x1+(t*t*t-t*t)*m1;
    return x - main - 1.9*Math.sin(z*.19) - 1.1*Math.sin(z*.43);
  }

  elevation(x, z) {
    if(this.dem) return this.sampleDEM(x,z);
    const s = this.inlandDistance(x,z);
    if (s < 0) return Math.max(-1.15, s * .23);
    const n = this.noise(x,z);
    const spine = z - (x * .43 - 54 + 11*Math.sin(x*.022));
    const ridge = Math.exp(-Math.pow(spine / (35 + 9*Math.sin(x*.015)), 2));
    const spurs = Math.exp(-Math.pow((spine-27) / 72, 2));
    const peaks = 5.8*Math.exp(-(((x-107)/13)**2+((z+10)/10)**2))
      + 5.0*Math.exp(-(((x-246)/14)**2+((z-47)/12)**2));
    return this.smooth(0, 19, s) * (0.43 + .33*n + ridge*(6.8 + 3.1*n)
      + spurs*(2.7 + 2.4*n) + peaks);
  }

  ground(x,z) { return Math.max(0, this.elevation(x,z)); }
  update(t) { this.water.material.uniforms.uTime.value = t; }
}
