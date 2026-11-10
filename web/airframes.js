/** Original representative meshes, not extracted simulator assets. +Z is forward. */
const BattlefrontAirframes = (() => {
  const jet = (p) => ({
    length:1, radius:.5, wing:4.4, root:1.35, back:-1.6, tip:-1.85, tipBack:-2.45,
    tail:1, tailSpread:1, engines:1, engineSpread:.63, tailplane:1.85,
    name:"Fighter", ...p
  });
  const profiles = {
    "F-16":jet({name:"F-16 Fighting Falcon",wing:4.45,root:1.7,chin:true}),
    "F-15":jet({name:"F-15 Eagle",wing:4.2,tail:2,engines:2,tip:-.55,tipBack:-1.8,shoulders:true,radius:.69}),
    "F/A-18":jet({name:"F/A-18 Hornet",wing:4.15,tail:2,engines:2,cant:.29,lex:true,tip:-1.1,tipBack:-2.45,light:true}),
    "F-14":jet({name:"F-14 Tomcat",wing:4.85,tail:2,engines:2,engineSpread:.95,radius:.61,tip:-2.1,tipBack:-3.08,tandem:true}),
    "A-10":jet({name:"A-10 Thunderbolt II",wing:5.45,tail:2,engines:2,highPod:true,tip:.08,tipBack:-.93,root:.73,back:-1.1,radius:.58}),
    "A-4":jet({name:"A-4 Skyhawk",wing:3.35,root:1.05,back:-2.45,tip:-1.82,tipBack:-2.5,radius:.61}),
    "F-5":jet({name:"F-5 Tiger II",wing:3.2,engines:2,tailplane:1.34,engineSpread:.38,radius:.36,light:true,tip:-1.7,tipBack:-2.35}),
    "F-117":jet({name:"F-117 Nighthawk",wing:4.8,root:3.28,back:-3.12,tip:-2.42,tipBack:-3.17,
      tail:2,cant:.55,facet:true,radius:.95,tailplane:0,engines:0}),
    "F-22":jet({name:"F-22 Raptor",wing:4.55,tail:2,engines:2,tip:-.9,tipBack:-2.12,cant:.5,radius:.73,flat:true,shoulders:true}),
    "F-23":jet({name:"YF-23 Black Widow II",wing:4.52,root:2.0,back:-2.8,tip:-.58,tipBack:-1.25,
      tail:2,cant:.88,radius:.76,flat:true,tailplane:0,engines:2,stealthPod:true}),
    "JF-17":jet({name:"JF-17 Thunder",wing:3.85,root:1.6,back:-1.5,tip:-1.15,tipBack:-2.1,lex:true,light:true}),
    "J-20":jet({name:"J-20 Mighty Dragon",wing:3.95,length:1.13,root:1.1,back:-2.7,tip:-1.46,tipBack:-2.5,
      tail:2,cant:.53,canard:true,engines:2,tailplane:0,radius:.7,flat:true}),
    "Su-25":jet({name:"Su-25 Frogfoot",wing:4.88,root:.86,back:-1.55,tip:-.58,tipBack:-1.26,
      engines:2,engineSpread:.77,radius:.68,attackPods:true}),
    "Su-27":jet({name:"Su-27 Flanker",wing:4.33,root:1.7,tail:2,engines:2,tip:-1.38,tipBack:-2.2,
      radius:.6,lex:true,engineSpread:.84}),
    "Su-30":jet({name:"Su-30 Flanker",wing:4.52,tail:2,engines:2,tip:-1.4,tipBack:-2.26,
      canard:true,lex:true,tandem:true,engineSpread:.87,radius:.67}),
    "Su-33":jet({name:"Su-33 Sea Flanker",wing:4.95,tail:2,engines:2,tip:-1.34,tipBack:-2.27,
      canard:true,lex:true,engineSpread:.89,radius:.66,carrier:true}),
    "Su-34":jet({name:"Su-34 Fullback",wing:4.5,tail:2,engines:2,tip:-1.55,tipBack:-2.25,
      canard:true,flatNose:true,lex:true,engineSpread:.95,radius:.82}),
    "Su-35":jet({name:"Su-35 Flanker-E",wing:4.62,tail:2,engines:2,tip:-1.05,tipBack:-2.15,
      lex:true,engineSpread:.93,radius:.56,flat:true}),
    "Su-57":jet({name:"Su-57 Felon",wing:4.83,root:1.98,back:-1.8,tail:2,engines:2,
      tip:-.78,tipBack:-2.1,cant:.8,engineSpread:.96,radius:.78,flat:true}),
    "MiG-29":jet({name:"MiG-29 Fulcrum",wing:4.08,tail:2,engines:2,tip:-1.25,tipBack:-2.2,
      lex:true,engineSpread:.69,radius:.55,light:true}),
    "MiG-31":jet({name:"MiG-31 Foxhound",wing:3.78,length:1.14,tail:2,engines:2,tip:-.49,tipBack:-1.78,
      shoulders:true,tandem:true,engineSpread:.61,radius:.77}),
    "C-130":jet({name:"C-130 Hercules",wing:6.1,radius:1.04,tailplane:2.35,prop:true,highWing:true,transport:true,engines:0}),
    "E-3":jet({name:"E-3 Sentry",wing:5.68,radius:.73,tailplane:1.95,radar:true,transport:true,pods:4,engines:0}),
    "A-50":jet({name:"A-50 Mainstay",wing:5.35,radius:.88,tailplane:2.05,radar:true,transport:true,pods:4,highWing:true,tee:true,engines:0}),
    "UH-60":{name:"UH-60 Black Hawk",rotor:true,width:1,stub:.8},
    "Mi-24":{name:"Mi-24 Hind",rotor:true,width:.83,tandem:true,stub:2.2},
    "Mi-8":{name:"Mi-8 Hip",rotor:true,width:1.05,stub:.5,transport:true},
    "AH-64":{name:"AH-64 Apache",rotor:true,width:.7,tandem:true,stub:1.75},
    "AV-8":jet({name:"AV-8B Harrier",wing:3.42,radius:.72,tip:-.56,tipBack:-1.88,shoulders:true}),
  };
  const names = Object.keys(profiles).sort((a,b)=>b.length-a.length);
  function keyFor(type) {
    const normalize=(s)=>String(s).toLowerCase().replace(/[ _/\-]/g,"");
    const t=normalize(type);
    if (/hercules/.test(t)) return "C-130";
    return names.find(k => t.startsWith(normalize(k))) || null;
  }

  const materialCache = new Map();
  function mats(side, stealth) {
    const key=side+":"+stealth;
    if (materialCache.has(key)) return materialCache.get(key);
    const team=side===2?0x53aaff:side===1?0xff7c67:0x9f95aa;
    const base=stealth?(side===2?0x637a8c:0x846765):side===2?0x759cb6:0xae8c7e;
    const m=(color,extra={})=>new THREE.MeshStandardMaterial({color:new THREE.Color(color).convertSRGBToLinear(),roughness:.63,metalness:.08,...extra});
    const result={
      skin:m(base), panel:m(stealth?0x48535d:0x687883), trim:m(team,{emissive:team,emissiveIntensity:.12}),
      glass:m(0x214857,{roughness:.24,metalness:.38}), dark:m(0x252d30), metal:m(0x849597,{roughness:.4}),
      pale:m(0xebefe2), heat:m(0xff9950,{emissive:0xff6f26,emissiveIntensity:1.1})
    };
    materialCache.set(key,result);
    return result;
  }

  function builder(materials) {
    const buckets=new Map();
    function add(g, material, x=0,y=0,z=0,sx=1,sy=1,sz=1,rx=0,ry=0,rz=0) {
      const o=g.index?g.toNonIndexed():g;
      o.scale(sx,sy,sz);o.rotateX(rx);o.rotateY(ry);o.rotateZ(rz);o.translate(x,y,z);
      if (!o.getAttribute("normal")) o.computeVertexNormals();
      const p=o.attributes.position.array, n=o.attributes.normal.array;
      if (!buckets.has(material)) buckets.set(material,[[],[]]);
      const b=buckets.get(material);
      for(let j=0;j<p.length;j++) {b[0].push(p[j]);b[1].push(n[j]);}
      if(o!==g)o.dispose();
      g.dispose();
    }
    function tube(stations, material, sides=18, x=0,y=0) {
      const pos=[], indices=[];
      for(const [z,rx,ry,dy=0] of stations) {
        for(let j=0;j<sides;j++) {
          const a=Math.PI*2*j/sides;
          pos.push(x+Math.cos(a)*rx,y+dy+Math.sin(a)*ry,z);
        }
      }
      for(let i=0;i<stations.length-1;i++) for(let j=0;j<sides;j++){
        const a=i*sides+j,b=i*sides+(j+1)%sides;
        indices.push(a,b,b+sides,a,b+sides,a+sides);
      }
      const g=new THREE.BufferGeometry();g.setAttribute("position",new THREE.Float32BufferAttribute(pos,3));g.setIndex(indices);
      g.computeVertexNormals();add(g,material);
    }
    const ell=(mat,x,y,z,a,b,c)=>add(new THREE.SphereGeometry(1,18,10),mat,x,y,z,a,b,c);
    const box=(mat,x,y,z,a,b,c,rz=0)=>add(new THREE.BoxGeometry(a,b,c),mat,x,y,z,1,1,1,0,0,rz);
    function slab(pts,thickness,material) {
      const vertices=[],tri=[];
      const a=new THREE.Vector3(...pts[0]), b=new THREE.Vector3(...pts[1]).sub(a), c=new THREE.Vector3(...pts[2]).sub(a);
      const d=b.cross(c).normalize().multiplyScalar(thickness/2);
      for(const sign of [-1,1]) for(const [x,y,z] of pts) vertices.push(x+d.x*sign,y+d.y*sign,z+d.z*sign);
      for(let k=1;k<pts.length-1;k++) {
        tri.push(0,k+1,k,pts.length,pts.length+k,pts.length+k+1);
      }
      for(let k=0;k<pts.length;k++) {
        const j=(k+1)%pts.length,n=pts.length;
        tri.push(k,j,j+n,k,j+n,k+n);
      }
      const g=new THREE.BufferGeometry();g.setAttribute("position",new THREE.Float32BufferAttribute(vertices,3));g.setIndex(tri);
      add(g,material);
    }
    function finish() {
      const root=new THREE.Group();
      for(const [mat, [p,n]] of buckets) {
        const g=new THREE.BufferGeometry();
        g.setAttribute("position",new THREE.Float32BufferAttribute(p,3));
        g.setAttribute("normal",new THREE.Float32BufferAttribute(n,3));
        root.add(new THREE.Mesh(g, materials[mat]));
      }
      root.rotation.order="YXZ";
      return root;
    }
    return {add,tube,ell,box,slab,finish};
  }

  function aircraft(type, side, category) {
    const key=keyFor(type);
    const p=profiles[key] || (category==="helicopter"?profiles["UH-60"]:jet({}));
    const a=builder(mats(side,p.facet||p.flat));
    const {tube,ell,box,slab,add}=a;
    const rw=p.radius||.7;
    if(p.rotor) {
      const w=p.width;
      tube([[-2.7,.18,.19],[-1.8,.52,.55],[.15,w,.65],[1.65,w*.85,.58],[2.55,w*.63,.51],[3.2,.34,.30],[3.45,.03,.02]],"skin");
      ell("glass",0,.4,2.43,w*.75,.39,p.tandem?1.03:.72);
      tube([[-5.75,.11,.1],[-4.8,.19,.2],[-2.26,.38,.32]],"panel",14,0,.28);
      box("dark",0,.98,.22,.14,.6,.14);
      for(let i=0;i<4;i++) {
        const angle=i*Math.PI/2+.2;
        add(new THREE.BoxGeometry(.18,.035,4.3),"dark",Math.sin(angle)*2.3,1.26,Math.cos(angle)*2.3,1,1,1,0,angle);
      }
      box("trim",0,.72,-5.6,.16,.85,.63);
      box("metal",.2,.84,-5.72,.045,1.46,.10);
      box("metal",.2,.84,-5.72,.045,.10,1.46);
      for(const s of [-1,1]) {
        if(p.stub>.9) slab([[s*.36,.02,1],[s*p.stub,-.16,.35],[s*p.stub,-.16,-.22],[s*.42,.02,-.65]],.13,"trim");
        ell("dark",s*.69,-.58,-.67,.13,.20,.2);
        box("panel",s*.81,.07,.54,.03,.37,.77);
      }
    } else {
      const stretch=p.length||1, z=v=>v*stretch;
      const deck=p.highWing?.38:-.05;
      if(p.facet){
        tube([[z(-3.65),.88,.25],[z(-2),1.12,.32],[z(.4),1,.50],[z(2.55),.55,.40],[z(4.85),.006,.007]],"skin",4);
        tube([[z(.72),.54,.13,.45],[z(1.5),.49,.27,.48],[z(2.65),.13,.10,.35]],"glass",4);
      } else {
        const stations=p.transport ? [[-4.9,.03,.04,.38],[-3.8,rw*.47,rw*.47,.22],[-2.55,rw,rw*.87],[-1,rw,rw],[3.2,rw,rw],[4.02,rw*.88,rw*.8],[4.8,rw*.61,rw*.66],[5.32,.06,.11,-.1]]
          : [[-4.62,rw*.32,rw*.39],[-3.95,rw*.8,rw*.72],[-2.66,rw,rw*.88],[-.59,rw*1.1,rw*.79],[1.12,rw*.93,rw*.82],[2.24,p.flatNose?rw*1.03:rw*.77,rw*.71],[3.27,p.flatNose?rw*.82:rw*.51,rw*.52],[4.27,rw*.30,rw*.31],[5.12,.013,.018]];
        tube(stations.map(([zz,x,y,d])=>[z(zz),x,y,d]),"skin",18);
        const cabin=p.transport?4.25:p.tandem?1.91:2.33;
        ell("glass",0,p.transport?rw*.48:rw*.64,z(cabin),p.flatNose?.77:p.transport?rw*.65:.35,p.transport?.24:.32,p.tandem?1.46:p.transport?.64:.91);
        if (!p.transport) tube([[z(3.52),rw*.46,rw*.47],[z(4.31),rw*.29,rw*.30],[z(5.13),.013,.017]],"panel");
      }
      for(const s of [-1,1]){
        const wx=p.wing, tip=p.transport?-.52:p.tip, tipBack=p.transport?-1.38:p.tipBack;
        slab([[s*.25,deck,z(p.root)],[s*wx,deck+.035,z(tip)],[s*wx,deck+.035,z(tipBack)],[s*.30,deck,z(p.back)]],p.flat||p.facet?.12:.13,"skin");
        slab([[s*(wx-.35),deck+.045,z(tip-.015)],[s*(wx+.015),deck+.045,z(tip)],[s*(wx+.015),deck+.045,z(tipBack)],[s*(wx-.35),deck+.045,z(tipBack+.08)]],.063,"trim");
        slab([[s*.63,deck+.075,z(p.back+.16)],[s*(wx-.50),deck+.075,z(tipBack+.09)],[s*(wx-.50),deck+.075,z(tipBack+.27)],[s*.69,deck+.075,z(p.back+.43)]],.016,"panel");
        ell(s===1?"trim":"pale",s*wx,deck+.03,z(tipBack+.14),.085,.071,.085);
        if(p.lex) slab([[s*.26,.06,z(2.75)],[s*1.56,.02,z(.69)],[s*1.8,0,z(-.14)],[s*.35,.06,z(-.45)]],.085,"panel");
        if(p.canard) slab([[s*.41,.14,z(2.52)],[s*1.62,.18,z(1.7)],[s*1.56,.18,z(1.17)],[s*.41,.14,z(1.47)]],.09,"skin");
        if(p.tailplane) {
          const h=p.tee?1.62:p.highPod?.58:.12;
          slab([[s*.26,h,z(-2.92)],[s*p.tailplane,h,z(-3.87)],[s*p.tailplane,h,z(-4.43)],[s*.26,h,z(-4.54)]],.115,"panel");
        }
        if (p.tail===2) {
          const sx=s*(p.engineSpread||.7)*1.27, cant=p.cant||.12;
          slab([[sx,.1,z(-2.58)],[sx+s*cant,1.62,z(-3.66)],[sx+s*cant,1.50,z(-4.29)],[sx,.1,z(-4.57)]],.1,"skin");
          slab([[sx+s*cant*.89,1.44,z(-3.61)],[sx+s*cant,1.65,z(-3.67)],[sx+s*cant,1.54,z(-4.3)],[sx+s*cant*.85,1.32,z(-4.29)]],.08,"trim");
        }
        if(p.pods||p.prop){
          for(const i of [1,2]){
            const xx=s*(1.34+i*1.46), yy=p.prop?.19:-.40, zz=z(.24-.31*i);
            ell("panel",xx,yy,zz,p.prop?.31:.42,p.prop?.31:.42,1.04);
            ell("metal",xx,yy,zz+.72,p.prop?.24:.37,p.prop?.24:.37,.36);
            if(p.prop){box("dark",xx,yy,zz+.98,.10,1.63,.06);box("dark",xx,yy,zz+.99,1.63,.10,.05);}
            else ell("dark",xx,yy,zz+.98,.27,.27,.09);
          }
        }
        if(p.shoulders) {
          box("panel",s*.66,-.32,z(.9),.48,.34,2.71);
          box("dark",s*.66,-.32,z(2.28),.41,.24,.07);
        }
      }
      if(p.tail===1){
        slab([[0,.15,z(-1.96)],[0,1.90,z(-3.56)],[0,1.78,z(-4.25)],[0,.10,z(-4.64)]],.13,"skin");
        slab([[0,1.69,z(-3.35)],[0,1.91,z(-3.56)],[0,1.78,z(-4.25)],[0,1.56,z(-4.23)]],.14,"trim");
      }
      if(p.chin) {ell("panel",0,-.30,z(.28),.37,.28,1.17);ell("dark",0,-.35,z(1.28),.28,.16,.1);}
      const spread=p.highPod?1.07:p.engineSpread, ey=p.highPod?.39:-.12;
      for(const x of p.engines===2?[-spread,spread]:p.engines===1?[0]:[]) {
        const r=p.highPod?.48:.35, z0=p.highPod?-3.19:-4.29;
        if(p.engines===2) ell(p.stealthPod?"skin":"panel",x,ey,z(z0+1),r*1.2,r*1.09,p.highPod?1.45:2.35);
        ell("metal",x,ey,z(z0),r,r,.31);
        ell("dark",x,ey,z(z0-.23),r*.76,r*.76,.083);
      }
      if(p.radar){
        for(const s of [-1,1]) box("panel",s*.37,1.2,-.8,.14,1.27,.30);
        ell("pale",0,1.88,-.99,1.65,.19,1.65);
        ell("dark",0,1.93,-.99,1.69,.09,1.68);
        ell("pale",0,2.00,-.83,1.23,.071,1.28);
      }
      if(p.carrier) box("dark",0,-.49,-4.03,.075,.075,1.03);
    }
    const mesh=a.finish();
    mesh.userData={profile:key,displayName:p.name,representative:!!key};
    return mesh;
  }

  function missile(type, side) {
    const a=builder(mats(side,false));
    const r=/[RP][-_ ]?27/i.test(type)?.22:.17, large=r>.2;
    a.tube([[-1.6,r,r],[-.66,r,r],[1.05,r,r],[1.47,r*.65,r*.65],[1.89,.009,.009]],"pale",20);
    a.tube([[-1.61,r*1.02,r*1.02],[-1.32,r*1.02,r*1.02]],"metal",20);
    a.tube([[.50,r*1.02,r*1.02],[.64,r*1.02,r*1.02]],"trim",20);
    for(let i=0;i<4;i++){
      const angle=Math.PI/4+i*Math.PI/2;
      const shape=new THREE.Shape();shape.moveTo(.06,.86);shape.lineTo(large?.61:.36,-.2);
      shape.lineTo(large?.47:.31,-.48);shape.lineTo(.06,-.69);shape.closePath();
      const g=new THREE.ExtrudeGeometry(shape,{depth:.038,bevelEnabled:false});
      g.rotateX(Math.PI/2);g.rotateZ(angle);g.translate(0,0,.25);
      a.add(g,"panel");
      const fin=new THREE.Shape();fin.moveTo(.05,.08);fin.lineTo(.39,-.27);fin.lineTo(.38,-.48);fin.lineTo(.06,-.51);fin.closePath();
      const f=new THREE.ExtrudeGeometry(fin,{depth:.035,bevelEnabled:false});
      f.rotateX(Math.PI/2);f.rotateZ(angle);f.translate(0,0,-.91);a.add(f,"metal");
    }
    a.ell("heat",0,0,-1.68,r*.7,r*.7,.10);
    return a.finish();
  }
  return {profiles,keyFor,aircraft,missile};
})();
if (typeof module !== "undefined") module.exports=BattlefrontAirframes;
