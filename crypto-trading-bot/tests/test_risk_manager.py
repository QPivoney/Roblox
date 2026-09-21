from bot.risk_manager import RiskManager


def make_risk(**overrides):
    defaults = dict(
        starting_capital_usd=1000, risk_per_trade_pct=2, max_daily_loss_pct=6,
        max_drawdown_pct=20, max_open_positions=3,
    )
    defaults.update(overrides)
    return RiskManager(**defaults)


def test_position_size_scales_with_stop_distance():
    risk = make_risk()
    tight = risk.position_size_usd(entry_price=100, stop_price=98)  # 2% stop
    wide = risk.position_size_usd(entry_price=100, stop_price=90)  # 10% stop
    assert tight > wide


def test_position_size_respects_cap():
    risk = make_risk()
    size = risk.position_size_usd(entry_price=100, stop_price=99.9, cap_usd=50)
    assert size == 50


def test_daily_loss_halts_trading():
    risk = make_risk(max_daily_loss_pct=5)
    risk.mark_to_equity(940)  # -6% for the day
    assert risk.halted
    can_open, reason = risk.can_open_position("tokenA", 0)
    assert not can_open
    assert "daily loss" in reason


def test_drawdown_halts_trading():
    risk = make_risk(max_drawdown_pct=10)
    risk.mark_to_equity(1200)
    risk.mark_to_equity(1050)  # >10% off the 1200 peak
    assert risk.halted


def test_consecutive_losses_trigger_cooldown():
    risk = make_risk()
    risk.record_trade_result("tokenA", -10)
    risk.record_trade_result("tokenA", -10)
    assert risk.is_on_cooldown("tokenA")
    can_open, reason = risk.can_open_position("tokenA", 0)
    assert not can_open


def test_win_resets_loss_streak():
    risk = make_risk()
    risk.record_trade_result("tokenA", -10)
    risk.record_trade_result("tokenA", 5)
    risk.record_trade_result("tokenA", -10)
    assert not risk.is_on_cooldown("tokenA")


def test_max_open_positions_enforced():
    risk = make_risk(max_open_positions=2)
    can_open, _ = risk.can_open_position("tokenB", open_position_count=2)
    assert not can_open
