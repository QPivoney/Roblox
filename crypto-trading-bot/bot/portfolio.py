"""In-memory position and PnL tracking shared by paper and live execution."""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone

logger = logging.getLogger(__name__)


@dataclass
class Position:
    token_key: str
    symbol: str
    entry_price: float
    size_usd: float
    quantity: float
    original_quantity: float
    stop_price: float
    take_profit_levels: list  # list[tuple[float, float]] = (price, fraction_of_original_qty)
    opened_at: datetime
    strategy: str
    trailing_stop_price: float | None = None
    realized_pnl_usd: float = 0.0
    filled_targets: set = field(default_factory=set)

    def unrealized_pnl_usd(self, price: float) -> float:
        return (price - self.entry_price) * self.quantity

    def r_multiple(self, price: float) -> float:
        risk_per_unit = self.entry_price - self.stop_price
        if risk_per_unit <= 0:
            return 0.0
        return (price - self.entry_price) / risk_per_unit


@dataclass
class ClosedTrade:
    token_key: str
    symbol: str
    strategy: str
    entry_price: float
    exit_price: float
    quantity: float
    pnl_usd: float
    r_multiple: float
    opened_at: datetime
    closed_at: datetime
    exit_reason: str


class Portfolio:
    def __init__(self, starting_capital_usd: float):
        self.cash_usd = starting_capital_usd
        self.starting_capital_usd = starting_capital_usd
        self.positions: dict[str, Position] = {}
        self.closed_trades: list[ClosedTrade] = []

    def equity_usd(self, mark_prices: dict[str, float]) -> float:
        open_value = sum(
            pos.quantity * mark_prices.get(key, pos.entry_price) for key, pos in self.positions.items()
        )
        return self.cash_usd + open_value

    def open_position(self, position: Position) -> None:
        self.cash_usd -= position.size_usd
        self.positions[position.token_key] = position
        logger.info(
            "OPEN %s %s qty=%.4f entry=%.6f stop=%.6f size=$%.2f",
            position.strategy, position.symbol, position.quantity, position.entry_price, position.stop_price, position.size_usd,
        )

    def reduce_position(self, token_key: str, quantity: float, price: float, reason: str) -> float:
        pos = self.positions.get(token_key)
        if not pos or quantity <= 0:
            return 0.0
        quantity = min(quantity, pos.quantity)
        proceeds = quantity * price
        pnl = (price - pos.entry_price) * quantity
        pos.quantity -= quantity
        pos.realized_pnl_usd += pnl
        self.cash_usd += proceeds
        logger.info("REDUCE %s qty=%.4f price=%.6f pnl=$%.2f reason=%s", pos.symbol, quantity, price, pnl, reason)
        if pos.quantity <= 1e-12:
            self._close(token_key, price, reason)
        return pnl

    def close_position(self, token_key: str, price: float, reason: str) -> ClosedTrade | None:
        pos = self.positions.get(token_key)
        if not pos:
            return None
        proceeds = pos.quantity * price
        pnl = (price - pos.entry_price) * pos.quantity + pos.realized_pnl_usd
        self.cash_usd += proceeds
        trade = ClosedTrade(
            token_key=token_key, symbol=pos.symbol, strategy=pos.strategy,
            entry_price=pos.entry_price, exit_price=price, quantity=pos.quantity,
            pnl_usd=pnl, r_multiple=pos.r_multiple(price), opened_at=pos.opened_at,
            closed_at=datetime.now(timezone.utc), exit_reason=reason,
        )
        self.closed_trades.append(trade)
        del self.positions[token_key]
        logger.info("CLOSE %s pnl=$%.2f reason=%s", pos.symbol, pnl, reason)
        return trade

    def _close(self, token_key: str, price: float, reason: str) -> None:
        pos = self.positions.pop(token_key, None)
        if not pos:
            return
        trade = ClosedTrade(
            token_key=token_key, symbol=pos.symbol, strategy=pos.strategy,
            entry_price=pos.entry_price, exit_price=price, quantity=0,
            pnl_usd=pos.realized_pnl_usd, r_multiple=pos.r_multiple(price), opened_at=pos.opened_at,
            closed_at=datetime.now(timezone.utc), exit_reason=reason,
        )
        self.closed_trades.append(trade)

    def stats(self, mark_prices: dict[str, float] | None = None) -> dict:
        """Win rate / R-multiple / profit factor come only from fully closed
        round-trips (a partial fill has no completed R-multiple to report).
        `total_pnl_usd` additionally folds in PnL already realized via
        partial take-profits on positions that are still open — otherwise a
        position that banked real profit at its 2x/5x targets but hasn't
        fully closed yet would look like it made nothing. Pass mark_prices
        to also fold in unrealized PnL on whatever is still open.
        """
        trades = self.closed_trades
        closed_pnl = sum(t.pnl_usd for t in trades)
        open_realized_pnl = sum(pos.realized_pnl_usd for pos in self.positions.values())
        open_unrealized_pnl = None
        if mark_prices is not None:
            open_unrealized_pnl = sum(
                pos.unrealized_pnl_usd(mark_prices.get(key, pos.entry_price))
                for key, pos in self.positions.items()
            )

        wins = [t for t in trades if t.pnl_usd > 0]
        losses = [t for t in trades if t.pnl_usd <= 0]
        gross_win = sum(t.pnl_usd for t in wins)
        gross_loss = abs(sum(t.pnl_usd for t in losses))

        result = {
            "trades": len(trades),
            "win_rate_pct": (len(wins) / len(trades) * 100) if trades else None,
            "avg_r": (sum(t.r_multiple for t in trades) / len(trades)) if trades else None,
            "profit_factor": (gross_win / gross_loss) if gross_loss else (float("inf") if gross_win else None),
            "closed_pnl_usd": closed_pnl,
            "open_realized_pnl_usd": open_realized_pnl,
            "total_pnl_usd": closed_pnl + open_realized_pnl + (open_unrealized_pnl or 0.0),
        }
        if open_unrealized_pnl is not None:
            result["open_unrealized_pnl_usd"] = open_unrealized_pnl
        return result
