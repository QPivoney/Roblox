"""Replays recorded bar data through the same strategy, risk manager, and
paper executor the live bot uses, so strategy tuning happens against
historical evidence instead of guesswork. Data comes from `DataRecorder`
CSV output — this bot does not have access to true historical candles
from DexScreener, so a backtest only covers whatever period you've been
recording (see README "Backtesting").

Known simplification: unlike the live scanner this replay closes a
position fully on a signal/stop exit rather than walking the scaled
take-profit ladder bar-by-bar; it's accurate enough for tuning entry/exit
thresholds without the added bookkeeping complexity.
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone

import pandas as pd

from .executor import PaperExecutor
from .portfolio import Portfolio, Position
from .risk_manager import RiskManager
from .strategy_dexscreener import TrendConfluenceStrategy

logger = logging.getLogger(__name__)


def run_backtest(
    csv_path: str,
    starting_capital_usd: float = 1000,
    risk_per_trade_pct: float = 1.5,
    entry_score_threshold: float = 70,
    exit_score_threshold: float = 40,
    position_size_cap_usd: float = 200,
) -> dict:
    df = pd.read_csv(csv_path, parse_dates=["timestamp"])
    strategy = TrendConfluenceStrategy(entry_score_threshold=entry_score_threshold, exit_score_threshold=exit_score_threshold)
    risk = RiskManager(
        starting_capital_usd=starting_capital_usd, risk_per_trade_pct=risk_per_trade_pct,
        max_daily_loss_pct=100, max_drawdown_pct=100, max_open_positions=10,
    )
    portfolio = Portfolio(starting_capital_usd)
    executor = PaperExecutor()

    equity_curve = []
    for token_key, group in df.groupby("token_key"):
        group = group.sort_values("timestamp").reset_index(drop=True)
        for i in range(strategy.min_bars, len(group)):
            window = group.iloc[: i + 1]
            price = window["close"].iloc[-1]
            liquidity_proxy = window["volume"].iloc[-1] * 5  # rough stand-in when true liquidity wasn't recorded

            if token_key in portfolio.positions:
                pos = portfolio.positions[token_key]
                hit_stop = price <= pos.stop_price
                signal = strategy.evaluate_exit(window)
                if hit_stop or signal.action == "exit":
                    fill = executor.sell(price=price, quantity=pos.quantity, liquidity_usd=liquidity_proxy)
                    trade = portfolio.close_position(token_key, fill.price, "stop" if hit_stop else "signal exit")
                    if trade:
                        risk.record_trade_result(token_key, trade.pnl_usd)
            else:
                can_open, _ = risk.can_open_position(token_key, len(portfolio.positions))
                if not can_open:
                    continue
                signal = strategy.evaluate_entry(window)
                if signal.action == "enter" and signal.stop_price:
                    size_usd = risk.position_size_usd(price, signal.stop_price, cap_usd=position_size_cap_usd)
                    if size_usd < 5:
                        continue
                    fill = executor.buy(price=price, size_usd=size_usd, liquidity_usd=liquidity_proxy)
                    portfolio.open_position(Position(
                        token_key=token_key, symbol=token_key, entry_price=fill.price, size_usd=size_usd,
                        quantity=fill.quantity, original_quantity=fill.quantity, stop_price=signal.stop_price,
                        take_profit_levels=signal.take_profit_levels or [], opened_at=window["timestamp"].iloc[-1],
                        strategy="dexscreener_trend",
                    ))

            mark_prices = {k: price for k in portfolio.positions}
            equity = portfolio.equity_usd(mark_prices)
            risk.mark_to_equity(equity)
            equity_curve.append({"timestamp": window["timestamp"].iloc[-1], "equity": equity})

    stats = portfolio.stats()
    stats["ending_equity_usd"] = portfolio.equity_usd({})
    stats["equity_curve"] = equity_curve
    return stats
