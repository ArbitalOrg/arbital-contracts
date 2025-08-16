# Arb Observer — Contracts

Non-custodial arbitrage vault with **cohort pooling**, **soulbound Position NFT**, **non-linear principal vesting**, and **pro‑rata PnL** distribution. Multi-chain friendly (deploy one vault per network/asset).

## Stack
- Foundry
- OpenZeppelin Contracts v4.9.x

## Install
```bash
git clone <your-repo-url> arb-observer-contracts
cd arb-observer-contracts
forge install openzeppelin/openzeppelin-contracts@v4.9.5
forge build
```

## Test
```bash
forge test -vv
```

## Deploy (example)
```bash
export ASSET=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48   # USDC (example)
export FEE_RECIPIENT=0xYourTreasury
export PERF_FEE_BPS=1500  # 15%
forge script script/Deploy.s.sol:Deploy   --rpc-url $RPC_URL   --private-key $PK   --broadcast -vv
```

## Security notes
- Soulbound Position NFT (non-transferable).
- `cancelBeforeActivation()` returns **100% principal** before cohort activation (user pays gas).
- PnL is distributed via a cohort-wide index; perf-fee is charged only on **positive cumulative PnL** (HWM-like behavior).
- No project token. No fixed APY. Principal vesting is **return of funds, not yield**.
- Guardian can `pause` execution.
