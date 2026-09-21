"""High-risk/high-reward strategy for brand-new pump.fun launches.

Unlike the DexScreener strategy this is deliberately *not* about
technical consistency — a brand-new pump.fun token has no price history to
build confluence from. Instead it leans on the originality/rug screen to
avoid the most obvious scams, caps position size hard, and manages the
boom-or-bust payoff shape explicitly: a small, fixed loss on the (common)
bust case and a scaled-out ladder plus a moonbag runner on the (rare)
boom case — the asymmetry is what can make this viable across many small
trials even with a low hit rate, not any predictive edge on which token
moons.

Because total token supply is fixed on a pump.fun bonding curve, market
cap moves proportionally with per-token price, so market-cap multiples
(2x/5x/10x) are used directly as price targets below.
"""
from __future__ import annotations

from dataclasses import dataclass

from .originality_filter import OriginalityFilter, OriginalityResult


@dataclass
class PumpFunSignal:
    action: str  # "enter" | "skip"
    score: float
    reasons: list
    stop_price: float | None = None
    take_profit_levels: list | None = None  # list[tuple[float, float]]
    originality: OriginalityResult | None = None


class PumpFunMomentumStrategy:
    def __init__(
        self,
        originality_filter: OriginalityFilter,
        min_market_cap_usd: float,
        max_market_cap_usd: float,
        min_holder_count: int,
        max_dev_hold_pct: float,
        originality_min_score: float,
        stop_loss_pct: float,
        moonbag_pct: float,
    ):
        self.originality_filter = originality_filter
        self.min_market_cap_usd = min_market_cap_usd
        self.max_market_cap_usd = max_market_cap_usd
        self.min_holder_count = min_holder_count
        self.max_dev_hold_pct = max_dev_hold_pct
        self.originality_min_score = originality_min_score
        self.stop_loss_pct = stop_loss_pct
        self.moonbag_pct = moonbag_pct

    def evaluate(self, coin: dict, *, holder_growth_1m: float = 0.0) -> PumpFunSignal:
        mc = coin.get("market_cap_usd", 0)

        if not (self.min_market_cap_usd <= mc <= self.max_market_cap_usd):
            return PumpFunSignal(action="skip", score=0, reasons=[f"market cap ${mc:,.0f} outside scan range"])

        originality = self.originality_filter.evaluate(
            coin, min_holder_count=self.min_holder_count, max_dev_hold_pct=self.max_dev_hold_pct
        )
        if not originality.passed:
            return PumpFunSignal(
                action="skip", score=originality.score,
                reasons=[f"likely copycat of '{originality.closest_match}' ({originality.closest_match_similarity:.0%})"],
                originality=originality,
            )
        if originality.score < self.originality_min_score:
            return PumpFunSignal(
                action="skip", score=originality.score,
                reasons=["originality/quality score below threshold"] + originality.reasons,
                originality=originality,
            )

        momentum_score = 0.0
        momentum_reasons: list = []
        if holder_growth_1m > 0:
            momentum_score += min(30.0, holder_growth_1m * 3)
            momentum_reasons.append(f"+{holder_growth_1m:.0f} holders in last minute-window")
        if coin.get("reply_count", 0) >= 20:
            momentum_score += 10
            momentum_reasons.append("active reply/chat activity")

        composite = min(100.0, originality.score * 0.7 + momentum_score)
        reasons = originality.reasons + momentum_reasons

        price = mc  # market cap used directly as the price-equivalent unit — see module docstring
        stop = price * (1 - self.stop_loss_pct / 100)
        targets = [
            (price * 2, 0.35),
            (price * 5, 0.25),
            (price * 10, 0.20),
            # remaining moonbag_pct% of the original size is left to run uncapped
        ]

        action = "enter" if composite >= self.originality_min_score else "skip"
        return PumpFunSignal(
            action=action, score=composite, reasons=reasons,
            stop_price=stop if action == "enter" else None,
            take_profit_levels=targets if action == "enter" else None,
            originality=originality,
        )
