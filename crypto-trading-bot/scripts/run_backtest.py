#!/usr/bin/env python3
"""CLI: python scripts/run_backtest.py data/dexscreener_bars.csv [starting_capital_usd]"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from bot.backtester import run_backtest  # noqa: E402

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: run_backtest.py <bars.csv> [starting_capital_usd]")
        raise SystemExit(1)
    csv_path = sys.argv[1]
    capital = float(sys.argv[2]) if len(sys.argv) > 2 else 1000
    stats = run_backtest(csv_path, starting_capital_usd=capital)
    stats.pop("equity_curve", None)
    print(json.dumps(stats, indent=2, default=str))
