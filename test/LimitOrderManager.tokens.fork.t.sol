// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LimitOrderManager} from "../src/LimitOrderManager.sol";
import {IUniswapV3Factory} from "../src/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "./utils/TickMath.sol";

/// @notice Minimal ERC20 shared by the odd-token mocks. Tests mint balances instead of using `deal`.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    /// @notice Mints `amount` to `to` so a test can fund an order.
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    /// @notice Approves `spender` to move the caller's tokens.
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @notice Transfers `amount` from the caller to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    /// @notice Transfers `amount` from `from` to `to` using the caller's allowance.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spend(from, amount);
        return _transfer(from, to, amount);
    }

    /// @notice Spends `amount` of `from`'s allowance for the caller.
    function _spend(address from, uint256 amount) internal {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
    }

    /// @notice Moves `amount` from `from` to `to`. Odd-token mocks override this.
    function _transfer(address from, address to, uint256 amount) internal virtual returns (bool) {
        require(to != address(0), "zero");
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice ERC20 that keeps 1% of every transfer. createOrder against it reverts inside Uniswap.
contract FeeOnTransferToken is MockERC20 {
    /// @dev Share `_transfer` keeps on this contract, in basis points. 100 is 1% of every transfer.
    uint256 public constant FEE_BPS = 100;

    /// @notice Moves `amount` and keeps 1% on this contract.
    function _transfer(address from, address to, uint256 amount) internal override returns (bool) {
        require(to != address(0), "zero");
        require(balanceOf[from] >= amount, "balance");
        uint256 fee = amount * FEE_BPS / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        balanceOf[address(this)] += fee;
        return true;
    }
}

/// @notice ERC20 whose balance changes when `rebase` is called, with no transfer. Models a pool's stETH balance.
contract RebasingToken is MockERC20 {
    /// @notice Adds `delta` to the caller's balance without a transfer. A negative `delta` removes balance.
    function rebase(int256 delta) external {
        if (delta >= 0) {
            balanceOf[msg.sender] += uint256(delta);
            totalSupply += uint256(delta);
        } else {
            uint256 decrease = uint256(-delta);
            require(balanceOf[msg.sender] >= decrease, "rebase");
            balanceOf[msg.sender] -= decrease;
            totalSupply -= decrease;
        }
    }
}

/// @notice ERC20 that reverts on transfers to or from a blacklisted address. Models a USDC-like blacklist.
contract BlacklistToken is MockERC20 {
    /// @notice Thrown when a transfer touches a blacklisted address.
    error Blacklisted(address account);

    mapping(address => bool) public blacklisted;

    /// @notice Marks `account` so later transfers to or from it revert.
    function blacklist(address account) external {
        blacklisted[account] = true;
    }

    /// @notice Rejects a blacklisted `from` or `to`, then moves `amount`.
    function _transfer(address from, address to, uint256 amount) internal override returns (bool) {
        if (blacklisted[from]) revert Blacklisted(from);
        if (blacklisted[to]) revert Blacklisted(to);
        return super._transfer(from, to, amount);
    }
}

/// @notice Swaps a freshly created V3 pool and pulls the input token from a payer.
contract OddTokenSwapper {
    address public pool;

    /// @notice Swaps `amountIn` toward `limit` and sends the output here.
    function swap(address pool_, address payer, bool zeroForOne, uint256 amountIn, uint160 limit)
        external
        returns (int256 amount0, int256 amount1)
    {
        pool = pool_;
        return IOddPoolSwap(pool_).swap(address(this), zeroForOne, int256(amountIn), limit, abi.encode(payer));
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

/// @notice Pool swap entry point used by `OddTokenSwapper`.
interface IOddPoolSwap {
    /// @notice Swaps tokens on the pool and callbacks the caller to collect payment.
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice Factory method these tests use to open a real pool for a mock token.
interface IUniswapV3FactoryCreate {
    /// @notice Deploys a pool for `tokenA` and `tokenB` at `fee` and returns it.
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

/// @notice Initialize call these tests use after `createPool`.
interface IUniswapV3PoolInit {
    /// @notice Sets the pool's first sqrt price. The tests pass a TickMath price for tick 0.
    function initialize(uint160 sqrtPriceX96) external;
}

/// @notice Fork tests of fee-on-transfer, rebasing, and blacklist tokens on fresh Uniswap V3 pools.
/// @dev Each test deploys a mock on an Arbitrum One fork, calls factory.createPool, and initializes
/// tick 0 with TickMath. Ranges are one tick spacing wide so the deposit is single-sided.
contract LimitOrderManagerTokensForkTest is Test {
    /// @dev Arbitrum One WETH. `_market` pairs it with each mock, sorting token0 and token1 by address.
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    /// @dev Canonical Uniswap V3 factory. `_market` calls createPool here, and the manager resolves pools through it.
    address internal constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    /// @dev Uniswap V3 position manager. The manager mints each order's NFT through it.
    address internal constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    /// @dev Pool fee tier. `_market` passes it to createPool; the factory's spacing for it is `SPACING`.
    uint24 internal constant FEE = 500;
    /// @dev Tick spacing for fee 500. Deposit ranges are one spacing wide, and `_market` checks the pool uses it.
    int24 internal constant SPACING = 10;
    /// @dev Input budget `_move` approves for a price-limit swap. The pool pulls only what the target tick needs.
    uint256 internal constant SWAP_BUDGET = 10_000 ether;

    /// @notice A mock/WETH pool created and initialized inside one test.
    struct Market {
        address odd;
        address pool;
        address token0;
        address token1;
    }

    /// @notice One single-sided range and the deposit that matches the side of the price it sits on.
    struct Side {
        int24 lower;
        int24 upper;
        uint256 amount0;
        uint256 amount1;
        LimitOrderManager.Trigger trigger;
    }

    LimitOrderManager internal manager;
    OddTokenSwapper internal swapper;

    address internal owner;
    address internal treasury;
    address internal user;
    address internal filler;

    /// @notice Forks Arbitrum One (public node if `ARBITRUM_RPC_URL` is empty; block 0 means latest) and deploys a manager.
    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string("https://arbitrum-one-rpc.publicnode.com"));
        if (bytes(rpc).length == 0) rpc = "https://arbitrum-one-rpc.publicnode.com";
        uint256 forkBlock = vm.envOr("ARBITRUM_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);

        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        user = makeAddr("user");
        filler = makeAddr("filler");

        manager = new LimitOrderManager(FACTORY, POSITION_MANAGER, treasury, owner);
        swapper = new OddTokenSwapper();
    }

    /// @notice Fee-on-transfer createOrder reverts with the position manager's 'STF', not pool 'M0'/'M1'; balance and orders stay unchanged.
    function test_feeOnTransferCreateRevertsWithStfAndStoresNothing() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        Market memory market = _market(address(token));
        uint256 deposit = 100 ether;
        _fund(address(token), deposit, 0);
        Side memory side = _oddDeposit(market, deposit);

        uint256 balanceBefore = token.balanceOf(user);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "STF"));
        vm.prank(user);
        manager.createOrder(_params(market, side));

        assertEq(token.balanceOf(user), balanceBefore);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(market.pool), 0);
        assertEq(manager.nextOrderId(), 1);
        assertEq(_order(1).owner, address(0));
        assertFalse(_order(1).open);
        assertEq(_order(1).tokenId, 0);
    }

    /// @notice Rebase token: createPool, initialize, and createOrder succeed, and a positive rebase does not increase cancel payout.
    function test_positiveRebaseDoesNotIncreaseCancelPayout() public {
        RebasingToken token = new RebasingToken();
        Market memory market = _market(address(token));
        uint256 deposit = 100 ether;
        _fund(address(token), deposit, 0);
        uint256 id = _create(market, _oddDeposit(market, deposit));

        uint256 snap = vm.snapshotState();
        uint256 paidBefore = _cancelPaid(id, address(token));
        assertGt(paidBefore, 0);
        assertTrue(vm.revertToState(snap));

        uint256 poolBefore = token.balanceOf(market.pool);
        assertGt(poolBefore, 0);
        vm.prank(market.pool);
        token.rebase(int256(poolBefore));
        uint256 poolAfter = token.balanceOf(market.pool);
        assertEq(poolAfter, poolBefore * 2);

        uint256 paidAfter = _cancelPaid(id, address(token));
        assertEq(paidAfter, paidBefore);
        assertGe(token.balanceOf(market.pool), poolBefore);
        assertFalse(_order(id).open);
    }

    /// @notice A negative rebase that leaves the pool short makes cancel revert with the pool collect's 'TF' and keeps the order open.
    function test_negativeRebaseFreezesCancelAndKeepsTheOrderOpen() public {
        RebasingToken token = new RebasingToken();
        Market memory market = _market(address(token));
        uint256 deposit = 100 ether;
        _fund(address(token), deposit, 0);
        uint256 id = _create(market, _oddDeposit(market, deposit));
        uint256 tokenId = _order(id).tokenId;

        uint256 snap = vm.snapshotState();
        uint256 owed = _cancelPaid(id, address(token));
        assertGt(owed, 0);
        assertTrue(vm.revertToState(snap));

        uint256 poolBefore = token.balanceOf(market.pool);
        assertGe(poolBefore, owed);
        uint256 leave = owed / 2;
        vm.prank(market.pool);
        token.rebase(-int256(poolBefore - leave));
        assertEq(token.balanceOf(market.pool), leave);
        assertLt(leave, owed);

        uint256 userBefore = token.balanceOf(user);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "TF"));
        vm.prank(user);
        manager.cancelOrder(id, 0, 0, user);

        assertEq(token.balanceOf(user), userBefore);
        assertEq(token.balanceOf(market.pool), leave);
        assertTrue(_order(id).open);
        assertEq(_order(id).owner, user);
        assertEq(_order(id).tokenId, tokenId);
    }

    /// @notice Blacklisting the owner makes fill revert with Blacklisted(owner) from our payout, and cancel to another recipient succeeds.
    function test_blacklistedOwnerRevertsFillButCancelToAnotherRecipientWorks() public {
        BlacklistToken token = new BlacklistToken();
        Market memory market = _market(address(token));
        _fund(address(token), 0, 1 ether);
        Side memory side = _wethDeposit(market, 1 ether);
        uint256 id = _create(market, side);
        assertGt(_order(id).tokenId, 0);

        int24 target = side.trigger == LimitOrderManager.Trigger.Up ? side.upper : side.lower - 1;
        _move(market.pool, target);
        assertTrue(manager.isFillable(id));

        token.blacklist(user);
        vm.expectRevert(abi.encodeWithSelector(BlacklistToken.Blacklisted.selector, user));
        vm.prank(filler);
        manager.fill(id);
        assertTrue(_order(id).open);

        address recipient = makeAddr("recipient");
        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 ownerBefore = token.balanceOf(user);
        vm.prank(user);
        manager.cancelOrder(id, 0, 0, recipient);

        assertFalse(_order(id).open);
        assertGt(token.balanceOf(recipient), recipientBefore);
        assertEq(token.balanceOf(user), ownerBefore);
    }

    /// @notice Creates a fee-500 pool of `odd` and WETH, sorts the pair, and initializes tick 0.
    function _market(address odd) internal returns (Market memory market) {
        market.odd = odd;
        market.token0 = odd < WETH ? odd : WETH;
        market.token1 = odd < WETH ? WETH : odd;
        market.pool = IUniswapV3FactoryCreate(FACTORY).createPool(market.token0, market.token1, FEE);
        IUniswapV3PoolInit(market.pool).initialize(TickMath.getSqrtPriceAtTick(0));

        assertEq(IUniswapV3Factory(FACTORY).getPool(market.token0, market.token1, FEE), market.pool);
        assertEq(IUniswapV3Pool(market.pool).token0(), market.token0);
        assertEq(IUniswapV3Pool(market.pool).token1(), market.token1);
        assertEq(IUniswapV3Pool(market.pool).tickSpacing(), SPACING);
        assertEq(_tick(market.pool), 0);
    }

    /// @notice Mints the mock, deals WETH, and lets `user` spend both on the manager.
    function _fund(address odd, uint256 oddAmount, uint256 wethAmount) internal {
        if (oddAmount > 0) MockERC20(odd).mint(user, oddAmount);
        if (wethAmount > 0) deal(WETH, user, wethAmount);
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        IERC20(odd).approve(address(manager), type(uint256).max);
        IERC20(WETH).approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Returns a one-spacing range that deposits only the mock, on the side of tick 0 that holds it.
    function _oddDeposit(Market memory market, uint256 oddAmount) internal pure returns (Side memory side) {
        if (market.token0 == market.odd) {
            side = Side({
                lower: SPACING,
                upper: 2 * SPACING,
                amount0: oddAmount,
                amount1: 0,
                trigger: LimitOrderManager.Trigger.Up
            });
        } else {
            side = Side({
                lower: -2 * SPACING,
                upper: -SPACING,
                amount0: 0,
                amount1: oddAmount,
                trigger: LimitOrderManager.Trigger.Down
            });
        }
    }

    /// @notice Returns a one-spacing WETH range that turns into the mock once price crosses it.
    function _wethDeposit(Market memory market, uint256 wethAmount) internal pure returns (Side memory side) {
        if (market.token0 == market.odd) {
            side = Side({
                lower: -2 * SPACING,
                upper: -SPACING,
                amount0: 0,
                amount1: wethAmount,
                trigger: LimitOrderManager.Trigger.Down
            });
        } else {
            side = Side({
                lower: SPACING,
                upper: 2 * SPACING,
                amount0: wethAmount,
                amount1: 0,
                trigger: LimitOrderManager.Trigger.Up
            });
        }
    }

    /// @notice Builds createOrder parameters for `side` on `market` with zero minimums and a one-hour deadline.
    function _params(Market memory market, Side memory side)
        internal
        view
        returns (LimitOrderManager.OrderParams memory)
    {
        return LimitOrderManager.OrderParams({
            token0: market.token0,
            token1: market.token1,
            fee: FEE,
            tickLower: side.lower,
            tickUpper: side.upper,
            amount0: side.amount0,
            amount1: side.amount1,
            amount0Min: 0,
            amount1Min: 0,
            trigger: side.trigger,
            deadline: block.timestamp + 1 hours
        });
    }

    /// @notice Creates `side` as `user` with no tip and checks the order is open on `market.pool`.
    function _create(Market memory market, Side memory side) internal returns (uint256 id) {
        vm.prank(user);
        id = manager.createOrder(_params(market, side));
        LimitOrderManager.Order memory order = _order(id);
        assertTrue(order.open);
        assertEq(order.pool, market.pool);
        assertEq(order.owner, user);
        assertGt(order.tokenId, 0);
        assertEq(IERC20(market.token0).balanceOf(address(manager)), 0);
        assertEq(IERC20(market.token1).balanceOf(address(manager)), 0);
    }

    /// @notice Cancels `id` to `user` and returns how much of `token` they received.
    function _cancelPaid(uint256 id, address token) internal returns (uint256 paid) {
        uint256 beforeBal = IERC20(token).balanceOf(user);
        vm.prank(user);
        manager.cancelOrder(id, 0, 0, user);
        paid = IERC20(token).balanceOf(user) - beforeBal;
    }

    /// @notice Swaps `pool` until its tick reaches `targetTick`, paying whichever token that direction requires.
    function _move(address pool, int24 targetTick) internal {
        int24 tick = _tick(pool);
        bool zeroForOne = targetTick < tick;
        address tokenIn = zeroForOne ? IUniswapV3Pool(pool).token0() : IUniswapV3Pool(pool).token1();
        _fundSwapper(tokenIn);
        IERC20(tokenIn).approve(address(swapper), type(uint256).max);
        swapper.swap(pool, address(this), zeroForOne, SWAP_BUDGET, TickMath.getSqrtPriceAtTick(targetTick));
        if (zeroForOne) assertLe(_tick(pool), targetTick);
        else assertGe(_tick(pool), targetTick);
    }

    /// @notice Gives this contract `SWAP_BUDGET` of `token` so it can pay `_move`.
    function _fundSwapper(address token) internal {
        if (token == WETH) deal(WETH, address(this), SWAP_BUDGET);
        else MockERC20(token).mint(address(this), SWAP_BUDGET);
    }

    /// @notice Reads `pool`'s current tick.
    function _tick(address pool) internal view returns (int24 tick) {
        (, tick,,,,,) = IUniswapV3Pool(pool).slot0();
    }

    /// @notice Reads one order from the public getter.
    function _order(uint256 id) internal view returns (LimitOrderManager.Order memory order) {
        (bool ok, bytes memory data) = address(manager).staticcall(abi.encodeCall(manager.orders, (id)));
        require(ok, "order");
        order = abi.decode(data, (LimitOrderManager.Order));
    }
}
