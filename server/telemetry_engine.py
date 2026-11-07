"""
BATTLEFRONT TACTICAL TELEMETRY ENGINE
Handles real DCS World telemetry ingestion and autonomous Caucasus campaign flight simulation.
Keeps the explicit live campaign and recorded mission views distinct.
"""

import time
import math
import random
import json
import os
import re
from bisect import bisect_right
from pathlib import Path
from typing import Dict, List, Any, Optional

CAUCASUS_SECTOR_ANCHORS = {
    "Krasnodar": {"x": -12000, "z": 370000, "side": 1},
    "Novorossiysk": {"x": -25000, "z": 320000, "side": 1},
    "Krymsk": {"x": -7500, "z": 294000, "side": 1},
    "Maykop": {"x": -20000, "z": 475000, "side": 1},
    "Mineralnye Vody": {"x": -52089, "z": 707418, "side": 1},
    "Mozdok": {"x": -83329, "z": 835634, "side": 1},
    "Sochi": {"x": -150000, "z": 445000, "side": 2},
    "Gudauta": {"x": -195650, "z": 515898, "side": 2},
    "Gagra": {"x": -180000, "z": 490000, "side": 2},
    "Sukhumi": {"x": -221381, "z": 565908, "side": 2},
    "Kutaisi": {"x": -284582, "z": 685029, "side": 2},
    "Senaki": {"x": -281903, "z": 648379, "side": 2},
    "Batumi": {"x": -354000, "z": 621000, "side": 2},
}

AIRCRAFT_FRESH_SECONDS = 4
AIRCRAFT_HOLD_SECONDS = 15
CAMPAIGN_FRESH_SECONDS = 5
CAMPAIGN_MAX_SKEW_SECONDS = 5

class TelemetryEngine:
    def __init__(self):
        self.paths = [Path(p) for p in os.environ.get('BF_TELEMETRY_FILES', '').split(os.pathsep) if p]
        self.campaign_paths = [Path(p) for p in os.environ.get('BF_CAMPAIGN_FILES', '').split(os.pathsep) if p]
        self.campaign_only = os.environ.get('BF_LIVE_CAMPAIGN_ONLY') == '1'
        self._last_campaign_flight = None
        self.replay = []
        self.replay_times = []
        self.replay_start = time.monotonic()
        replay_file = os.environ.get('BF_REPLAY_FILE')
        if replay_file:
            with open(replay_file, encoding='utf-8') as recording:
                self.replay = [frame for line in recording if line.strip()
                               if (frame := self.validate(json.loads(line))) is not None]
            if self.replay:
                origin = self.replay[0]['sim_time']
                self.replay_times = [frame['sim_time'] - origin for frame in self.replay]
                self.first_missile = next((t for t, f in zip(self.replay_times,self.replay) if f['missiles']), None)
        self.simulated_units: List[Dict[str, Any]] = []
        self.active_missiles: List[Dict[str, Any]] = []
        self.last_sim_tick = time.time()
        self.missile_counter = 100
        self._init_simulation_flights()

    def _init_simulation_flights(self):
        """Initializes balanced, realistic combat air patrols & strike flights across the Caucasus."""
        self.simulated_units = [
            # BLUFOR Sorties (Side 2)
            {
                "id": "BLU-CAP-01",
                "callsign": "Viper 1-1",
                "side": 2,
                "type": "F-16C Block 50",
                "role": "CAP (Combat Air Patrol)",
                "x": -185000.0,
                "z": 490000.0,
                "alt": 8200.0,
                "heading": 35.0,
                "pitch": 1.0,
                "roll": 8.0,
                "speed_kts": 470.0,
                "route": [
                    {"x": -180000, "z": 480000},
                    {"x": -140000, "z": 430000},
                    {"x": -100000, "z": 400000},
                    {"x": -150000, "z": 445000}
                ],
                "wp_index": 0,
                "status": "PATROL FL270",
                "target_id": "RED-CAP-01",
                "weapons": ["AIM-120D AMRAAM", "AIM-9X Sidewinder", "M61A1 Vulcan"]
            },
            {
                "id": "BLU-CAP-02",
                "callsign": "Viper 1-2",
                "side": 2,
                "type": "F-16C Block 50",
                "role": "CAP (Wingman)",
                "x": -187000.0,
                "z": 488000.0,
                "alt": 8250.0,
                "heading": 35.0,
                "pitch": 0.5,
                "roll": 6.0,
                "speed_kts": 472.0,
                "route": [
                    {"x": -182000, "z": 478000},
                    {"x": -142000, "z": 428000},
                    {"x": -102000, "z": 398000},
                    {"x": -152000, "z": 443000}
                ],
                "wp_index": 0,
                "status": "TRAIL ESCORT",
                "target_id": "RED-CAP-01",
                "weapons": ["AIM-120D AMRAAM", "AIM-9X Sidewinder"]
            },
            {
                "id": "BLU-STK-03",
                "callsign": "Hammer 2-1",
                "side": 2,
                "type": "F-16C Strike",
                "role": "STRIKE / DEAD",
                "x": -240000.0,
                "z": 580000.0,
                "alt": 4800.0,
                "heading": 340.0,
                "pitch": -1.0,
                "roll": 3.0,
                "speed_kts": 510.0,
                "route": [
                    {"x": -200000, "z": 520000},
                    {"x": -140000, "z": 410000},
                    {"x": -30000, "z": 330000}, # Novorossiysk refinery target
                    {"x": -180000, "z": 490000}
                ],
                "wp_index": 0,
                "status": "INGRESS LOW-LEVEL",
                "target_id": None,
                "weapons": ["AGM-88C HARM", "GBU-39 SDB", "AIM-120D AMRAAM"]
            },
            {
                "id": "BLU-LOG-04",
                "callsign": "Dustoff 4-1",
                "side": 2,
                "type": "UH-60L Black Hawk",
                "role": "FORWARD LOGISTICS",
                "x": -270000.0,
                "z": 660000.0,
                "alt": 1100.0,
                "heading": 315.0,
                "pitch": 2.0,
                "roll": 0.0,
                "speed_kts": 145.0,
                "route": [
                    {"x": -250000, "z": 620000},
                    {"x": -210000, "z": 550000},
                    {"x": -195000, "z": 515000}  # Gudauta LZ
                ],
                "wp_index": 0,
                "status": "TACTICAL AIRDROP TRANSIT",
                "target_id": None,
                "weapons": ["M134 Minigun", "Defensive Flares"]
            },

            # REDFOR Sorties (Side 1)
            {
                "id": "RED-CAP-01",
                "callsign": "Bort 301",
                "side": 1,
                "type": "Su-27 Flanker",
                "role": "CAP (Interceptor)",
                "x": -45000.0,
                "z": 380000.0,
                "alt": 9100.0,
                "heading": 195.0,
                "pitch": -0.5,
                "roll": -12.0,
                "speed_kts": 520.0,
                "route": [
                    {"x": -70000, "z": 390000},
                    {"x": -130000, "z": 430000},
                    {"x": -80000, "z": 490000},
                    {"x": -15000, "z": 410000}
                ],
                "wp_index": 0,
                "status": "RADAR SEARCH HOT",
                "target_id": "BLU-CAP-01",
                "weapons": ["R-27ER Alamo", "R-73 Archer", "GSh-30-1"]
            },
            {
                "id": "RED-CAP-02",
                "callsign": "Bort 302",
                "side": 1,
                "type": "Su-27 Flanker",
                "role": "CAP (Wingman)",
                "x": -43000.0,
                "z": 383000.0,
                "alt": 9150.0,
                "heading": 195.0,
                "pitch": -0.5,
                "roll": -10.0,
                "speed_kts": 518.0,
                "route": [
                    {"x": -68000, "z": 393000},
                    {"x": -128000, "z": 433000},
                    {"x": -78000, "z": 493000},
                    {"x": -13000, "z": 413000}
                ],
                "wp_index": 0,
                "status": "LINE ABREAST",
                "target_id": "BLU-CAP-02",
                "weapons": ["R-27ER Alamo", "R-73 Archer"]
            },
            {
                "id": "RED-STK-03",
                "callsign": "Bort 510",
                "side": 1,
                "type": "Su-34 Fullback",
                "role": "DEEP STRIKE",
                "x": -75000.0,
                "z": 750000.0,
                "alt": 6200.0,
                "heading": 230.0,
                "pitch": 0.0,
                "roll": -4.0,
                "speed_kts": 490.0,
                "route": [
                    {"x": -120000, "z": 700000},
                    {"x": -170000, "z": 620000},
                    {"x": -270000, "z": 670000}, # Kutaisi C2 Complex
                    {"x": -80000, "z": 780000}
                ],
                "wp_index": 0,
                "status": "PENETRATION SORTIE",
                "target_id": None,
                "weapons": ["Kh-31P Krypton", "KAB-500Kr", "R-77 Adder"]
            },
            {
                "id": "RED-AWACS-04",
                "callsign": "Mainstay 50",
                "side": 1,
                "type": "A-50 Mainstay",
                "role": "AIRBORNE EARLY WARNING",
                "x": -30000.0,
                "z": 620000.0,
                "alt": 9500.0,
                "heading": 90.0,
                "pitch": 0.0,
                "roll": 2.0,
                "speed_kts": 390.0,
                "route": [
                    {"x": -30000, "z": 720000},
                    {"x": -40000, "z": 720000},
                    {"x": -40000, "z": 600000},
                    {"x": -30000, "z": 600000}
                ],
                "wp_index": 0,
                "status": "ORBIT FL310 GCI ACTIVE",
                "target_id": None,
                "weapons": ["Shmel Radar Complex"]
            }
        ]

    @staticmethod
    def validate(frame):
        """Validate the hook schema; an empty snapshot is still a valid live frame."""
        def finite(v):
            return type(v) in (int, float) and abs(v) <= 1.e9
        if not isinstance(frame, dict) or frame.get('version') != 1 or frame.get('theater') != 'Caucasus':
            return None
        if not all(type(frame.get(k)) is int and frame[k] >= 0 for k in ('session', 'seq')):
            return None
        if not finite(frame.get('sim_time')) or not isinstance(frame.get('units'), list) or len(frame['units']) > 256:
            return None
        units = {}
        for u in frame['units']:
            if not isinstance(u, dict) or not all(isinstance(u.get(k), str) and len(u[k]) <= 240
                                                 for k in ('id', 'callsign', 'type')):
                return None
            if (not u['id'] or type(u.get('side')) is not int or u['side'] not in (1, 2)
                    or u.get('category') not in ('airplane', 'helicopter') or type(u.get('on_ground')) is not bool):
                return None
            if not all(finite(u.get(k)) for k in ('x', 'z', 'alt', 'heading', 'pitch', 'roll', 'speed_kts')):
                return None
            keys = ('id', 'callsign', 'type', 'side', 'category', 'on_ground', 'x', 'z', 'alt', 'heading', 'pitch', 'roll', 'speed_kts')
            units[u['id']] = {k: u[k] for k in keys}
        raw_missiles = frame.get('missiles', [])
        if not isinstance(raw_missiles, list) or len(raw_missiles) > 160:
            return None
        missiles = {}
        for m in raw_missiles:
            if (not isinstance(m,dict) or not all(isinstance(m.get(k),str) and 0 < len(m[k]) <= 160 for k in ('id','type'))
                    or type(m.get('side')) is not int or m['side'] not in (0,1,2)
                    or not all(finite(m.get(k)) for k in ('x','z','alt','heading','pitch','speed_kts'))):
                return None
            missiles[m['id']] = {k:m[k] for k in ('id','type','side','x','z','alt','heading','pitch','speed_kts')}
        return {**{k: frame[k] for k in ('version', 'theater', 'session', 'seq', 'sim_time')}, 'units': list(units.values()), 'missiles': list(missiles.values()),
                'mission': 'Battlefront Caucasus' if frame.get('mission')=='Battlefront Caucasus' else None}

    @staticmethod
    def validate_campaign(campaign):
        def finite(x):
            return type(x) in (int,float) and abs(x) <= 1.e9
        if not isinstance(campaign,dict) or campaign.get('mission') != 'Battlefront Caucasus' or campaign.get('total_objectives') != 21:
            return None
        sectors, finance = campaign.get('sectors'), campaign.get('coalitions')
        if not isinstance(sectors,list) or len(sectors)!=21 or not isinstance(finance,dict):
            return None
        clean=[]
        for s in sectors:
            if not isinstance(s,dict) or type(s.get('id')) is not int or type(s.get('side')) is not int or s['side'] not in (0,1,2):
                return None
            if not isinstance(s.get('name'),str) or not 1 <= len(s['name']) <= 90:
                return None
            if not isinstance(s.get('status'),str) or not 1 <= len(s['status']) <= 36:
                return None
            if type(s.get('level')) is not int or not 1 <= s['level'] <= 12 or not all(finite(s.get(k)) for k in ('x','z')):
                return None
            clean.append({k:s[k] for k in ('id','name','side','status','level','x','z')})
        if {s['id'] for s in clean} != set(range(101,122)):
            return None
        totals={}
        for side in ('1','2'):
            c=finance.get(side)
            if (not isinstance(c,dict) or not all(finite(c.get(k)) for k in ('treasury','hourly_income'))
                    or type(c.get('controlled_sectors')) is not int
                    or c['controlled_sectors'] != sum(s['side']==int(side) for s in clean)):
                return None
            total={k:c[k] for k in ('treasury','hourly_income','controlled_sectors')}
            seconds, required = c.get('stock_flight_seconds'), c.get('stock_flight_required')
            if type(seconds) is int and type(required) is int and 0 <= seconds <= required <= 86400 and required > 0:
                total.update(stock_flight_seconds=seconds, stock_flight_required=required)
            receipt = c.get('last_blueprint_purchase')
            if isinstance(receipt,dict):
                key, cost, before, after = (receipt.get(k) for k in ('key','cost','before','after'))
                if (isinstance(key,str) and re.fullmatch(r'[A-Za-z0-9_ -]{1,64}',key)
                        and all(finite(x) for x in (cost,before,after)) and 0 < cost <= before and after >= 0
                        and abs(before-cost-after) <= .011):
                    total['last_blueprint_purchase'] = {'key':key,'cost':cost,'before':before,'after':after}
                    if receipt.get('source') in ('director','f10'):
                        total['last_blueprint_purchase']['source'] = receipt['source']
            blueprints = c.get('blueprints')
            if isinstance(blueprints, list) and len(blueprints) <= 32:
                catalog = {}
                for bp in blueprints:
                    if not isinstance(bp,dict):
                        continue
                    key,name,cost,unlocked=(bp.get(k) for k in ('key','name','cost','unlocked'))
                    if (isinstance(key,str) and re.fullmatch(r'[A-Za-z0-9_ -]{1,64}',key) and isinstance(name,str)
                            and 0<len(name)<=100 and finite(cost) and cost>0 and type(unlocked) is bool):
                        catalog[key]={'key':key,'name':name,'cost':cost,'unlocked':unlocked}
                total['blueprints']=sorted(catalog.values(),key=lambda bp:(bp['cost'],bp['key']))
            totals[side]=total
        return {'mission':'Battlefront Caucasus','total_objectives':21,'coalitions':totals,'sectors':sorted(clean,key=lambda s:s['id'])}

    def read_live(self, now):
        latest = None
        max_age = AIRCRAFT_HOLD_SECONDS if self.campaign_only else AIRCRAFT_FRESH_SECONDS
        for path in self.paths:
            try:
                with path.open('rb') as f:
                    st = os.fstat(f.fileno())
                    age = now - st.st_mtime
                    if not -1 <= age < max_age or st.st_size > 300_000:
                        continue
                    frame = self.validate(json.load(f))
                if frame is not None and (latest is None or
                        (frame['session'], frame['seq']) > (latest[1]['session'], latest[1]['seq'])):
                    latest = st.st_mtime, frame
            except (OSError, UnicodeError, ValueError):
                continue

        if self.campaign_only:
            previous = self._last_campaign_flight
            if latest and latest[1]['mission'] != 'Battlefront Caucasus':
                # An actual mission change is not an exporter hiccup. Never show
                # the previous campaign or promote an ordinary mission as live.
                self._last_campaign_flight = None
                return None
            if previous:
                stamp, saved = previous
                if not -1 <= now - stamp < AIRCRAFT_HOLD_SECONDS:
                    self._last_campaign_flight = previous = None
                elif not latest or (latest[1]['session'], latest[1]['seq']) < (saved['session'], saved['seq']):
                    # Brief simultaneous file loss or a stale alternate file must
                    # not replace a newer frame or attach old economic data.
                    return max(0, now - stamp), {**saved, 'campaign': None, 'flight_status': 'delayed'}
            if latest:
                self._last_campaign_flight = latest

        if latest is None:
            return None
        stamp, frame = latest
        age = max(0, now - stamp)
        fresh = age < AIRCRAFT_FRESH_SECONDS
        campaign = self.read_campaign(now, frame) if fresh else None
        return age, {**frame, 'campaign': campaign, 'flight_status': 'live' if fresh else 'delayed'}

    def read_campaign(self, now, aircraft_frame):
        if aircraft_frame['mission'] != 'Battlefront Caucasus':
            return None
        newest = None
        for path in self.campaign_paths:
            try:
                with path.open('rb') as f:
                    st = os.fstat(f.fileno())
                    if not -1 <= now - st.st_mtime < CAMPAIGN_FRESH_SECONDS or st.st_size > 60_000:
                        continue
                    row = json.load(f)
                if (not isinstance(row,dict) or type(row.get('sim_time')) not in (int,float)
                        or not abs(row['sim_time']-aircraft_frame['sim_time']) <= CAMPAIGN_MAX_SKEW_SECONDS):
                    continue
                validated = self.validate_campaign(row.get('campaign'))
                if validated and (newest is None or row['sim_time'] > newest[0]):
                    newest = row['sim_time'], validated
            except (OSError,UnicodeError,ValueError):
                continue
        return newest[1] if newest else None

    def tick_simulation(self):
        """Advances flight kinematic states, waypoints, and dogfight intercepts."""
        now = time.time()
        dt = max(0, min(now - self.last_sim_tick, 1.0))
        self.last_sim_tick = now

        # Update simulated aircraft
        for unit in self.simulated_units:
            route = unit.get("route", [])
            if not route:
                continue

            target_wp = route[unit["wp_index"]]
            dx = target_wp["x"] - unit["x"]
            dz = target_wp["z"] - unit["z"]
            dist = math.hypot(dx, dz)

            # Desired heading to waypoint (DCS angles: 0=North (+X), 90=East (+Z))
            desired_hdg = math.degrees(math.atan2(dz, dx)) % 360

            # Smoothly turn towards desired heading
            current_hdg = unit["heading"]
            diff = (desired_hdg - current_hdg + 180) % 360 - 180
            turn_rate = 18.0 * dt # max degrees per tick
            if abs(diff) <= turn_rate:
                unit["heading"] = desired_hdg
                unit["roll"] = 0.0
            else:
                bank_sign = 1 if diff > 0 else -1
                unit["heading"] = (current_hdg + bank_sign * turn_rate) % 360
                unit["roll"] = bank_sign * min(35.0, abs(diff) * 1.5)

            # Move forward
            speed_mps = unit["speed_kts"] * 0.514444
            rad = math.radians(unit["heading"])
            unit["x"] += math.cos(rad) * speed_mps * dt
            unit["z"] += math.sin(rad) * speed_mps * dt

            # Slight altitude oscillation for realism
            unit["pitch"] = math.sin(now * 0.5 + unit["x"] * 0.001) * 2.0

            # Waypoint advancement
            if dist < 6000:
                unit["wp_index"] = (unit["wp_index"] + 1) % len(route)

        # Update active missiles
        surviving_missiles = []
        for m in self.active_missiles:
            m["life_seconds"] -= dt
            if m["life_seconds"] <= 0:
                continue

            target = next((u for u in self.simulated_units if u["id"] == m.get("target_id")), None)
            if target:
                tx, tz = target["x"], target["z"]
                dx = tx - m["x"]
                dz = tz - m["z"]
                m["heading"] = math.degrees(math.atan2(dz, dx)) % 360

            speed_mps = m["speed_kts"] * 0.514444
            rad = math.radians(m["heading"])
            m["x"] += math.cos(rad) * speed_mps * dt
            m["z"] += math.sin(rad) * speed_mps * dt
            surviving_missiles.append(m)

        self.active_missiles = surviving_missiles

        # Periodic engagement logic (spawn missile trail during dogfight)
        if len(self.active_missiles) < 2 and random.random() < 0.065 * dt:
            self._trigger_combat_missile_launch()

    def _trigger_combat_missile_launch(self):
        """Simulates an AIM-120D or R-27ER BVR launch between the CAP patrols."""
        shooter = self.simulated_units[0] if random.random() > 0.5 else self.simulated_units[4]
        target = self.simulated_units[4] if shooter["side"] == 2 else self.simulated_units[0]

        dx = target["x"] - shooter["x"]
        dz = target["z"] - shooter["z"]
        dist_km = math.hypot(dx, dz) / 1000.0

        if dist_km < 90.0:
            self.missile_counter += 1
            msl_type = "AIM-120D AMRAAM" if shooter["side"] == 2 else "R-27ER Alamo"
            self.active_missiles.append({
                "id": f"MSL-{self.missile_counter}",
                "type": msl_type,
                "side": shooter["side"],
                "shooter_id": shooter["id"],
                "target_id": target["id"],
                "x": shooter["x"],
                "z": shooter["z"],
                "alt": shooter["alt"] + 20,
                "heading": math.degrees(math.atan2(dz, dx)) % 360,
                "speed_kts": 1400.0,
                "life_seconds": 18.0
            })
            shooter["status"] = f"FOX-3 LAUNCH ({msl_type})"

    def get_tactical_state(self, replay_elapsed=None, *, replay_only=False) -> Dict[str, Any]:
        """Returns the full tactical picture for the 3D Tacview client."""
        now = time.time()
        live = None if replay_only else self.read_live(now)
        frame, age, playback, rendered_missiles = None, None, None, None
        telemetry_mode, live_status = 'sample', None
        waiting = self.campaign_only and not replay_only and live is None
        if live is not None:
            age, frame = live
            telemetry_mode, live_status = 'live', frame['flight_status']
            if live_status == 'delayed':
                data_source = 'DELAYED DCS · HOLDING LAST LIVE FRAME'
            elif frame.get('campaign'):
                data_source = 'LIVE DCS · BATTLEFRONT CAMPAIGN'
            elif self.campaign_only:
                data_source = 'LIVE DCS · AIRSPACE ONLY · CAMPAIGN DATA UNAVAILABLE'
            else:
                data_source = 'LIVE DCS · DEDICATED SERVER'
        elif waiting:
            telemetry_mode, live_status = 'live', 'waiting'
            data_source = 'WAITING FOR LIVE DCS · BATTLEFRONT CAMPAIGN'
        elif self.replay:
            telemetry_mode = 'replay'
            if len(self.replay_times) != len(self.replay):
                self.replay_times = [f['sim_time']-self.replay[0]['sim_time'] for f in self.replay]
                self.first_missile = next((t for t,f in zip(self.replay_times,self.replay) if f.get('missiles')),None)
            length = max(0.25, self.replay_times[-1] + 0.25)
            elapsed = (time.monotonic() - self.replay_start) if replay_elapsed is None else replay_elapsed
            cycle = int(elapsed / length)
            cursor = elapsed % length
            index = max(0,bisect_right(self.replay_times,cursor)-1)
            frame = self.replay[index]
            tails = {m['id']:[] for m in frame['missiles']}
            if tails:
                for prior in self.replay[max(0,index-40):index:2]:
                    for m in prior['missiles']:
                        if m['id'] in tails:
                            tails[m['id']].append([m['x'],m['z'],m['alt']])
                rendered_missiles = [{**m,'tail':tails[m['id']]} for m in frame['missiles']]
            playback = {'duration': length, 'cursor': cursor, 'first_missile': self.first_missile}
            data_source = 'RECORDED DCS · SERVER REPLAY'
        else:
            self.tick_simulation()
            data_source = 'SIMULATED · SAMPLE FLIGHTS'

        units = frame['units'] if frame else ([] if waiting else self.simulated_units)

        return {
            "timestamp": now,
            "data_source": data_source,
            "telemetry_mode": telemetry_mode,
            "live_status": live_status,
            "is_live_dcs": live is not None,
            "sample_age": age,
            "capture_timestamp": now - age if age is not None else None,
            "sim_time": frame['sim_time'] if frame else None,
            "frame_id": (f"{frame['session']}:{frame['seq']}" + (f':{cycle}' if not live else '')) if frame else None,
            "unit_count": len(units),
            "units": units,
            "missiles": rendered_missiles if rendered_missiles is not None else (frame.get('missiles', []) if frame else ([] if waiting else self.active_missiles)),
            "playback": playback,
            "campaign": frame.get('campaign') if live else None,
            "sectors_count": len(CAUCASUS_SECTOR_ANCHORS)
        }
