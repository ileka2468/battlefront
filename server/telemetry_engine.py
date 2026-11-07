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


    def tick_simulation(self):
        pass
