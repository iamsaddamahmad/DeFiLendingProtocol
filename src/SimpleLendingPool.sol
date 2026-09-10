// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./IPriceOracle.sol";

/// @title SimpleLendingPool
/// @notice A simplified crypto-backed lending protocol: deposit collateral,
///         borrow against it up to a loan-to-value ratio, repay accrued
///         interest plus principal, and liquidate (fully or partially)
///         positions that fall below the liquidation threshold.
/// @dev EDUCATIONAL / DEMO CONTRACT. Not audited. See the repo README for
///      a full list of simplifications relative to production protocols
///      like Aave or Compound (linear interest, single price feed, no
///      professional audit).
contract SimpleLendingPool is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateralToken;
    IERC20 public immutable borrowToken;
    IPriceOracle public immutable oracle;

    uint256 public immutable loanToValueBps;
    uint256 public immutable liquidationThresholdBps;
    uint256 public immutable liquidationBonusBps;
    uint256 public immutable annualInterestRateBps;

    /// @notice Maximum fraction of a position's debt that can be repaid in
    ///         a single liquidation call, in basis points (e.g. 5000 =
    ///         50%). Limits how much capital any one liquidator needs and
    ///         reduces market impact from large, sudden liquidations —
    ///         the same rationale real protocols use for "close factors".
    ///         Full liquidation remains possible via repeated calls, or in
    ///         one call once remaining debt is small enough that the close
    ///         factor no longer binds (see `maxLiquidatable`).
    uint256 public immutable maxLiquidationCloseFactorBps;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    struct Position {
        uint256 collateral;
        uint256 principal;
        uint256 accruedInterest;
        uint256 lastUpdate;
    }

    mapping(address => Position) public positions;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event InterestAccrued(address indexed user, uint256 interestAmount);
    event Liquidated(
        address indexed borrower, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized
    );

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientCollateral();
    error ExceedsLoanToValue(uint256 requested, uint256 maxAllowed);
    error WithdrawalWouldUnderCollateralize();
    error PositionIsHealthy();
    error RepayExceedsDebt(uint256 requested, uint256 currentDebt);
    error InvalidThresholds();
    error ExceedsCloseFactor(uint256 requested, uint256 maxAllowed);

    constructor(
        address collateralToken_,
        address borrowToken_,
        address oracle_,
        uint256 loanToValueBps_,
        uint256 liquidationThresholdBps_,
        uint256 liquidationBonusBps_,
        uint256 annualInterestRateBps_,
        uint256 maxLiquidationCloseFactorBps_,
        address initialOwner
    ) Ownable(initialOwner) {
        if (
            collateralToken_ == address(0) || borrowToken_ == address(0) || oracle_ == address(0)
                || initialOwner == address(0)
        ) revert ZeroAddress();
        if (
            loanToValueBps_ == 0 || liquidationThresholdBps_ <= loanToValueBps_
                || liquidationThresholdBps_ > BPS_DENOMINATOR || maxLiquidationCloseFactorBps_ == 0
                || maxLiquidationCloseFactorBps_ > BPS_DENOMINATOR
        ) revert InvalidThresholds();

        collateralToken = IERC20(collateralToken_);
        borrowToken = IERC20(borrowToken_);
        oracle = IPriceOracle(oracle_);
        loanToValueBps = loanToValueBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationBonusBps = liquidationBonusBps_;
        annualInterestRateBps = annualInterestRateBps_;
        maxLiquidationCloseFactorBps = maxLiquidationCloseFactorBps_;
    }

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
        uint256 interest = (pos.principal * annualInterestRateBps * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        if (interest > 0) {
            pos.accruedInterest += interest;
            emit InterestAccrued(user, interest);
        }
        pos.lastUpdate = block.timestamp;
    }

    function totalDebt(address user) public view returns (uint256) {
        Position memory pos = positions[user];
        return pos.principal + pos.accruedInterest;
    }

    function currentDebt(address user) public view returns (uint256) {
        Position memory pos = positions[user];
        if (pos.lastUpdate == 0 || pos.principal == 0) {
            return pos.principal + pos.accruedInterest;
        }
        uint256 elapsed = block.timestamp - pos.lastUpdate;
        uint256 pendingInterest =
            (pos.principal * annualInterestRateBps * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
        return pos.principal + pos.accruedInterest + pendingInterest;
    }

    /// @notice The maximum amount of debt that can be repaid in a single
    ///         `liquidatePartial` call right now, for `user`. Equal to the
    ///         full debt if the close-factor-limited amount would exceed
    ///         the actual debt (i.e. small positions can always be closed
    ///         fully in one call).
    function maxLiquidatable(address user) public view returns (uint256) {
        uint256 debt = currentDebt(user);
        uint256 closeFactorLimited = (debt * maxLiquidationCloseFactorBps) / BPS_DENOMINATOR;
        return closeFactorLimited < debt ? closeFactorLimited : debt;
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

    function repay(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _accrue(msg.sender);
        Position storage pos = positions[msg.sender];
        uint256 debt = pos.principal + pos.accruedInterest;
        if (amount > debt) revert RepayExceedsDebt(amount, debt);

        _reduceDebt(pos, amount);
        emit Repaid(msg.sender, amount);
        borrowToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Fully liquidate an under-collateralized position in one call.
    function liquidate(address borrower) external nonReentrant whenNotPaused {
        _accrue(borrower);
        Position storage pos = positions[borrower];
        uint256 debt = pos.principal + pos.accruedInterest;
        if (debt == 0) revert PositionIsHealthy();
        if (!_isLiquidatable(pos.collateral, debt)) revert PositionIsHealthy();

        _executeLiquidation(borrower, pos, debt);
    }

    /// @notice Partially liquidate an under-collateralized position,
    ///         repaying up to `maxLiquidatable(borrower)` in one call.
    /// @param repayAmount Amount of debt to repay. Must not exceed
    ///        `maxLiquidatable(borrower)` — call that function first to
    ///        find the current limit.
    function liquidatePartial(address borrower, uint256 repayAmount) external nonReentrant whenNotPaused {
        if (repayAmount == 0) revert ZeroAmount();
        _accrue(borrower);
        Position storage pos = positions[borrower];
        uint256 debt = pos.principal + pos.accruedInterest;
        if (debt == 0) revert PositionIsHealthy();
        if (!_isLiquidatable(pos.collateral, debt)) revert PositionIsHealthy();

        uint256 limit = maxLiquidatable(borrower);
        if (repayAmount > limit) revert ExceedsCloseFactor(repayAmount, limit);

        _executeLiquidation(borrower, pos, repayAmount);
    }

    /// @dev Shared liquidation logic: seize collateral proportional to
    ///      `debtToRepay` plus the liquidation bonus, capped at the
    ///      position's total collateral. Used by both full and partial
    ///      liquidation — the only difference between them is how much of
    ///      the total debt `debtToRepay` represents.
    function _executeLiquidation(address borrower, Position storage pos, uint256 debtToRepay) internal {
        uint256 collateralValue = _collateralValue(pos.collateral);
        uint256 seizeValue = debtToRepay + (debtToRepay * liquidationBonusBps / BPS_DENOMINATOR);
        uint256 collateralToSeize = collateralValue == 0 ? 0 : (seizeValue * pos.collateral) / collateralValue;
        if (collateralToSeize > pos.collateral) {
            collateralToSeize = pos.collateral;
        }

        _reduceDebt(pos, debtToRepay);
        pos.collateral -= collateralToSeize;

        emit Liquidated(borrower, msg.sender, debtToRepay, collateralToSeize);

        borrowToken.safeTransferFrom(msg.sender, address(this), debtToRepay);
        collateralToken.safeTransfer(msg.sender, collateralToSeize);
    }

    /// @dev Reduces a position's debt by `amount`, paying down accrued
    ///      interest before principal — shared by repay() and liquidation.
    function _reduceDebt(Position storage pos, uint256 amount) internal {
        if (amount <= pos.accruedInterest) {
            pos.accruedInterest -= amount;
        } else {
            uint256 remainder = amount - pos.accruedInterest;
            pos.accruedInterest = 0;
            pos.principal -= remainder;
        }
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
