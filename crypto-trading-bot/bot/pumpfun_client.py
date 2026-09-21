"""Client for pump.fun's unofficial public API.

pump.fun does not publish a stable/versioned API contract; endpoints and
field names have moved before and may move again. Every call here fails
soft (returns an empty result and logs) so one broken endpoint degrades
the scan instead of crashing the bot — treat this client as best-effort
and re-verify the endpoints in `BASE_URL` if scans stop returning data.
"""
from __future__ import annotations

import logging
from typing import Any

import requests
from tenacity import retry, stop_after_attempt, wait_exponential

logger = logging.getLogger(__name__)

BASE_URL = "https://frontend-api-v3.pump.fun"


class PumpFunClient:
    def __init__(self, timeout: float = 10.0):
        self.timeout = timeout
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": "pumpfun-scan-bot/1.0", "Accept": "application/json"})

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=1, max=6))
    def _get(self, path: str, params: dict | None = None) -> Any:
        resp = self.session.get(f"{BASE_URL}{path}", params=params, timeout=self.timeout)
        resp.raise_for_status()
        return resp.json()

    def list_new_coins(self, limit: int = 50) -> list[dict]:
        try:
            data = self._get(
                "/coins",
                params={"offset": 0, "limit": limit, "sort": "created_timestamp", "order": "DESC", "includeNsfw": "false"},
            )
            return data if isinstance(data, list) else data.get("coins", [])
        except Exception:
            logger.exception("pump.fun list_new_coins failed")
            return []

    def list_trending_coins(self, limit: int = 50) -> list[dict]:
        try:
            data = self._get(
                "/coins",
                params={"offset": 0, "limit": limit, "sort": "market_cap", "order": "DESC", "includeNsfw": "false"},
            )
            return data if isinstance(data, list) else data.get("coins", [])
        except Exception:
            logger.exception("pump.fun list_trending_coins failed")
            return []

    def get_coin(self, mint: str) -> dict | None:
        try:
            return self._get(f"/coins/{mint}")
        except Exception:
            logger.exception("pump.fun get_coin failed for %s", mint)
            return None


def normalize_coin(coin: dict) -> dict:
    def f(key, default=0.0):
        try:
            return float(coin.get(key)) if coin.get(key) is not None else default
        except (TypeError, ValueError):
            return default

    def i(key, default=0):
        try:
            return int(coin.get(key)) if coin.get(key) is not None else default
        except (TypeError, ValueError):
            return default

    return {
        "mint": coin.get("mint", ""),
        "name": coin.get("name", "") or "",
        "symbol": coin.get("symbol", "") or "",
        "creator": coin.get("creator", ""),
        "market_cap_usd": f("usd_market_cap"),
        "market_cap_sol": f("market_cap"),
        "reply_count": i("reply_count"),
        "holder_count": i("holder_count") or i("num_holders"),
        "created_timestamp_ms": i("created_timestamp"),
        "complete": bool(coin.get("complete", False)),
        "king_of_the_hill_timestamp": coin.get("king_of_the_hill_timestamp"),
        "twitter": coin.get("twitter") or "",
        "telegram": coin.get("telegram") or "",
        "website": coin.get("website") or "",
        "image_uri": coin.get("image_uri") or "",
        "description": coin.get("description") or "",
        "associated_bonding_curve": coin.get("associated_bonding_curve", ""),
        "raydium_pool": coin.get("raydium_pool"),
    }
