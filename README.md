//Readme
# Simple Lending Protocol

A simplified crypto-backed lending protocol built with
[Foundry](https://book.getfoundry.sh/) and
[OpenZeppelin](https://www.openzeppelin.com/contracts): deposit collateral,
borrow a different asset against it up to a loan-to-value limit, repay, and
liquidate positions that fall below a liquidation threshold — the same core
mechanics behind protocols like Aave and Compound, at a scale meant to be
read, tested, and understood end to end.

Deposit one asset (e.g. a stablecoin) as collateral, borrow a different
asset (e.g. an ETH- or BTC-like token) against it, without selling the
original holdings — exactly the pattern real lending markets use.

## Architecture

```
.
├── src/
│   ├── SimpleLendingPool.sol      # Core lending logic
│   ├── IPriceOracle.sol           # Shared price interface — pool works with either oracle below
│   ├── MockPriceOracle.sol        # Owner-settable price feed, for testing/demos
│   └── ChainlinkPriceOracle.sol   # Real decentralized price feed adapter, for actual deployments
├── script/
│   ├── DeployLendingPool.s.sol       # Deploys mock oracle + pool together
│   ├── DeployLendingPoolOnly.s.sol   # Deploys just the pool, given an existing oracle
│   └── DeployChainlinkPool.s.sol     # Deploys Chainlink oracle + pool together
├── test/
│   ├── SimpleLendingPool.t.sol       # Unit + fuzz tests, including interest accrual and liquidation
│   └── ChainlinkPriceOracle.t.sol    # Oracle adapter tests: decimal rescaling, staleness rejection
├── foundry.toml                # Multi-chain RPC + explorer config
└── .env.example                # Required environment variables
```

This repo is intentionally separate from the
[MultichainContract](https://github.com/iamsaddamahmad/MultichainContract)
ERC-20 token repo — a lending protocol is a distinct piece of infrastructure
that happens to consume ERC-20 tokens as inputs, not a feature of any one
token. The deployed instance below actually uses tokens from that other
repo as its borrow asset, tying the two projects together without merging
their codebases.

## How it works

1. **Deposit collateral** — lock an ERC20 (e.g. a stablecoin) into the pool.
2. **Borrow** — draw a different ERC20 against that collateral, up to
   `loanToValueBps` (e.g. 66%) of its current value.
3. **Interest accrues** — debt grows over time at `annualInterestRateBps`
   (linear, non-compounding), calculated fresh on every deposit, borrow,
   repay, or liquidation check — see [Interest model](#interest-model).
4. **Repay** — pay back borrowed tokens (interest first, then principal) to
   reduce debt and free up collateral for withdrawal.
5. **Withdraw collateral** — allowed any time it wouldn't push the
   remaining position (including accrued interest) over its loan-to-value
   limit.
6. **Liquidation** — if a position's total debt (principal + interest)
   rises above `liquidationThresholdBps` of its collateral value — because
   the collateral's price drops, because enough time and interest has
   passed, or both — *anyone* can repay that debt and receive the
   collateral plus a bonus (`liquidationBonusBps`). This is the incentive
   mechanism that keeps the protocol solvent without relying on a trusted
   party to monitor positions.

## Price oracles

The pool depends on `IPriceOracle`, a one-function interface
(`price() returns (uint256)`), not on any specific oracle implementation —
swapping oracles requires no changes to `SimpleLendingPool` itself, only a
different address at deployment.

**`ChainlinkPriceOracle`** — what real deployments use. Wraps a live
Chainlink `AggregatorV3Interface` price feed, rescales its answer to 18
decimals, and **reverts if the feed is stale** (hasn't updated within
`maxStaleness`) or reports a non-positive price — both are real failure
modes a production system must handle explicitly rather than trust blindly.

**`MockPriceOracle`** — owner-settable, for local testing and demos where
deterministic, controllable prices matter (e.g. simulating a price crash in
a test, as `SimpleLendingPool.t.sol` does). Never intended for a deployment
holding real value — a single owner-controlled price is a centralization
and manipulation risk that decentralized oracles specifically exist to
avoid.

## Interest model

Interest is **linear (simple), not compounding**:

```
interest = principal × annualInterestRateBps × secondsElapsed
           ────────────────────────────────────────────────
                  10,000 × secondsPerYear
```

This was a deliberate choice over a compounding model. Compounding interest
on-chain requires careful fixed-point math to avoid precision loss or
overflow across long time periods, and a simpler, provably correct model
was preferred over a compounding one implemented incorrectly. A production
protocol (Aave, Compound) uses a compounding, utilization-based rate — a
meaningfully larger and separate engineering problem from what this repo
demonstrates.

Two read functions expose debt:
- `totalDebt(user)` — principal + interest accrued as of the last on-chain
  update (cheap, but can be stale if no transaction has touched the
  position recently)
- `currentDebt(user)` — principal + interest computed live, including time
  elapsed since the last update, without needing a transaction first (use
  this for anything time-sensitive, like checking `isLiquidatable`)

## Setup

```bash
git clone <this-repo-url>
cd lending-protocol
forge install
cp .env.example .env
```

Fill in `.env` with real values — **never commit this file**.

## Testing

```bash
forge test -vv
```

27 tests across two suites:

`SimpleLendingPool.t.sol` (20 tests):
- Deposit, borrow within limits, repay, withdrawal health checks
- Rejection of borrows that exceed the loan-to-value ratio
- Rejection of withdrawals that would under-collateralize a position
- **Interest accrual over exactly one year**, confirming a 5% APR position
  accrues exactly 500 in interest on a 10,000 principal — not just that
  interest exists, but that the math is correct
- **Partial-year interest** accrual, confirming proportional accrual for
  a non-whole-year time span
- **Repayment order**: confirms interest is paid down before principal
- **A full price-crash liquidation scenario**: a healthy position, a
  simulated price crash via the mock oracle, confirmation the position
  becomes liquidatable, and a liquidator profiting from the bonus
- **A liquidation-by-interest-alone scenario**: confirms a position at the
  borrowing limit can become liquidatable purely from accrued interest
  over time, with no price movement at all — a distinct trigger from price
  risk
- **Partial liquidation respects the close factor**: rejects a repay
  amount above the limit, confirms the correct maximum
- **Two sequential partial liquidations by different liquidators fully
  close a position** — the close factor recalculates correctly against
  remaining debt each time, not just once against the original amount
- Confirmation full liquidation (`liquidate`) still works unchanged
  alongside the new partial path (`liquidatePartial`)
- A fuzz test confirming positions opened at the maximum allowed
  loan-to-value are never immediately liquidatable at the same price

`ChainlinkPriceOracle.t.sol` (7 tests):
- Correct rescaling from 8-decimal (typical Chainlink format) to 18-decimal
- Correct pass-through when the feed already reports 18 decimals
- **Staleness rejection**, including a test confirming a price just under
  the staleness cutoff still succeeds (the boundary condition, not just
  the failure case)
- Rejection of zero or negative prices
- Rejection of a zero feed address at construction
- Confirmation that the interface swap between mock and Chainlink oracles
  is real, not assumed — checked via a raw selector-matching call

## Deployment

Deploy the oracle and pool together:
```bash
forge script script/DeployLendingPool.s.sol:DeployLendingPool --rpc-url sepolia --broadcast --verify
```

Or, if an oracle already exists and you only need a new pool pointed at it
(set `ORACLE_ADDRESS` in `.env` first):
```bash
forge script script/DeployLendingPoolOnly.s.sol:DeployLendingPoolOnly --rpc-url sepolia --broadcast --verify
```

Or, deploy against a real Chainlink price feed (recommended for anything
beyond local mock-oracle testing):
```bash
forge script script/DeployChainlinkPool.s.sol:DeployChainlinkPool --rpc-url sepolia --broadcast --verify
```

Same pattern works on any network defined in `foundry.toml` — swap
`--rpc-url sepolia` for any other configured chain.

## Deployed addresses (Sepolia testnet)

### Current — Chainlink-backed, with interest accrual and partial liquidation (flagship deployment)

| Contract | Address | Explorer |
|---|---|---|
| Collateral token (USDT_TEST, stablecoin stand-in) | `0xf7776eDcE20AF5048fDE7a500449E317C570C698` | [View](https://sepolia.etherscan.io/address/0xf7776edce20af5048fde7a500449e317c570c698#code) |
| Borrow token (MyToken / MTK, from the [token repo](https://github.com/iamsaddamahmad/MultichainContract)) | `0x4602E3EDc16d24457C7Af5f286e89a43e7575119` | [View](https://sepolia.etherscan.io/address/0x4602e3edc16d24457c7af5f286e89a43e7575119#code) |
| Chainlink price oracle (wraps the real Sepolia ETH/USD feed, `0x694AA1769357215DE4FAC081bf1f309aDC325306`) | `0x2Df4A9882563C39893e7EF3435DAFbb68c522F6c` | [View](https://sepolia.etherscan.io/address/0x2df4a9882563c39893e7ef3435dafbb68c522f6c#code) |
| Lending pool | `0x037A610845d6982841939772AB1F2B95570C9317` | [View](https://sepolia.etherscan.io/address/0x037a610845d6982841939772ab1f2b95570c9317#code) |

**Live parameters:** 66% loan-to-value, 80% liquidation threshold, 5%
liquidation bonus, 5% APR interest (linear), **50% max close factor per
liquidation call**, price sourced live from Chainlink's decentralized
oracle network (confirmed reading a real price of $2,435.26 per ETH at
deployment — not a value anyone set manually).

### Superseded — earlier versions (kept for reference)

| Contract | Address | Notes |
|---|---|---|
| Lending pool, Chainlink oracle, no partial liquidation | `0x031E2E0B0d518E2083C562474b933D17179d64e5` | Superseded — partial liquidation added since |
| Chainlink oracle (paired with above) | `0x4D0f9e2700A5acd983154b3A5056Cec8586c6f48` | Superseded |
| Lending pool, mock oracle, with interest | `0x1b6A211716598c7fAcAD4EeB561748004CEFCBF3` | Superseded |
| Mock oracle (paired with above) | `0x2868651e67A85f6CA48e013fc173E2023A80BAe4` | Superseded |
| Lending pool, mock oracle, no interest | `0x47541b746357f5d2C5728572769A86906aD65478` | Superseded — earliest version |
| Mock oracle (paired with above) | `0x645d4a9B80BCA3Ea0212B6100b204C274f5D75cC` | Superseded |

A real deposit → borrow cycle has been executed and verified on the
mock-oracle deployment; every Chainlink-backed deployment has been
confirmed to read a live, correct price on-chain at the moment of
deployment.

## Interacting with the deployed contracts

```bash
# Check your position
cast call <POOL_ADDRESS> "positions(address)(uint256,uint256)" <YOUR_ADDRESS> --rpc-url sepolia

# Check your maximum borrowable amount given current collateral
cast call <POOL_ADDRESS> "maxBorrow(address)(uint256)" <YOUR_ADDRESS> --rpc-url sepolia

# Check if a position is currently liquidatable
cast call <POOL_ADDRESS> "isLiquidatable(address)(bool)" <BORROWER_ADDRESS> --rpc-url sepolia

# Deposit collateral (requires approving the pool first)
cast send <COLLATERAL_TOKEN> "approve(address,uint256)" <POOL_ADDRESS> <AMOUNT> --rpc-url sepolia --private-key $PRIVATE_KEY
cast send <POOL_ADDRESS> "depositCollateral(uint256)" <AMOUNT> --rpc-url sepolia --private-key $PRIVATE_KEY

# Borrow
cast send <POOL_ADDRESS> "borrow(uint256)" <AMOUNT> --rpc-url sepolia --private-key $PRIVATE_KEY

# Repay (requires approving the pool to pull the borrow token first)
cast send <BORROW_TOKEN> "approve(address,uint256)" <POOL_ADDRESS> <AMOUNT> --rpc-url sepolia --private-key $PRIVATE_KEY
cast send <POOL_ADDRESS> "repay(uint256)" <AMOUNT> --rpc-url sepolia --private-key $PRIVATE_KEY

# Check maximum debt liquidatable in a single call right now
cast call <POOL_ADDRESS> "maxLiquidatable(address)(uint256)" <BORROWER_ADDRESS> --rpc-url sepolia

# Liquidate an under-collateralized position (as the liquidator, requires
# approving the pool to pull the borrow token needed to repay the debt)
cast send <BORROW_TOKEN> "approve(address,uint256)" <POOL_ADDRESS> <AMOUNT> --rpc-url sepolia --private-key $LIQUIDATOR_PRIVATE_KEY
cast send <POOL_ADDRESS> "liquidate(address)" <BORROWER_ADDRESS> --rpc-url sepolia --private-key $LIQUIDATOR_PRIVATE_KEY

# Or partially liquidate — repay up to maxLiquidatable(borrower), receive
# a proportional share of collateral plus bonus
cast send <BORROW_TOKEN> "approve(address,uint256)" <POOL_ADDRESS> <REPAY_AMOUNT> --rpc-url sepolia --private-key $LIQUIDATOR_PRIVATE_KEY
cast send <POOL_ADDRESS> "liquidatePartial(address,uint256)" <BORROWER_ADDRESS> <REPAY_AMOUNT> --rpc-url sepolia --private-key $LIQUIDATOR_PRIVATE_KEY
```

## Security

### What's implemented

- **Reentrancy protection** on every state-changing function
  (`ReentrancyGuard`), combined with checks-effects-interactions ordering
  (state updated before any external token transfer) — this contract, unlike
  a plain ERC-20, makes real external calls on every action, so this
  protection is load-bearing, not precautionary
- **Custom errors + zero-address checks** throughout
- **Two-step ownership** (`Ownable2Step`) — the owner can only pause/unpause,
  has no minting power and no ability to withdraw user funds directly
- **Pausable** — an emergency stop for all deposits, borrows, repayments,
  and liquidations
- **Static analysis** with [Slither](https://github.com/crytic/slither) —
  `slither src/SimpleLendingPool.sol` reports no findings in this contract's
  own logic; all findings trace to OpenZeppelin's library internals
  (`Ownable2Step`'s self-healing zero-check, `SafeERC20`'s assembly usage)
- **Test suite includes an actual liquidation scenario**, not just isolated
  unit assertions — a price crash is simulated, the position's liquidatable
  state is confirmed, and a liquidator's profit from the bonus is verified
- **Oracle-agnostic design** (`IPriceOracle`) — the pool depends on a
  one-function interface, not a concrete oracle implementation, so a real
  Chainlink-backed deployment and a mock-oracle test deployment share
  identical pool logic with zero code duplication or special-casing
- **Real Chainlink integration** (`ChainlinkPriceOracle`) — deployed against
  the actual Sepolia ETH/USD feed, with staleness rejection and non-positive
  price rejection both implemented and tested
- **Partial liquidation** with a close factor (`maxLiquidationCloseFactorBps`)
  — limits how much debt can be repaid in a single liquidation call,
  reducing the capital any one liquidator needs and market impact from a
  single large seizure; full liquidation (`liquidate`) remains available
  for positions small enough that the close factor no longer binds, or for
  liquidators who simply prefer to close a position in one transaction

### Known limitations (by design, for a learning/demo project)

This is an educational implementation of the core mechanics, not
production-grade lending infrastructure. Specifically missing, compared to
protocols like Aave or Compound:

- **Linear, not compounding, interest** — see [Interest model](#interest-model)
  for why this was a deliberate simplification
- **Single price feed, no fallback** — if the configured Chainlink feed
  itself is compromised or deprecated, the pool has no secondary oracle to
  fall back on; production systems often aggregate multiple sources
- **No independent professional audit** — this contract has been reasoned
  through, tested, and run through Slither, but has not been reviewed by a
  human security researcher. See the token repo's README for a fuller
  discussion of when a professional audit is (and isn't) worth the cost for
  a project at this stage.

None of these are oversights — they're the specific pieces every real
lending protocol has to solve, called out explicitly rather than glossed
over, so the difference between "demonstrates the mechanics" and
"production-ready" stays honest.

## License

MIT
