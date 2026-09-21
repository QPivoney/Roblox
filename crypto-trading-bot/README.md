# DexScreener / pump.fun Trading Bot

A Python bot that scans **DexScreener** pairs for consistent, rule-based
trend-following setups, and — as a separate, deliberately higher-risk
module — scans **pump.fun** launches for asymmetric boom-or-bust bets while
filtering out obvious copycats and rugs.

> **⚠️ Read this before running anything.**
> Crypto markets, and pump.fun launches especially, are extremely volatile
> and largely unregulated. No strategy, indicator, or filter here — or
> anywhere — guarantees profit, and past or backtested performance is not
> predictive of future results. This project defaults to **paper trading**
> (simulated fills, no real money) and it should stay that way until you've
> reviewed the code, understood the risk settings, and run it on your own
> historical data. Never risk money you can't afford to lose, and never
> paste a real wallet private key into a chat session, shared machine, or
> any environment you don't fully control.

## Why two separate strategies

- **DexScreener (`bot/strategy_dexscreener.py`)** targets pairs that already
  have liquidity and trading history. The goal is *consistency*: it only
  acts when several independent signals agree — EMA trend stack, RSI,
  MACD momentum, a volume z-score spike, and 1h buy/sell order flow —
  scored into a single 0-100 confluence score. Requiring agreement across
  signals (instead of trading off any single one) is what makes entries
  repeatable rather than reactive to noise. Exits are systematic too: an
  ATR-based stop, a trailing stop once the trade is in profit, and a
  scaled take-profit ladder (50% at 2R, 30% at 4R, the rest trails).

- **pump.fun (`bot/strategy_pumpfun.py`)** targets brand-new launches that
  have no price history to build technical confluence from. Here the edge
  is structural, not technical: an **originality filter**
  (`bot/originality_filter.py`) screens out name-squatting copycats of
  trending tokens, high dev-wallet concentration, near-zero holder counts,
  and missing socials, and a small fixed position size + hard stop + a
  2x/5x/10x take-profit ladder shapes the payoff so a few big winners can
  outweigh many small, capped losses. This is the "boom or bust" module —
  size positions accordingly (the default is $25 per pump.fun trade vs.
  $200 per DexScreener trade).

## Architecture

```
main.py                     orchestrates both scanners + a status reporter
config.py                   loads all settings from .env
bot/
  dexscreener_client.py     DexScreener public API wrapper
  pumpfun_client.py         pump.fun public API wrapper (unofficial, see below)
  indicators.py             EMA/RSI/MACD/ATR/Bollinger/volume z-score (pure functions)
  data_recorder.py          turns repeated polls into OHLC-style bars (+ CSV log)
  strategy_dexscreener.py   trend-confluence scoring + entry/exit signals
  strategy_pumpfun.py       originality + momentum scoring + entry signal
  originality_filter.py     copycat/rug heuristics for pump.fun coins
  risk_manager.py           position sizing, daily-loss/drawdown halts, cooldowns
  portfolio.py              position and PnL tracking
  executor.py               PaperExecutor (default) + LiveExecutor (opt-in, Solana/Jupiter)
  notifier.py                optional Discord/Telegram alerts
  scanner_dexscreener.py    poll loop wiring strategy + risk + executor together
  scanner_pumpfun.py        poll loop wiring strategy + risk + executor together
  backtester.py             replays recorded bars through the strategy/risk/executor
scripts/run_backtest.py     CLI wrapper around bot/backtester.py
tests/                      unit tests for indicators, risk manager, originality filter
```

## Setup

```bash
cd crypto-trading-bot
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env    # edit thresholds/position sizes as you like
```

## Running (paper trading — default and recommended)

```bash
python main.py
```

This starts both scanners concurrently. Nothing here touches real funds
unless you explicitly set `LIVE_TRADING=true` (see "Going live" below).
Logs go to `logs/bot.log`; DexScreener price bars are recorded to
`data/dexscreener_bars.csv` as they're collected — that file becomes your
backtest dataset.

## Backtesting

DexScreener's public API does not expose historical OHLC candles, so this
bot **builds its own price history over time** via `DataRecorder` instead
of pretending to fetch one. Let `main.py` run in paper mode for a while to
accumulate `data/dexscreener_bars.csv`, then replay it:

```bash
python scripts/run_backtest.py data/dexscreener_bars.csv
```

This runs the exact same `TrendConfluenceStrategy` + `RiskManager` +
`PaperExecutor` used live, so you can tune `DEX_ENTRY_SCORE_THRESHOLD`,
`DEX_EXIT_SCORE_THRESHOLD`, and risk settings against real evidence before
trusting the bot with money. There's no equivalent backtest for the
pump.fun strategy — new launches don't have enough usable history, which
is exactly why that module leans on the originality filter and strict
position sizing instead of a tuned technical edge.

## Tests

```bash
pytest
```

Covers the indicators, risk manager (position sizing, daily-loss/drawdown
halts, cooldowns), and the originality filter — all pure functions with no
network dependency.

## Going live (optional, and genuinely risky)

Live trading is **off by default** and requires real, deliberate setup:

1. Set `LIVE_TRADING=true` in `.env`.
2. Set `SOLANA_RPC_URL` and `WALLET_PRIVATE_KEY` for a **small, dedicated
   hot wallet** — never your main wallet, and never a key you'd be upset
   to lose.
3. `pip install solders solana`.
4. `bot/executor.py`'s `LiveExecutor.buy()`/`sell()` currently raise
   `NotImplementedError` — you need to wire per-token mint/decimals
   conversion (the swap/quote plumbing via Jupiter is already there).
   This is intentional: it forces you to read and understand that code
   path, rather than the bot silently executing real swaps the first time
   you flip a flag.
5. Test with trivial amounts on a token you already understand before
   trusting it with anything larger.

## Known limitations

- **pump.fun's API is unofficial.** `bot/pumpfun_client.py` targets
  `frontend-api-v3.pump.fun`, which is not a documented/versioned API and
  can change without notice. Every call fails soft (logs and returns
  empty) so a broken endpoint degrades scanning instead of crashing the
  bot — but if scans stop finding candidates, check this first.
- **Slippage is a model, not measured reality.** `PaperExecutor` estimates
  slippage from order size vs. pool liquidity; real fills, MEV, and
  bot competition on pump.fun launches can be considerably worse,
  especially in the first seconds of a launch.
- **The originality filter reduces obvious scams, it does not eliminate
  risk.** It cannot detect a rug pulled after purchase, a contract-level
  exploit, or a well-disguised copycat. Treat every pump.fun position as
  money you're comfortable losing entirely.
- **No guarantee of profit.** This is a piece of infrastructure for
  running a rules-based process consistently — not a promise about
  outcomes in an unpredictable market.
