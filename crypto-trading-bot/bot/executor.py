"""Order execution abstraction.

`PaperExecutor` is the default, and is what should be run and observed
for a meaningful sample of trades before anyone considers live trading. It
simulates fills with a liquidity-aware slippage model so paper results are
realistic for thin pump.fun-style pools, not just idealized mid-price
fills.

`LiveExecutor` is a real (Solana + Jupiter) execution path for anyone who
explicitly opts in. It is guarded behind LIVE_TRADING=true and a wallet
private key that YOU control locally — never paste a real private key
into a chat session, a shared machine, or an environment you do not
control. Fund the trading wallet with only what you can afford to lose,
and keep the bulk of any capital in a separate wallet the bot never
touches. Its buy()/sell() are intentionally left unimplemented (see the
NotImplementedError messages) until you wire per-token mint/decimals
handling and have tested on small amounts — see README.md "Going live".
"""
from __future__ import annotations

import logging
from dataclasses import dataclass

import requests

logger = logging.getLogger(__name__)


@dataclass
class Fill:
    price: float
    quantity: float
    slippage_pct: float


class Executor:
    def buy(self, *, price: float, size_usd: float, liquidity_usd: float) -> Fill:
        raise NotImplementedError

    def sell(self, *, price: float, quantity: float, liquidity_usd: float) -> Fill:
        raise NotImplementedError


class PaperExecutor(Executor):
    """Simulated fills. Slippage scales with the fraction of pool liquidity
    the order represents, which matters a lot for pump.fun-sized pools
    (a few thousand dollars deep) and much less for a deep DexScreener pair.
    """

    def __init__(self, base_slippage_pct: float = 0.3, impact_coefficient: float = 40.0):
        self.base_slippage_pct = base_slippage_pct
        self.impact_coefficient = impact_coefficient

    def _slippage_pct(self, order_usd: float, liquidity_usd: float) -> float:
        if liquidity_usd <= 0:
            return 10.0  # unknown/near-zero liquidity: assume it's bad
        pool_fraction = order_usd / liquidity_usd
        return self.base_slippage_pct + self.impact_coefficient * pool_fraction

    def buy(self, *, price: float, size_usd: float, liquidity_usd: float) -> Fill:
        slip = self._slippage_pct(size_usd, liquidity_usd)
        fill_price = price * (1 + slip / 100)
        quantity = size_usd / fill_price if fill_price else 0.0
        return Fill(price=fill_price, quantity=quantity, slippage_pct=slip)

    def sell(self, *, price: float, quantity: float, liquidity_usd: float) -> Fill:
        order_usd = quantity * price
        slip = self._slippage_pct(order_usd, liquidity_usd)
        fill_price = price * (1 - slip / 100)
        return Fill(price=fill_price, quantity=quantity, slippage_pct=slip)


class LiveExecutor(Executor):
    """Executes real swaps on Solana via the Jupiter aggregator.

    Requires `pip install solders solana` and a funded wallet. This class
    intentionally does no position sizing or risk logic of its own — it
    only fills orders the strategy/risk manager have already approved.
    """

    JUPITER_QUOTE_URL = "https://quote-api.jup.ag/v6/quote"
    JUPITER_SWAP_URL = "https://quote-api.jup.ag/v6/swap"
    SOL_MINT = "So11111111111111111111111111111111111111112"

    def __init__(self, rpc_url: str, private_key_base58: str, slippage_bps: int = 150):
        if not rpc_url or not private_key_base58:
            raise ValueError("LiveExecutor requires SOLANA_RPC_URL and WALLET_PRIVATE_KEY")
        try:
            from solders.keypair import Keypair  # type: ignore
        except ImportError as exc:  # pragma: no cover
            raise ImportError("Live trading requires `pip install solders solana`") from exc
        self.rpc_url = rpc_url
        self.keypair = Keypair.from_base58_string(private_key_base58)
        self.slippage_bps = slippage_bps
        self.session = requests.Session()
        logger.warning(
            "LiveExecutor initialized — REAL FUNDS at %s will be traded. "
            "Confirm SOLANA_RPC_URL, wallet balance, and slippage settings before proceeding.",
            str(self.keypair.pubkey()),
        )

    def _quote(self, input_mint: str, output_mint: str, amount: int) -> dict:
        resp = self.session.get(
            self.JUPITER_QUOTE_URL,
            params={
                "inputMint": input_mint,
                "outputMint": output_mint,
                "amount": amount,
                "slippageBps": self.slippage_bps,
            },
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()

    def _execute_swap(self, quote: dict) -> dict:
        import base64

        from solders.transaction import VersionedTransaction  # type: ignore

        swap_resp = self.session.post(
            self.JUPITER_SWAP_URL,
            json={
                "quoteResponse": quote,
                "userPublicKey": str(self.keypair.pubkey()),
                "wrapAndUnwrapSol": True,
                "dynamicComputeUnitLimit": True,
                "prioritizationFeeLamports": "auto",
            },
            timeout=15,
        )
        swap_resp.raise_for_status()
        swap_tx_b64 = swap_resp.json()["swapTransaction"]
        raw_tx = VersionedTransaction.from_bytes(base64.b64decode(swap_tx_b64))
        signed_tx = VersionedTransaction(raw_tx.message, [self.keypair])

        rpc_resp = self.session.post(
            self.rpc_url,
            json={
                "jsonrpc": "2.0", "id": 1, "method": "sendTransaction",
                "params": [base64.b64encode(bytes(signed_tx)).decode(), {"encoding": "base64", "maxRetries": 3}],
            },
            timeout=20,
        )
        rpc_resp.raise_for_status()
        return rpc_resp.json()

    def buy(self, *, price: float, size_usd: float, liquidity_usd: float, token_mint: str | None = None) -> Fill:
        raise NotImplementedError(
            "Wire token_mint -> lamport amount conversion (fetch decimals, convert size_usd to an "
            "input amount, call _quote/_execute_swap) for your target token before enabling live buys. "
            "Test with a tiny amount on a token you already understand before trusting this path."
        )

    def sell(self, *, price: float, quantity: float, liquidity_usd: float, token_mint: str | None = None) -> Fill:
        raise NotImplementedError(
            "Wire token_mint -> lamport amount conversion for your target token before enabling live sells."
        )
