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
│   ├── SimpleLendingPool.sol   # Core lending logic
│   └── MockPriceOracle.sol     # Owner-settable price feed (stands in for Chainlink)
├── script/
│   ├── DeployLendingPool.s.sol       # Deploys oracle + pool together
│   └── DeployLendingPoolOnly.s.sol   # Deploys just the pool, given an existing oracle
├── test/
│   └── SimpleLendingPool.t.sol # Unit + fuzz tests, including a full liquidation scenario
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
3. **Repay** — pay back borrowed tokens to reduce debt and free up
   collateral for withdrawal.
4. **Withdraw collateral** — allowed any time it wouldn't push the
   remaining position over its loan-to-value limit.
5. **Liquidation** — if a position's debt rises above
   `liquidationThresholdBps` of its collateral value (e.g. because the
   collateral's price drops), *anyone* can repay that debt and receive the
   collateral plus a bonus (`liquidationBonusBps`). This is the incentive
   mechanism that keeps the protocol solvent without relying on a trusted
   party to monitor positions.

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

11 tests, including:
- Deposit, borrow within limits, repay, withdrawal health checks
- Rejection of borrows that exceed the loan-to-value ratio
- Rejection of withdrawals that would under-collateralize a position
- **A full liquidation scenario**: a healthy position, a simulated price
  crash via the mock oracle, confirmation the position becomes
  liquidatable, and a liquidator profiting from the bonus — the complete
  mechanism, not just isolated pieces
- A fuzz test confirming positions opened at the maximum allowed
  loan-to-value are never immediately liquidatable at the same price

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

Same pattern works on any network defined in `foundry.toml` — swap
`--rpc-url sepolia` for any other configured chain.

## Deployed addresses (Sepolia testnet)

| Contract | Address | Explorer |
|---|---|---|
| Collateral token (USDT_TEST, stablecoin stand-in) | `0xf7776eDcE20AF5048fDE7a500449E317C570C698` | [View](https://sepolia.etherscan.io/address/0xf7776edce20af5048fde7a500449e317c570c698#code) |
| Borrow token (MyToken / MTK, from the [token repo](https://github.com/iamsaddamahmad/MultichainContract)) | `0x4602E3EDc16d24457C7Af5f286e89a43e7575119` | [View](https://sepolia.etherscan.io/address/0x4602e3edc16d24457c7af5f286e89a43e7575119#code) |
| Price oracle | `0x645d4a9B80BCA3Ea0212B6100b204C274f5D75cC` | [View](https://sepolia.etherscan.io/address/0x645d4a9b80bca3ea0212b6100b204c274f5d75cc#code) |
| Lending pool | `0x47541b746357f5d2C5728572769A86906aD65478` | [View](https://sepolia.etherscan.io/address/0x47541b746357f5d2c5728572769a86906ad65478#code) |

**Live parameters:** 66% loan-to-value, 80% liquidation threshold, 5%
liquidation bonus, oracle price fixed at 1 collateral token = 2,000 borrow
tokens (arbitrary demo ratio, manually settable by the owner).

A real deposit → borrow cycle has been executed and verified on this
deployment: 10 collateral tokens deposited, 5,000 borrow tokens drawn
against them (well within the 13,200 maximum allowed at that collateral
level), confirmed via `positions()` on-chain.

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

# Liquidate an under-collateralized position (as the liquidator, requires
# approving the pool to pull the borrow token needed to repay the debt)
cast send <BORROW_TOKEN> "approve(address,uint256)" <POOL_ADDRESS> <AMOUNT> --rpc-url sepolia --private-key $LIQUIDATOR_PRIVATE_KEY
cast send <POOL_ADDRESS> "liquidate(address)" <BORROWER_ADDRESS> --rpc-url sepolia --private-key $LIQUIDATOR_PRIVATE_KEY
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

### Known limitations (by design, for a learning/demo project)

This is an educational implementation of the core mechanics, not
production-grade lending infrastructure. Specifically missing, compared to
protocols like Aave or Compound:

- **No interest accrual** — borrowing is currently interest-free; a real
  protocol accrues interest over time based on utilization
- **Mock price oracle, not a decentralized one** — `MockPriceOracle` is a
  single owner-settable value. This is a critical centralization and
  manipulation risk in any deployment holding real value; production
  protocols use Chainlink Price Feeds or similar decentralized oracle
  networks specifically to prevent any single party from moving the price
- **Whole-position liquidation only** — a liquidatable position is
  liquidated entirely in one transaction; real protocols typically support
  partial liquidation to reduce liquidator capital requirements and limit
  market impact
- **No oracle staleness checks** — a production system would reject prices
  that haven't updated recently, rather than trusting whatever value is
  currently stored
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
