// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./MockPriceOracle.sol";

/// @title SimpleLendingPool
/// @notice A simplified crypto-backed lending protocol: deposit collateral,
///         borrow against it up to a loan-to-value ratio, repay accrued
///         interest plus principal, and liquidate positions that fall
///         below the liquidation threshold.
/// @dev EDUCATIONAL / DEMO CONTRACT. Not audited. Interest uses a simple
///      linear (non-compounding) model — `interest = principal * rate *
///      elapsedTime / (BPS_DENOMINATOR * SECONDS_PER_YEAR)` — deliberately
///      chosen over compound interest for this version: compounding on-chain
///      needs careful fixed-point math to avoid precision loss or overflow,
///      and getting that subtly wrong is a worse outcome than a simpler,
///      provably correct model. A production protocol would likely use a
///      compounding, utilization-based rate (like Aave's), which is a
///      meaningfully larger and separate engineering problem from what's
///      demonstrated here.
///
///      Still missing before real-value use: a decentralized price oracle
///      (uses MockPriceOracle — see its own NatSpec), partial liquidation,
///      oracle staleness checks, and a professional audit.
contract SimpleLendingPool is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateralToken;
    IERC20 public immutable borrowToken;
    MockPriceOracle public immutable oracle;

    uint256 public immutable loanToValueBps;
    uint256 public immutable liquidationThresholdBps;
    uint256 public immutable liquidationBonusBps;

    /// @notice Annual interest rate on borrowed amounts, in basis points
    ///         (e.g. 500 = 5% APR). Fixed at deployment.
    uint256 public immutable annualInterestRateBps;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    struct Position {
        uint256 collateral;
        uint256 principal; // borrowed amount, excluding interest
        uint256 accruedInterest; // interest accumulated as of lastUpdate
        uint256 lastUpdate; // timestamp interest was last accrued
    }

    mapping(address => Position) public positions;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event InterestAccrued(address indexed user, uint256 interestAmount);
    event Liquidated(
        address indexed borrower,
        address indexed liquidator,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientCollateral();
    error ExceedsLoanToValue(uint256 requested, uint256 maxAllowed);
    error WithdrawalWouldUnderCollateralize();
    error PositionIsHealthy();
    error RepayExceedsDebt(uint256 requested, uint256 currentDebt);
    error InvalidThresholds();

    constructor(
        address collateralToken_,
        address borrowToken_,
        address oracle_,
        uint256 loanToValueBps_,
        uint256 liquidationThresholdBps_,
        uint256 liquidationBonusBps_,
        uint256 annualInterestRateBps_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            collateralToken_ == address(0) || borrowToken_ == address(0)
                || oracle_ == address(0) || initialOwner == address(0)
        ) revert ZeroAddress();
        if (
            loanToValueBps_ == 0 || liquidationThresholdBps_ <= loanToValueBps_
                || liquidationThresholdBps_ > BPS_DENOMINATOR
        ) revert InvalidThresholds();

        collateralToken = IERC20(collateralToken_);
        borrowToken = IERC20(borrowToken_);
        oracle = MockPriceOracle(oracle_);
        loanToValueBps = loanToValueBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationBonusBps = liquidationBonusBps_;
        annualInterestRateBps = annualInterestRateBps_;
    }

    /// @dev Accrues interest on `user`'s position up to the current block
    ///      timestamp, moving it from "not yet counted" into
    ///      `accruedInterest`. Must be called before any function that
    ///      reads or changes debt, so debt is always current.
    function _accrue(address user) internal {
        Position storage pos = positions[user];
        if (pos.lastUpdate == 0) {
            pos.lastUpdate = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - pos.lastUpdate;
        if (elapsed == 0 || pos.principal == 0) {
            pos.lastUpdate = block.timestamp;
            return;
        }
        uint256 interest = (pos.principal * annualInterestRateBps * elapsed)
            / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        if (interest > 0) {
            pos.accruedInterest += interest;
            emit InterestAccrued(user, interest);
        }
        pos.lastUpdate = block.timestamp;
    }

    /// @notice Total debt (principal + accrued interest) for `user`, as of
    ///         the last time it was accrued on-chain. For a view of debt
    ///         accrued up to *right now* (including time since the last
    ///         transaction), use `currentDebt`.
    function totalDebt(address user) public view returns (uint256) {
        Position memory pos = positions[user];
        return pos.principal + pos.accruedInterest;
    }

    /// @notice Debt including interest accrued up to this exact block,
    ///         without needing a transaction first.
    function currentDebt(address user) public view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.lastUpdate == 0 || pos.principal == 0) {
            return pos.principal + pos.accruedInterest;
        }
        uint256 elapsed = block.timestamp - pos.lastUpdate;
        uint256 pendingInterest = (pos.principal * annualInterestRateBps * elapsed)
            / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        return pos.principal + pos.accruedInterest + pendingInterest;
    }

    function depositCollateral(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);

        positions[msg.sender].collateral += amount;
        emit CollateralDeposited(msg.sender, amount);

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        Position storage pos = positions[msg.sender];
        if (pos.collateral < amount) revert InsufficientCollateral();

        uint256 newCollateral = pos.collateral - amount;
        uint256 debt = pos.principal + pos.accruedInterest;
        uint256 maxBorrowAfter = _maxBorrow(newCollateral);
        if (debt > maxBorrowAfter) revert WithdrawalWouldUnderCollateralize();

        pos.collateral = newCollateral;
        emit CollateralWithdrawn(msg.sender, amount);

        collateralToken.safeTransfer(msg.sender, amount);
    }

    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        Position storage pos = positions[msg.sender];

        uint256 newDebt = pos.principal + pos.accruedInterest + amount;
        uint256 maxBorrowable = _maxBorrow(pos.collateral);
        if (newDebt > maxBorrowable) {
            revert ExceedsLoanToValue(newDebt, maxBorrowable);
        }

        pos.principal += amount;
        emit Borrowed(msg.sender, amount);

        borrowToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Repay debt. Interest is repaid first, then principal.
    function repay(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        Position storage pos = positions[msg.sender];
        uint256 debt = pos.principal + pos.accruedInterest;
        if (amount > debt) revert RepayExceedsDebt(amount, debt);

        if (amount <= pos.accruedInterest) {
            pos.accruedInterest -= amount;
        } else {
            uint256 remainder = amount - pos.accruedInterest;
            pos.accruedInterest = 0;
            pos.principal -= remainder;
        }

        emit Repaid(msg.sender, amount);

        borrowToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function liquidate(address borrower) external nonReentrant whenNotPaused {
        _accrue(borrower);
        Position storage pos = positions[borrower];
        uint256 debt = pos.principal + pos.accruedInterest;
        if (debt == 0) revert PositionIsHealthy();
        if (!_isLiquidatable(pos.collateral, debt)) revert PositionIsHealthy();

        uint256 collateralValue = _collateralValue(pos.collateral);
        uint256 seizeValue = debt + (debt * liquidationBonusBps / BPS_DENOMINATOR);
        uint256 collateralToSeize =
            collateralValue == 0 ? 0 : (seizeValue * pos.collateral) / collateralValue;
        if (collateralToSeize > pos.collateral) {
            collateralToSeize = pos.collateral;
        }

        pos.principal = 0;
        pos.accruedInterest = 0;
        pos.collateral -= collateralToSeize;

        emit Liquidated(borrower, msg.sender, debt, collateralToSeize);

        borrowToken.safeTransferFrom(msg.sender, address(this), debt);
        collateralToken.safeTransfer(msg.sender, collateralToSeize);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function isLiquidatable(address user) external view returns (bool) {
        return _isLiquidatable(positions[user].collateral, currentDebt(user));
    }

    function maxBorrow(address user) external view returns (uint256) {
        return _maxBorrow(positions[user].collateral);
    }

    function _maxBorrow(uint256 collateralAmount) internal view returns (uint256) {
        return (_collateralValue(collateralAmount) * loanToValueBps) / BPS_DENOMINATOR;
    }

    function _collateralValue(uint256 collateralAmount) internal view returns (uint256) {
        return (collateralAmount * oracle.price()) / 1e18;
    }

    function _isLiquidatable(uint256 collateralAmount, uint256 debt) internal view returns (bool) {
        if (debt == 0) return false;
        uint256 liquidationDebtCap = (_collateralValue(collateralAmount) * liquidationThresholdBps) / BPS_DENOMINATOR;
        return debt > liquidationDebtCap;
    }
}
