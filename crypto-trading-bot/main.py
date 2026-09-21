"""Entry point: wires config -> clients -> strategies -> scanners and runs
both the DexScreener and pump.fun scan loops concurrently.

Defaults to paper trading. Live trading requires LIVE_TRADING=true *and*
a wallet configured in .env, plus finishing the token-decimal wiring in
executor.LiveExecutor — see README.md "Going live" before ever enabling it.
"""
from __future__ import annotations

import asyncio
import logging
import signal

from config import CONFIG
from bot.data_recorder import DataRecorder
from bot.dexscreener_client import DexScreenerClient
from bot.executor import Executor, PaperExecutor
from bot.logger_setup import setup_logging
from bot.notifier import Notifier
from bot.originality_filter import OriginalityFilter
from bot.portfolio import Portfolio
from bot.pumpfun_client import PumpFunClient
from bot.risk_manager import RiskManager
from bot.scanner_dexscreener import DexScreenerScanner
from bot.scanner_pumpfun import PumpFunScanner
from bot.strategy_dexscreener import TrendConfluenceStrategy
from bot.strategy_pumpfun import PumpFunMomentumStrategy

logger = logging.getLogger(__name__)


def build_executor() -> Executor:
    if not CONFIG.execution.live_trading:
        return PaperExecutor()
    from bot.executor import LiveExecutor

    logger.warning("LIVE_TRADING=true — real funds will be at risk.")
    return LiveExecutor(
        rpc_url=CONFIG.execution.solana_rpc_url,
        private_key_base58=CONFIG.execution.wallet_private_key,
        slippage_bps=CONFIG.execution.jupiter_slippage_bps,
    )


async def status_reporter(dex_portfolio: Portfolio, pump_portfolio: Portfolio, notifier: Notifier, interval_seconds: int = 1800) -> None:
    while True:
        await asyncio.sleep(interval_seconds)
        dex_stats = dex_portfolio.stats()
        pump_stats = pump_portfolio.stats()
        msg = (
            f"\U0001F4CA Status — DexScreener trades={dex_stats.get('trades', 0)} "
            f"pnl=${dex_stats.get('total_pnl_usd', 0):.2f} | "
            f"pump.fun trades={pump_stats.get('trades', 0)} pnl=${pump_stats.get('total_pnl_usd', 0):.2f}"
        )
        logger.info(msg)
        notifier.send(msg)


async def main() -> None:
    setup_logging()
    logger.info("Starting bot — LIVE_TRADING=%s", CONFIG.execution.live_trading)
    if not CONFIG.execution.live_trading:
        logger.info("Running in PAPER TRADING mode. No real funds will be used.")

    dex_portfolio = Portfolio(CONFIG.execution.starting_capital_usd / 2)
    pump_portfolio = Portfolio(CONFIG.execution.starting_capital_usd / 2)
    notifier = Notifier(
        CONFIG.notifier.discord_webhook_url, CONFIG.notifier.telegram_bot_token, CONFIG.notifier.telegram_chat_id
    )
    executor = build_executor()

    dex_risk = RiskManager(
        starting_capital_usd=dex_portfolio.starting_capital_usd,
        risk_per_trade_pct=CONFIG.risk.risk_per_trade_pct,
        max_daily_loss_pct=CONFIG.risk.max_daily_loss_pct,
        max_drawdown_pct=CONFIG.risk.max_drawdown_pct,
        max_open_positions=CONFIG.risk.max_open_positions,
        consecutive_losses_to_cooldown=CONFIG.risk.consecutive_losses_to_cooldown,
        cooldown_hours=CONFIG.risk.consecutive_loss_cooldown_hours,
    )
    pump_risk = RiskManager(
        starting_capital_usd=pump_portfolio.starting_capital_usd,
        risk_per_trade_pct=CONFIG.risk.risk_per_trade_pct,
        max_daily_loss_pct=CONFIG.risk.max_daily_loss_pct,
        max_drawdown_pct=CONFIG.risk.max_drawdown_pct,
        max_open_positions=CONFIG.risk.max_pumpfun_positions,
        consecutive_losses_to_cooldown=CONFIG.risk.consecutive_losses_to_cooldown,
        cooldown_hours=CONFIG.risk.consecutive_loss_cooldown_hours,
    )

    dex_scanner = DexScreenerScanner(
        client=DexScreenerClient(), recorder=DataRecorder(csv_path="data/dexscreener_bars.csv"),
        strategy=TrendConfluenceStrategy(
            entry_score_threshold=CONFIG.dexscreener.entry_score_threshold,
            exit_score_threshold=CONFIG.dexscreener.exit_score_threshold,
        ),
        risk=dex_risk, portfolio=dex_portfolio, executor=executor, notifier=notifier,
        chains=CONFIG.dexscreener.chains, min_liquidity_usd=CONFIG.dexscreener.min_liquidity_usd,
        min_volume_24h_usd=CONFIG.dexscreener.min_volume_24h_usd, min_pair_age_hours=CONFIG.dexscreener.min_pair_age_hours,
        position_size_usd=CONFIG.dexscreener.position_size_usd, poll_interval_seconds=CONFIG.dexscreener.poll_interval_seconds,
    )

    pump_scanner = PumpFunScanner(
        client=PumpFunClient(),
        strategy=PumpFunMomentumStrategy(
            originality_filter=OriginalityFilter(),
            min_market_cap_usd=CONFIG.pumpfun.min_market_cap_usd, max_market_cap_usd=CONFIG.pumpfun.max_market_cap_usd,
            min_holder_count=CONFIG.pumpfun.min_holder_count, max_dev_hold_pct=CONFIG.pumpfun.max_dev_hold_pct,
            originality_min_score=CONFIG.pumpfun.originality_min_score, stop_loss_pct=CONFIG.pumpfun.stop_loss_pct,
            moonbag_pct=CONFIG.pumpfun.moonbag_pct,
        ),
        risk=pump_risk, portfolio=pump_portfolio, executor=executor, notifier=notifier,
        position_size_usd=CONFIG.pumpfun.position_size_usd, poll_interval_seconds=CONFIG.pumpfun.poll_interval_seconds,
        max_positions=CONFIG.risk.max_pumpfun_positions,
    )

    tasks = [
        asyncio.create_task(dex_scanner.run_forever()),
        asyncio.create_task(pump_scanner.run_forever()),
        asyncio.create_task(status_reporter(dex_portfolio, pump_portfolio, notifier)),
    ]

    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop_event.set)
        except NotImplementedError:
            pass  # not supported on some platforms (e.g. Windows)

    await stop_event.wait()
    logger.info("Shutdown requested, cancelling scanners...")
    for t in tasks:
        t.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)


if __name__ == "__main__":
    asyncio.run(main())
