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
///         borrow against it up to a loan-to-value ratio, repay, and
///         liquidate positions that fall below the liquidation threshold.
/// @dev EDUCATIONAL / DEMO CONTRACT. Not audited. Missing several things a
///      real lending protocol needs before holding real value:
///        - Interest accrual (this version charges 0% interest)
///        - A decentralized price oracle (uses MockPriceOracle — see its
///          own NatSpec for why that matters)
///        - Partial liquidation logic (this version liquidates the entire
///          position at once, which is simpler but less capital-efficient
///          and can produce large liquidator payouts on big positions)
///        - Protection against oracle price staleness
///      Each of these is a real, separate engineering problem in
///      production protocols like Aave and Compound. This contract exists
///      to demonstrate the core mechanics correctly and safely on a small
///      scale, not to replace that engineering.
contract SimpleLendingPool is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice The token users deposit as collateral.
    IERC20 public immutable collateralToken;

    /// @notice The token users borrow.
    IERC20 public immutable borrowToken;

    /// @notice Price oracle: price of collateral, denominated in borrowToken.
    MockPriceOracle public immutable oracle;

    /// @notice Maximum borrow as a percentage of collateral value, in basis
    ///         points (e.g. 6600 = 66%). Set at deployment, immutable.
    uint256 public immutable loanToValueBps;

    /// @notice Collateral ratio below which a position becomes liquidatable,
    ///         in basis points (e.g. 8000 = position liquidatable once debt
    ///         reaches 80% of collateral value). Must be > loanToValueBps.
    uint256 public immutable liquidationThresholdBps;

    /// @notice Bonus paid to liquidators, in basis points of the collateral
    ///         they seize (e.g. 500 = 5% bonus).
    uint256 public immutable liquidationBonusBps;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    struct Position {
        uint256 collateral;
        uint256 debt;
    }

    mapping(address => Position) public positions;

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
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

    /// @param collateralToken_ ERC20 accepted as collateral.
    /// @param borrowToken_ ERC20 that can be borrowed.
    /// @param oracle_ Price oracle for collateralToken, denominated in borrowToken.
    /// @param loanToValueBps_ Max borrow as % of collateral value (basis points).
    /// @param liquidationThresholdBps_ Debt/collateral ratio that triggers
    ///        liquidation eligibility (basis points). Must exceed loanToValueBps_
    ///        so a healthy position always has room before liquidation.
    /// @param liquidationBonusBps_ Liquidator bonus on seized collateral (basis points).
    /// @param initialOwner Owner address (pause control only — this contract
    ///        has no admin minting or fund-withdrawal power over user funds).
    constructor(
        address collateralToken_,
        address borrowToken_,
        address oracle_,
        uint256 loanToValueBps_,
        uint256 liquidationThresholdBps_,
        uint256 liquidationBonusBps_,
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
    }

    /// @notice Deposit collateral into your position.
    function depositCollateral(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Effects before interaction (checks-effects-interactions pattern).
        positions[msg.sender].collateral += amount;

        emit CollateralDeposited(msg.sender, amount);

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Withdraw collateral, as long as the position stays within
    ///         the loan-to-value ratio afterward.
    function withdrawCollateral(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        if (pos.collateral < amount) revert InsufficientCollateral();

        uint256 newCollateral = pos.collateral - amount;
        uint256 maxBorrowAfter = _maxBorrow(newCollateral);
        if (pos.debt > maxBorrowAfter) revert WithdrawalWouldUnderCollateralize();

        pos.collateral = newCollateral;

        emit CollateralWithdrawn(msg.sender, amount);

        collateralToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Borrow against deposited collateral, up to the loan-to-value limit.
    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];

        uint256 newDebt = pos.debt + amount;
        uint256 maxBorrowable = _maxBorrow(pos.collateral);
        if (newDebt > maxBorrowable) {
            revert ExceedsLoanToValue(newDebt, maxBorrowable);
        }

        pos.debt = newDebt;

        emit Borrowed(msg.sender, amount);

        borrowToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Repay borrowed tokens, reducing your debt.
    function repay(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        Position storage pos = positions[msg.sender];
        if (amount > pos.debt) revert RepayExceedsDebt(amount, pos.debt);

        pos.debt -= amount;

        emit Repaid(msg.sender, amount);

        borrowToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Liquidate an under-collateralized position. The liquidator
    ///         repays the borrower's full debt and receives their collateral
    ///         plus a bonus, as long as enough collateral exists to cover it.
    /// @dev Whole-position liquidation only (no partial liquidation) —
    ///      a real production protocol would typically allow partial
    ///      liquidation to reduce liquidator capital requirements and
    ///      market impact.
    function liquidate(address borrower) external nonReentrant whenNotPaused {
        Position storage pos = positions[borrower];
        if (pos.debt == 0) revert PositionIsHealthy();
        if (!_isLiquidatable(pos)) revert PositionIsHealthy();

        uint256 debtToRepay = pos.debt;
        uint256 collateralValue = _collateralValue(pos.collateral);

        // Liquidator receives collateral proportional to debt repaid, plus bonus,
        // capped at the position's total collateral.
        uint256 seizeValue = debtToRepay + (debtToRepay * liquidationBonusBps / BPS_DENOMINATOR);
        uint256 collateralToSeize = collateralValue == 0
            ? 0
            : (seizeValue * pos.collateral) / collateralValue;
        if (collateralToSeize > pos.collateral) {
            collateralToSeize = pos.collateral;
        }

        pos.debt = 0;
        pos.collateral -= collateralToSeize;

        emit Liquidated(borrower, msg.sender, debtToRepay, collateralToSeize);

        borrowToken.safeTransferFrom(msg.sender, address(this), debtToRepay);
        collateralToken.safeTransfer(msg.sender, collateralToSeize);
    }

    /// @notice Pause all deposits, borrows, repayments, and liquidations.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume normal operation.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Whether a given position can currently be liquidated.
    function isLiquidatable(address user) external view returns (bool) {
        return _isLiquidatable(positions[user]);
    }

    /// @notice Maximum amount a user could currently borrow in total,
    ///         given their existing collateral (not accounting for existing debt).
    function maxBorrow(address user) external view returns (uint256) {
        return _maxBorrow(positions[user].collateral);
    }

    function _maxBorrow(uint256 collateralAmount) internal view returns (uint256) {
        return (_collateralValue(collateralAmount) * loanToValueBps) / BPS_DENOMINATOR;
    }

    function _collateralValue(uint256 collateralAmount) internal view returns (uint256) {
        return (collateralAmount * oracle.price()) / 1e18;
    }

    function _isLiquidatable(Position memory pos) internal view returns (bool) {
        if (pos.debt == 0) return false;
        uint256 liquidationDebtCap =
            (_collateralValue(pos.collateral) * liquidationThresholdBps) / BPS_DENOMINATOR;
        return pos.debt > liquidationDebtCap;
    }
}
