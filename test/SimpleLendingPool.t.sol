// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/SimpleLendingPool.sol";
import "../src/MockPriceOracle.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mintable ERC20 used only for test setup — not part of the
///      production contracts, so tests can freely mint collateral/borrow
///      tokens to test accounts without touching MyToken's real supply cap.
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
    address bob = address(0x2); // acts as liquidator

    uint256 constant LTV_BPS = 6_600; // 66%
    uint256 constant LIQ_THRESHOLD_BPS = 8_000; // 80%
    uint256 constant LIQ_BONUS_BPS = 500; // 5%
    uint256 constant INITIAL_PRICE = 2_000e18; // 1 collateral = 2000 borrow tokens

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
            owner
        );

        // Fund the pool with borrow tokens so users can actually borrow.
        borrowToken.mint(address(pool), 1_000_000e18);

        // Fund test users with collateral and borrow tokens, and approve the pool.
        collateralToken.mint(alice, 100e18);
        vm.prank(alice);
        collateralToken.approve(address(pool), type(uint256).max);

        borrowToken.mint(bob, 1_000_000e18);
        vm.prank(bob);
        borrowToken.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        collateralToken.approve(address(pool), type(uint256).max);

        vm.prank(alice);
        borrowToken.approve(address(pool), type(uint256).max);
    }

    function testDepositCollateral() public {
        vm.prank(alice);
        pool.depositCollateral(10e18);

        (uint256 collateral, uint256 debt) = pool.positions(alice);
        assertEq(collateral, 10e18);
        assertEq(debt, 0);
        assertEq(collateralToken.balanceOf(address(pool)), 10e18);
    }

    function testBorrowWithinLTV() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18); // worth 20,000 borrow tokens at 2000/unit
        uint256 maxBorrowable = pool.maxBorrow(alice); // 66% of 20,000 = 13,200
        assertEq(maxBorrowable, 13_200e18);

        pool.borrow(13_200e18);
        vm.stopPrank();

        (, uint256 debt) = pool.positions(alice);
        assertEq(debt, 13_200e18);
        assertEq(borrowToken.balanceOf(alice), 13_200e18);
    }

    function testCannotBorrowPastLTV() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        uint256 maxBorrowable = pool.maxBorrow(alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                SimpleLendingPool.ExceedsLoanToValue.selector,
                maxBorrowable + 1,
                maxBorrowable
            )
        );
        pool.borrow(maxBorrowable + 1);
        vm.stopPrank();
    }

    function testRepayReducesDebt() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(10_000e18);
        pool.repay(4_000e18);
        vm.stopPrank();

        (, uint256 debt) = pool.positions(alice);
        assertEq(debt, 6_000e18);
    }

    function testCannotWithdrawIfItWouldUnderCollateralize() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(13_200e18); // maxed out at 66% LTV

        vm.expectRevert(SimpleLendingPool.WithdrawalWouldUnderCollateralize.selector);
        pool.withdrawCollateral(1e18); // any withdrawal now breaches LTV
        vm.stopPrank();
    }

    function testWithdrawAllowedWhenHealthy() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(1_000e18); // well under the limit
        pool.withdrawCollateral(1e18); // still leaves plenty of room
        vm.stopPrank();

        (uint256 collateral,) = pool.positions(alice);
        assertEq(collateral, 9e18);
    }

    function testPositionNotLiquidatableWhileHealthy() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(13_200e18); // at the LTV limit, but below the liquidation threshold
        vm.stopPrank();

        assertFalse(pool.isLiquidatable(alice));
    }

    /// @dev The core liquidation scenario: price drops, position becomes
    ///      under-collateralized, and a liquidator can step in and profit
    ///      via the bonus — exactly the incentive mechanism that keeps
    ///      real lending protocols solvent.
    function testLiquidationWhenPriceDrops() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18); // worth 20,000 at price 2000
        pool.borrow(13_200e18); // 66% LTV, healthy for now
        vm.stopPrank();

        assertFalse(pool.isLiquidatable(alice));

        // Price crashes: collateral now worth far less relative to debt.
        oracle.setPrice(1_000e18); // collateral now worth 10,000 total
        // debt (13,200) / collateral value (10,000) = 132% — deeply underwater

        assertTrue(pool.isLiquidatable(alice));

        uint256 bobBorrowBefore = borrowToken.balanceOf(bob);
        uint256 bobCollateralBefore = collateralToken.balanceOf(bob);

        vm.prank(bob);
        pool.liquidate(alice);

        (uint256 aliceCollateralAfter, uint256 aliceDebtAfter) = pool.positions(alice);
        assertEq(aliceDebtAfter, 0);

        // Bob paid the debt in borrow tokens...
        assertEq(bobBorrowBefore - borrowToken.balanceOf(bob), 13_200e18);
        // ...and received collateral in return, profiting from the bonus.
        assertGt(collateralToken.balanceOf(bob), bobCollateralBefore);
        // Alice's remaining collateral is whatever wasn't seized.
        assertLt(aliceCollateralAfter, 10e18);
    }

    function testCannotLiquidateHealthyPosition() public {
        vm.startPrank(alice);
        pool.depositCollateral(10e18);
        pool.borrow(1_000e18); // very safe position
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

    /// @dev Fuzz test: across a wide range of deposit/borrow amounts within
    ///      the LTV limit, a position should never be immediately liquidatable
    ///      right after opening it (assuming price doesn't move).
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
