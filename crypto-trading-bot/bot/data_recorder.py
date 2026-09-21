"""Turns repeated DexScreener poll snapshots into OHLC-style bars so the
trend-confluence strategy (and the backtester) have something to compute
indicators on. DexScreener's public API does not expose historical
candles, so this bot builds its own price history over time instead of
pretending to fetch one.
"""
from __future__ import annotations

import csv
import logging
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class Bar:
    timestamp: datetime
    close: float
    high: float
    low: float
    volume: float
    buys: int
    sells: int


class DataRecorder:
    """Maintains a rolling per-token buffer of bars and optionally persists
    every snapshot to a CSV file for later backtesting/analysis."""

    def __init__(self, max_bars: int = 500, csv_path: str | None = None):
        self.max_bars = max_bars
        self._buffers: dict[str, deque] = defaultdict(lambda: deque(maxlen=max_bars))
        self.csv_path = Path(csv_path) if csv_path else None
        if self.csv_path and not self.csv_path.exists():
            self.csv_path.parent.mkdir(parents=True, exist_ok=True)
            with self.csv_path.open("w", newline="") as fh:
                csv.writer(fh).writerow(["token_key", "timestamp", "close", "high", "low", "volume", "buys", "sells"])

    def record(self, token_key: str, price: float, volume_1h: float, buys_1h: int, sells_1h: int) -> None:
        buf = self._buffers[token_key]
        prev_close = buf[-1].close if buf else price
        bar = Bar(
            timestamp=datetime.now(timezone.utc),
            close=price,
            high=max(price, prev_close),
            low=min(price, prev_close),
            volume=volume_1h,
            buys=buys_1h,
            sells=sells_1h,
        )
        buf.append(bar)
        if self.csv_path:
            with self.csv_path.open("a", newline="") as fh:
                csv.writer(fh).writerow(
                    [token_key, bar.timestamp.isoformat(), bar.close, bar.high, bar.low, bar.volume, bar.buys, bar.sells]
                )

    def history_df(self, token_key: str):
        import pandas as pd

        buf = self._buffers.get(token_key)
        if not buf:
            return pd.DataFrame(columns=["timestamp", "close", "high", "low", "volume", "buys", "sells"])
        return pd.DataFrame([b.__dict__ for b in buf])

    def bar_count(self, token_key: str) -> int:
        return len(self._buffers.get(token_key, ()))
