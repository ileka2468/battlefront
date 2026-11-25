import React, {memo, useEffect, useState} from 'react';
import {createRoot} from 'react-dom/client';

const params = new URLSearchParams(location.search);
const replay = params.get('replay') === '1';
const localHost = ['localhost','127.0.0.1','[::1]'].includes(location.hostname);
const tabGroups = [
  ['Campaign', [['tacview','Airspace','◎'],['operations','Flight operations','≡']]],
  ['Logistics', [['armory','Personal armory','▣'],['requisition','Munitions depot','◇'],['techTree','Airframe research','⊞'],['marketplace','Player exchange','⇄']]],
  ['Records', [['leaderboard','Pilot standings','▤'],['telemetry','Telemetry & MCP','◈']]],
];
const idFor = value => String(value ?? '').trim().toLowerCase().replace(/[^a-z0-9_]/g,'_');
const money = x => x == null ? '—' : `$${Number(x).toLocaleString('en-US',{maximumFractionDigits:2})}M`;
const sideName = side => +side === 2 ? 'BLUFOR' : 'REDFOR';
const noPilot = {callsign:'Guest',side:2,points:0,inventory:{}};
const feedEvents = new EventTarget();
window.setBattlefrontCampaignSnapshot = snapshot => feedEvents.dispatchEvent(new CustomEvent('campaign',{detail:snapshot}));

async function request(path, data, csrf, signal) {
  const options = data === undefined ? {cache:'no-store'} : {
    method:'POST',headers:{'Content-Type':'application/json',...(csrf?{'X-BF-CSRF':csrf}:{})},body:JSON.stringify(data),
  };
  options.credentials = 'same-origin';
  if (signal) options.signal = signal;
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
  return <header className="mb-5 flex flex-wrap items-end justify-between gap-3"><div><p className="eyebrow">Battlefront / workspace</p><h1 className="page-title">{title}</h1>{note&&<p className="mt-1 max-w-3xl text-sm text-muted">{note}</p>}</div>{children}</header>;
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

function Theater({observation, weather}) {
  const {snapshot:feed,current:live,changes} = observation;
  const coalitions = feed?.coalitions || {};
  const blue = coalitions['2'], red = coalitions['1'];
  const total = feed?.total_objectives || 21;
  return <div className="border-b border-line bg-panel px-4 pt-3 pb-2 sm:px-7">
    <div className="grid gap-3 lg:grid-cols-2 lg:gap-6"><section aria-label="Sector control">
      <div className="mb-2 flex items-center justify-between gap-2"><span className="eyebrow">Sector control</span><span className={`eyebrow ${live?'text-emerald-700':''}`} id="campaignFeedStatus">{live?'LIVE DCS • READ ONLY':replay?'RECORDED AIRSPACE • NO TREASURY':feed?'DELAYED DCS • LAST KNOWN':'WAITING FOR DCS CAMPAIGN'}</span></div>
      <div className="flex items-center gap-3 font-mono text-[11px]"><span><Side side={2}/> <strong id="blueSectorCount">{blue?.controlled_sectors??'—'}</strong>/{total}</span><div className="flex h-2.5 min-w-6 flex-1 gap-px overflow-hidden bg-field"><span className="block bg-blue-600/65" style={{width:`${100*(blue?.controlled_sectors||0)/total}%`}}/><span className="block bg-red-600/60" style={{width:`${100*(red?.controlled_sectors||0)/total}%`}}/></div><span><strong id="redSectorCount">{red?.controlled_sectors??'—'}</strong>/{total} <Side side={1}/></span></div>
    </section><section className="border-t border-line pt-2 lg:border-t-0 lg:border-l lg:pt-0 lg:pl-6" aria-label="DCS coalition treasury"><div className="mb-2 flex justify-between"><span className="eyebrow">DCS coalition treasury</span>{feed&&<span className="eyebrow">Balance / income rate</span>}</div><div className="grid grid-cols-2 gap-2"><TreasurySide side={2} coalition={blue} change={changes['2']}/><TreasurySide side={1} coalition={red} change={changes['1']}/></div></section></div>
    <div className="mt-2 flex flex-wrap items-center justify-between gap-2 text-[10px] text-muted"><p id="campaignWorkspaceNote">{replay?'The recording contains flight tracks, not campaign balances.':'Blueprints are paid for in DCS by the AI Director or via F10. Trading uses separate Companion Merits.'}</p>{weather?.live&&<span className="font-mono">Sochi WX ({weather.source}): {weather.temperature_c}°C · Wind {weather.wind_kt} kt @ {weather.wind_deg}°</span>}</div>
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
      <div id="bf-replay-controls" className="bf-replay-controls flex min-w-0 flex-1 items-center gap-2" hidden><button className="bf-btn bf-outline" id="bf-replay-restart" type="button">Restart</button><label className="hidden sm:inline" htmlFor="bf-replay-seek">REPLAY</label><input className="min-w-8 flex-1 accent-emerald-800" id="bf-replay-seek" aria-label="Seek recorded mission" type="range" min="0" max="1" step=".1" defaultValue="0"/><output id="bf-replay-time">0:00</output><select className="bf-field" id="bf-replay-speed" aria-label="Replay speed" defaultValue="1"><option value="0">Paused</option><option value="1">1×</option><option value="2">2×</option><option value="4">4×</option><option value="8">8×</option></select></div>
      <label className="flex shrink-0 items-center gap-1"><input type="checkbox" id="bf-show-details"/> All labels</label>
    </div>
    <div className="relative overflow-hidden border border-ink bg-ink"><div id="tacviewContainer" className="tacview-canvas-container">{offline&&<p className="flex h-full items-center justify-center p-6 text-white">WebGL viewer unavailable in this browser.</p>}</div>
      <div className="pointer-events-none absolute top-4 right-4 text-right font-mono text-[9px] tracking-widest text-[#ebe6ce]"><span className="block">BLACK SEA / CAUCASUS</span><span id="tacviewMapSource">Loading terrain</span></div>
      <div className="fleet-overlay pointer-events-none absolute top-3 left-3 flex gap-px" aria-label="Track counts">{[['BLUE','blue','text-blue-300'],['RED','red','text-red-300'],['MISSILES','missile','text-amber-200']].map(([name,id,c])=><div key={id} className="min-w-13 border border-white/20 bg-ink/95 px-2 py-1 text-white"><span className="block font-mono text-[9px]">{name}</span><strong className={`text-xl tabular-nums ${c}`} id={`bf-${id}-count`}>—</strong></div>)}</div>
      <div id="tacviewTargetHud" className="tacview-target-hud" style={{display:'none'}}/>
      <div className="flex flex-wrap gap-x-4 gap-y-1 bg-ink px-3 py-2 font-mono text-[10px] text-stone-200"><span><b className="text-blue-300">⌜⌟</b> BLUFOR aircraft</span><span><b className="text-red-300">⌜⌟</b> REDFOR aircraft</span><span><b className="text-amber-200">◇</b> Missile tracks</span><span className="sm:ml-auto">Drag to orbit · Scroll to zoom · WASD move (Shift faster) · M missile</span></div>
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
  const briefing = typeof op?.objective_desc === 'string' && !/^\s*Coalition briefing only\./i.test(op.objective_desc) ? op.objective_desc : '';
  return <section id="operationsTab">
    <Heading title="Flight operations">
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
      {briefing&&<p className="mt-4 border-l-2 border-emerald-800 bg-field p-3 text-sm text-muted">{briefing}</p>}
      <h3 className="my-3 font-semibold">Flight roster</h3>
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

function advertisedDcsQuantity(delivery) {
  const quantity = delivery?.max_quantity;
  return Number.isInteger(quantity) && quantity >= 1 ? Math.min(6, quantity) : null;
}

function settledDcsDelivery(status) {
  return status === 'ready' || status === 'rejected';
}

function DcsDeliveryStatus({delivery}) {
  const airfield = delivery.airfield || 'Mineralnye Vody';
  const item = delivery.item;
  const viperMod = item === 'AIM-120D';
  const maxQuantity = advertisedDcsQuantity(delivery);
  const count = Number.isInteger(delivery.quantity) && delivery.quantity >= 1 && delivery.quantity <= 6
    ? delivery.quantity : maxQuantity === null ? 1 : null;
  const amount = count === 1 ? 'One' : count;
  const shippedItem = `${viperMod ? 'modded ' : ''}${item}${count > 1 ? ' rounds' : ''}`;
  const details = {
    idle: ['Demo airfield delivery', `Send ${maxQuantity > 1 ? `up to ${maxQuantity} ${item} rounds` : `one ${item}`} from your armory to ${airfield}. Delivery uses items you already own; there is no second merit charge.`],
    pending: ['Awaiting DCS confirmation', `${count ? `${amount} ${item}${count > 1 ? ' rounds are' : ' is'}` : `Your ${item} delivery is`} held from your inventory until DCS confirms delivery. It is not ready to rearm yet.`],
    ready: ['Ready to rearm at the demo airfield', `DCS confirmed ${count ? `${count === 1 ? 'one' : count} ${shippedItem}` : `the ${item} delivery`} in base stock at ${airfield}. When parked there, use Rearm & Refuel in DCS. Your aircraft loadout was not changed automatically.`],
    rejected: ['DCS delivery not completed', `The requested items are back in your armory. ${maxQuantity !== null && delivery.can_send === true ? 'You can send a new order.' : 'This order will not retry automatically.'}`],
    review: ['Delivery held for review', `The ${item} is still reserved and delivery has not been confirmed. Do not resend or try to rearm from this order.`],
  };
  const detail = Object.hasOwn(details, delivery.status) ? details[delivery.status] : null;
  if (!detail) return null;
  return <aside role="status" aria-atomic="true" className="mb-4 border border-line bg-panel px-4 py-3" id="dcs-delivery-status">
    <p className="eyebrow">DCS delivery</p><strong className="mt-1 block">{detail[0]}</strong><p className="mt-1 text-sm text-muted">{detail[1]}</p>
    {viperMod&&['idle','pending','ready'].includes(delivery.status)&&<p className="mt-3 border-l-4 border-signal bg-field px-3 py-2 text-sm"><strong>DCS may show AIM-120B.</strong> The private Viper recording mod puts the AIM-120D in the stock AIM-120B slot. This is not native AIM-120D support.</p>}
  </aside>;
}

function DcsDeliveryControl({delivery, owned, disabled, action}) {
  const [requested,setRequested] = useState(1);
  const limit = advertisedDcsQuantity(delivery);
  const max = Math.min(limit ?? 1, owned);
  const quantity = Math.min(requested, max);
  if (!Number.isInteger(max) || max < 1) return null;
  return <>
    {limit > 1 && <label className="bf-label">
      Quantity to send
      <select className="bf-field" value={quantity} onChange={event=>setRequested(Number(event.target.value))} disabled={disabled}>
        {Array.from({length:max},(_,i)=><option key={i+1} value={i+1}>{i+1}</option>)}
      </select>
    </label>}
    <Btn kind="primary" disabled={disabled} onClick={()=>action('/api/dcs/deliver',
      limit === null ? {munition:delivery.item} : {munition:delivery.item,quantity},
      'Delivery requested. Awaiting DCS confirmation.')}>Send to DCS</Btn>
  </>;
}

function Armory({player,catalog,action,open,disabled,delivery}) {
  const items=Object.entries(player.inventory||{}).filter(([,n])=>n>0);
  const canSend = (delivery?.status==='idle' && delivery.can_send!==false) ||
    (settledDcsDelivery(delivery?.status) && advertisedDcsQuantity(delivery)!==null && delivery.can_send===true);
  const sendable = canSend ? delivery.item : null;
  return <section id="armoryTab"><Heading title="Personal armory" note={delivery?"Manage your inventory, list items for trade, or send eligible items to the DCS airfield.":"Manage your inventory and list items for trade."}><Btn id="openSellModalBtn" kind="primary" onClick={()=>open({type:'sell'})} disabled={disabled||!items.length}>Create sell order</Btn></Heading>
    {delivery&&<DcsDeliveryStatus delivery={delivery}/>}
    {items.length?<div className="card-grid">{items.map(([key,n])=><Card key={key}><p className="eyebrow">{key} · {n} in stock</p><h2 className="my-1 text-xl font-semibold">{catalog[key]?.name||key}</h2><p className="mb-4 text-sm text-muted">{catalog[key]?.type||'Inventory item'}</p><div className="flex flex-wrap items-end gap-2"><Btn disabled={disabled} onClick={()=>open({type:'sell',item:key})}>List for sale</Btn>{key===sendable&&<DcsDeliveryControl key={delivery.order_id ?? 'new-delivery'} delivery={delivery} owned={n} disabled={disabled} action={action}/>}</div></Card>)}</div>:<Empty>No items in your armory. Visit the munitions depot to add inventory.</Empty>}
  </section>;
}

function Depot({catalog,player,action,disabled,production}) {
  const [filter,setFilter]=useState('all');
  const entries=Object.entries(catalog).filter(([,v])=>filter==='all'||v.coalition===filter);
  return <section id="requisitionTab"><Heading title="Munitions depot" note="Spend Companion Merits (CM) to add items to your personal armory. This does not spend DCS coalition funds."><Filter values={[["all","All fleets"],["BLUFOR","BLUFOR"],["REDFOR","REDFOR"]]} selected={filter} onSelect={setFilter}/></Heading>
    {entries.length?<div className="card-grid">{entries.map(([key,v])=>{
      const specs=[Number.isFinite(v.range_km)&&`${v.range_km} km`,Number.isFinite(v.mach)&&`Mach ${v.mach}`,v.compatible?.join(', ')].filter(Boolean).join(' · ');
      return <Card key={key} className="flex flex-col items-start gap-2"><p className="eyebrow">{v.coalition} · {v.type}</p><h2 className="text-lg font-semibold">{v.name}</h2><p className="text-sm text-muted">{v.desc}</p>{specs&&<p className="text-xs text-muted">{specs}</p>}<Btn className="mt-auto" kind="primary" disabled={disabled||player.points<v.cost_points||production&&v.coalition!==sideName(player.side)} onClick={()=>action('/api/requisition',{munition:key},`${key} requisitioned.`)}>Requisition · {v.cost_points} CM</Btn></Card>;
    })}</div>:<Empty>No matching items.</Empty>}
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

function Exchange({orders,history,catalog,player,pilotId,open,action,disabled,production,players}) {
  const active=orders.filter(x=>x.status==='active');
  return <section id="marketplaceTab"><Heading title="Player exchange" note={`${active.length} active orders · ${history.reduce((sum,row)=>sum+(+row.price_points||0),0)} CM recorded volume`}><Btn kind="primary" disabled={disabled||!Object.values(player.inventory||{}).some(n=>n>0)} onClick={()=>open({type:'sell'})}>Create sell order</Btn></Heading>
    <Table headers={['Ordnance','Seller','Quantity','Ask','Action']} empty="No open orders. List an item from your armory." rows={active.map(o=>[o.id,[<strong>{catalog[o.item]?.name||o.item}</strong>,o.seller_callsign,o.quantity,`${o.price_points} CM`,<Btn kind="primary" disabled={disabled||(o.seller===pilotId?!production:player.points<o.price_points)} onClick={()=>action(o.seller===pilotId?'/api/marketplace/cancel':'/api/marketplace/buy',{listing_id:o.id},o.seller===pilotId?'Listing cancelled.':'Order purchased.')}>{o.seller===pilotId?(production?'Cancel listing':'Your order'):player.points<o.price_points?'Insufficient CM':'Buy'}</Btn>]])}/>
    <h2 className="mt-6 mb-3 text-lg font-semibold">Recent trades</h2><Table headers={['Item','Buyer','Seller','Quantity','Price','Time']} rows={history.slice(0,10).map((o,i)=>[o.id||i,[o.item,players[o.buyer]?.callsign||'Pilot',players[o.seller]?.callsign||'Pilot',o.quantity,`${o.price_points} CM`,o.timestamp||'Recent']])}/>
  </section>;
}

function Standings({players}) {
  const rows=Object.entries(players).sort(([,a],[,b])=>(b.stats?.a2a_kills||0)+(b.stats?.a2g_kills||0)-(a.stats?.a2a_kills||0)-(a.stats?.a2g_kills||0)||a.callsign.localeCompare(b.callsign));
  return <section id="leaderboardTab"><Heading title="Pilot standings" note="Recorded stats for companion pilots. Personal merit balances are private."/><Table headers={['Rank','Pilot','Coalition','Air kills','Ground kills','Assists','Sorties','Merits']} rows={rows.map(([id,p],i)=>[id,[`#${i+1}`,p.callsign,<Side side={p.side}/>,p.stats?.a2a_kills||0,p.stats?.a2g_kills||0,p.stats?.datalink_assists||0,p.stats?.sorties||0,p.points==null?'—':p.points+' CM']])}/></section>;
}

function TelemetryPanel() {
  const [data,setData]=useState(null),[err,setErr]=useState('');
  const load=async()=>{try{setErr('');setData(await request('/api/app-telemetry'));}catch(e){setErr(e.message);}};
  useEffect(()=>{void load();},[]);
  const events=data?.events||[], summary=data?.summary||{total:0,errors:0,avg_ms:0};
  return <section id="telemetryTab">
    <Heading title="Telemetry & MCP" note="Live API/UI observability log and Model Context Protocol endpoint.">
      <Btn onClick={load}>Refresh</Btn>
    </Heading>
    {err&&<p className="mb-3 text-sm text-red-700">{err}</p>}
    <div className="mb-4 grid gap-3 sm:grid-cols-3">
      <Card><p className="eyebrow">Logged events</p><strong className="text-2xl tabular-nums">{summary.total}</strong></Card>
      <Card><p className="eyebrow">HTTP 4xx/5xx</p><strong className="text-2xl tabular-nums">{summary.errors}</strong></Card>
      <Card><p className="eyebrow">MCP endpoint</p><code className="font-mono text-xs">{location.origin}/mcp</code></Card>
    </div>
    <h2 className="mb-2 text-lg font-semibold">Application telemetry log</h2>
    <Table headers={['Time (UTC)','Kind','Path / Event','Status','Detail']} empty="No telemetry events recorded yet."
      rows={events.slice(0,25).map((e,i)=>[`${e.ts}-${i}`,[e.ts,e.kind,e.path,String(e.status),e.detail||'—']])}/>
    <h2 className="mt-6 mb-2 text-lg font-semibold">MCP App iframe preview (/mcp/app)</h2>
    <p className="mb-2 text-xs text-muted">Tools: <code>get_theater_status</code>, <code>get_sector_threat_picture</code>, <code>list_ordnance_orders</code>, <code>propose_flight_plan</code></p>
    <iframe title="Battlefront MCP App" src="/mcp/app" className="h-72 w-full border border-line bg-white"/>
  </section>;
}

function Modal({modal,close,player,catalog,campaign,busy,oauth,savePilot,login,signup,startLink,finishLink,action}) {
  const [item,setItem]=useState(modal.item||Object.keys(player.inventory||{}).find(k=>player.inventory[k]>0)||'');
  const [qty,setQty]=useState(1);
  const [price,setPrice]=useState(6);
  const [callsign,setCallsign]=useState(player.callsign==='Guest'?'':player.callsign);
  const [side,setSide]=useState(player.side||2);
  const [sector,setSector]=useState('');
  const [username,setUsername]=useState('');
  const [password,setPassword]=useState('');
  const [pairCode,setPairCode]=useState('');
  const titles={login:'Sign in to the companion',signup:'Create a Companion account',link:'Link your DCS account',profile:'Edit callsign',pilot:'Choose a local demo callsign',sell:'Create sell order',operation:'Propose flight target'};
  const buttons={login:'Sign in',signup:'Create account',link:pairCode?'Check link':'Get one-time code',profile:'Save callsign',pilot:'Set callsign',sell:'Publish listing',operation:'Propose target'};
  useEffect(()=>{const onKey=e=>{if(e.key==='Escape'&&!busy)close();};window.addEventListener('keydown',onKey);return()=>window.removeEventListener('keydown',onKey);},[close,busy]);
  async function submit(e) {
    e.preventDefault();
    if(busy) return;
    let done;
    if(modal.type==='login') done=await login(username,password);
    if(modal.type==='signup') done=await signup(username,password);
    if(modal.type==='link') {
      if (pairCode) done=await finishLink(pairCode);
      else setPairCode(await startLink()||'');
    }
    if(modal.type==='pilot'||modal.type==='profile') done=await savePilot(callsign,+side);
    if(modal.type==='sell') done=await action('/api/marketplace/list',{munition:item,quantity:+qty,price_points:+price},'Sell order posted.');
    if(modal.type==='operation') done=await action('/api/operations/propose',{side:player.side,target_sector:sector},'Target proposed.');
    if(done) close();
  }
  return <div className="fixed inset-0 z-40 grid place-items-center bg-black/55 p-4" onClick={e=>{if(e.target===e.currentTarget&&!busy)close();}}>
    <div role="dialog" aria-modal="true" aria-labelledby="modal-title" className="w-full max-w-lg border border-line bg-paper shadow-xl">
      <form onSubmit={submit} className="grid gap-4 p-5">
        <div className="flex items-center justify-between"><h2 className="text-xl font-semibold" id="modal-title">{titles[modal.type]}</h2><Btn aria-label="Close dialog" onClick={close} disabled={busy}>×</Btn></div>
        {(modal.type==='login'||modal.type==='signup')&&<>
          <p className="text-sm text-muted">{modal.type==='signup'?'Choose a new Companion password. You’ll link DCS in the next step.':'Use your Battlefront Companion account, not your DCS credentials.'}</p>
          <label className="bf-label">Username<input className="bf-field" value={username} onChange={e=>setUsername(e.target.value)} required minLength={modal.type==='signup'?3:undefined} maxLength={modal.type==='signup'?24:32} autoFocus autoComplete="username" autoCapitalize="none" spellCheck={false}/></label>
          <label className="bf-label">Password<input className="bf-field" type="password" value={password} onChange={e=>setPassword(e.target.value)} required minLength={modal.type==='signup'?12:undefined} maxLength={modal.type==='signup'?128:256} autoComplete={modal.type==='signup'?'new-password':'current-password'}/></label>
          {modal.type==='login'&&oauth?.enabled&&<a className="bf-btn bf-outline text-center" href={oauth.login_url}>Continue with Google (OAuth 2.0)</a>}
        </>}
        {modal.type==='link'&&<>
          <ol className="list-decimal space-y-1 pl-5 text-sm text-muted">
            <li>Join this Battlefront mission in DCS and select a pilot slot.</li>
            <li>Open DCS multiplayer chat. Enter the command below.</li>
            <li>Return here and choose <strong>Check link</strong>.</li>
          </ol>
          {pairCode&&<div className="grid gap-2 border border-line bg-panel p-3">
            <code className="select-all font-mono text-sm" aria-label="One-time DCS command">-bf-link {pairCode}</code>
            <small className="text-muted">The link code is valid for five minutes and can be used once.</small>
            <Btn onClick={async()=>{const code=await startLink();if(code)setPairCode(code);}} disabled={busy} className="justify-self-start">Generate a new code</Btn>
          </div>}
        </>}
        {(modal.type==='pilot'||modal.type==='profile')&&<>
          <p className="text-sm text-muted">{modal.type==='profile'?'Your pilot account and coalition stay the same.':'This callsign is only for the local demo.'}</p>
          <label className="bf-label">Callsign<input id="callsignInput" className="bf-field" value={callsign} onChange={e=>setCallsign(e.target.value)} required maxLength={24} autoFocus placeholder="Enter callsign"/></label>
          {modal.type==='pilot'&&<label className="bf-label">Coalition<select id="sideSelect" className="bf-field" value={side} onChange={e=>setSide(e.target.value)}><option value="2">BLUFOR</option><option value="1">REDFOR</option></select></label>}
        </>}
        {modal.type==='sell'&&<>
          <label className="bf-label">Item<select id="sellItemSelect" className="bf-field" value={item} onChange={e=>{setItem(e.target.value);setQty(1);}} required>{Object.entries(player.inventory||{}).filter(([,n])=>n>0).map(([k,n])=><option key={k} value={k}>{catalog[k]?.name||k} ({n} in stock)</option>)}</select></label>
          <div className="grid grid-cols-2 gap-3"><label className="bf-label">Quantity<input className="bf-field" type="number" min="1" max={Math.min(50,player.inventory?.[item]||1)} required value={qty} onChange={e=>setQty(e.target.value)}/></label><label className="bf-label">Total price (CM)<input className="bf-field" type="number" min="1" max="10000" required value={price} onChange={e=>setPrice(e.target.value)}/></label></div>
        </>}
        {modal.type==='operation'&&<label className="bf-label">Target sector<select className="bf-field" value={sector} onChange={e=>setSector(e.target.value)} required><option value="" disabled>Select a sector</option>{(campaign?.sectors||[]).filter(s=>[1,2].includes(+s.side)&&+s.side!==+player.side).map(s=><option key={s.name}>{s.name}</option>)}</select></label>}
        <div className="flex justify-end gap-2"><Btn onClick={close} disabled={busy}>Cancel</Btn><Btn kind="primary" type="submit" disabled={busy}>{buttons[modal.type]}</Btn></div>
      </form>
    </div>
  </div>;
}

function App() {
  const [section,setSection]=useState('tacview');
  const [state,setState]=useState(null),[campaign,setCampaign]=useState(null),[live,setLive]=useState({snapshot:null,current:false,changes:{}});
  const [weather,setWeather]=useState(null),[oauth,setOauth]=useState({enabled:false});
  const [demoPilotId,setDemoPilotId]=useState(''),[demoPilot,setDemoPilot]=useState(null);
  const [connection,setConnection]=useState('Connecting'),[busy,setBusy]=useState(false),[modal,setModal]=useState(null),[notice,setNotice]=useState(null);
  const workspace=state?.workspace;
  const production=workspace?.mode==='production';
  const localDemo=Boolean(state)&&!production&&localHost;
  const pilotId=production?(workspace.authenticated?workspace.player_id||'':''):localDemo?demoPilotId:'';
  const delivery=production&&workspace.authenticated&&pilotId&&typeof state?.delivery?.item==='string'?state.delivery:null;
  const deliveryStatus=delivery?.status, deliveryOrderId=delivery?.order_id;
  const watchReadyProfile=section==='armory'&&delivery?.item==='AIM-120D'&&
    (deliveryStatus==='idle'||(settledDcsDelivery(deliveryStatus)&&advertisedDcsQuantity(delivery)!==null));
  const player=state?.players?.[pilotId]||(localDemo&&demoPilot)||noPilot;
  const catalog=state?.munition_catalog||{};
  const orders=state?.marketplace||[];
  const dcsCatalog=Object.values(live.snapshot?.coalitions||{}).flatMap(coalition=>coalition.blueprints||[]);
  const counts={armory:pilotId?Object.values(player.inventory||{}).reduce((n,v)=>n+(+v||0),0):null,
    techTree:dcsCatalog.length?dcsCatalog.filter(bp=>bp.unlocked).length+'/'+dcsCatalog.length:null,
    marketplace:pilotId?orders.filter(o=>o.status==='active').length:null};
  const title=tabGroups.flatMap(([,t])=>t).find(t=>t[0]===section)?.[1];
  const alert=(text,error=false)=>setNotice({text,error});
  async function refresh() {
    try {
      const stored=await request('/api/state');
      setState(stored);
      const nextCampaign=await request('/api/campaign'+(replay?'?replay=1':''));
      setCampaign(nextCampaign);
      if(!replay&&nextCampaign.live_snapshot) setLive(previous=>previous.snapshot?previous:
        {snapshot:nextCampaign.live_snapshot,current:false,changes:{}});
      setConnection('Connected');
      return stored;
    } catch {setConnection('Workspace unavailable'); return null;}
  }
  async function identifyLocal(callsign,side) {
    const answer=await request('/api/player/set_callsign',{callsign:callsign.trim(),side});
    setDemoPilotId(answer.player_id||idFor(callsign));setDemoPilot(answer.player);
    localStorage.setItem('bf_callsign',callsign.trim());localStorage.setItem('bf_side',String(side));
  }
  useEffect(()=>{
    const change=({detail:snapshot})=>{
      if (replay) return;
      setLive(previous=>{
        if (!snapshot) return previous.current?{...previous,current:false}:previous;
        const changes=previous.current?{...previous.changes}:{};
        for (const side of ['1','2']) {
          const before=previous.snapshot?.coalitions?.[side]?.treasury;
          const after=snapshot.coalitions?.[side]?.treasury;
          if (previous.current&&Number.isFinite(before)&&Number.isFinite(after)&&before!==after) changes[side]=Math.round((after-before)*100)/100;
        }
        return {snapshot,current:true,changes};
      });
    };
    feedEvents.addEventListener('campaign',change);
    void (async()=>{
      const stored=await refresh();
      request('/api/weather').then(setWeather).catch(()=>{});
      request('/api/auth/oauth/status').then(setOauth).catch(()=>{});
      if (!stored||stored.workspace?.mode==='production'||!localHost) return;
      const name=params.get('callsign')||localStorage.getItem('bf_callsign')||(params.get('demo')==='1'?'Professor_Smith':'');
      if(name){try{await identifyLocal(name,+localStorage.getItem('bf_side')||2);await refresh();}catch(e){alert(e.message,true);}}
    })();
    return ()=>feedEvents.removeEventListener('campaign',change);
  },[]);
  useEffect(()=>{
    if((deliveryStatus!=='pending'&&!watchReadyProfile)||!pilotId||busy) return;
    let timer;
    const controller=new AbortController();
    const poll=async()=>{
      try {
        const next=await request('/api/state',undefined,undefined,controller.signal);
        if(controller.signal.aborted) return;
        if(!next.workspace?.authenticated||next.workspace.player_id===pilotId) {
          setState(current=>current?.workspace?.player_id===pilotId&&current.delivery?.status===deliveryStatus&&
            current.delivery.order_id===deliveryOrderId?next:current);
          if(next.delivery?.status!==deliveryStatus) return;
        }
      } catch { /* A network delay is not a delivery decision; retry without clearing the status. */ }
      if(!controller.signal.aborted) timer=setTimeout(poll,3000);
    };
    timer=setTimeout(poll,3000);
    return ()=>{clearTimeout(timer);controller.abort();};
  },[busy,pilotId,deliveryStatus,deliveryOrderId,watchReadyProfile]);
  useEffect(()=>{if(!notice)return;const t=setTimeout(()=>setNotice(null),6500);return()=>clearTimeout(t);},[notice]);
  async function login(username,password){
    setBusy(true);
    try {
      await request('/api/workspace/login',{username:username.trim(),password});
      const stored=await refresh();
      if(!stored?.workspace?.authenticated) throw Error('Signed in, but the pilot workspace could not be loaded. Reload to retry.');
      if(stored.workspace.link_required){setModal({type:'link'});return false;}
      alert('Signed in to Battlefront.');
      return true;
    } catch(e){alert(e.message,true);return false;} finally{setBusy(false);}
  }
  async function signup(username,password){
    setBusy(true);
    try{
      await request('/api/workspace/signup',{username:username.trim(),password});
      const stored=await refresh();
      if(!stored?.workspace?.link_required) throw Error('Account created. Sign in again to link your DCS account.');
      setModal({type:'link'});
      return false;
    }catch(e){alert(e.message,true);return false;}finally{setBusy(false);}
  }
  async function startLink(){
    setBusy(true);
    try{return (await request('/api/dcs/link/start',{},workspace.csrf)).code;}
    catch(e){alert(e.message,true);return '';}finally{setBusy(false);}
  }
  async function finishLink(code){
    setBusy(true);
    try{
      const result=await request('/api/dcs/link/finish',{code},workspace.csrf);
      if(result.status==='waiting'){alert('Waiting for DCS. Send the command from your occupied pilot slot, then check again.');return false;}
      const stored=await refresh();
      if(!stored?.workspace?.player_id) throw Error('DCS approved the link. Reload to see your pilot account.');
      alert('DCS account linked.');return true;
    }catch(e){alert(e.message,true);return false;}finally{setBusy(false);}
  }
  async function logout(){
    if(!production||!workspace.csrf) return;
    setBusy(true);
    try {
      await request('/api/workspace/logout',{},workspace.csrf);
      setState({...state,workspace:{mode:'production',authenticated:false},players:{},marketplace:[],trade_history:[],delivery:undefined});
      setCampaign(null);
      await refresh();
      alert('Signed out.');
    } catch(e){await refresh();alert(e.message,true);}finally{setBusy(false);}
  }
  async function savePilot(name,side){
    setBusy(true);
    try {
      if (production&&pilotId&&workspace.csrf) await request('/api/player/set_callsign',{callsign:name.trim()},workspace.csrf);
      else if(localDemo) await identifyLocal(name,side);
      else return false;
      await refresh(); alert('Callsign saved.'); return true;
    } catch(e){alert(e.message,true);return false;}finally{setBusy(false);}
  }
  async function action(path,fields,message){
    if(!pilotId||connection!=='Connected'||production&&!workspace.csrf) return false;
    setBusy(true);
    try {
      const body=production?fields:{player_id:pilotId,seller_id:pilotId,buyer_id:pilotId,...fields};
      const data=await request(path,body,production?workspace.csrf:null);
      await refresh(); alert(data.message||message||'Done.');return true;
    } catch(e){if(e.status===401||e.status===403||(path==='/api/dcs/deliver'&&e.status===409)) await refresh();alert(e.message,true);return false;}finally{setBusy(false);}
  }
  const common={campaign,player,pilotId,action,open:setModal,production,
    canCommand:production?Boolean(workspace.can_command):localDemo,
    disabled:busy||!pilotId||connection!=='Connected'||(production&&!workspace.csrf)};
  const selectSection=next=>{
    setSection(next);
    fetch('/api/app-telemetry',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({event:'tab_view',detail:next})}).catch(()=>{});
  };
  return <div className="min-h-screen lg:grid lg:grid-cols-[220px_minmax(0,1fr)]">
    <Sidebar section={section} setSection={selectSection} counts={counts} connection={connection}/>
    <div className="min-w-0">
      <header className="flex flex-wrap items-center justify-between gap-2 border-b border-line bg-panel px-4 py-3 sm:px-7">
        <div><span className="eyebrow">{production?'Campaign workspace':localDemo?'Local demo workspace':'Campaign spectator'}</span><div id="workspaceName" className="font-semibold">{title}</div></div>
        <div className="flex flex-wrap items-center gap-3">
          {production&&!workspace.authenticated&&<><Btn kind={workspace.signup_enabled?'outline':'primary'} onClick={()=>setModal({type:'login'})}>Sign in</Btn>{workspace.signup_enabled&&<Btn kind="primary" onClick={()=>setModal({type:'signup'})}>Sign up</Btn>}</>}
          {production&&workspace.link_required&&<><Btn kind="primary" onClick={()=>setModal({type:'link'})}>Link DCS account</Btn><Btn onClick={logout} disabled={busy}>Sign out</Btn></>}
          {production&&pilotId&&<><Btn onClick={()=>setModal({type:'profile'})} aria-label="Edit callsign" disabled={busy}>{player.callsign}</Btn><Btn onClick={logout} disabled={busy}>Sign out</Btn></>}
          {localDemo&&<Btn onClick={()=>setModal({type:'pilot'})} aria-label={pilotId?'Change callsign':'Choose callsign'}>{pilotId?player.callsign:'Choose callsign'}</Btn>}
          {pilotId&&<><Side side={player.side}/><strong className="font-mono text-xs" id="meritsValue">{player.points} CM</strong></>}
          {localDemo&&pilotId&&params.get('demo')==='1'&&<Btn disabled={common.disabled} onClick={()=>action('/api/demo/grant_merits',{amount:25},'25 demo merits awarded.')}>+25 demo CM</Btn>}
        </div>
      </header>
      <Theater observation={live} weather={weather}/>
      <main className="min-w-0 px-3 py-4 sm:px-6 sm:py-6">
        <Airspace visible={section==='tacview'}/>
        {production&&!pilotId&&['armory','requisition','marketplace'].includes(section)&&<div className="mb-4 border border-line bg-panel p-4 text-sm"><Btn onClick={()=>setModal({type:workspace.link_required?'link':'login'})}>{workspace.link_required?'Link your DCS account':'Sign in'}</Btn> to use your personal inventory and coalition exchange.</div>}
        {section==='operations'&&<Operations {...common}/>}
        {section==='armory'&&<Armory {...common} catalog={catalog} delivery={delivery}/>}
        {section==='requisition'&&<Depot {...common} catalog={catalog}/>}
        {section==='techTree'&&<Research observation={live}/>}
        {section==='marketplace'&&<Exchange {...common} orders={orders} history={state?.trade_history||[]} catalog={catalog} players={state?.players||{}}/>}
        {section==='leaderboard'&&<Standings players={state?.players||{}}/>}
        {section==='telemetry'&&<TelemetryPanel/>}
      </main>
      <footer className="border-t border-line px-4 py-3 font-mono text-[10px] text-muted sm:px-7">Companion Merits are separate from the DCS coalition treasury.</footer>
    </div>
    {modal&&<Modal key={modal.type+'-'+(modal.item||'')} modal={modal} close={()=>setModal(null)} {...common} oauth={oauth} catalog={catalog} savePilot={savePilot} login={login} signup={signup} startLink={startLink} finishLink={finishLink} busy={busy}/>}
    {notice&&<div className={'fixed right-4 bottom-4 z-50 max-w-[min(420px,90vw)] border bg-paper p-3 text-sm shadow-lg '+(notice.error?'border-red-500':'border-emerald-700')} role={notice.error?'alert':'status'}>{notice.text}<button className="ml-4 cursor-pointer text-muted" type="button" aria-label="Dismiss notification" onClick={()=>setNotice(null)}>×</button></div>}
  </div>;
}

createRoot(document.getElementById('root')).render(<App/>);
