"""Thin, defensive client for the public DexScreener HTTP API.

DexScreener does not publish an official SDK and its public endpoints can
change without notice, so every parse here is defensive (`.get` with
fallbacks) rather than assuming a fixed schema.
"""
from __future__ import annotations

import logging
from typing import Any

import requests
from tenacity import retry, stop_after_attempt, wait_exponential

logger = logging.getLogger(__name__)

BASE_URL = "https://api.dexscreener.com"


class DexScreenerClient:
    def __init__(self, timeout: float = 10.0):
        self.timeout = timeout
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": "dex-trend-bot/1.0"})

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=1, max=8))
    def _get(self, path: str, params: dict | None = None) -> Any:
        resp = self.session.get(f"{BASE_URL}{path}", params=params, timeout=self.timeout)
        resp.raise_for_status()
        return resp.json()

    def search_pairs(self, query: str) -> list[dict]:
        try:
            data = self._get("/latest/dex/search", params={"q": query})
            return data.get("pairs") or []
        except Exception:
            logger.exception("DexScreener search_pairs failed for %r", query)
            return []

    def get_token_pairs(self, chain_id: str, token_address: str) -> list[dict]:
        try:
            data = self._get(f"/token-pairs/v1/{chain_id}/{token_address}")
            return data if isinstance(data, list) else data.get("pairs", [])
        except Exception:
            logger.exception("DexScreener get_token_pairs failed for %s/%s", chain_id, token_address)
            return []

    def get_pair(self, chain_id: str, pair_id: str) -> dict | None:
        try:
            data = self._get(f"/latest/dex/pairs/{chain_id}/{pair_id}")
            pairs = data.get("pairs") or []
            return pairs[0] if pairs else None
        except Exception:
            logger.exception("DexScreener get_pair failed for %s/%s", chain_id, pair_id)
            return None

    def get_boosted_tokens(self) -> list[dict]:
        """Tokens currently paying for a DexScreener boost — a cheap proxy
        for 'popular right now' used to widen the scan universe."""
        try:
            data = self._get("/token-boosts/latest/v1")
            return data if isinstance(data, list) else []
        except Exception:
            logger.exception("DexScreener get_boosted_tokens failed")
            return []


def normalize_pair(pair: dict) -> dict:
    """Flatten the nested DexScreener pair payload into the fields the
    strategy/filters actually use, with safe numeric defaults."""

    def f(*path, default=0.0):
        node = pair
        for key in path:
            if not isinstance(node, dict):
                return default
            node = node.get(key)
        try:
            return float(node) if node is not None else default
        except (TypeError, ValueError):
            return default

    txns_h1 = (pair.get("txns") or {}).get("h1", {}) or {}
    return {
        "chain_id": pair.get("chainId", ""),
        "pair_address": pair.get("pairAddress", ""),
        "dex_id": pair.get("dexId", ""),
        "base_symbol": (pair.get("baseToken") or {}).get("symbol", ""),
        "base_address": (pair.get("baseToken") or {}).get("address", ""),
        "price_usd": f("priceUsd"),
        "price_change_5m": f("priceChange", "m5"),
        "price_change_1h": f("priceChange", "h1"),
        "price_change_6h": f("priceChange", "h6"),
        "price_change_24h": f("priceChange", "h24"),
        "liquidity_usd": f("liquidity", "usd"),
        "volume_24h": f("volume", "h24"),
        "volume_1h": f("volume", "h1"),
        "buys_1h": int(txns_h1.get("buys", 0) or 0),
        "sells_1h": int(txns_h1.get("sells", 0) or 0),
        "fdv": f("fdv"),
        "pair_created_at_ms": pair.get("pairCreatedAt", 0) or 0,
        "url": pair.get("url", ""),
    }
