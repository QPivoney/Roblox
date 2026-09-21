"""Polls DexScreener for candidate pairs, records price history, and drives
the trend-confluence strategy + risk manager + executor to open/manage
paper (or live) positions."""
from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime, timezone

from .data_recorder import DataRecorder
from .dexscreener_client import DexScreenerClient, normalize_pair
from .executor import Executor
from .notifier import Notifier
from .portfolio import Portfolio, Position
from .risk_manager import RiskManager
from .strategy_dexscreener import TrendConfluenceStrategy

logger = logging.getLogger(__name__)


class DexScreenerScanner:
    def __init__(
        self, *, client: DexScreenerClient, recorder: DataRecorder, strategy: TrendConfluenceStrategy,
        risk: RiskManager, portfolio: Portfolio, executor: Executor, notifier: Notifier,
        chains, min_liquidity_usd: float, min_volume_24h_usd: float,
        min_pair_age_hours: float, position_size_usd: float, poll_interval_seconds: int,
        watchlist_queries=("SOL", "ETH", "BASE"),
    ):
        self.client = client
        self.recorder = recorder
        self.strategy = strategy
        self.risk = risk
        self.portfolio = portfolio
        self.executor = executor
        self.notifier = notifier
        self.chains = {c.strip().lower() for c in chains}
        self.min_liquidity_usd = min_liquidity_usd
        self.min_volume_24h_usd = min_volume_24h_usd
        self.min_pair_age_hours = min_pair_age_hours
        self.position_size_usd = position_size_usd
        self.poll_interval_seconds = poll_interval_seconds
        self.watchlist_queries = watchlist_queries

    def _passes_hard_filters(self, pair: dict) -> bool:
        if pair["chain_id"] not in self.chains:
            return False
        if pair["liquidity_usd"] < self.min_liquidity_usd:
            return False
        if pair["volume_24h"] < self.min_volume_24h_usd:
            return False
        age_hours = (time.time() * 1000 - pair["pair_created_at_ms"]) / 3_600_000 if pair["pair_created_at_ms"] else 0
        if age_hours < self.min_pair_age_hours:
            return False
        return True

    def _candidate_pairs(self) -> list:
        seen: dict[str, dict] = {}
        for boosted in self.client.get_boosted_tokens():
            token_address = boosted.get("tokenAddress")
            chain_id = boosted.get("chainId", "")
            if not token_address:
                continue
            for pair in self.client.get_token_pairs(chain_id, token_address):
                np = normalize_pair(pair)
                if np["pair_address"]:
                    seen[np["pair_address"]] = np
        for q in self.watchlist_queries:
            for pair in self.client.search_pairs(q):
                np = normalize_pair(pair)
                if np["pair_address"]:
                    seen[np["pair_address"]] = np
        return [p for p in seen.values() if self._passes_hard_filters(p)]

    def _manage_open_position(self, pair: dict) -> None:
        token_key = pair["pair_address"]
        pos = self.portfolio.positions.get(token_key)
        if not pos:
            return
        price = pair["price_usd"]
        if price <= 0:
            return

        if price <= pos.stop_price:
            fill = self.executor.sell(price=price, quantity=pos.quantity, liquidity_usd=pair["liquidity_usd"])
            trade = self.portfolio.close_position(token_key, fill.price, "stop loss")
            if trade:
                self.risk.record_trade_result(token_key, trade.pnl_usd)
                self.notifier.send(f"\U0001F6D1 Stopped out {pair['base_symbol']} pnl=${trade.pnl_usd:.2f}")
            return

        for target_price, fraction in pos.take_profit_levels:
            if target_price in pos.filled_targets or pos.quantity <= 0:
                continue
            if price >= target_price:
                qty = min(pos.original_quantity * fraction, pos.quantity)
                fill = self.executor.sell(price=price, quantity=qty, liquidity_usd=pair["liquidity_usd"])
                self.portfolio.reduce_position(token_key, fill.quantity, fill.price, f"take-profit @ {target_price:.6f}")
                pos.filled_targets.add(target_price)
                self.notifier.send(f"\U0001F3AF Took profit on {pair['base_symbol']} at {target_price:.6f}")

        if token_key not in self.portfolio.positions:
            return  # fully closed via the take-profit ladder above

        r = pos.r_multiple(price)
        if r >= 1.0:
            new_trail = price - self.strategy.atr_trail_multiplier * max(price - pos.entry_price, price * 0.02)
            candidate = max(pos.trailing_stop_price or pos.stop_price, new_trail, pos.entry_price)
            pos.trailing_stop_price = candidate
            pos.stop_price = max(pos.stop_price, candidate)

        history = self.recorder.history_df(token_key)
        if len(history) >= self.strategy.min_bars:
            exit_signal = self.strategy.evaluate_exit(history)
            if exit_signal.action == "exit":
                fill = self.executor.sell(price=price, quantity=pos.quantity, liquidity_usd=pair["liquidity_usd"])
                trade = self.portfolio.close_position(token_key, fill.price, "confluence breakdown")
                if trade:
                    self.risk.record_trade_result(token_key, trade.pnl_usd)
                    self.notifier.send(f"\U0001F4C9 Exited {pair['base_symbol']} (signal) pnl=${trade.pnl_usd:.2f}")

    def _consider_entry(self, pair: dict) -> None:
        token_key = pair["pair_address"]
        can_open, _ = self.risk.can_open_position(token_key, len(self.portfolio.positions))
        if not can_open:
            return
        history = self.recorder.history_df(token_key)
        if len(history) < self.strategy.min_bars:
            return
        signal = self.strategy.evaluate_entry(history)
        if signal.action != "enter" or not signal.stop_price:
            return
        price = pair["price_usd"]
        size_usd = self.risk.position_size_usd(price, signal.stop_price, cap_usd=self.position_size_usd)
        if size_usd < 5:
            return
        fill = self.executor.buy(price=price, size_usd=size_usd, liquidity_usd=pair["liquidity_usd"])
        self.portfolio.open_position(Position(
            token_key=token_key, symbol=pair["base_symbol"], entry_price=fill.price, size_usd=size_usd,
            quantity=fill.quantity, original_quantity=fill.quantity, stop_price=signal.stop_price,
            take_profit_levels=signal.take_profit_levels or [], opened_at=datetime.now(timezone.utc),
            strategy="dexscreener_trend",
        ))
        self.notifier.send(
            f"\U0001F7E2 Entered {pair['base_symbol']} score={signal.score:.0f} size=${size_usd:.2f}\n"
            + "\n".join(signal.reasons)
        )

    async def run_forever(self) -> None:
        logger.info("DexScreener scanner started (chains=%s)", self.chains)
        while True:
            try:
                pairs = self._candidate_pairs()
                for pair in pairs:
                    self.recorder.record(pair["pair_address"], pair["price_usd"], pair["volume_1h"], pair["buys_1h"], pair["sells_1h"])
                    self._manage_open_position(pair)
                    if pair["pair_address"] not in self.portfolio.positions:
                        self._consider_entry(pair)
                mark_prices = {p["pair_address"]: p["price_usd"] for p in pairs}
                self.risk.mark_to_equity(self.portfolio.equity_usd(mark_prices))
            except Exception:
                logger.exception("DexScreener scan loop error")
            await asyncio.sleep(self.poll_interval_seconds)
