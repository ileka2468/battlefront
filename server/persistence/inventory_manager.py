import json
import os
import time
from typing import Dict, Any, Optional

DB_PATH = os.path.join(os.path.dirname(__file__), "global_players.json")

class InventoryManager:
    def __init__(self, db_path: str = DB_PATH):
        self.db_path = db_path
        self._ensure_db()

    def _ensure_db(self):
        if not os.path.exists(self.db_path):
            os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
            default_data = {
                "currency_name": "Combat Merits",
                "currency_symbol": "CM",
                "points_config": {"a2a_kill": 2, "a2g_kill": 1, "base_capture": 3},
                "munition_catalog": {},
                "players": {},
                "marketplace": [],
                "trade_history": []
            }
            self.save_data(default_data)

    def load_data(self) -> Dict[str, Any]:
        with open(self.db_path, "r", encoding="utf-8") as f:
            return json.load(f)

    def save_data(self, data: Dict[str, Any]):
        with open(self.db_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)

    def get_player(self, player_id: str) -> Dict[str, Any]:
        data = self.load_data()
        if player_id not in data["players"]:
            data["players"][player_id] = {
                "callsign": player_id,
                "name": player_id.capitalize(),
                "side": 2,
                "points": 4, # Calibrated Starter Combat Merits
                "stats": {"a2a_kills": 0, "a2g_kills": 0, "sorties": 0, "losses": 0},
                "inventory": {}
            }
            self.save_data(data)

        return data["players"][player_id]

    def award_kill(self, player_id: str, kill_type: str) -> Dict[str, Any]:
        self.get_player(player_id) # ensure exists and persists in database first
        data = self.load_data()
        player = data["players"][player_id]

        points_awarded = data["points_config"].get(kill_type, 1)
        player["points"] += points_awarded
        if kill_type == "a2a_kill":
            player["stats"]["a2a_kills"] = player["stats"].get("a2a_kills", 0) + 1
        elif kill_type == "a2g_kill":
            player["stats"]["a2g_kills"] = player["stats"].get("a2g_kills", 0) + 1
        elif kill_type == "datalink_assist":
            player["stats"]["datalink_assists"] = player["stats"].get("datalink_assists", 0) + 1

        self.save_data(data)
        return {
            "player_id": player_id,
            "awarded": points_awarded,
            "new_balance": player["points"],
            "kill_type": kill_type
        }

    def award_assist(self, player_id: str, assist_type: str = "datalink_assist") -> Dict[str, Any]:
        self.get_player(player_id)
        data = self.load_data()
        player = data["players"][player_id]

        points_awarded = data.get("points_config", {}).get(assist_type, 1)
        player["points"] += points_awarded
        player["stats"]["datalink_assists"] = player["stats"].get("datalink_assists", 0) + 1

        self.save_data(data)
        return {
            "player_id": player_id,
            "awarded": points_awarded,
            "new_balance": player["points"],
            "assist_type": assist_type,
            "total_assists": player["stats"]["datalink_assists"]
        }

    def buy_munition(self, player_id: str, munition_key: str) -> Dict[str, Any]:
        self.get_player(player_id)
        data = self.load_data()
        player = data["players"][player_id]

        catalog = data.get("munition_catalog", {})
        if munition_key not in catalog:
            return {"success": False, "error": f"Munition '{munition_key}' not found in catalog."}

        cost = catalog[munition_key]["cost_points"]
        if player["points"] < cost:
            return {
                "success": False,
                "error": f"Insufficient Combat Merits. Required: {cost} CM, Available: {player['points']} CM."
            }

        player["points"] -= cost
        player["inventory"][munition_key] = player["inventory"].get(munition_key, 0) + 1
        self.save_data(data)

        return {
            "success": True,
            "munition": munition_key,
            "cost": cost,
            "new_balance": player["points"],
            "inventory": player["inventory"]
        }

    def list_for_sale(self, seller_id: str, munition_key: str, quantity: int, price_points: int) -> Dict[str, Any]:
        if quantity <= 0:
            return {"success": False, "error": "Listing quantity must be greater than zero."}
        if price_points <= 0:
            return {"success": False, "error": "Listing price must be greater than zero."}

        self.get_player(seller_id)
        data = self.load_data()
        seller = data["players"][seller_id]

        owned = seller["inventory"].get(munition_key, 0)
        if owned < quantity:
            return {"success": False, "error": f"Insufficient stock. You own {owned}x {munition_key}."}

        # Deduct from inventory to escrow
        seller["inventory"][munition_key] -= quantity
        if seller["inventory"][munition_key] <= 0:
            del seller["inventory"][munition_key]

        listing_id = f"trade_{int(time.time())}_{len(data['marketplace']) + 1}"
        listing = {
            "id": listing_id,
            "seller": seller_id,
            "seller_callsign": seller.get("callsign", seller_id),
            "item": munition_key,
            "quantity": quantity,
            "price_points": price_points,
            "created_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "status": "active"
        }
        data["marketplace"].append(listing)
        self.save_data(data)

        return {"success": True, "listing": listing}

    def buy_from_market(self, buyer_id: str, listing_id: str) -> Dict[str, Any]:
        data = self.load_data()
        self.get_player(buyer_id)
        buyer = data["players"][buyer_id]

        listing = None
        for item in data["marketplace"]:
            if item["id"] == listing_id and item["status"] == "active":
                listing = item
                break

        if not listing:
            return {"success": False, "error": "Listing not found or already sold."}

        if listing["seller"] == buyer_id:
            return {"success": False, "error": "Cannot purchase your own listing."}

        total_price = listing["price_points"]
        if buyer["points"] < total_price:
            return {"success": False, "error": f"Insufficient points. Required: {total_price} CM."}

        # Transfer points
        buyer["points"] -= total_price
        seller = data["players"].get(listing["seller"])
        if seller:
            seller["points"] += total_price

        # Transfer items
        item_key = listing["item"]
        buyer["inventory"][item_key] = buyer["inventory"].get(item_key, 0) + listing["quantity"]
        listing["status"] = "sold"

        # Record trade
        trade_record = {
            "id": listing_id,
            "buyer": buyer_id,
            "seller": listing["seller"],
            "item": item_key,
            "quantity": listing["quantity"],
            "price_points": total_price,
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S")
        }
        data.setdefault("trade_history", []).insert(0, trade_record)

        self.save_data(data)
        return {"success": True, "trade": trade_record, "new_balance": buyer["points"]}
