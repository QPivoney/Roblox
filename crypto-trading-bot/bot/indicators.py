"""Pure, dependency-light technical indicators used across strategies.

All functions take/return `pandas.Series` and are side-effect free so they
can be unit tested without network access and reused by both the live
strategies and the backtester.
"""
from __future__ import annotations

import numpy as np
import pandas as pd


def ema(series: pd.Series, length: int) -> pd.Series:
    return series.ewm(span=length, adjust=False, min_periods=length).mean()


def sma(series: pd.Series, length: int) -> pd.Series:
    return series.rolling(length, min_periods=length).mean()


def rsi(series: pd.Series, length: int = 14) -> pd.Series:
    delta = series.diff()
    gain = delta.clip(lower=0)
    loss = -delta.clip(upper=0)
    avg_gain = gain.ewm(alpha=1 / length, min_periods=length, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1 / length, min_periods=length, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0, np.nan)
    out = 100 - (100 / (1 + rs))
    out = out.mask((avg_loss == 0) & (avg_gain > 0), 100.0)
    out = out.mask((avg_loss == 0) & (avg_gain == 0), 50.0)
    return out.fillna(50)


def macd(series: pd.Series, fast: int = 12, slow: int = 26, signal: int = 9):
    fast_ema = ema(series, fast)
    slow_ema = ema(series, slow)
    macd_line = fast_ema - slow_ema
    signal_line = macd_line.ewm(span=signal, adjust=False, min_periods=signal).mean()
    histogram = macd_line - signal_line
    return macd_line, signal_line, histogram


def atr(high: pd.Series, low: pd.Series, close: pd.Series, length: int = 14) -> pd.Series:
    prev_close = close.shift(1)
    tr = pd.concat(
        [high - low, (high - prev_close).abs(), (low - prev_close).abs()], axis=1
    ).max(axis=1)
    return tr.ewm(alpha=1 / length, min_periods=length, adjust=False).mean()


def bollinger_bands(series: pd.Series, length: int = 20, num_std: float = 2.0):
    mid = sma(series, length)
    std = series.rolling(length, min_periods=length).std()
    upper = mid + num_std * std
    lower = mid - num_std * std
    return upper, mid, lower


def volume_zscore(volume: pd.Series, length: int = 20) -> pd.Series:
    mean = volume.rolling(length, min_periods=max(2, length // 2)).mean()
    std = volume.rolling(length, min_periods=max(2, length // 2)).std().replace(0, np.nan)
    return ((volume - mean) / std).fillna(0)


def trend_alignment_score(close: pd.Series, fast: int = 9, mid: int = 21, slow: int = 55) -> pd.Series:
    """1.0 when fast > mid > slow EMAs (strong uptrend stack), -1.0 for the
    mirrored downtrend stack, 0 when the EMAs are tangled (no clean trend).
    Requiring this alignment is what makes the strategy trade *with* a
    persistent pattern instead of reacting to single-bar noise.
    """
    f, m, s = ema(close, fast), ema(close, mid), ema(close, slow)
    up = (f > m) & (m > s)
    down = (f < m) & (m < s)
    return pd.Series(np.select([up, down], [1.0, -1.0], default=0.0), index=close.index)
