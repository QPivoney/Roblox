"""Polls pump.fun for new/trending launches, runs them through the
originality + momentum strategy, and manages boom-or-bust positions with a
hard stop and a scaled take-profit ladder."""
from __future__ import annotations

import asyncio
import logging
import time
from collections import defaultdict
from datetime import datetime, timezone

from .executor import Executor
from .notifier import Notifier
from .portfolio import Portfolio, Position
from .pumpfun_client import PumpFunClient, normalize_coin
from .risk_manager import RiskManager
from .strategy_pumpfun import PumpFunMomentumStrategy

logger = logging.getLogger(__name__)


class PumpFunScanner:
    def __init__(
        self, *, client: PumpFunClient, strategy: PumpFunMomentumStrategy, risk: RiskManager,
        portfolio: Portfolio, executor: Executor, notifier: Notifier, position_size_usd: float,
        poll_interval_seconds: int, max_positions: int,
    ):
        self.client = client
        self.strategy = strategy
        self.risk = risk
        self.portfolio = portfolio
        self.executor = executor
        self.notifier = notifier
        self.position_size_usd = position_size_usd
        self.poll_interval_seconds = poll_interval_seconds
        self.max_positions = max_positions
        self._holder_history: dict[str, list] = defaultdict(list)

    def _holder_growth_1m(self, mint: str, holder_count: int) -> float:
        history = self._holder_history[mint]
        now = time.time()
        history.append((now, holder_count))
        del history[:-20]
        cutoff = now - 60
        past = [h for t, h in history if t <= cutoff]
        return float(holder_count - past[-1]) if past else 0.0

    def _manage_open_position(self, coin: dict) -> None:
        token_key = coin["mint"]
        pos = self.portfolio.positions.get(token_key)
        if not pos:
            return
        price = coin["market_cap_usd"]  # proportional to per-token price on a fixed-supply bonding curve
        if price <= 0:
            return

        if price <= pos.stop_price:
            fill = self.executor.sell(price=price, quantity=pos.quantity, liquidity_usd=price)
            trade = self.portfolio.close_position(token_key, fill.price, "stop loss")
            if trade:
                self.risk.record_trade_result(token_key, trade.pnl_usd)
                self.notifier.send(f"\U0001F6D1\U0001F4A5 pump.fun stop-out {coin['symbol']} pnl=${trade.pnl_usd:.2f}")
            return

        for target_price, fraction in pos.take_profit_levels:
            if target_price in pos.filled_targets or pos.quantity <= 0:
                continue
            if price >= target_price:
                qty = min(pos.original_quantity * fraction, pos.quantity)
                fill = self.executor.sell(price=price, quantity=qty, liquidity_usd=price)
                self.portfolio.reduce_position(token_key, fill.quantity, fill.price, f"take-profit @ {target_price:,.0f} mc")
                pos.filled_targets.add(target_price)
                self.notifier.send(f"\U0001F680 pump.fun take-profit {coin['symbol']} at ${target_price:,.0f} mc")

    def _consider_entry(self, coin: dict) -> None:
        token_key = coin["mint"]
        can_open, _ = self.risk.can_open_position(
            token_key, len(self.portfolio.positions), max_positions_override=self.max_positions
        )
        if not can_open:
            return
        holder_growth = self._holder_growth_1m(token_key, coin.get("holder_count", 0))
        signal = self.strategy.evaluate(coin, holder_growth_1m=holder_growth)
        if signal.action != "enter" or not signal.stop_price:
            return
        price = coin["market_cap_usd"]
        size_usd = self.risk.position_size_usd(price, signal.stop_price, cap_usd=self.position_size_usd)
        if size_usd < 1:
            return
        fill = self.executor.buy(price=price, size_usd=size_usd, liquidity_usd=price)
        self.portfolio.open_position(Position(
            token_key=token_key, symbol=coin["symbol"], entry_price=fill.price, size_usd=size_usd,
            quantity=fill.quantity, original_quantity=fill.quantity, stop_price=signal.stop_price,
            take_profit_levels=signal.take_profit_levels or [], opened_at=datetime.now(timezone.utc),
            strategy="pumpfun_momentum",
        ))
        self.notifier.send(
            f"\U0001F3B0 pump.fun entry {coin['symbol']} score={signal.score:.0f} size=${size_usd:.2f}\n"
            + "\n".join(signal.reasons)
        )

    async def run_forever(self) -> None:
        logger.info("pump.fun scanner started")
        while True:
            try:
                coins = [normalize_coin(c) for c in self.client.list_new_coins(limit=60)]
                coins += [normalize_coin(c) for c in self.client.list_trending_coins(limit=30)]
                by_mint = {c["mint"]: c for c in coins if c["mint"]}
                for coin in by_mint.values():
                    self._manage_open_position(coin)
                    if coin["mint"] not in self.portfolio.positions:
                        self._consider_entry(coin)
                mark_prices = {m: c["market_cap_usd"] for m, c in by_mint.items()}
                self.risk.mark_to_equity(self.portfolio.equity_usd(mark_prices))
            except Exception:
                logger.exception("pump.fun scan loop error")
            await asyncio.sleep(self.poll_interval_seconds)
