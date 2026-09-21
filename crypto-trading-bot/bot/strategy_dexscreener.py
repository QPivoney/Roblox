"""Trend-confluence strategy for established DexScreener pairs.

The design goal is *consistency*: only act when several independent
signals agree (EMA stack, momentum, volume, order-flow), size around
volatility (ATR), and exit systematically (fixed stop, trailing stop,
scaled take-profit) rather than on discretion. That combination is what
turns "sometimes right" indicators into a repeatable process — it is not
a guarantee of profit, and DexScreener pairs remain volatile, thinly
regulated markets.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass

import pandas as pd

from . import indicators as ta

logger = logging.getLogger(__name__)


@dataclass
class Signal:
    action: str  # "enter" | "exit" | "hold"
    score: float
    reasons: list
    stop_price: float | None = None
    take_profit_levels: list | None = None  # list[tuple[float, float]]


class TrendConfluenceStrategy:
    def __init__(
        self,
        entry_score_threshold: float = 70,
        exit_score_threshold: float = 40,
        atr_stop_multiplier: float = 1.5,
        atr_trail_multiplier: float = 1.0,
        min_bars: int = 30,
    ):
        self.entry_score_threshold = entry_score_threshold
        self.exit_score_threshold = exit_score_threshold
        self.atr_stop_multiplier = atr_stop_multiplier
        self.atr_trail_multiplier = atr_trail_multiplier
        self.min_bars = min_bars

    def score(self, history: pd.DataFrame) -> tuple[float, list, dict]:
        """history columns: close, high, low, volume, buys, sells (1 row/bar)."""
        reasons: list = []
        if len(history) < self.min_bars:
            return 0.0, ["insufficient history"], {}

        close = history["close"]
        trend = ta.trend_alignment_score(close).iloc[-1]
        rsi_val = ta.rsi(close).iloc[-1]
        _, _, macd_hist = ta.macd(close)
        macd_hist_val = macd_hist.iloc[-1]
        macd_hist_prev = macd_hist.iloc[-2] if len(macd_hist) > 1 else macd_hist_val
        vol_z = ta.volume_zscore(history["volume"]).iloc[-1]
        atr_val = ta.atr(history["high"], history["low"], close).iloc[-1]

        buys = history["buys"].iloc[-1] if "buys" in history else None
        sells = history["sells"].iloc[-1] if "sells" in history else None

        score = 0.0

        if trend > 0:
            score += 30
            reasons.append("EMA stack bullish (9>21>55)")
        elif trend < 0:
            reasons.append("EMA stack bearish")

        if 45 <= rsi_val <= 72:
            score += 20
            reasons.append(f"RSI {rsi_val:.0f} in healthy momentum zone")
        elif rsi_val > 80:
            reasons.append(f"RSI {rsi_val:.0f} overbought — skip")

        if macd_hist_val > 0 and macd_hist_val >= macd_hist_prev:
            score += 20
            reasons.append("MACD histogram positive and rising")
        elif macd_hist_val > 0:
            score += 10
            reasons.append("MACD histogram positive")

        if vol_z > 1.0:
            score += 15
            reasons.append(f"volume {vol_z:.1f} std above average")
        elif vol_z > 0.3:
            score += 7

        if buys is not None and sells is not None and (buys + sells) > 0:
            buy_ratio = buys / (buys + sells)
            if buy_ratio > 0.55:
                score += 15
                reasons.append(f"order flow {buy_ratio:.0%} buys (1h)")
            elif buy_ratio < 0.40:
                score -= 10
                reasons.append(f"order flow only {buy_ratio:.0%} buys (1h)")

        return max(0.0, min(100.0, score)), reasons, {"atr": atr_val, "trend": trend}

    def evaluate_entry(self, history: pd.DataFrame) -> Signal:
        score, reasons, extra = self.score(history)
        if score < self.entry_score_threshold:
            return Signal(action="hold", score=score, reasons=reasons)

        close = history["close"].iloc[-1]
        atr_val = extra.get("atr") or close * 0.03
        stop = close - self.atr_stop_multiplier * atr_val
        risk = close - stop
        targets = [
            (close + 2 * risk, 0.5),  # sell half at 2R
            (close + 4 * risk, 0.3),  # sell another 30% at 4R
        ]  # remaining 20% trails
        return Signal(action="enter", score=score, reasons=reasons, stop_price=stop, take_profit_levels=targets)

    def evaluate_exit(self, history: pd.DataFrame) -> Signal:
        score, reasons, _ = self.score(history)
        if score < self.exit_score_threshold:
            return Signal(action="exit", score=score, reasons=reasons + ["confluence broke down"])
        return Signal(action="hold", score=score, reasons=reasons)
