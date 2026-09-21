"""Central configuration for the trading bot, loaded from environment variables."""
from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent / ".env")


def _bool(name: str, default: bool) -> bool:
    return os.getenv(name, str(default)).strip().lower() in ("1", "true", "yes", "on")


def _float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, default))
    except (TypeError, ValueError):
        return default


def _int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, default))
    except (TypeError, ValueError):
        return default


@dataclass(frozen=True)
class RiskConfig:
    risk_per_trade_pct: float = _float("RISK_PER_TRADE_PCT", 1.5)
    max_daily_loss_pct: float = _float("MAX_DAILY_LOSS_PCT", 6.0)
    max_drawdown_pct: float = _float("MAX_DRAWDOWN_PCT", 20.0)
    max_open_positions: int = _int("MAX_OPEN_POSITIONS", 5)
    max_pumpfun_positions: int = _int("MAX_CONCURRENT_PUMPFUN_POSITIONS", 3)
    consecutive_loss_cooldown_hours: float = _float("CONSECUTIVE_LOSS_COOLDOWN_HOURS", 12.0)
    consecutive_losses_to_cooldown: int = _int("CONSECUTIVE_LOSSES_TO_COOLDOWN", 2)


@dataclass(frozen=True)
class DexScreenerConfig:
    chains: tuple = tuple(c.strip() for c in os.getenv("DEXSCREENER_CHAINS", "solana,base,ethereum").split(","))
    min_liquidity_usd: float = _float("MIN_LIQUIDITY_USD", 50_000)
    min_volume_24h_usd: float = _float("MIN_VOLUME_24H_USD", 100_000)
    min_pair_age_hours: float = _float("MIN_PAIR_AGE_HOURS", 24)
    entry_score_threshold: float = _float("DEX_ENTRY_SCORE_THRESHOLD", 70)
    exit_score_threshold: float = _float("DEX_EXIT_SCORE_THRESHOLD", 40)
    poll_interval_seconds: int = _int("DEX_POLL_INTERVAL_SECONDS", 60)
    position_size_usd: float = _float("DEX_POSITION_SIZE_USD", 200)


@dataclass(frozen=True)
class PumpFunConfig:
    min_market_cap_usd: float = _float("PUMPFUN_MIN_MARKET_CAP_USD", 5_000)
    max_market_cap_usd: float = _float("PUMPFUN_MAX_MARKET_CAP_USD", 150_000)
    min_holder_count: int = _int("PUMPFUN_MIN_HOLDER_COUNT", 25)
    max_dev_hold_pct: float = _float("PUMPFUN_MAX_DEV_HOLD_PCT", 15)
    position_size_usd: float = _float("PUMPFUN_POSITION_SIZE_USD", 25)
    originality_min_score: float = _float("PUMPFUN_ORIGINALITY_MIN_SCORE", 65)
    stop_loss_pct: float = _float("PUMPFUN_STOP_LOSS_PCT", 30)
    moonbag_pct: float = _float("PUMPFUN_MOONBAG_PCT", 20)
    poll_interval_seconds: int = _int("PUMPFUN_POLL_INTERVAL_SECONDS", 20)


@dataclass(frozen=True)
class ExecutionConfig:
    live_trading: bool = _bool("LIVE_TRADING", False)
    starting_capital_usd: float = _float("STARTING_CAPITAL_USD", 1_000)
    solana_rpc_url: str = os.getenv("SOLANA_RPC_URL", "")
    wallet_private_key: str = os.getenv("WALLET_PRIVATE_KEY", "")
    jupiter_slippage_bps: int = _int("JUPITER_SLIPPAGE_BPS", 150)


@dataclass(frozen=True)
class NotifierConfig:
    discord_webhook_url: str = os.getenv("DISCORD_WEBHOOK_URL", "")
    telegram_bot_token: str = os.getenv("TELEGRAM_BOT_TOKEN", "")
    telegram_chat_id: str = os.getenv("TELEGRAM_CHAT_ID", "")


@dataclass(frozen=True)
class Config:
    risk: RiskConfig = field(default_factory=RiskConfig)
    dexscreener: DexScreenerConfig = field(default_factory=DexScreenerConfig)
    pumpfun: PumpFunConfig = field(default_factory=PumpFunConfig)
    execution: ExecutionConfig = field(default_factory=ExecutionConfig)
    notifier: NotifierConfig = field(default_factory=NotifierConfig)


CONFIG = Config()
