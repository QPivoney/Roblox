import numpy as np
import pandas as pd

from bot import indicators as ta


def test_ema_matches_pandas_ewm():
    s = pd.Series(np.arange(1, 21, dtype=float))
    result = ta.ema(s, 5)
    expected = s.ewm(span=5, adjust=False, min_periods=5).mean()
    pd.testing.assert_series_equal(result, expected)


def test_rsi_bounds():
    s = pd.Series(np.random.default_rng(0).normal(0, 1, 200).cumsum() + 100)
    result = ta.rsi(s, 14)
    assert result.between(0, 100).all()


def test_rsi_strong_uptrend_is_high():
    s = pd.Series(np.arange(1, 51, dtype=float))
    result = ta.rsi(s, 14)
    assert result.iloc[-1] > 90


def test_trend_alignment_bullish_stack():
    s = pd.Series(np.linspace(1, 100, 120))
    result = ta.trend_alignment_score(s)
    assert result.iloc[-1] == 1.0


def test_volume_zscore_spike_detected():
    volume = pd.Series([100] * 30 + [1000])
    z = ta.volume_zscore(volume, length=20)
    assert z.iloc[-1] > 2
