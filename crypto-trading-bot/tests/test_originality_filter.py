from bot.originality_filter import OriginalityFilter, name_similarity


def test_name_similarity_identical():
    assert name_similarity("Pepe", "PEPE") == 1.0


def test_name_similarity_unrelated():
    assert name_similarity("Bonk", "Zzyzxqrst") < 0.4


def test_flags_obvious_copycat():
    f = OriginalityFilter()
    result = f.evaluate(
        {"name": "official pepe!!", "symbol": "PEPE", "holder_count": 100, "twitter": "x", "description": "the real one"},
        min_holder_count=25, max_dev_hold_pct=15,
    )
    assert not result.passed
    assert result.closest_match_similarity > 0.8


def test_passes_original_looking_launch():
    f = OriginalityFilter()
    result = f.evaluate(
        {
            "name": "Quantum Capybara", "symbol": "QCAP", "holder_count": 80,
            "twitter": "https://twitter.com/x", "telegram": "https://t.me/x",
            "description": "A community coin about a capybara that does quantum physics memes.",
        },
        min_holder_count=25, max_dev_hold_pct=15,
    )
    assert result.passed
    assert result.score >= 65


def test_low_holder_count_penalized():
    f = OriginalityFilter()
    result = f.evaluate(
        {"name": "Quantum Ferret", "symbol": "QFER", "holder_count": 3, "description": "unique coin"},
        min_holder_count=25, max_dev_hold_pct=15,
    )
    assert result.score < 100
    assert any("holders" in r for r in result.reasons)


def test_high_dev_hold_penalized():
    f = OriginalityFilter()
    result = f.evaluate(
        {"name": "Nebula Otter", "symbol": "NOTR", "holder_count": 50, "dev_hold_pct": 40, "description": "space otter"},
        min_holder_count=25, max_dev_hold_pct=15,
    )
    assert any("dev wallet" in r for r in result.reasons)
