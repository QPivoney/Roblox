"""Position sizing and the circuit breakers that keep pattern-following
consistent instead of degenerating into revenge trading after a string of
losses. This module has no network or exchange dependency so it is fully
unit-testable."""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

logger = logging.getLogger(__name__)


@dataclass
class RiskManager:
    starting_capital_usd: float
    risk_per_trade_pct: float
    max_daily_loss_pct: float
    max_drawdown_pct: float
    max_open_positions: int
    consecutive_losses_to_cooldown: int = 2
    cooldown_hours: float = 12.0

    equity_usd: float = field(init=False)
    peak_equity_usd: float = field(init=False)
    _daily_start_equity: float = field(init=False)
    _daily_anchor_date: str = field(init=False)
    _consecutive_losses: dict = field(default_factory=dict)
    _cooldown_until: dict = field(default_factory=dict)
    _halted: bool = field(default=False, init=False)
    _halt_reason: str = field(default="", init=False)

    def __post_init__(self) -> None:
        self.equity_usd = self.starting_capital_usd
        self.peak_equity_usd = self.starting_capital_usd
        self._daily_start_equity = self.starting_capital_usd
        self._daily_anchor_date = datetime.now(timezone.utc).date().isoformat()

    def _roll_daily_anchor(self) -> None:
        today = datetime.now(timezone.utc).date().isoformat()
        if today != self._daily_anchor_date:
            self._daily_anchor_date = today
            self._daily_start_equity = self.equity_usd
            if self._halt_reason.startswith("daily loss"):
                self._halted = False
                self._halt_reason = ""

    def mark_to_equity(self, equity_usd: float) -> None:
        self._roll_daily_anchor()
        self.equity_usd = equity_usd
        self.peak_equity_usd = max(self.peak_equity_usd, equity_usd)

        daily_loss_pct = (
            (self._daily_start_equity - equity_usd) / self._daily_start_equity * 100
            if self._daily_start_equity else 0
        )
        if daily_loss_pct >= self.max_daily_loss_pct:
            self._halted = True
            self._halt_reason = f"daily loss limit hit ({daily_loss_pct:.1f}% >= {self.max_daily_loss_pct}%)"
            logger.warning("Risk halt: %s", self._halt_reason)

        drawdown_pct = (
            (self.peak_equity_usd - equity_usd) / self.peak_equity_usd * 100
            if self.peak_equity_usd else 0
        )
        if drawdown_pct >= self.max_drawdown_pct:
            self._halted = True
            self._halt_reason = f"max drawdown hit ({drawdown_pct:.1f}% >= {self.max_drawdown_pct}%)"
            logger.warning("Risk halt: %s", self._halt_reason)

    @property
    def halted(self) -> bool:
        self._roll_daily_anchor()
        return self._halted

    @property
    def halt_reason(self) -> str:
        return self._halt_reason

    def resume(self) -> None:
        """Manual override to resume trading after a halt (e.g. max
        drawdown). Intentionally not automatic — a blown risk limit should
        require a human to look at what happened."""
        self._halted = False
        self._halt_reason = ""

    def is_on_cooldown(self, token_key: str) -> bool:
        until = self._cooldown_until.get(token_key)
        return bool(until and datetime.now(timezone.utc) < until)

    def record_trade_result(self, token_key: str, pnl_usd: float) -> None:
        if pnl_usd < 0:
            streak = self._consecutive_losses.get(token_key, 0) + 1
            self._consecutive_losses[token_key] = streak
            if streak >= self.consecutive_losses_to_cooldown:
                self._cooldown_until[token_key] = datetime.now(timezone.utc) + timedelta(hours=self.cooldown_hours)
                logger.info("Cooling down %s for %.1fh after %d consecutive losses", token_key, self.cooldown_hours, streak)
        else:
            self._consecutive_losses[token_key] = 0

    def can_open_position(
        self, token_key: str, open_position_count: int, max_positions_override: int | None = None
    ) -> tuple[bool, str]:
        if self.halted:
            return False, self._halt_reason
        if self.is_on_cooldown(token_key):
            return False, f"{token_key} is on loss-streak cooldown"
        limit = max_positions_override if max_positions_override is not None else self.max_open_positions
        if open_position_count >= limit:
            return False, f"max open positions reached ({limit})"
        return True, ""

    def position_size_usd(self, entry_price: float, stop_price: float, *, cap_usd: float | None = None) -> float:
        """Volatility-adjusted sizing: risk a fixed % of equity on the
        distance to the stop, so a tight-stop setup gets a bigger size and a
        wide-stop (choppier) setup automatically gets a smaller one."""
        stop_distance_pct = abs(entry_price - stop_price) / entry_price if entry_price else 0
        if stop_distance_pct <= 0:
            return 0.0
        risk_amount_usd = self.equity_usd * (self.risk_per_trade_pct / 100)
        size_usd = risk_amount_usd / stop_distance_pct
        if cap_usd is not None:
            size_usd = min(size_usd, cap_usd)
        return max(0.0, min(size_usd, self.equity_usd))
