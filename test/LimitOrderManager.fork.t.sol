// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {LimitOrderManager} from "../src/LimitOrderManager.sol";
import {IUniswapV3Factory} from "../src/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";
import {TickMath} from "./utils/TickMath.sol";

/// @notice Swaps against a V3 pool and pulls the input token from a payer.
contract PoolSwapper {
    address public pool;

    /// @notice Swaps `amountIn` toward `limit` and sends the output here.
    function swap(address pool_, address payer, bool zeroForOne, uint256 amountIn, uint160 limit)
        external
        returns (int256 amount0, int256 amount1)
    {
        pool = pool_;
        return IUniswapV3PoolSwap(pool_).swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(payer));
    }

    /// @notice Pays the pool for the swap it just requested.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        require(msg.sender == pool, "callback");
        address payer = abi.decode(data, (address));
        if (amount0Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token0()).transferFrom(payer, msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(IUniswapV3Pool(msg.sender).token1()).transferFrom(payer, msg.sender, uint256(amount1Delta));
        }
    }
}

/// @notice Contract with no receive function, so a tipped cancel must name another recipient.
contract EthRejecter {}

/// @notice Pool swap entry point used only by the fork tests.
interface IUniswapV3PoolSwap {
    /// @notice Swaps tokens on the pool and callbacks the caller to collect payment.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice Fork tests 1-10 against the Base WETH/USDC 0.05% pool.
/// @dev WETH is token0 and USDC is token1. Up is the old ask, Down is the old bid, and Both is a
/// range that closes on either edge. Swaps aim at a sqrt price from TickMath so the tick lands
/// where the trigger should flip. Payout checks preview the position, roll that back, then compare
/// balances and the values returned by fill.
contract LimitOrderManagerForkTest is Test {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address internal constant POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    uint24 internal constant FEE = 500;
    uint256 internal constant BPS = 10_000;

    LimitOrderManager internal manager;
    PoolSwapper internal swapper;
    address internal pool;

    address internal owner;
    address internal treasury;
    address internal user;
    address internal filler;
    address internal stranger;

    int24 internal spacing;

    /// @notice Forks Base and deploys a manager owned by a fresh address.
    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://base.publicnode.com")));

        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        user = makeAddr("user");
        filler = makeAddr("filler");
        stranger = makeAddr("stranger");

        manager = new LimitOrderManager(FACTORY, POSITION_MANAGER, treasury, owner);
        swapper = new PoolSwapper();
        pool = IUniswapV3Factory(FACTORY).getPool(WETH, USDC, FEE);
        spacing = IUniswapV3Pool(pool).tickSpacing();

        assertEq(IUniswapV3Pool(pool).token0(), WETH);
        assertGt(spacing, 0);

        _fund(user, 100 ether, 1_000_000e6);
        deal(USDC, address(this), 20_000_000e6);
        deal(WETH, address(this), 5_000 ether);
        IERC20(USDC).approve(address(swapper), type(uint256).max);
        IERC20(WETH).approve(address(swapper), type(uint256).max);
        vm.deal(filler, 1 ether);
    }

    /// @notice A single-sided Up order pulls only WETH, and a single-sided Down order pulls only USDC.
    function test_createSingleSidedUpAndDownPullsOnlyTheInputToken() public {
        (int24 upLower, int24 upUpper) = _ticksAbove(1);
        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);

        uint256 upId = _create(user, _params(upLower, upUpper, 1 ether, 0, LimitOrderManager.Trigger.Up), 0.001 ether);

        assertEq(IERC20(USDC).balanceOf(user), usdcBefore);
        assertLt(IERC20(WETH).balanceOf(user), wethBefore);
        LimitOrderManager.Order memory up = _order(upId);
        assertEq(uint8(up.trigger), uint8(LimitOrderManager.Trigger.Up));
        assertTrue(up.open);
        assertEq(up.pool, pool);
        assertEq(up.owner, user);
        assertEq(up.tip, 0.001 ether);
        assertEq(up.tickLower, upLower);
        assertEq(up.tickUpper, upUpper);
        assertEq(up.keeperBps, manager.DEFAULT_KEEPER_BPS());
        assertEq(up.protocolBps, manager.DEFAULT_PROTOCOL_BPS());
        assertGt(up.tokenId, 0);

        (int24 downLower, int24 downUpper) = _ticksBelow(1);
        wethBefore = IERC20(WETH).balanceOf(user);
        usdcBefore = IERC20(USDC).balanceOf(user);

        uint256 downId = _create(user, _params(downLower, downUpper, 0, 1_000e6, LimitOrderManager.Trigger.Down), 0);

        assertEq(IERC20(WETH).balanceOf(user), wethBefore);
        assertLt(IERC20(USDC).balanceOf(user), usdcBefore);
        LimitOrderManager.Order memory down = _order(downId);
        assertEq(uint8(down.trigger), uint8(LimitOrderManager.Trigger.Down));
        assertTrue(down.open);
        assertEq(down.tip, 0);
        assertEq(IERC20(WETH).balanceOf(address(manager)), 0);
        assertEq(IERC20(USDC).balanceOf(address(manager)), 0);
    }

    /// @notice A straddling order of each trigger pulls both tokens, refunds the leftover, and reverts below its minimums.
    function test_createStraddlingOrdersRefundsBothTokensAndEnforcesMinimums() public {
        (int24 lower, int24 upper) = _ticksAround(2);
        _assertStraddle(lower, upper, LimitOrderManager.Trigger.Up);
        _assertStraddle(lower, upper, LimitOrderManager.Trigger.Down);
        _assertStraddle(lower, upper, LimitOrderManager.Trigger.Both);

        LimitOrderManager.OrderParams memory tooTight =
            _params(lower, upper, 0.2 ether, 100_000e6, LimitOrderManager.Trigger.Both);
        tooTight.amount0Min = 10 ether;
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Price slippage check"));
        vm.prank(user);
        manager.createOrder(tooTight);
    }

    /// @notice Creation reverts for a bad trigger, a missing pool, reversed tokens, a past deadline, and a deposit on the wrong side.
    function test_createRevertsForBadTriggerPoolOrderAndDeadline() public {
        (int24 aboveLower, int24 aboveUpper) = _ticksAbove(1);
        (int24 belowLower, int24 belowUpper) = _ticksBelow(1);

        vm.expectRevert(LimitOrderManager.TriggerAlreadyMet.selector);
        vm.prank(user);
        manager.createOrder(_params(aboveLower, aboveUpper, 0, 500e6, LimitOrderManager.Trigger.Down));

        vm.expectRevert(LimitOrderManager.TriggerAlreadyMet.selector);
        vm.prank(user);
        manager.createOrder(_params(belowLower, belowUpper, 0.5 ether, 0, LimitOrderManager.Trigger.Up));

        vm.expectRevert(LimitOrderManager.TriggerAlreadyMet.selector);
        vm.prank(user);
        manager.createOrder(_params(aboveLower, aboveUpper, 0.1 ether, 1_000e6, LimitOrderManager.Trigger.Both));

        vm.expectRevert(LimitOrderManager.TriggerAlreadyMet.selector);
        vm.prank(user);
        manager.createOrder(_params(belowLower, belowUpper, 0.1 ether, 1_000e6, LimitOrderManager.Trigger.Both));

        LimitOrderManager.OrderParams memory missing =
            _params(aboveLower, aboveUpper, 0.5 ether, 0, LimitOrderManager.Trigger.Up);
        missing.fee = 250;
        vm.expectRevert(LimitOrderManager.PoolNotFound.selector);
        vm.prank(user);
        manager.createOrder(missing);

        LimitOrderManager.OrderParams memory reversed =
            _params(aboveLower, aboveUpper, 0, 0.5 ether, LimitOrderManager.Trigger.Up);
        reversed.token0 = USDC;
        reversed.token1 = WETH;
        reversed.amount0 = 500e6;
        reversed.amount1 = 0;
        vm.expectRevert(LimitOrderManager.TokenOrder.selector);
        vm.prank(user);
        manager.createOrder(reversed);

        LimitOrderManager.OrderParams memory expired =
            _params(aboveLower, aboveUpper, 0.5 ether, 0, LimitOrderManager.Trigger.Up);
        expired.deadline = block.timestamp - 1;
        vm.expectRevert(LimitOrderManager.DeadlinePassed.selector);
        vm.prank(user);
        manager.createOrder(expired);

        vm.expectRevert(LimitOrderManager.ZeroLiquidity.selector);
        vm.prank(user);
        manager.createOrder(_params(aboveLower, aboveUpper, 0, 500e6, LimitOrderManager.Trigger.Up));

        vm.expectRevert(LimitOrderManager.ZeroLiquidity.selector);
        vm.prank(user);
        manager.createOrder(_params(belowLower, belowUpper, 0.5 ether, 0, LimitOrderManager.Trigger.Down));

        (int24 aroundLower, int24 aroundUpper) = _ticksAround(2);
        vm.expectRevert(LimitOrderManager.ZeroLiquidity.selector);
        vm.prank(user);
        manager.createOrder(_params(aroundLower, aroundUpper, 0.2 ether, 0, LimitOrderManager.Trigger.Both));

        vm.expectRevert(LimitOrderManager.ZeroLiquidity.selector);
        vm.prank(user);
        manager.createOrder(_params(aroundLower, aroundUpper, 0, 10_000e6, LimitOrderManager.Trigger.Both));
    }

    /// @notice A real swap through an Up order accrues fees, and fill's return values match the payout.
    function test_fillAfterPriceCrossPaysSplitTipAndReturnsKeeperAmounts() public {
        (int24 lower, int24 upper) = _ticksAbove(1);
        uint256 id = _create(user, _params(lower, upper, 5 ether, 0, LimitOrderManager.Trigger.Up), 0.01 ether);

        assertFalse(manager.isFillable(id));
        _movePriceUpTo(upper);
        assertTrue(manager.isFillable(id));
        _fillAndCheck(id, manager.DEFAULT_KEEPER_BPS(), manager.DEFAULT_PROTOCOL_BPS());
        assertEq(address(manager).balance, 0);
    }

    /// @notice Both fills upward and downward. Up and Down fill only in their own direction.
    function test_bothFillsEitherWayAndDirectionalOrdersDoNot() public {
        (int24 upLower, int24 upUpper) = _ticksAbove(1);
        (int24 downLower, int24 downUpper) = _ticksBelow(1);
        (int24 bothLower, int24 bothUpper) = _ticksAround(4);
        (int24 highLower, int24 highUpper) = _ticksAbove(30);

        uint256 upId = _create(user, _params(upLower, upUpper, 5 ether, 0, LimitOrderManager.Trigger.Up), 0.01 ether);
        uint256 downId =
            _create(user, _params(downLower, downUpper, 0, 20_000e6, LimitOrderManager.Trigger.Down), 0.02 ether);
        uint256 bothUpId =
            _create(user, _params(bothLower, bothUpper, 2 ether, 10_000e6, LimitOrderManager.Trigger.Both), 0.01 ether);
        uint256 bothDownId =
            _create(user, _params(bothLower, bothUpper, 2 ether, 10_000e6, LimitOrderManager.Trigger.Both), 0.01 ether);
        uint256 highId = _create(user, _params(highLower, highUpper, 1 ether, 0, LimitOrderManager.Trigger.Up), 0);

        _movePriceUpTo(bothUpper);
        assertTrue(manager.isFillable(upId));
        assertTrue(manager.isFillable(bothUpId));
        assertTrue(manager.isFillable(bothDownId));
        assertFalse(manager.isFillable(downId));
        assertFalse(manager.isFillable(highId));
        _fillAndCheck(upId, manager.DEFAULT_KEEPER_BPS(), manager.DEFAULT_PROTOCOL_BPS());
        _fillAndCheck(bothUpId, manager.DEFAULT_KEEPER_BPS(), manager.DEFAULT_PROTOCOL_BPS());

        _movePriceDownTo(bothLower + spacing);
        assertGt(_tick(), bothLower);
        assertLt(_tick(), bothUpper);
        assertFalse(manager.isFillable(bothDownId));
        assertFalse(manager.isFillable(highId));

        _movePriceDownTo(bothLower - 1);
        assertTrue(manager.isFillable(bothDownId));
        assertTrue(manager.isFillable(downId));
        assertFalse(manager.isFillable(highId));
        _fillAndCheck(bothDownId, manager.DEFAULT_KEEPER_BPS(), manager.DEFAULT_PROTOCOL_BPS());
        _fillAndCheck(downId, manager.DEFAULT_KEEPER_BPS(), manager.DEFAULT_PROTOCOL_BPS());
    }

    /// @notice Fill reverts while the trigger is not met, including while price is still inside the range.
    function test_fillRevertsWhenNotFillable() public {
        (int24 lower, int24 upper) = _ticksAbove(2);
        uint256 id = _create(user, _params(lower, upper, 1 ether, 0, LimitOrderManager.Trigger.Up), 0);
        assertFalse(manager.isFillable(id));

        vm.expectRevert(abi.encodeWithSelector(LimitOrderManager.NotFillable.selector, id));
        vm.prank(filler);
        manager.fill(id);

        _movePriceUpTo(lower + spacing);
        assertLt(_tick(), upper);
        assertFalse(manager.isFillable(id));

        vm.expectRevert(abi.encodeWithSelector(LimitOrderManager.NotFillable.selector, id));
        vm.prank(filler);
        manager.fill(id);

        (int24 aroundLower, int24 aroundUpper) = _ticksAround(2);
        uint256 bothId =
            _create(user, _params(aroundLower, aroundUpper, 0.2 ether, 10_000e6, LimitOrderManager.Trigger.Both), 0);
        assertFalse(manager.isFillable(bothId));
        vm.expectRevert(abi.encodeWithSelector(LimitOrderManager.NotFillable.selector, bothId));
        vm.prank(filler);
        manager.fill(bothId);
    }

    /// @notice Cancel pays a chosen recipient, enforces minimums, and lets an ETH-rejecting owner exit.
    function test_cancelPartialOrderSplitsFeesRefundsTipAndEnforcesMinimums() public {
        (int24 lower, int24 upper) = _ticksAbove(8);
        uint96 tip = 0.005 ether;
        uint256 id = _create(user, _params(lower, upper, 5 ether, 0, LimitOrderManager.Trigger.Up), tip);
        address recipient = makeAddr("cancelRecipient");

        _movePriceUpTo(lower + spacing * 4);
        assertGt(_tick(), lower);
        assertLt(_tick(), upper);
        assertFalse(manager.isFillable(id));

        vm.expectRevert(abi.encodeWithSelector(LimitOrderManager.NotOrderOwner.selector, id));
        vm.prank(stranger);
        manager.cancelOrder(id, 0, 0, recipient);

        vm.expectRevert(abi.encodeWithSignature("Error(string)", "Price slippage check"));
        vm.prank(user);
        manager.cancelOrder(id, type(uint128).max, type(uint128).max, recipient);
        assertTrue(_order(id).open);

        vm.expectRevert(LimitOrderManager.ZeroAddress.selector);
        vm.prank(user);
        manager.cancelOrder(id, 0, 0, address(0));
        assertTrue(_order(id).open);

        (uint256 p0, uint256 p1, uint256 t0, uint256 t1) = _previewWithdraw(_order(id).tokenId);
        assertGt(p0, 0.01 ether);
        assertGt(p1, 1e6);
        uint256 fee0 = t0 > p0 ? t0 - p0 : 0;
        uint256 fee1 = t1 > p1 ? t1 - p1 : 0;
        assertGt(fee0 + fee1, 0);

        (uint256 user0, uint256 protocol0) = _splitCancel(p0, t0, manager.DEFAULT_PROTOCOL_BPS());
        (uint256 user1, uint256 protocol1) = _splitCancel(p1, t1, manager.DEFAULT_PROTOCOL_BPS());
        assertEq(protocol0, fee0 * 3_000 / BPS);
        assertEq(protocol1, fee1 * 3_000 / BPS);
        _cancelAndCheck(id, recipient, tip, user0, user1, protocol0, protocol1);

        vm.expectRevert(abi.encodeWithSelector(LimitOrderManager.OrderNotOpen.selector, id));
        vm.prank(user);
        manager.cancelOrder(id, 0, 0, recipient);

        EthRejecter rejecter = new EthRejecter();
        _fund(address(rejecter), 2 ether, 0);
        uint96 rejecterTip = 0.004 ether;
        (int24 rejectLower, int24 rejectUpper) = _ticksAbove(1);
        uint256 rejecterId = _create(
            address(rejecter), _params(rejectLower, rejectUpper, 1 ether, 0, LimitOrderManager.Trigger.Up), rejecterTip
        );

        vm.expectRevert(LimitOrderManager.TipTransferFailed.selector);
        vm.prank(address(rejecter));
        manager.cancelOrder(rejecterId, 0, 0, address(rejecter));
        assertTrue(_order(rejecterId).open);

        (uint256 rp0, uint256 rp1, uint256 rt0, uint256 rt1) = _previewWithdraw(_order(rejecterId).tokenId);
        (uint256 rejectUser0, uint256 rejectProtocol0) = _splitCancel(rp0, rt0, manager.DEFAULT_PROTOCOL_BPS());
        (uint256 rejectUser1, uint256 rejectProtocol1) = _splitCancel(rp1, rt1, manager.DEFAULT_PROTOCOL_BPS());
        _cancelAndCheck(rejecterId, recipient, rejecterTip, rejectUser0, rejectUser1, rejectProtocol0, rejectProtocol1);
    }

    /// @notice A zero-tip fill pays the keeper in fees and does not move ETH.
    function test_zeroTipFillDoesNotTransferEth() public {
        (int24 lower, int24 upper) = _ticksAbove(1);
        uint256 id = _create(user, _params(lower, upper, 5 ether, 0, LimitOrderManager.Trigger.Up), 0);
        assertEq(_order(id).tip, 0);
        assertEq(address(manager).balance, 0);

        uint256 fillerEth = filler.balance;
        _movePriceUpTo(upper);
        _fillAndCheck(id, manager.DEFAULT_KEEPER_BPS(), manager.DEFAULT_PROTOCOL_BPS());
        assertEq(filler.balance, fillerEth);
        assertEq(address(manager).balance, 0);
    }

    /// @notice Pausing creation blocks new orders and still allows fill and cancel.
    function test_pauseBlocksCreateButNotFillOrCancel() public {
        (int24 askLower, int24 askUpper) = _ticksAbove(1);
        (int24 bidLower, int24 bidUpper) = _ticksBelow(1);
        uint256 askId =
            _create(user, _params(askLower, askUpper, 5 ether, 0, LimitOrderManager.Trigger.Up), 0.001 ether);
        uint256 bidId =
            _create(user, _params(bidLower, bidUpper, 0, 1_000e6, LimitOrderManager.Trigger.Down), 0.001 ether);

        _movePriceUpTo(askUpper);

        vm.expectEmit(false, false, false, true, address(manager));
        emit LimitOrderManager.CreationPaused(true);
        vm.prank(owner);
        manager.pauseCreation(true);
        assertTrue(manager.creationPaused());

        vm.expectRevert(LimitOrderManager.CreationIsPaused.selector);
        vm.prank(user);
        manager.createOrder(_params(askLower, askUpper, 1 ether, 0, LimitOrderManager.Trigger.Up));

        _fillAndCheck(askId, manager.DEFAULT_KEEPER_BPS(), manager.DEFAULT_PROTOCOL_BPS());

        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        vm.prank(user);
        manager.cancelOrder(bidId, 0, 0, user);
        assertGt(IERC20(USDC).balanceOf(user), usdcBefore);
        assertFalse(_order(bidId).open);
    }

    /// @notice The split is copied per order, rejects shares above 100%, and admin calls are owner-only.
    function test_setSplitAffectsNewOrdersOnlyAndAdminGuards() public {
        address newTreasury = makeAddr("newTreasury");

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        manager.setTreasury(newTreasury);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        manager.setSplit(1, 1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        manager.pauseCreation(true);
        vm.stopPrank();

        vm.expectRevert(LimitOrderManager.InvalidSplit.selector);
        vm.prank(owner);
        manager.setSplit(5_000, 5_001);

        (int24 lower, int24 upper) = _ticksAbove(1);
        uint256 oldId = _create(user, _params(lower, upper, 5 ether, 0, LimitOrderManager.Trigger.Up), 0.001 ether);

        vm.expectEmit(false, false, false, true, address(manager));
        emit LimitOrderManager.SplitUpdated(1_000, 2_000);
        vm.prank(owner);
        manager.setSplit(1_000, 2_000);
        assertEq(manager.keeperBps(), 1_000);
        assertEq(manager.protocolBps(), 2_000);
        assertEq(_order(oldId).keeperBps, manager.DEFAULT_KEEPER_BPS());
        assertEq(_order(oldId).protocolBps, manager.DEFAULT_PROTOCOL_BPS());

        uint256 newId = _create(user, _params(lower, upper, 5 ether, 0, LimitOrderManager.Trigger.Up), 0.002 ether);
        assertEq(_order(newId).keeperBps, 1_000);
        assertEq(_order(newId).protocolBps, 2_000);

        vm.expectEmit(true, false, false, true, address(manager));
        emit LimitOrderManager.TreasuryUpdated(newTreasury);
        vm.prank(owner);
        manager.setTreasury(newTreasury);

        vm.expectEmit(false, false, false, true, address(manager));
        emit LimitOrderManager.CreationPaused(true);
        vm.prank(owner);
        manager.pauseCreation(true);
        vm.prank(owner);
        manager.pauseCreation(false);

        _movePriceUpTo(upper);
        _fillAndCheck(oldId, manager.DEFAULT_KEEPER_BPS(), manager.DEFAULT_PROTOCOL_BPS());
        _fillAndCheck(newId, 1_000, 2_000);

        assertEq(IERC20(WETH).balanceOf(treasury), 0);
        assertEq(IERC20(USDC).balanceOf(treasury), 0);
        assertGt(IERC20(WETH).balanceOf(newTreasury) + IERC20(USDC).balanceOf(newTreasury), 0);
    }

    /// @notice Checks that a straddling mint spends both tokens and refunds the surplus input.
    function _assertStraddle(int24 lower, int24 upper, LimitOrderManager.Trigger trigger) internal {
        uint256 amount0 = 0.2 ether;
        uint256 amount1 = 100_000e6;
        uint256 wethBefore = IERC20(WETH).balanceOf(user);
        uint256 usdcBefore = IERC20(USDC).balanceOf(user);

        uint256 id = _create(user, _params(lower, upper, amount0, amount1, trigger), 0);

        uint256 spent0 = wethBefore - IERC20(WETH).balanceOf(user);
        uint256 spent1 = usdcBefore - IERC20(USDC).balanceOf(user);
        assertGt(spent0, 0);
        assertGt(spent1, 0);
        assertLt(spent1, amount1);
        assertEq(uint8(_order(id).trigger), uint8(trigger));
        assertEq(IERC20(WETH).balanceOf(address(manager)), 0);
        assertEq(IERC20(USDC).balanceOf(address(manager)), 0);
    }

    /// @notice Funds `account` and lets it spend both tokens on the manager.
    function _fund(address account, uint256 wethAmount, uint256 usdcAmount) internal {
        deal(WETH, account, wethAmount);
        deal(USDC, account, usdcAmount);
        vm.deal(account, 1 ether);
        vm.startPrank(account);
        IERC20(WETH).approve(address(manager), type(uint256).max);
        IERC20(USDC).approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Builds order parameters for the WETH/USDC pool with zero minimums and a one-hour deadline.
    function _params(int24 lower, int24 upper, uint256 amount0, uint256 amount1, LimitOrderManager.Trigger trigger)
        internal
        view
        returns (LimitOrderManager.OrderParams memory)
    {
        return LimitOrderManager.OrderParams({
            token0: WETH,
            token1: USDC,
            fee: FEE,
            tickLower: lower,
            tickUpper: upper,
            amount0: amount0,
            amount1: amount1,
            amount0Min: 0,
            amount1Min: 0,
            trigger: trigger,
            deadline: block.timestamp + 1 hours
        });
    }

    /// @notice Creates an order as `account` and escrows `tip`.
    function _create(address account, LimitOrderManager.OrderParams memory params, uint96 tip)
        internal
        returns (uint256 id)
    {
        vm.prank(account);
        id = manager.createOrder{value: tip}(params);
    }

    /// @notice Cancels as the owner and checks the 70/30 split and the tip paid to `recipient`.
    function _cancelAndCheck(
        uint256 id,
        address recipient,
        uint96 tip,
        uint256 user0,
        uint256 user1,
        uint256 protocol0,
        uint256 protocol1
    ) internal {
        address owner_ = _order(id).owner;
        uint256 ownerWeth = IERC20(WETH).balanceOf(owner_);
        uint256 ownerUsdc = IERC20(USDC).balanceOf(owner_);
        uint256 ownerEth = owner_.balance;
        uint256 recipientWeth = IERC20(WETH).balanceOf(recipient);
        uint256 recipientUsdc = IERC20(USDC).balanceOf(recipient);
        uint256 recipientEth = recipient.balance;
        uint256 treasuryWeth = IERC20(WETH).balanceOf(treasury);
        uint256 treasuryUsdc = IERC20(USDC).balanceOf(treasury);

        vm.prank(owner_);
        manager.cancelOrder(id, 0, 0, recipient);

        assertEq(IERC20(WETH).balanceOf(recipient) - recipientWeth, user0);
        assertEq(IERC20(USDC).balanceOf(recipient) - recipientUsdc, user1);
        assertEq(recipient.balance - recipientEth, tip);
        if (recipient != owner_) {
            assertEq(IERC20(WETH).balanceOf(owner_), ownerWeth);
            assertEq(IERC20(USDC).balanceOf(owner_), ownerUsdc);
            assertEq(owner_.balance, ownerEth);
        }
        assertEq(IERC20(WETH).balanceOf(treasury) - treasuryWeth, protocol0);
        assertEq(IERC20(USDC).balanceOf(treasury) - treasuryUsdc, protocol1);
        assertEq(address(manager).balance, 0);
        assertEq(IERC20(WETH).balanceOf(address(manager)), 0);
        assertEq(IERC20(USDC).balanceOf(address(manager)), 0);
        assertFalse(_order(id).open);
    }

    /// @notice Fills from the keeper address and checks the split, the tip, and the returned payout.
    function _fillAndCheck(uint256 id, uint16 keeperBps, uint16 protocolBps) internal {
        LimitOrderManager.Order memory order = _order(id);
        (uint256 p0, uint256 p1, uint256 t0, uint256 t1) = _previewWithdraw(order.tokenId);
        uint256 fee0 = t0 > p0 ? t0 - p0 : 0;
        uint256 fee1 = t1 > p1 ? t1 - p1 : 0;
        assertGt(fee0 + fee1, 0);

        (uint256 user0, uint256 keeper0, uint256 protocol0) = _splitFill(p0, t0, keeperBps, protocolBps);
        (uint256 user1, uint256 keeper1, uint256 protocol1) = _splitFill(p1, t1, keeperBps, protocolBps);

        uint256 userWeth = IERC20(WETH).balanceOf(user);
        uint256 userUsdc = IERC20(USDC).balanceOf(user);
        uint256 fillerWeth = IERC20(WETH).balanceOf(filler);
        uint256 fillerUsdc = IERC20(USDC).balanceOf(filler);
        uint256 treasuryWeth = IERC20(WETH).balanceOf(manager.treasury());
        uint256 treasuryUsdc = IERC20(USDC).balanceOf(manager.treasury());
        uint256 fillerEth = filler.balance;

        vm.prank(filler);
        (uint256 returned0, uint256 returned1, uint96 returnedTip) = manager.fill(id);

        assertEq(returned0, keeper0);
        assertEq(returned1, keeper1);
        assertEq(returnedTip, order.tip);
        assertEq(IERC20(WETH).balanceOf(user) - userWeth, user0);
        assertEq(IERC20(USDC).balanceOf(user) - userUsdc, user1);
        assertEq(IERC20(WETH).balanceOf(filler) - fillerWeth, keeper0);
        assertEq(IERC20(USDC).balanceOf(filler) - fillerUsdc, keeper1);
        assertEq(IERC20(WETH).balanceOf(manager.treasury()) - treasuryWeth, protocol0);
        assertEq(IERC20(USDC).balanceOf(manager.treasury()) - treasuryUsdc, protocol1);
        assertEq(filler.balance - fillerEth, order.tip);
        assertEq(IERC20(WETH).balanceOf(address(manager)), 0);
        assertEq(IERC20(USDC).balanceOf(address(manager)), 0);
        assertFalse(_order(id).open);
        assertFalse(manager.isFillable(id));
    }

    /// @notice Simulates closing the position and rolls the fork state back.
    function _previewWithdraw(uint256 tokenId)
        internal
        returns (uint256 principal0, uint256 principal1, uint256 total0, uint256 total1)
    {
        uint256 snap = vm.snapshotState();
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);
        if (liquidity > 0) {
            vm.prank(address(manager));
            (principal0, principal1) = INonfungiblePositionManager(POSITION_MANAGER)
                .decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: tokenId, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                    })
                );
        }
        vm.prank(address(manager));
        (total0, total1) = INonfungiblePositionManager(POSITION_MANAGER)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(manager),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
        assertTrue(vm.revertToState(snap));
    }

    /// @notice Applies the fill split: keeper and protocol take their shares, and the user keeps the remainder.
    function _splitFill(uint256 principal, uint256 total, uint16 keeperBps, uint16 protocolBps)
        internal
        pure
        returns (uint256 toUser, uint256 toKeeper, uint256 toProtocol)
    {
        uint256 fee = total > principal ? total - principal : 0;
        toKeeper = fee * keeperBps / BPS;
        toProtocol = fee * protocolBps / BPS;
        toUser = (total - fee) + (fee - toKeeper - toProtocol);
    }

    /// @notice Applies the cancel split: the owner receives the keeper share as well as their own.
    function _splitCancel(uint256 principal, uint256 total, uint16 protocolBps)
        internal
        pure
        returns (uint256 toUser, uint256 toProtocol)
    {
        uint256 fee = total > principal ? total - principal : 0;
        toProtocol = fee * protocolBps / BPS;
        toUser = (total - fee) + (fee - toProtocol);
    }

    /// @notice Buys WETH with USDC until the pool tick reaches `targetTick`.
    function _movePriceUpTo(int24 targetTick) internal {
        assertGt(targetTick, _tick());
        swapper.swap(pool, address(this), false, 20_000_000e6, TickMath.getSqrtPriceAtTick(targetTick));
        assertGe(_tick(), targetTick);
    }

    /// @notice Sells WETH for USDC until the pool tick reaches `targetTick`.
    function _movePriceDownTo(int24 targetTick) internal {
        assertLt(targetTick, _tick());
        swapper.swap(pool, address(this), true, 5_000 ether, TickMath.getSqrtPriceAtTick(targetTick));
        assertLe(_tick(), targetTick);
    }

    /// @notice Returns a range that sits entirely above the current tick.
    function _ticksAbove(int24 widths) internal view returns (int24 lower, int24 upper) {
        lower = _alignUp(_tick() + 1, spacing);
        upper = lower + spacing * widths;
    }

    /// @notice Returns a range that sits entirely below the current tick.
    function _ticksBelow(int24 widths) internal view returns (int24 lower, int24 upper) {
        upper = _alignDown(_tick(), spacing);
        lower = upper - spacing * widths;
    }

    /// @notice Returns a range that contains the current tick, extending `widths` spacings each way.
    function _ticksAround(int24 widths) internal view returns (int24 lower, int24 upper) {
        int24 tick = _tick();
        lower = _alignDown(tick, spacing) - spacing * widths;
        upper = _alignUp(tick + 1, spacing) + spacing * widths;
    }

    /// @notice Reads the pool's current tick.
    function _tick() internal view returns (int24 tick) {
        (, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    /// @notice Rounds `tick` down to a multiple of `step`, including negative ticks.
    function _alignDown(int24 tick, int24 step) internal pure returns (int24) {
        int24 compressed = tick / step;
        if (tick < 0 && tick % step != 0) compressed--;
        return compressed * step;
    }

    /// @notice Rounds `tick` up to a multiple of `step`, including negative ticks.
    function _alignUp(int24 tick, int24 step) internal pure returns (int24) {
        int24 down = _alignDown(tick, step);
        return down == tick ? down : down + step;
    }

    /// @notice Reads one order from the public getter.
    function _order(uint256 id) internal view returns (LimitOrderManager.Order memory order) {
        (bool ok, bytes memory data) = address(manager).staticcall(abi.encodeCall(manager.orders, (id)));
        require(ok, "order");
        order = abi.decode(data, (LimitOrderManager.Order));
    }
}
