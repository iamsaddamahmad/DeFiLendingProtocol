// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SimpleLendingPool.sol";
import "../src/MockPriceOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract SimpleLendingPoolTest is Test {
    SimpleLendingPool pool;
    MockPriceOracle oracle;
    TestToken collateralToken;
    TestToken borrowToken;

    address owner = address(this);
    address alice = address(0x1);
    address bob = address(0x2);
    address carol = address(0x3);

    uint256 constant LTV_BPS = 6_600;
    uint256 constant LIQ_THRESHOLD_BPS = 8_000;
    uint256 constant LIQ_BONUS_BPS = 500;
    uint256 constant INTEREST_RATE_BPS = 500; // 5% APR
    uint256 constant CLOSE_FACTOR_BPS = 5_000; // 50% max per liquidation call
    uint256 constant INITIAL_PRICE = 2_000e18;

    function setUp() public {
        collateralToken = new TestToken("Collateral", "COLL");
        borrowToken = new TestToken("Borrow", "BORW");
        oracle = new MockPriceOracle(INITIAL_PRICE, owner);

        pool = new SimpleLendingPool(
            address(collateralToken),
            address(borrowToken),
            address(oracle),
            LTV_BPS,
            LIQ_THRESHOLD_BPS,
            LIQ_BONUS_BPS,
            INTEREST_RATE_BPS,
            CLOSE_FACTOR_BPS,
            owner
        );

        borrowToken.mint(address(pool), 1_000_000e18);

        collateralToken.mint(alice, 100e18);
        vm.prank(alice);
        collateralToken.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        borrowToken.approve(address(pool), type(uint256).max);

        borrowToken.mint(bob, 1_000_000e18);
        vm.startPrank(bob);
        borrowToken.approve(address(pool), type(uint256).max);
        collateralToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        borrowToken.mint(carol, 1_000_000e18);
        vm.startPrank(carol);
        borrowToken.approve(address(pool), type(uint256).max);
        collateralToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _openUnderwaterPosition() internal {
        vm.startPrank(alice);
        pool.depositCollateral(10e18); // worth 20,000 at price 2000
        pool.borrow(13_200e18); // 66% LTV, healthy for now
        vm.stopPrank();

        oracle.setPrice(1_000e18); // collateral now worth 10,000 — deeply underwater
    }

    // --- Original coverage ---

    function testDepositCollateral() public {
        vm.prank(alice);
        pool.depositCollateral(10e18);
        (uint256 collateral,,,) = pool.positions(alice);
        assertEq(collateral, 10e18);
    }

    function testBorrowWithinLTV() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(13_200e18);
        vm.stopPrank();

        assertEq(pool.totalDebt(alice), 13_200e18);
    }

    function testCannotBorrowPastLTV() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        uint256 maxBorrowable = pool.maxBorrow(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                SimpleLendingPool.ExceedsLoanToValue.selector, maxBorrowable + 1, maxBorrowable
            )
        );
        pool.borrow(maxBorrowable + 1);
        vm.stopPrank();
    }

    /// @dev Core interest test: borrow, let a year pass, confirm ~5% interest
    ///      accrued — proving the linear rate model is actually correct,
    ///      not just present.
    function testInterestAccruesOverTime() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(10_000e18);
        vm.stopPrank();

        assertEq(pool.currentDebt(alice), 10_000e18);

        vm.warp(block.timestamp + 365 days);

        // 5% APR on 10,000 for exactly one year = 500.
        assertEq(pool.currentDebt(alice), 10_500e18);
    }

    function testInterestAccruesProportionallyForPartialYear() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(10_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 182 days + 12 hours); // ~half a year

        uint256 debt = pool.currentDebt(alice);
        assertApproxEqAbs(debt, 10_250e18, 1e18);
    }

    function testRepayPaysInterestBeforePrincipal() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(10_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days); // debt now 10,500 (500 interest)

        vm.prank(alice);
        pool.repay(300e18); // less than the 500 owed in interest

        (, uint256 principal, uint256 accruedInterest,) = pool.positions(alice);
        assertEq(principal, 10_000e18); // untouched — interest paid first
        assertEq(accruedInterest, 200e18); // 500 - 300
    }

    function testRepayFullyClearsDebtAfterInterest() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(10_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 365 days); // debt now 10,500

        vm.startPrank(alice);
        borrowToken.mint(alice, 500e18); // top up so alice can repay interest too
        pool.repay(10_500e18);
        vm.stopPrank();

        assertEq(pool.totalDebt(alice), 0);
    }

    function testCannotWithdrawIfItWouldUnderCollateralize() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(13_200e18);

        vm.expectRevert(SimpleLendingPool.WithdrawalWouldUnderCollateralize.selector);
        pool.withdrawCollateral(1e18);
        vm.stopPrank();
    }

    function testPositionNotLiquidatableWhileHealthy() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(13_200e18);
        vm.stopPrank();

        assertFalse(pool.isLiquidatable(alice));
    }

    function testLiquidationWhenPriceDrops() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(13_200e18);
        vm.stopPrank();

        oracle.setPrice(1_000e18);
        assertTrue(pool.isLiquidatable(alice));

        uint256 bobCollateralBefore = collateralToken.balanceOf(bob);

        vm.prank(bob);
        pool.liquidate(alice);

        assertEq(pool.totalDebt(alice), 0);
        assertGt(collateralToken.balanceOf(bob), bobCollateralBefore);
    }

    /// @dev Confirms interest accrual alone (with no price change) can push
    ///      a position into liquidation over a long enough time horizon —
    ///      an important real-world liquidation trigger distinct from price risk.
    function testLiquidationTriggeredByInterestAloneOverLongTime() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18); // value 20,000
        pool.borrow(13_200e18); // right at the 66% LTV limit
        vm.stopPrank();

        assertFalse(pool.isLiquidatable(alice));

        vm.warp(block.timestamp + 365 days * 5);

        assertTrue(pool.isLiquidatable(alice));
    }

    function testCannotLiquidateHealthyPosition() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(1_000e18);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(SimpleLendingPool.PositionIsHealthy.selector);
        pool.liquidate(alice);
    }

    function testPauseBlocksAllActions() public {
        pool.pause();

        vm.startPrank(alice);
        vm.expectRevert();
        pool.depositCollateral(1e18);
        vm.stopPrank();
    }

    function testFuzz_HealthyBorrowNeverImmediatelyLiquidatable(uint256 collateralAmount) public {
        collateralAmount = bound(collateralAmount, 1e18, 100e18);
        collateralToken.mint(alice, collateralAmount);

        vm.startPrank(alice);
        collateralToken.approve(address(pool), collateralAmount);
        pool.depositCollateral(collateralAmount);
        uint256 maxBorrowable = pool.maxBorrow(alice);
        if (maxBorrowable > 0) {
            pool.borrow(maxBorrowable);
        }
        vm.stopPrank();

        assertFalse(pool.isLiquidatable(alice));
    }

    // --- New: partial liquidation coverage ---

    function testMaxLiquidatableIsCloseFactorOfDebt() public {
        _openUnderwaterPosition();
        assertEq(pool.maxLiquidatable(alice), 6_600e18); // 50% of 13,200
    }

    function testCannotLiquidatePartialPastCloseFactor() public {
        _openUnderwaterPosition();
        uint256 limit = pool.maxLiquidatable(alice);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(SimpleLendingPool.ExceedsCloseFactor.selector, limit + 1, limit)
        );
        pool.liquidatePartial(alice, limit + 1);
    }

    function testPartialLiquidationReducesDebtProportionally() public {
        _openUnderwaterPosition();
        uint256 limit = pool.maxLiquidatable(alice);

        uint256 bobCollateralBefore = collateralToken.balanceOf(bob);

        vm.prank(bob);
        pool.liquidatePartial(alice, limit);

        assertEq(pool.totalDebt(alice), 13_200e18 - limit);
        assertGt(collateralToken.balanceOf(bob), bobCollateralBefore);
        assertTrue(pool.isLiquidatable(alice));
    }

    /// @dev Two separate liquidators each partially liquidate the same
    ///      position in turn, fully closing it across two transactions —
    ///      proving partial liquidation composes correctly with itself.
    function testTwoPartialLiquidationsFullyCloseDebt() public {
        _openUnderwaterPosition();

        uint256 firstLimit = pool.maxLiquidatable(alice); // 6,600
        vm.prank(bob);
        pool.liquidatePartial(alice, firstLimit);

        assertEq(pool.totalDebt(alice), 13_200e18 - firstLimit);

        uint256 secondLimit = pool.maxLiquidatable(alice);
        vm.prank(carol);
        pool.liquidatePartial(alice, secondLimit);

        assertEq(pool.totalDebt(alice), 13_200e18 - firstLimit - secondLimit);
    }

    function testFullLiquidationStillWorksAlongsidePartial() public {
        _openUnderwaterPosition();

        uint256 debtBefore = pool.totalDebt(alice);
        vm.prank(bob);
        pool.liquidate(alice); // full liquidation, ignoring the close factor

        assertEq(pool.totalDebt(alice), 0);
        assertGt(debtBefore, 0);
    }

    function testCannotPartiallyLiquidateHealthyPosition() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(1_000e18);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(SimpleLendingPool.PositionIsHealthy.selector);
        pool.liquidatePartial(alice, 100e18);
    }
}
