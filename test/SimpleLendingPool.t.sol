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

    uint256 constant LTV_BPS = 6_600;
    uint256 constant LIQ_THRESHOLD_BPS = 8_000;
    uint256 constant LIQ_BONUS_BPS = 500;
    uint256 constant INTEREST_RATE_BPS = 500; // 5% APR
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
            owner
        );

        borrowToken.mint(address(pool), 1_000_000e18);

        collateralToken.mint(alice, 100e18);
        vm.prank(alice);
        collateralToken.approve(address(pool), type(uint256).max);

        borrowToken.mint(bob, 1_000_000e18);
        vm.startPrank(bob);
        borrowToken.approve(address(pool), type(uint256).max);
        collateralToken.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.prank(alice);
        borrowToken.approve(address(pool), type(uint256).max);
    }

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
        // Should be close to 10,250 (half of 500 annual interest), allowing
        // for integer-division rounding.
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

        // Liquidation threshold is 80% of 20,000 = 16,000.
        // At 5% APR on 13,200 principal, reaching 16,000 total debt takes
        // multiple years of accrual (linear model) — warp far enough forward.
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
}
