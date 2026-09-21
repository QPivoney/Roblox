"""Heuristics for telling a genuinely new pump.fun launch apart from a
copycat/rug of something already trending.

None of this proves a token is safe — it can't, pump.fun tokens are
inherently high risk — it only screens out the cheapest, most mechanical
scams (name-squatting a trending ticker, a dev wallet holding most of
supply, zero holders) before capital is risked on them.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from difflib import SequenceMatcher

_NOISE_RE = re.compile(r"[^a-z0-9]+")


def _normalize(text: str) -> str:
    return _NOISE_RE.sub("", text.lower())


def name_similarity(a: str, b: str) -> float:
    """0..1 similarity between two token names/symbols, ignoring case and
    punctuation, so 'PEPE 2.0' and 'pepe2.0!!' are recognized as the same
    copycat attempt."""
    na, nb = _normalize(a), _normalize(b)
    if not na or not nb:
        return 0.0
    return SequenceMatcher(None, na, nb).ratio()


@dataclass
class OriginalityResult:
    score: float  # 0-100, higher = more likely an original, healthier launch
    passed: bool  # hard gate: False only for an obvious name-squat/copycat
    reasons: list[str] = field(default_factory=list)
    closest_match: str | None = None
    closest_match_similarity: float = 0.0


class OriginalityFilter:
    """Stateful filter: it remembers every coin symbol/name it has scanned
    so later launches can be checked against both a static watchlist of
    majors/blue-chip memecoins and everything this session has already seen
    — which is where most copycat launches actually come from."""

    SIMILARITY_FLAG_THRESHOLD = 0.82

    def __init__(self, known_names: list[str] | None = None):
        base_watchlist = [
            "Bitcoin", "BTC", "Ethereum", "ETH", "Solana", "SOL", "Dogecoin", "DOGE",
            "Shiba Inu", "SHIB", "Pepe", "PEPE", "Bonk", "BONK", "dogwifhat", "WIF",
            "Official Trump", "TRUMP", "Fartcoin", "Popcat", "Book of Meme", "BOME",
        ]
        self._seen: dict[str, str] = {_normalize(n): n for n in (known_names or []) + base_watchlist}

    def _closest_known(self, name: str, symbol: str) -> tuple[str | None, float]:
        best_name, best_score = None, 0.0
        for candidate in self._seen.values():
            score = max(name_similarity(name, candidate), name_similarity(symbol, candidate))
            if score > best_score:
                best_name, best_score = candidate, score
        return best_name, best_score

    def evaluate(self, coin: dict, *, min_holder_count: int, max_dev_hold_pct: float) -> OriginalityResult:
        reasons: list[str] = []
        score = 100.0

        name = coin.get("name", "") or ""
        symbol = coin.get("symbol", "") or ""

        closest, similarity = self._closest_known(name, symbol)
        if similarity >= self.SIMILARITY_FLAG_THRESHOLD:
            score -= 45
            reasons.append(f"name/symbol {similarity:.0%} similar to '{closest}' — likely copycat/name-squat")
        elif similarity >= 0.6:
            score -= 15
            reasons.append(f"name/symbol somewhat similar to '{closest}' ({similarity:.0%})")

        holder_count = coin.get("holder_count", 0) or 0
        if holder_count < min_holder_count:
            score -= 20
            reasons.append(f"only {holder_count} holders (< {min_holder_count})")

        dev_hold_pct = coin.get("dev_hold_pct")
        if dev_hold_pct is not None and dev_hold_pct > max_dev_hold_pct:
            score -= 25
            reasons.append(f"creator/dev wallet holds {dev_hold_pct:.1f}% of supply (> {max_dev_hold_pct}%)")

        has_socials = any(coin.get(k) for k in ("twitter", "telegram", "website"))
        if not has_socials:
            score -= 10
            reasons.append("no twitter/telegram/website set")

        description = (coin.get("description") or "").strip()
        if len(description) < 5:
            score -= 5
            reasons.append("no meaningful description")

        if not name or not symbol:
            score -= 30
            reasons.append("missing name or symbol")

        score = max(0.0, min(100.0, score))

        key = _normalize(name) or _normalize(symbol)
        if key:
            self._seen[key] = name or symbol

        return OriginalityResult(
            score=score,
            passed=similarity < self.SIMILARITY_FLAG_THRESHOLD,
            reasons=reasons,
            closest_match=closest,
            closest_match_similarity=similarity,
        )
