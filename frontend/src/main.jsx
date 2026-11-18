import React, {memo, useEffect, useState} from 'react';
import {createRoot} from 'react-dom/client';

const params = new URLSearchParams(location.search);
const replay = params.get('replay') === '1';
const localHost = ['localhost','127.0.0.1','[::1]'].includes(location.hostname);
const tabGroups = [
  ['Campaign', [['tacview','Airspace','◎'],['operations','Flight operations','≡']]],
  ['Logistics', [['armory','Personal armory','▣'],['requisition','Munitions depot','◇'],['techTree','Airframe research','⊞'],['marketplace','Player exchange','⇄']]],
  ['Records', [['leaderboard','Pilot standings','▤']]],
];
const idFor = value => String(value ?? '').trim().toLowerCase().replace(/[^a-z0-9_]/g,'_');
const money = x => x == null ? '—' : `$${Number(x).toLocaleString('en-US',{maximumFractionDigits:2})}M`;
const sideName = side => +side === 2 ? 'BLUFOR' : 'REDFOR';
const noPilot = {callsign:'Guest',side:2,points:0,inventory:{}};
const feedEvents = new EventTarget();
window.setBattlefrontCampaignSnapshot = snapshot => feedEvents.dispatchEvent(new CustomEvent('campaign',{detail:snapshot}));

async function request(path, data, csrf) {
  const options = data === undefined ? {cache:'no-store'} : {
    method:'POST',headers:{'Content-Type':'application/json',...(csrf?{'X-BF-CSRF':csrf}:{})},body:JSON.stringify(data),
  };
  options.credentials = 'same-origin';
  const res = await fetch(path, options);
  const json = await res.json().catch(()=>null);
  if (!res.ok || !json || json.success === false) throw Object.assign(Error(json?.error || `Request failed (${res.status})`),{status:res.status});
  return json;
}

function Btn({children, kind='outline', className='', type='button', ...props}) {
  return <button type={type} className={`bf-btn bf-${kind} ${className}`} {...props}>{children}</button>;
}
function Side({side}) { return <span className={+side===2?'badge-blue':'badge-red'}>{sideName(side)}</span>; }
function Heading({title,note,children}) {
  return <header className="mb-5 flex flex-wrap items-end justify-between gap-3"><div><p className="eyebrow">Battlefront / workspace</p><h1 className="page-title">{title}</h1><p className="mt-1 max-w-3xl text-sm text-muted">{note}</p></div>{children}</header>;
}
function Card({children,className=''}) { return <div className={`bf-card ${className}`}>{children}</div>; }
function Empty({children}) { return <div className="border border-dashed border-line p-6 text-center text-sm text-muted">{children}</div>; }
function Filter({values,selected,onSelect}) {return <div className="flex flex-wrap gap-1" aria-label="Filter by coalition">{values.map(([key,name])=><Btn key={key} aria-pressed={selected===key} kind={selected===key?'primary':'outline'} onClick={()=>onSelect(key)}>{name}</Btn>)}</div>;}

function Sidebar({section,setSection,counts,connection}) {
  return <aside className="rail"><div className="flex items-center gap-3 px-2 pb-4"><svg className="h-8 w-8 shrink-0 text-signal" viewBox="0 0 48 48" aria-hidden="true"><path d="M24 3 45 15v18L24 45 3 33V15Z M24 10v28 M10 24h28 M14 33 34 15" fill="none" stroke="currentColor" strokeWidth="1.7"/></svg><div><div className="font-bold tracking-[0.11em]">BATTLEFRONT</div><div className="font-mono text-[9px] tracking-[0.2em] text-rail-muted">CAMPAIGN CONTROL</div></div></div>
    <div className="hidden border-y border-white/15 px-2 py-4 lg:block"><p className="eyebrow text-rail-muted">THEATER / 01</p><p className="text-xl font-medium">Caucasus</p><p className="text-xs text-rail-muted">Dynamic multiplayer</p></div>
    <nav className="flex gap-1 overflow-x-auto lg:flex-col lg:overflow-visible" aria-label="Campaign sections">
      {tabGroups.map(([label,tabs])=><React.Fragment key={label}><p className="hidden px-2 pt-5 pb-1 font-mono text-[9px] tracking-[.18em] text-rail-muted uppercase lg:block">{label}</p>{tabs.map(([key,name,icon])=><button type="button" key={key} data-tab={key} aria-current={section===key?'page':undefined} className="nav-tab" onClick={()=>setSection(key)}><span aria-hidden="true" className="text-lg leading-none">{icon}</span><span>{name}</span>{counts[key]!=null&&<span className="ml-auto pl-2 font-mono text-[10px] text-rail-muted">{counts[key]}</span>}</button>)}</React.Fragment>)}
    </nav><div className="mt-auto hidden border-t border-white/15 px-2 pt-3 text-xs text-rail-muted lg:block"><span className={`mr-2 inline-block size-2 ${connection==='Connected'?'bg-emerald-300':'bg-amber-300'}`}/><span id="connectionStatus">{connection}</span><p className="mt-2 text-[10px]">DCS link · read only</p></div>
  </aside>;
}

function TreasurySide({side, coalition, change}) {
  const purchase = coalition?.last_blueprint_purchase;
  const buyer = purchase?.source === 'director' ? 'AI Director' : purchase?.source === 'f10' ? 'F10' : null;
  const prefix = side===2?'blue':'red';
  return <div>
    <div className="flex flex-wrap items-center gap-x-2 text-sm"><Side side={side}/><strong className="tabular-nums" id={`${prefix}TreasuryVal`}>{money(coalition?.treasury)}</strong>{coalition?.hourly_income!=null&&<span className="text-xs text-emerald-800">{money(coalition.hourly_income)}/hr</span>}</div>
    {purchase&&<p className="mt-1 text-[11px]" id={`${prefix}LastBlueprint`}><strong>Last blueprint{buyer?` · ${buyer}`:''}: {purchase.key} · −{money(purchase.cost)}</strong><span className="block tabular-nums text-muted">{money(purchase.before)} → {money(purchase.after)}</span></p>}
    {change!=null&&<p className="mt-1 text-[11px] text-muted" id={`${prefix}TreasuryChange`}>Last observed net change: <strong className="tabular-nums">{change<0?'−':'+'}{money(Math.abs(change))}</strong></p>}
  </div>;
}

function Theater({observation}) {
  const {snapshot:feed,current:live,changes} = observation;
  const coalitions = feed?.coalitions || {};
  const blue = coalitions['2'], red = coalitions['1'];
  const total = feed?.total_objectives || 21;
  return <div className="border-b border-line bg-panel px-4 pt-3 pb-2 sm:px-7">
    <div className="grid gap-3 lg:grid-cols-2 lg:gap-6"><section aria-label="Sector control">
      <div className="mb-2 flex items-center justify-between gap-2"><span className="eyebrow">Sector control</span><span className={`eyebrow ${live?'text-emerald-700':''}`} id="campaignFeedStatus">{live?'LIVE DCS • READ ONLY':replay?'RECORDED AIRSPACE • NO TREASURY':feed?'DELAYED DCS • LAST KNOWN':'WAITING FOR DCS CAMPAIGN'}</span></div>
      <div className="flex items-center gap-3 font-mono text-[11px]"><span><Side side={2}/> <strong id="blueSectorCount">{blue?.controlled_sectors??'—'}</strong>/{total}</span><div className="flex h-2.5 min-w-6 flex-1 gap-px overflow-hidden bg-field"><span className="block bg-blue-600/65" style={{width:`${100*(blue?.controlled_sectors||0)/total}%`}}/><span className="block bg-red-600/60" style={{width:`${100*(red?.controlled_sectors||0)/total}%`}}/></div><span><strong id="redSectorCount">{red?.controlled_sectors??'—'}</strong>/{total} <Side side={1}/></span></div>
    </section><section className="border-t border-line pt-2 lg:border-t-0 lg:border-l lg:pt-0 lg:pl-6" aria-label="DCS coalition treasury"><div className="mb-2 flex justify-between"><span className="eyebrow">DCS coalition treasury</span>{feed&&<span className="eyebrow">Balance / income rate</span>}</div><div className="grid grid-cols-2 gap-2"><TreasurySide side={2} coalition={blue} change={changes['2']}/><TreasurySide side={1} coalition={red} change={changes['1']}/></div></section></div>
    <p id="campaignWorkspaceNote" className="mt-2 text-[10px] text-muted">{replay?'The recording contains flight tracks, not campaign balances.':'Blueprints are paid for in DCS by the AI Director or via F10. Trading uses separate Companion Merits.'}</p>
  </div>;
}

// React owns the panel layout. The imperative Three.js adapter alone owns the
// canvas, HUD children, and frequently refreshed track list/transport bindings.
const Airspace = memo(function Airspace({visible}) {
  const [offline, setOffline] = useState(false);
  useEffect(()=>{const id=requestAnimationFrame(()=>{try {if (!window.initTacview) throw Error('Viewer runtime unavailable'); window.initTacview('tacviewContainer');} catch (e) {console.warn(e);setOffline(true);}});return ()=>cancelAnimationFrame(id);},[]);
  useEffect(()=>{if (!visible) return; const id=requestAnimationFrame(()=>window.tacview?.onResize()); return ()=>cancelAnimationFrame(id);},[visible]);
  const modes=[['engagement','Engagement'],['theater','Theater'],['frontline','Frontline'],['blufor','Blue'],['redfor','Red'],['topdown','Plan view']];
  return <section id="tacviewTab" className={`tab-content ${visible?'active':''}`} hidden={!visible}>
    <div className="mb-4 flex items-end justify-between gap-4"><div><p className="eyebrow">Theater picture / Caucasus</p><h1 className="page-title">Airspace</h1><p className="mt-1 text-sm text-muted">Engagement starts close to nearby contacts. Click a bracket or diamond to follow it, or open Theater for the full map.</p></div><p className="eyebrow hidden text-right sm:block">View<br/><strong>3D / Tacview</strong></p></div>
    <div className="flex flex-wrap items-center justify-between gap-3 border border-ink bg-ink px-3 py-2 text-white sm:px-4"><div><strong className="text-sm">Airspace picture</strong><p className="tacview-meta mt-1 font-mono text-[11px]" id="tacviewDataSourceBadge" role="status">{offline?'3D viewer unavailable':'Waiting for telemetry'}</p></div><div className="flex flex-wrap gap-1" aria-label="Camera controls">
      <a className="cam-preset-btn" id="bf-campaign-mode" href={replay?'/':'/?replay=1'}>{replay?'Open live campaign':'20v20 replay'}</a>
      {modes.map(([value,name])=><button key={value} type="button" className={`cam-preset-btn ${value==='engagement'?'active':''}`} data-camera-preset={value} aria-pressed={value==='engagement'} onClick={()=>window.tacview?.setCameraPreset(value)}>{name}</button>)}
      <button className="cam-preset-btn" id="bf-view-fullscreen" type="button">Full screen</button></div></div>
    <div className="fleet-transport flex flex-wrap items-center gap-2 border-x border-line bg-[#e3e6d9] px-3 py-2 font-mono text-xs"><button className="bf-missile-jump" id="bf-missile-jump" type="button" disabled>No active missiles</button>
      <div id="bf-replay-controls" className="bf-replay-controls flex min-w-0 flex-1 items-center gap-2" hidden><button className="bf-btn bf-outline" id="bf-replay-restart" type="button">Restart</button><label className="hidden sm:inline" htmlFor="bf-replay-seek">REPLAY</label><input className="min-w-8 flex-1 accent-emerald-800" id="bf-replay-seek" aria-label="Seek recorded mission" type="range" min="0" max="1" step=".1" defaultValue="0"/><output id="bf-replay-time">0:00</output><select className="bf-field" id="bf-replay-speed" aria-label="Replay speed" defaultValue="4"><option value="0">Paused</option><option value="1">1×</option><option value="2">2×</option><option value="4">4×</option><option value="8">8×</option></select></div>
      <label className="flex shrink-0 items-center gap-1"><input type="checkbox" id="bf-show-details"/> All labels</label>
    </div>
    <div className="relative overflow-hidden border border-ink bg-ink"><div id="tacviewContainer" className="tacview-canvas-container">{offline&&<p className="flex h-full items-center justify-center p-6 text-white">WebGL viewer unavailable in this browser.</p>}</div>
      <div className="pointer-events-none absolute top-4 right-4 text-right font-mono text-[9px] tracking-widest text-[#ebe6ce]"><span className="block">BLACK SEA / CAUCASUS</span><span id="tacviewMapSource">Loading terrain</span></div>
      <div className="fleet-overlay pointer-events-none absolute top-3 left-3 flex gap-px" aria-label="Track counts">{[['BLUE','blue','text-blue-300'],['RED','red','text-red-300'],['MISSILES','missile','text-amber-200']].map(([name,id,c])=><div key={id} className="min-w-13 border border-white/20 bg-ink/95 px-2 py-1 text-white"><span className="block font-mono text-[9px]">{name}</span><strong className={`text-xl tabular-nums ${c}`} id={`bf-${id}-count`}>—</strong></div>)}</div>
      <div id="tacviewTargetHud" className="tacview-target-hud" style={{display:'none'}}/>
      <div className="flex flex-wrap gap-x-4 gap-y-1 bg-ink px-3 py-2 font-mono text-[10px] text-stone-200"><span><b className="text-blue-300">⌜⌟</b> BLUFOR aircraft</span><span><b className="text-red-300">⌜⌟</b> REDFOR aircraft</span><span><b className="text-amber-200">◇</b> Missile tracks</span><span className="sm:ml-auto">Drag to orbit · Scroll to zoom</span></div>
    </div>
    <div id="bf-missile-list" className="fleet-missile-list" aria-label="Active missiles"/><details className="border border-t-0 border-line bg-panel"><summary className="cursor-pointer px-3 py-2 font-mono text-xs">Aircraft roster · select a chase camera</summary><div className="airspace-contacts" id="tacviewContacts" aria-label="Reported aircraft"/></details>
    <p className="mt-2 font-mono text-[10px] text-muted">Terrain: <a className="underline" href="https://registry.opendata.aws/terrain-tiles/" target="_blank" rel="noreferrer">Mapzen Terrain Tiles</a> / SRTM · <a className="underline" href="/models/vendor/credits.html" target="_blank" rel="noreferrer">Aircraft model credits and source</a>.</p>
  </section>;
});

function Table({headers,rows,empty='No entries yet.'}) {
  return <div className="overflow-x-auto border border-line bg-panel"><table className="bf-table"><thead><tr>{headers.map(h=><th scope="col" key={h}>{h}</th>)}</tr></thead><tbody>{rows.length?rows.map(([key,cells])=><tr key={key}>{cells.map((cell,i)=><td key={i}>{cell}</td>)}</tr>):<tr><td colSpan={headers.length}>{empty}</td></tr>}</tbody></table></div>;
}

function Operations({campaign,player,pilotId,action,open,disabled,production,canCommand}) {
  const side = player.side || 2;
  const op = campaign?.operations?.[side];
  const commander = campaign?.coalitions?.[side]?.human_commander;
  const isCommander = Boolean(pilotId) && commander === pilotId;
  const scheduled = op?.status === 'SCHEDULED' || op?.status === 'ACTIVE';
  const slots = op?.slots || [];
  return <section id="operationsTab">
    <Heading title="Flight operations" note="Propose a coalition plan and reserve roster slots. Scheduling saves the plan here; it does not launch a DCS flight.">
      <div className="flex flex-wrap gap-2">
        <Btn onClick={()=>open({type:'operation'})} disabled={disabled||production&&op?.status==='PLANNED'}>Propose target</Btn>
        {(!production||canCommand)&&<Btn onClick={()=>action('/api/operations/command',{side},'Command updated.')} disabled={disabled||Boolean(commander&&!isCommander)}>{isCommander?'Relinquish command':'Take coalition command'}</Btn>}
      </div>
    </Heading>
    {!op?<Empty>{pilotId?'No flight plan available for '+sideName(side)+'.':'Sign in to see your coalition flight plans.'}</Empty>:<Card>
      <div className="flex flex-wrap justify-between gap-3">
        <div><p className="eyebrow">{op.status} · {op.target_quadrant}</p><h2 className="text-2xl font-semibold">{op.name}</h2><p className="text-sm text-muted">{op.target_sector} · {op.frequency} · {op.coordinator}</p></div>
        {(!production||canCommand&&isCommander)&&<Btn kind="primary" disabled={disabled||scheduled||production&&!slots.some(slot=>slot.pilot)} onClick={()=>action('/api/operations/launch',{side},'Flight plan scheduled.')}>{scheduled?'Plan scheduled':'Confirm flight plan'}</Btn>}
      </div>
      <p className="my-4 border-l-2 border-emerald-800 bg-field p-3 text-sm text-muted">{op.objective_desc}</p>
      <h3 className="mb-3 font-semibold">Flight roster</h3>
      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-4">{slots.map((slot,i)=>{
        const mine = Boolean(pilotId) && (slot.pilot===pilotId || !production&&slot.pilot===player.callsign);
        return <Card key={slot.role_title+'-'+i} className="flex min-h-34 flex-col justify-between gap-2">
          <div><p className="eyebrow">{slot.role} · {slot.pilot_callsign||(!production&&slot.pilot)||(slot.pilot?'Reserved':'Open')}</p><strong>{slot.role_title}</strong><p className="text-xs text-muted">{slot.airframes}</p></div>
          <Btn disabled={disabled||production&&scheduled||(!mine&&Boolean(slot.pilot))} onClick={()=>action(mine?'/api/operations/leave':'/api/operations/join',mine?{side}:{side,slot_index:i},mine?'Roster slot released.':'Roster slot reserved.')}>{mine?'Leave roster':slot.pilot?'Assigned':'Reserve slot'}</Btn>
        </Card>;
      })}</div>
    </Card>}
  </section>;
}

function Armory({player,catalog,action,open,disabled}) {
  const items=Object.entries(player.inventory||{}).filter(([,n])=>n>0);
  return <section id="armoryTab"><Heading title="Personal armory" note="Manage inventory and sell orders without changing the live DCS server."><Btn id="openSellModalBtn" kind="primary" onClick={()=>open({type:'sell'})} disabled={disabled||!items.length}>Create sell order</Btn></Heading>
    {items.length?<div className="card-grid">{items.map(([key,n])=><Card key={key}><p className="eyebrow">{key} · {n} in stock</p><h2 className="my-1 text-xl font-semibold">{catalog[key]?.name||key}</h2><p className="mb-4 text-sm text-muted">{catalog[key]?.type||'Inventory item'}</p><div className="flex flex-wrap gap-2"><Btn disabled={disabled} onClick={()=>action('/api/armory/mount',{munition:key},'Mounted in workspace.')}>Mount on airframe</Btn><Btn disabled={disabled} onClick={()=>open({type:'sell',item:key})}>List for sale</Btn></div></Card>)}</div>:<Empty>No items in your armory. Visit the munitions depot to add inventory.</Empty>}
  </section>;
}

function Depot({catalog,player,action,disabled}) {
  const [filter,setFilter]=useState('all');
  const entries=Object.entries(catalog).filter(([,v])=>filter==='all'||v.coalition===filter);
  return <section id="requisitionTab"><Heading title="Munitions depot" note="Spend classroom Combat Merits to requisition inventory."><Filter values={[["all","All fleets"],["BLUFOR","BLUFOR"],["REDFOR","REDFOR"]]} selected={filter} onSelect={setFilter}/></Heading>
    {entries.length?<div className="card-grid">{entries.map(([key,v])=><Card key={key} className="flex flex-col items-start gap-2"><p className="eyebrow">{v.coalition} · {v.type}</p><h2 className="text-lg font-semibold">{v.name}</h2><p className="text-sm text-muted">{v.desc}</p><p className="text-xs text-muted">{v.range_km} km · Mach {v.mach} · {v.compatible?.join(', ')}</p><Btn className="mt-auto" kind="primary" disabled={disabled||player.points<v.cost_points} onClick={()=>action('/api/requisition',{munition:key},`${key} requisitioned.`)}>Requisition · {v.cost_points} CM</Btn></Card>)}</div>:<Empty>No matching items.</Empty>}
  </section>;
}

function Research({observation}) {
  const [filter,setFilter] = useState('all');
  const coalitions = observation.snapshot?.coalitions || {};
  const catalog = [2,1].flatMap(side => (coalitions[side]?.blueprints || []).map(bp => ({...bp,side})));
  const entries = catalog.filter(bp => filter==='all'||String(bp.side)===filter);
  return <section id="techTreeTab">
    <Heading title="DCS airframe research" note="This catalog is read-only. The AI Director and in-game F10 purchases spend the same coalition treasury. New campaign flights use advanced airframes only after their blueprint is paid for.">
      <Filter values={[[ "all","All fleets" ],[ "2","BLUFOR" ],[ "1","REDFOR" ]]} selected={filter} onSelect={setFilter}/>
    </Heading>
    {catalog.length>0&&<p className="eyebrow mb-3" role="status">{observation.current?'Live DCS catalog':'Last reported DCS catalog'}</p>}
    {entries.length?<div className="card-grid">{entries.map(bp=><Card key={bp.side+'-'+bp.key}>
      <div className="flex justify-between gap-2"><h2 className="text-xl font-semibold">{bp.name||bp.key}</h2><Side side={bp.side}/></div>
      <p className="mt-2 text-sm"><strong>{bp.unlocked?'Unlocked':'Locked'}</strong> · {money(bp.cost)}</p>
    </Card>)}</div>:<Empty>{replay?'This replay has no DCS blueprint ledger.':catalog.length?'No blueprints for this coalition.':'Waiting for the DCS blueprint ledger. No demo catalog is shown.'}</Empty>}
  </section>;
}


createRoot(document.getElementById('root')).render(<Sidebar section="tacview" setSection={()=>{}} counts={{}} connection="Connecting"/>);
