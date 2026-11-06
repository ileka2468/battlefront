import json
import os
import time
from typing import Dict, Any, Optional, List

STATE_JSON_PATH = os.path.join(os.path.dirname(__file__), "campaign_state.json")

AIRFRAME_UPGRADE_CATALOG = {
    # BLUFOR Airframes
    "F-23A": {
        "name": "F-23A Spectre",
        "coalition": 2,
        "coalition_name": "BLUFOR",
        "role": "5th-Gen Stealth Interceptor",
        "base_blueprint": "F-23A",
        "track1": {
            "id": "F23A_T1",
            "title": "YF120 Variable-Cycle Turbofans",
            "cost": 800,
            "category": "Kinematics / Propulsion",
            "description": "High-altitude sustained Mach 1.8+ supercruise without afterburner and ultra-low thermal IR exhaust signature."
        },
        "track2": {
            "id": "F23A_T2",
            "title": "Deep Internal Bay JATM & Long-Range Fox-3",
            "cost": 850,
            "category": "Weapons Suite / BVR",
            "description": "Internal 6-missile AIM-260 JATM carriage & CEC airborne datalink forward-pass integration."
        }
    },
    "F-22A": {
        "name": "F-22A Raptor",
        "coalition": 2,
        "coalition_name": "BLUFOR",
        "role": "5th-Gen Air Dominance",
        "base_blueprint": "F-22A",
        "track1": {
            "id": "F22A_T1",
            "title": "Supercruise Thermal Profile",
            "cost": 750,
            "category": "Kinematics / Stealth",
            "description": "Reduced IR signature at military thrust and extended supersonic persistence without afterburner."
        },
        "track2": {
            "id": "F22A_T2",
            "title": "Internal Bay SDB Standoff Rack",
            "cost": 800,
            "category": "Weapons Suite / Standoff",
            "description": "Internal 8-rack GBU-39 Small Diameter Bombs for surgical strikes without compromising radar cross section."
        }
    },
    "F-117A": {
        "name": "F-117A Nighthawk",
        "coalition": 2,
        "coalition_name": "BLUFOR",
        "role": "Tactical Stealth Strike",
        "base_blueprint": "F-117-NightHawk",
        "track1": {
            "id": "F117A_T1",
            "title": "Modernized DLIR/FLIR Avionics",
            "cost": 400,
            "category": "Avionics / Sensors",
            "description": "Enhanced high-definition thermal targeting sensor and precision GPS/INS navigation."
        },
        "track2": {
            "id": "F117A_T2",
            "title": "GBU-27 Paveway III Penetrator Suite",
            "cost": 500,
            "category": "Weapons Suite / Bunker Buster",
            "description": "Hardened penetration warheads specifically tuned to destroy Level 3 industrial refineries and bunkers."
        }
    },
    "A-4E-C": {
        "name": "A-4E-C Skyhawk",
        "coalition": 2,
        "coalition_name": "BLUFOR",
        "role": "Light Attack / Forward CAS",
        "base_blueprint": "A-4E-C",
        "track1": {
            "id": "A4EC_T1",
            "title": "J52-P-408 High-Thrust Turbine",
            "cost": 150,
            "category": "Kinematics / Propulsion",
            "description": "Higher climb rates, short-field tactical takeoff, and increased combat ordnance ceiling."
        },
        "track2": {
            "id": "A4EC_T2",
            "title": "Shrike SEAD & Walleye TV Glider",
            "cost": 200,
            "category": "Weapons Suite / SEAD & PGM",
            "description": "AGM-45 Shrike anti-radiation missiles & AGM-62 Walleye TV stand-off precision strike."
        }
    },
    "AH-64D": {
        "name": "AH-64D Apache Longbow",
        "coalition": 2,
        "coalition_name": "BLUFOR",
        "role": "Attack Helicopter",
        "base_blueprint": "AH-64D",
        "track1": {
            "id": "AH64D_T1",
            "title": "Longbow Fire Control Radar",
            "cost": 350,
            "category": "Avionics / Radar Mast",
            "description": "Mast-mounted APG-78 FCR radar + AGM-114L fire-and-forget radar Hellfires."
        },
        "track2": {
            "id": "AH64D_T2",
            "title": "Stinger Air-to-Air Defense",
            "cost": 250,
            "category": "Weapons Suite / AAM Defense",
            "description": "ATAS Air-to-Air Stingers + APKWS laser-guided rockets for hunting enemy helicopters."
        }
    },
    "UH-60L": {
        "name": "UH-60L Black Hawk",
        "coalition": 2,
        "coalition_name": "BLUFOR",
        "role": "Tactical Assault & Logistics Transport",
        "base_blueprint": "UH-60L",
        "track1": {
            "id": "UH60L_T1",
            "title": "High-Altitude Turbines & Ext. Tanks",
            "cost": 100,
            "category": "Kinematics / Range",
            "description": "Expanded combat radius and rapid high-altitude mountain transit speed."
        },
        "track2": {
            "id": "UH60L_T2",
            "title": "Fast-Rope Insertion & Heavy Winch",
            "cost": 150,
            "category": "Utility / Fortification",
            "description": "Cuts fortification drop time at captured sector LZs in half and adds automatic flare dispensers."
        }
    },

    # REDFOR Airframes
    "Su-57": {
        "name": "Su-57 Felon",
        "coalition": 1,
        "coalition_name": "REDFOR",
        "role": "5th-Gen Multi-Role Stealth",
        "base_blueprint": "Su-57",
        "track1": {
            "id": "SU57_T1",
            "title": "Izdeliye 30 5th-Gen Turbofans",
            "cost": 850,
            "category": "Kinematics / 3D Thrust Vectoring",
            "description": "Enhanced supercruise thrust profile and extreme 3D thrust vectoring agility."
        },
        "track2": {
            "id": "SU57_T2",
            "title": "Internal Hypersonic & SEAD",
            "cost": 900,
            "category": "Weapons Suite / Standoff & VVLRAAM",
            "description": "Kh-59MK2 stealth standoff cruise missile & internal R-37M long-range interceptor carriage."
        }
    },
    "J-20A": {
        "name": "J-20A Mighty Dragon",
        "coalition": 1,
        "coalition_name": "REDFOR",
        "role": "5th-Gen Heavy Stealth Interceptor",
        "base_blueprint": "J-20A",
        "track1": {
            "id": "J20A_T1",
            "title": "WS-15 Turbofans & 4K RAM Coating",
            "cost": 750,
            "category": "Kinematics / VLO Stealth",
            "description": "Supercruise thrust profile and optimized radar-absorbent skin for superior stealth."
        },
        "track2": {
            "id": "J20A_T2",
            "title": "Dual-Pulse BVR & Standoff Glide",
            "cost": 800,
            "category": "Weapons Suite / Dual-Pulse Fox-3",
            "description": "PL-15 active radar AAM + LS-6 satellite-guided standoff glide bombs."
        }
    },
    "Su-35S": {
        "name": "Su-35S Flanker-E",
        "coalition": 1,
        "coalition_name": "REDFOR",
        "role": "Super-Maneuverable Air Superiority",
        "base_blueprint": "Su-35S",
        "track1": {
            "id": "SU35S_T1",
            "title": "High-Output Afterburner",
            "cost": 500,
            "category": "Kinematics / Maneuverability",
            "description": "Increases sustained dry/wet thrust and corner speed under heavy combat payloads."
        },
        "track2": {
            "id": "SU35S_T2",
            "title": "Cockpit Weapon System (CWS) Suite",
            "cost": 650,
            "category": "Avionics / Multi-Role PGM",
            "description": "Full MFD integration for Kh-31P anti-radiation, Kh-29T TV missiles, and KAB precision glide bombs."
        }
    },
    "Su-30SM": {
        "name": "Su-30SM Flanker",
        "coalition": 1,
        "coalition_name": "REDFOR",
        "role": "Multi-Role Strike Fighter",
        "base_blueprint": "Su-30SM",
        "track1": {
            "id": "SU30_T1",
            "title": "Su-30SM 3D Thrust Vectoring",
            "cost": 500,
            "category": "Kinematics / Supermaneuverability",
            "description": "Supermaneuverable dogfighting package with pitch/yaw thrust vector nozzles."
        },
        "track2": {
            "id": "SU30_T2",
            "title": "Heavy Standoff & Maritime Strike",
            "cost": 650,
            "category": "Weapons Suite / Anti-Ship & Cruise",
            "description": "Kh-31A supersonic anti-ship & Kh-59ME heavy standoff cruise missile integration."
        }
    },
    "Su-34": {
        "name": "Su-34 Fullback",
        "coalition": 1,
        "coalition_name": "REDFOR",
        "role": "Heavy Tactical Strike Bomber",
        "base_blueprint": "Su-34",
        "track1": {
            "id": "SU34_T1",
            "title": "Shpital Rear-Facing Radar",
            "cost": 550,
            "category": "Avionics / Defensive Radar",
            "description": "Rear-aspect missile warning radar and rearward-firing R-73/R-77 defensive capability."
        },
        "track2": {
            "id": "SU34_T2",
            "title": "Bunker Buster & Penetrators",
            "cost": 700,
            "category": "Weapons Suite / Hardened Penetrators",
            "description": "Heavy KAB-1500 laser/satellite penetrators and Kh-59MK2 cruise missiles for Level 3 C2 fortresses."
        }
    },
    "Ka-50-3": {
        "name": "Ka-50-3 Black Shark III",
        "coalition": 1,
        "coalition_name": "REDFOR",
        "role": "All-Weather Attack Helicopter",
        "base_blueprint": "Ka-50_3",
        "track1": {
            "id": "KA50_T1",
            "title": "President-S DIRCM Suite",
            "cost": 350,
            "category": "Avionics / Countermeasures",
            "description": "Directional Infrared Countermeasures jammer to defeat incoming MANPADS and heat-seeking missiles."
        },
        "track2": {
            "id": "KA50_T2",
            "title": "Igla-V & Long-Range Vikhr",
            "cost": 250,
            "category": "Weapons Suite / AAM & Long-Range ATGM",
            "description": "Igla-V air-to-air missile racks + extended-range AT-16 Vikhr anti-armor missiles."
        }
    }
}

class CampaignManager:
    def __init__(self, state_path: str = STATE_JSON_PATH):
        self.state_path = state_path
        self._ensure_state()

    def _default_state(self) -> Dict[str, Any]:
        return {
            "total_objectives": 21,
            "mvi_threshold_million": 80,         # Minimum Viable Income ($80M/hour)
            "solvency_threshold_million": 300,   # Treasury required to cancel collapse ($300M)
            "collapse_duration_seconds": 2700,   # 45 Minutes
            "victory": {
                "won": False,
                "winner_side": None,
                "victory_type": None,             # "TERRITORIAL" or "ECONOMIC"
                "victory_message": None,
                "victory_timestamp": None
            },
            "coalitions": {
                "2": {
                    "name": "BLUFOR",
                    "treasury": 1000,
                    "hourly_income": 264,
                    "controlled_sectors": 11,
                    "in_collapse": False,
                    "collapse_remaining_seconds": 2700,
                    "collapse_started_at": None,
                    "human_commander": None,
                    "human_commander_expires": 0
                },
                "1": {
                    "name": "REDFOR",
                    "treasury": 1000,
                    "hourly_income": 240,
                    "controlled_sectors": 10,
                    "in_collapse": False,
                    "collapse_remaining_seconds": 2700,
                    "collapse_started_at": None,
                    "human_commander": None,
                    "human_commander_expires": 0
                }
            },
            "sectors": [
                {"id": 101, "name": "Krasnodar Silicon Fab", "quadrant": "NW", "side": 1, "status": "DEFENDED", "income": 2.5, "level": 1},
                {"id": 102, "name": "Novorossiysk Oil Refinery", "quadrant": "NW", "side": 1, "status": "DEFENDED", "income": 3.0, "level": 1},
                {"id": 103, "name": "Krymsk Airfield Base", "quadrant": "NW", "side": 1, "status": "DEFENDED", "income": 2.0, "level": 1},
                {"id": 104, "name": "Anapa Marine Fuel Terminal", "quadrant": "NW", "side": 1, "status": "DEFENDED", "income": 2.0, "level": 1},
                {"id": 105, "name": "Slavyansk Chemical & Propellant Plant", "quadrant": "NW", "side": 1, "status": "DEFENDED", "income": 2.0, "level": 1},
                {"id": 106, "name": "Armavir Metallurgy Complex", "quadrant": "NE", "side": 1, "status": "DEFENDED", "income": 2.5, "level": 1},
                {"id": 107, "name": "Maykop Aerospace Center", "quadrant": "NE", "side": 1, "status": "DEFENDED", "income": 2.5, "level": 1},
                {"id": 108, "name": "Nalchik C2 Fortress", "quadrant": "NE", "side": 1, "status": "DEFENDED", "income": 2.0, "level": 1},
                {"id": 109, "name": "Mineralnye Vody Forward FARP", "quadrant": "NE", "side": 1, "status": "DEFENDED", "income": 1.5, "level": 1},
                {"id": 110, "name": "Mozdok Strategic Bomber Hub", "quadrant": "NE", "side": 1, "status": "DEFENDED", "income": 2.0, "level": 1},
                {"id": 111, "name": "Sochi Strategic Harbor", "quadrant": "SW", "side": 2, "status": "DEFENDED", "income": 2.5, "level": 1},
                {"id": 112, "name": "Sukhumi Munitions Plant", "quadrant": "SW", "side": 2, "status": "DEFENDED", "income": 2.5, "level": 1},
                {"id": 113, "name": "Gudauta Forward Staging Strip", "quadrant": "SW", "side": 2, "status": "DEFENDED", "income": 2.0, "level": 1},
                {"id": 114, "name": "Gagra Coastal Defense Outpost", "quadrant": "SW", "side": 2, "status": "DEFENDED", "income": 1.5, "level": 1},
                {"id": 115, "name": "Adler High-Tech Sensor Lab", "quadrant": "SW", "side": 2, "status": "DEFENDED", "income": 2.0, "level": 1},
                {"id": 116, "name": "Poti Deepwater Refinery", "quadrant": "SE", "side": 2, "status": "DEFENDED", "income": 3.0, "level": 1},
                {"id": 117, "name": "Kutaisi Silicon & Avionics Fab", "quadrant": "SE", "side": 2, "status": "DEFENDED", "income": 2.5, "level": 1},
                {"id": 118, "name": "Batumi Metallurgy Drydocks", "quadrant": "SE", "side": 2, "status": "DEFENDED", "income": 2.0, "level": 1},
                {"id": 119, "name": "Kobuleti Stealth Skunkworks", "quadrant": "SE", "side": 2, "status": "DEFENDED", "income": 2.5, "level": 1},
                {"id": 120, "name": "Tskhaltubo Joint C2 Complex", "quadrant": "SE", "side": 2, "status": "DEFENDED", "income": 2.0, "level": 1},
                {"id": 121, "name": "Senaki-Kolkhi Airbase", "quadrant": "SE", "side": 2, "status": "DEFENDED", "income": 2.0, "level": 1}
            ],
            "operations": {
                "2": {
                    "id": "op_blue_1",
                    "name": "Operation Iron Hammer",
                    "target_sector": "Novorossiysk Oil Refinery",
                    "target_quadrant": "NW",
                    "mission_type": "Strategic Industrial Strike",
                    "coordinator": "AI Tactical Command",
                    "frequency": "251.000 MHz UHF",
                    "objective_desc": "Target hostile catalytic cracking towers to cripple REDFOR fuel reserves and drive enemy below Minimum Viable Income.",
                    "status": "RECRUITING",
                    "slots": [
                        {"role": "STRIKE", "role_title": "Lead Strike Bomber", "airframes": "F-117A / FA-18C", "pilot": "Ghost_Lead", "status": "CLAIMED"},
                        {"role": "STRIKE", "role_title": "Secondary Strike", "airframes": "F-16C / A-4E", "pilot": None, "status": "OPEN"},
                        {"role": "ESCORT", "role_title": "Fighter Sweep / High Escort", "airframes": "F-15C / F-22A", "pilot": "Viper_One", "status": "CLAIMED"},
                        {"role": "ESCORT", "role_title": "Close Barrier CAP", "airframes": "F-14BU / F-23A", "pilot": None, "status": "OPEN"},
                        {"role": "SEAD", "role_title": "Air Defense Suppression", "airframes": "F-16C / FA-18C (HARM)", "pilot": None, "status": "OPEN"},
                        {"role": "LOGISTICS", "role_title": "Consolidation Transport", "airframes": "C-130 Hercules / UH-60L", "pilot": None, "status": "OPEN"}
                    ]
                },
                "1": {
                    "id": "op_red_1",
                    "name": "Operation Black Tide",
                    "target_sector": "Poti Deepwater Refinery",
                    "target_quadrant": "SE",
                    "mission_type": "Strategic Industrial Strike",
                    "coordinator": "AI Tactical Command",
                    "frequency": "252.000 MHz UHF",
                    "objective_desc": "Sever BLUFOR Black Sea fuel supply infrastructure to induce immediate industrial insolvency.",
                    "status": "RECRUITING",
                    "slots": [
                        {"role": "STRIKE", "role_title": "Precision Penetration Strike", "airframes": "Su-34 / Su-25T", "pilot": "Foxhound_01", "status": "CLAIMED"},
                        {"role": "STRIKE", "role_title": "Heavy Standoff Strike", "airframes": "MiG-31K (Kinzhal) / Su-34", "pilot": None, "status": "OPEN"},
                        {"role": "ESCORT", "role_title": "Air Superiority Escort", "airframes": "Su-57 / Su-35S", "pilot": None, "status": "OPEN"},
                        {"role": "ESCORT", "role_title": "Long-Range Intercept", "airframes": "MiG-31BM (R-37M) / J-20A", "pilot": None, "status": "OPEN"},
                        {"role": "SEAD", "role_title": "Radar Suppression (Kh-31P)", "airframes": "Su-30SM / JF-17", "pilot": None, "status": "OPEN"},
                        {"role": "LOGISTICS", "role_title": "Air Assault & Cargo", "airframes": "Mi-8MT / Ka-50-3 / C-130", "pilot": None, "status": "OPEN"}
                    ]
                }
            }
        }

    def _ensure_state(self):
        if not os.path.exists(self.state_path):
            os.makedirs(os.path.dirname(self.state_path), exist_ok=True)
            self.save_state(self._default_state())

    def _sync_with_dcs_lua(self, state: Dict[str, Any]) -> Dict[str, Any]:
        lua_path = os.environ.get("DCS_STATE_LUA_PATH", "/home/dcs/.wine/drive_c/DCS_configs/DCS.server1/Scripts/battlefront_campaign_state.lua")
        if not os.path.exists(lua_path):
            return state
        try:
            with open(lua_path, "r", encoding="utf-8", errors="ignore") as f:
                content = f.read()
            import re
            for side_str, treas_str in re.findall(r'\[(\d+)\]\s*=\s*\{\s*treasury\s*=\s*([\d\.]+)', content):
                if side_str in state["coalitions"]:
                    state["coalitions"][side_str]["treasury"] = float(treas_str)
            sec_matches = re.findall(r'\["([^"]+)"\]\s*=\s*\{\s*side\s*=\s*(\d+),\s*level\s*=\s*(\d+),\s*status\s*=\s*"([^"]+)"', content)
            if sec_matches:
                sec_dict = {name: (int(side), int(lvl), stat) for name, side, lvl, stat in sec_matches}
                blue_cnt = 0
                red_cnt = 0
                for sec in state.get("sectors", []):
                    if sec["name"] in sec_dict:
                        s, l, st = sec_dict[sec["name"]]
                        sec["side"] = s
                        sec["level"] = l
                        sec["status"] = st
                    if sec.get("side") == 2:
                        blue_cnt += 1
                    elif sec.get("side") == 1:
                        red_cnt += 1
                state["coalitions"]["2"]["controlled_sectors"] = blue_cnt
                state["coalitions"]["1"]["controlled_sectors"] = red_cnt
        except Exception:
            pass
        return state

    def load_state(self) -> Dict[str, Any]:
        with open(self.state_path, "r", encoding="utf-8") as f:
            state = json.load(f)
        return self._sync_with_dcs_lua(state)


    def save_state(self, state: Dict[str, Any]):
        with open(self.state_path, "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)

