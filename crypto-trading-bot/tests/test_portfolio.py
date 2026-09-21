from datetime import datetime, timezone

import pytest

from bot.portfolio import Portfolio, Position


def make_position(token_key="tok", qty=10.0, entry=1.0, stop=0.9):
    return Position(
        token_key=token_key, symbol=token_key, entry_price=entry, size_usd=qty * entry,
        quantity=qty, original_quantity=qty, stop_price=stop, take_profit_levels=[],
        opened_at=datetime.now(timezone.utc), strategy="test",
    )


def test_stats_includes_partial_realized_pnl_on_open_position():
    p = Portfolio(1000)
    p.open_position(make_position(qty=10.0, entry=1.0, stop=0.9))
    p.reduce_position("tok", quantity=4.0, price=2.0, reason="take-profit")  # +$4 realized, still open

    stats = p.stats()
    assert stats["trades"] == 0  # not fully closed yet
    assert stats["open_realized_pnl_usd"] == 4.0
    assert stats["total_pnl_usd"] == 4.0
    assert "tok" in p.positions


def test_stats_folds_in_unrealized_pnl_when_mark_prices_given():
    p = Portfolio(1000)
    p.open_position(make_position(qty=10.0, entry=1.0, stop=0.9))
    p.reduce_position("tok", quantity=4.0, price=2.0, reason="take-profit")

    stats = p.stats(mark_prices={"tok": 1.5})
    # remaining 6 qty marked at 1.5 vs entry 1.0 -> +$3 unrealized
    assert stats["open_unrealized_pnl_usd"] == 3.0
    assert stats["total_pnl_usd"] == 4.0 + 3.0


def test_stats_after_full_close_counts_as_a_trade():
    p = Portfolio(1000)
    p.open_position(make_position(qty=10.0, entry=1.0, stop=0.9))
    p.reduce_position("tok", quantity=4.0, price=2.0, reason="take-profit")
    p.close_position("tok", price=1.2, reason="exit")

    stats = p.stats()
    assert stats["trades"] == 1
    assert stats["open_realized_pnl_usd"] == 0.0
    # partial (4.0) + remaining 6 qty at (1.2-1.0) = 1.2 -> 5.2
    assert stats["total_pnl_usd"] == pytest.approx(4.0 + 1.2)


def test_stats_empty_portfolio_has_no_trades_and_zero_pnl():
    p = Portfolio(1000)
    stats = p.stats()
    assert stats["trades"] == 0
    assert stats["win_rate_pct"] is None
    assert stats["total_pnl_usd"] == 0.0
