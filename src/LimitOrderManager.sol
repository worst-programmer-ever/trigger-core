// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Factory} from "./interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";

/// @notice Turns a Uniswap V3 range into a trigger order that anyone can fill once price leaves that range.
/// @dev Every order is a position plus a direction. The position is held here as an NFT.
///
/// Up fills when `tick >= tickUpper`, so the position is entirely token1. That covers a single-sided
/// ask (the range sits above the price, only token0 is deposited) and a straddling ask (the range
/// contains the price, both tokens are deposited).
/// Down fills when `tick < tickLower`, so the position is entirely token0. That covers a single-sided
/// bid and a straddling bid.
/// Both fills when the price leaves through either edge. The range must contain the price at creation.
///
/// Creation only checks that the trigger is not already true. Up needs `tick < tickUpper`, Down needs
/// `tick >= tickLower`, and Both needs the price inside the range. A range above the price with a Down
/// trigger is rejected because it would be fillable immediately.
///
/// On a fill the owner gets their principal back plus their share of the fees. The caller gets the
/// keeper share plus the escrowed ETH tip. The treasury gets the protocol share in the same transaction.
/// The default split is 20% / 50% / 30%, copied onto the order so a later setSplit does not change it.
/// On a cancel there is no keeper, so the owner's share is principal plus the keeper's basis points.
/// At the default protocol share that is 70/30. Those tokens and the tip go to a recipient the owner
/// names, which can be an address other than the owner.
///
/// Create, fill, and cancel are internal so a later batch function can loop over them under one lock.
contract LimitOrderManager is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice Which edge closes the order.
    enum Trigger {
        Up,
        Down,
        Both
    }

    /// @notice Basis-point denominator. User share is the remainder after keeper and protocol.
    uint256 public constant BPS = 10_000;

    /// @notice Default keeper share of fees, in basis points, copied onto each new order.
    uint16 public constant DEFAULT_KEEPER_BPS = 5_000;

    /// @notice Default protocol share of fees, in basis points, copied onto each new order.
    uint16 public constant DEFAULT_PROTOCOL_BPS = 3_000;

    /// @notice Parameters for one order. A later batch function takes an array of these.
    /// @dev `token0` and `token1` must already be in the pool's order. The tip is not a field:
    /// `createOrder` stores `msg.value`, and the internal function takes the tip separately so a
    /// batch can pass one tip per order after checking that `msg.value` equals their sum.
    struct OrderParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        uint256 amount0Min;
        uint256 amount1Min;
        Trigger trigger;
        uint256 deadline;
    }

    /// @dev Fee split for both tokens of one closed order.
    struct Shares {
        uint256 user0;
        uint256 user1;
        uint256 keeper0;
        uint256 keeper1;
        uint256 protocol0;
        uint256 protocol1;
    }

    /// @dev Amounts and recipients used while closing one order.
    struct Payout {
        address owner;
        address beneficiary;
        address recipient; // Cancel pays the owner's tokens and the tip here. Unused on a fill.
        address pool;
        uint96 tip;
        uint16 keeperBps;
        uint16 protocolBps;
        bool payKeeper;
        uint256 principal0;
        uint256 principal1;
        uint256 total0;
        uint256 total1;
    }

    /// @notice A stored order.
    /// @dev Packing is intentional. `owner` and `tip` share slot 0 (20 + 12 bytes).
    /// `pool`, both ticks, the trigger, the open flag, and both fee shares share slot 1
    /// (20+3+3+1+1+2+2 bytes). `tokenId` sits alone in slot 2.
    struct Order {
        address owner;
        uint96 tip; // Escrowed ETH. Zero is allowed. Cleared when the order closes.
        address pool; // Real pool from the factory. Never an address supplied by the caller.
        int24 tickLower;
        int24 tickUpper;
        Trigger trigger; // Up, Down, or Both. One byte, in place of the old ask/bid flag.
        bool open;
        uint16 keeperBps; // Keeper share of fees, frozen at creation. The owner's share is the remainder.
        uint16 protocolBps; // Treasury share of fees, frozen at creation.
        uint256 tokenId; // Position NFT held by this contract.
    }

    /// @notice Uniswap V3 factory used to resolve pools. Callers cannot pass a pool address.
    /// @dev A fake pool could report any tick and make an order look fillable. Looking the pool
    /// up here means the price we trust is the real pool for this pair and fee.
    IUniswapV3Factory public immutable factory;

    /// @notice Position manager that custodies every order's NFT. This contract is the NFT owner.
    INonfungiblePositionManager public immutable positionManager;

    /// @notice Recipient of the protocol's share of fees. Fees are sent here inside fill and cancel.
    /// @dev Also the recovery path: if a token ever refuses transfers to this address, the owner
    /// points it somewhere else and the next fill or cancel can complete.
    address public treasury;

    /// @notice Keeper share, in basis points, applied to orders created from now on.
    uint16 public keeperBps;

    /// @notice Protocol share, in basis points, applied to orders created from now on.
    uint16 public protocolBps;

    /// @notice When true, new orders revert. Fills and cancels stay open so funds cannot be frozen by a pause.
    bool public creationPaused;

    /// @notice Next id to assign. Ids start at 1.
    uint256 public nextOrderId = 1;

    /// @notice Orders by id.
    mapping(uint256 id => Order order) public orders;

    /// @notice Emitted with everything a keeper needs to track the order from logs alone.
    event OrderCreated(
        uint256 indexed orderId,
        address indexed owner,
        address indexed pool,
        int24 tickLower,
        int24 tickUpper,
        Trigger trigger,
        uint96 tip,
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1,
        uint16 keeperBps,
        uint16 protocolBps
    );

    /// @notice Emitted after an order is filled and every payout has been sent.
    event OrderFilled(
        uint256 indexed orderId,
        address indexed filler,
        uint256 amount0ToOwner,
        uint256 amount1ToOwner,
        uint256 amount0ToFiller,
        uint256 amount1ToFiller,
        uint256 amount0ToTreasury,
        uint256 amount1ToTreasury,
        uint96 tip
    );

    /// @notice Emitted after the owner cancels and the position's tokens and tip are sent to `recipient`.
    event OrderCancelled(
        uint256 indexed orderId,
        address indexed owner,
        address indexed recipient,
        uint256 amount0ToRecipient,
        uint256 amount1ToRecipient,
        uint256 amount0ToTreasury,
        uint256 amount1ToTreasury,
        uint96 tip
    );

    /// @notice Emitted when the treasury address changes.
    event TreasuryUpdated(address indexed treasury);

    /// @notice Emitted when the split for future orders changes.
    event SplitUpdated(uint16 keeperBps, uint16 protocolBps);

    /// @notice Emitted when creation is paused or unpaused.
    event CreationPaused(bool paused);

    /// @notice Thrown when an address argument is the zero address.
    error ZeroAddress();
    /// @notice Thrown when both deposit amounts are zero.
    error ZeroAmount();
    /// @notice Thrown when token0 and token1 are the same address.
    error SameToken();
    /// @notice Thrown when the ETH tip does not fit in uint96.
    error TipTooLarge();
    /// @notice Thrown when the factory has no pool for the pair and fee.
    error PoolNotFound();
    /// @notice Thrown when token0 and token1 are not in the pool's order.
    error TokenOrder();
    /// @notice Thrown when tickLower is not below tickUpper.
    error InvalidTickRange();
    /// @notice Thrown when the pool spacing is invalid or a tick is not a multiple of it.
    error InvalidTickSpacing();
    /// @notice Thrown when the trigger is already met at the current price.
    error TriggerAlreadyMet();
    /// @notice Thrown when the creation deadline is already in the past.
    error DeadlinePassed();
    /// @notice Thrown when creation is paused.
    error CreationIsPaused();
    /// @notice Thrown when the order was already filled or cancelled.
    error OrderNotOpen(uint256 orderId);
    /// @notice Thrown when the order is open but its trigger is not met.
    error NotFillable(uint256 orderId);
    /// @notice Thrown when the caller is not the order's owner.
    error NotOrderOwner(uint256 orderId);
    /// @notice Thrown when the keeper and protocol shares sum to more than 10000 basis points.
    error InvalidSplit();
    /// @notice Thrown when the tip's ETH transfer fails.
    error TipTransferFailed();
    /// @notice Thrown when the deposit is on the wrong side of the range for the current price.
    error ZeroLiquidity();

    /// @notice Deploys the manager. The initial owner should be a Safe, never the deployer key for long.
    constructor(address factory_, address positionManager_, address treasury_, address initialOwner)
        Ownable(initialOwner)
    {
        if (factory_ == address(0) || positionManager_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        factory = IUniswapV3Factory(factory_);
        positionManager = INonfungiblePositionManager(positionManager_);
        treasury = treasury_;
        keeperBps = DEFAULT_KEEPER_BPS;
        protocolBps = DEFAULT_PROTOCOL_BPS;
    }

    /// @notice Creates one order and escrows `msg.value` as the filler's tip.
    function createOrder(OrderParams calldata params) external payable nonReentrant returns (uint256 orderId) {
        // The tip is stored as uint96 so it packs next to the owner. The check makes the cast safe.
        if (msg.value > type(uint96).max) revert TipTooLarge();
        // forge-lint: disable-next-line(unsafe-typecast)
        orderId = _createOrder(params, msg.sender, uint96(msg.value));
    }

    /// @notice Fills an open order whose trigger the price has met, and returns the keeper's payout.
    /// @dev The return values are what a keeper reads from a simulated call. Simulations return
    /// values and do not return events.
    function fill(uint256 orderId) external nonReentrant returns (uint256 keeper0, uint256 keeper1, uint96 tip) {
        return _fill(orderId, msg.sender);
    }

    /// @notice Closes the caller's order and sends the owner's tokens and the tip to `recipient`.
    /// @dev No deadline. A late cancel only returns funds the owner wanted back. Minimums matter while
    /// the price is still inside the range, because the mix of tokens then depends on the price.
    /// The recipient can differ from the owner, so a contract that rejects ETH, or an owner a token
    /// refuses to pay, can still exit by naming an address that can receive both.
    function cancelOrder(uint256 orderId, uint256 amount0Min, uint256 amount1Min, address recipient)
        external
        nonReentrant
    {
        _cancelOrder(orderId, amount0Min, amount1Min, recipient);
    }

    /// @notice Returns whether `orderId` is open and its trigger is met.
    function isFillable(uint256 orderId) external view returns (bool) {
        Order storage order = orders[orderId];
        return order.open && _priceCrossed(order);
    }

    /// @notice Points the protocol share at a new treasury. Also the recovery path when a token refuses the current one.
    function setTreasury(address newTreasury) external nonReentrant onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /// @notice Sets the keeper and protocol shares for orders created after this call.
    function setSplit(uint16 newKeeperBps, uint16 newProtocolBps) external nonReentrant onlyOwner {
        if (uint256(newKeeperBps) + uint256(newProtocolBps) > BPS) revert InvalidSplit();
        keeperBps = newKeeperBps;
        protocolBps = newProtocolBps;
        emit SplitUpdated(newKeeperBps, newProtocolBps);
    }

    /// @notice Stops or resumes new orders. Existing orders can still be filled or cancelled.
    function pauseCreation(bool paused) external nonReentrant onlyOwner {
        creationPaused = paused;
        emit CreationPaused(paused);
    }

    /// @dev Mints one order for `owner_`. `tip` must already have been escrowed in ETH by the caller.
    function _createOrder(OrderParams memory params, address owner_, uint96 tip) internal returns (uint256 orderId) {
        if (creationPaused) revert CreationIsPaused();
        if (block.timestamp > params.deadline) revert DeadlinePassed();
        if (params.amount0 == 0 && params.amount1 == 0) revert ZeroAmount();
        if (params.token0 == address(0) || params.token1 == address(0)) revert ZeroAddress();
        if (params.token0 == params.token1) revert SameToken();

        // getPool sorts the pair, so a reversed pair still finds the pool. The check below rejects
        // that: minting requires token0 to be the pool's lower address.
        address pool = factory.getPool(params.token0, params.token1, params.fee);
        if (pool == address(0)) revert PoolNotFound();
        if (params.token0 != IUniswapV3Pool(pool).token0() || params.token1 != IUniswapV3Pool(pool).token1()) {
            revert TokenOrder();
        }
        _validatePosition(pool, params);

        _pull(params.token0, owner_, params.amount0);
        _pull(params.token1, owner_, params.amount1);
        (uint256 tokenId, uint256 used0, uint256 used1) = _mint(pool, params);
        _refund(params.token0, owner_, params.amount0, used0);
        _refund(params.token1, owner_, params.amount1, used1);

        orderId = _record(params, owner_, pool, tokenId, used0, used1, tip);
    }

    /// @dev Checks tick spacing, that the trigger is not already met, and that the deposit matches the side the range holds.
    function _validatePosition(address pool, OrderParams memory params) internal view {
        int24 spacing = IUniswapV3Pool(pool).tickSpacing();
        if (spacing <= 0 || params.tickLower % spacing != 0 || params.tickUpper % spacing != 0) {
            revert InvalidTickSpacing();
        }
        if (params.tickLower >= params.tickUpper) revert InvalidTickRange();

        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        if (params.trigger == Trigger.Up) {
            // Above the price, or containing it. Not already through the top.
            if (tick >= params.tickUpper) revert TriggerAlreadyMet();
        } else if (params.trigger == Trigger.Down) {
            // Below the price, or containing it. Not already through the bottom.
            if (tick < params.tickLower) revert TriggerAlreadyMet();
        } else if (tick < params.tickLower || tick >= params.tickUpper) {
            // Both is only meaningful while the price is still inside the range.
            revert TriggerAlreadyMet();
        }

        // The pool reverts with an empty require when the computed liquidity is zero, and that
        // happens inside the position manager before mint returns. Check the side here instead.
        // A range above the price holds only token0, a range below holds only token1, and a range
        // that contains the price needs both.
        if (tick < params.tickLower) {
            if (params.amount0 == 0) revert ZeroLiquidity();
        } else if (tick >= params.tickUpper) {
            if (params.amount1 == 0) revert ZeroLiquidity();
        } else if (params.amount0 == 0 || params.amount1 == 0) {
            revert ZeroLiquidity();
        }
    }

    /// @dev Pulls `amount` of `token` from `owner_` and lets the position manager spend it.
    function _pull(address token, address owner_, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(token).safeTransferFrom(owner_, address(this), amount);
        IERC20(token).forceApprove(address(positionManager), amount);
    }

    /// @dev Returns unused input to `owner_` and clears the position manager's allowance.
    function _refund(address token, address owner_, uint256 pulled, uint256 used) internal {
        if (pulled == 0) return;
        if (pulled > used) IERC20(token).safeTransfer(owner_, pulled - used);
        IERC20(token).forceApprove(address(positionManager), 0);
    }

    /// @dev Mints the position to this contract and returns the token id and the amounts actually used.
    function _mint(address pool, OrderParams memory params)
        internal
        returns (uint256 tokenId, uint256 used0, uint256 used1)
    {
        (uint256 mintedId,, uint256 amount0, uint256 amount1) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: IUniswapV3Pool(pool).token0(),
                token1: IUniswapV3Pool(pool).token1(),
                fee: params.fee,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                amount0Desired: params.amount0,
                amount1Desired: params.amount1,
                // These protect a straddling mint, whose token ratio depends on the price.
                // A single-sided mint can pass zero: if the price moves into that range, the other
                // deposit is zero and _validatePosition reverts with ZeroLiquidity; if it moves past
                // the range, the trigger check reverts with TriggerAlreadyMet.
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                recipient: address(this),
                deadline: params.deadline
            })
        );
        tokenId = mintedId;
        used0 = amount0;
        used1 = amount1;
    }

    /// @dev Stores an order with the current fee split and emits `OrderCreated`.
    function _record(
        OrderParams memory params,
        address owner_,
        address pool,
        uint256 tokenId,
        uint256 used0,
        uint256 used1,
        uint96 tip
    ) internal returns (uint256 orderId) {
        orderId = nextOrderId++;
        // Freeze the current split onto this order. setSplit only changes the storage read here.
        uint16 copiedKeeperBps = keeperBps;
        uint16 copiedProtocolBps = protocolBps;
        orders[orderId] = Order({
            owner: owner_,
            tip: tip,
            pool: pool,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            trigger: params.trigger,
            open: true,
            keeperBps: copiedKeeperBps,
            protocolBps: copiedProtocolBps,
            tokenId: tokenId
        });

        emit OrderCreated(
            orderId,
            owner_,
            pool,
            params.tickLower,
            params.tickUpper,
            params.trigger,
            tip,
            tokenId,
            used0,
            used1,
            copiedKeeperBps,
            copiedProtocolBps
        );
    }

    /// @dev Fills `orderId` and pays the keeper share and the tip to `beneficiary`.
    function _fill(uint256 orderId, address beneficiary)
        internal
        returns (uint256 keeper0, uint256 keeper1, uint96 tip)
    {
        Order storage order = orders[orderId];
        if (!order.open) revert OrderNotOpen(orderId);
        if (!_priceCrossed(order)) revert NotFillable(orderId);
        // A met trigger means the position is out of range and holds one token, so the withdrawn
        // amounts do not depend on the price. Minimums stay zero and there is no deadline.
        return _settle(orderId, beneficiary, address(0), true, 0, 0);
    }

    /// @dev Cancels the caller's order and pays the owner's share and the tip to `recipient`.
    function _cancelOrder(uint256 orderId, uint256 amount0Min, uint256 amount1Min, address recipient) internal {
        if (recipient == address(0)) revert ZeroAddress();
        Order storage order = orders[orderId];
        if (!order.open) revert OrderNotOpen(orderId);
        if (order.owner != msg.sender) revert NotOrderOwner(orderId);
        _settle(orderId, address(0), recipient, false, amount0Min, amount1Min);
    }

    /// @dev Marks the order closed, withdraws the position, pays everyone, and sends the tip last.
    function _settle(
        uint256 orderId,
        address beneficiary,
        address recipient,
        bool payKeeper,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 keeper0, uint256 keeper1, uint96 tip) {
        Order storage order = orders[orderId];
        Payout memory payout = Payout({
            owner: order.owner,
            beneficiary: beneficiary,
            recipient: recipient,
            pool: order.pool,
            tip: order.tip,
            keeperBps: order.keeperBps,
            protocolBps: order.protocolBps,
            payKeeper: payKeeper,
            principal0: 0,
            principal1: 0,
            total0: 0,
            total1: 0
        });
        uint256 tokenId = order.tokenId;
        // Close the order and forget the tip before any call that can run outside code.
        // A token callback or the tip recipient then sees a closed order and cannot settle it again.
        order.open = false;
        order.tip = 0;
        (payout.principal0, payout.principal1, payout.total0, payout.total1) =
            _withdraw(tokenId, amount0Min, amount1Min);
        return _distribute(orderId, payout);
    }

    /// @dev Splits both tokens, transfers them, sends the tip, and emits the closing event.
    function _distribute(uint256 orderId, Payout memory payout)
        internal
        returns (uint256 keeper0, uint256 keeper1, uint96 tip)
    {
        Shares memory shares;
        (shares.user0, shares.keeper0, shares.protocol0) =
            _split(payout.principal0, payout.total0, payout.keeperBps, payout.protocolBps, payout.payKeeper);
        (shares.user1, shares.keeper1, shares.protocol1) =
            _split(payout.principal1, payout.total1, payout.keeperBps, payout.protocolBps, payout.payKeeper);
        _payShares(payout, shares);
        _emitClose(orderId, payout, shares);
        return (shares.keeper0, shares.keeper1, payout.tip);
    }

    /// @dev Transfers the owner's, keeper's, and treasury's tokens, then sends the tip.
    function _payShares(Payout memory payout, Shares memory shares) internal {
        address token0 = IUniswapV3Pool(payout.pool).token0();
        address token1 = IUniswapV3Pool(payout.pool).token1();
        // A fill returns the owner's share to the owner. A cancel sends it to the chosen recipient.
        address userPayee = payout.payKeeper ? payout.owner : payout.recipient;
        _send(token0, userPayee, shares.user0);
        _send(token1, userPayee, shares.user1);
        if (payout.payKeeper) {
            _send(token0, payout.beneficiary, shares.keeper0);
            _send(token1, payout.beneficiary, shares.keeper1);
        }
        _send(token0, treasury, shares.protocol0);
        _send(token1, treasury, shares.protocol1);
        // The tip is the last external call. On a fill it pays the keeper. On a cancel it goes to the recipient.
        _payTip(payout.payKeeper ? payout.beneficiary : payout.recipient, payout.tip);
    }

    /// @dev Emits the fill or cancel event for a closed order.
    function _emitClose(uint256 orderId, Payout memory payout, Shares memory shares) internal {
        if (payout.payKeeper) {
            emit OrderFilled(
                orderId,
                payout.beneficiary,
                shares.user0,
                shares.user1,
                shares.keeper0,
                shares.keeper1,
                shares.protocol0,
                shares.protocol1,
                payout.tip
            );
        } else {
            emit OrderCancelled(
                orderId,
                payout.owner,
                payout.recipient,
                shares.user0,
                shares.user1,
                shares.protocol0,
                shares.protocol1,
                payout.tip
            );
        }
    }

    /// @dev Removes all liquidity, collects principal plus fees, and burns the position NFT.
    function _withdraw(uint256 tokenId, uint256 amount0Min, uint256 amount1Min)
        internal
        returns (uint256 principal0, uint256 principal1, uint256 total0, uint256 total1)
    {
        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(tokenId);
        if (liquidity > 0) {
            // pool.burn, which this wraps, returns the principal only. Accrued fees stay in the position
            // until collect. That gap is how _split tells principal and fees apart.
            // Fill passes zero minimums. Cancel passes the owner's, because an in-range withdrawal
            // mixes the two tokens at the current price and can be sandwiched.
            (principal0, principal1) = positionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: block.timestamp
                })
            );
        }
        // Collect pays out everything the position owes: the principal just removed, plus fees.
        (total0, total1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
        // burn reverts unless liquidity is zero and nothing remains to collect, so it also
        // checks that the position was fully emptied.
        positionManager.burn(tokenId);
    }

    /// @dev Splits one token into user, keeper, and protocol shares. A shortfall is treated as zero fees.
    function _split(uint256 principal, uint256 total, uint16 orderKeeperBps, uint16 orderProtocolBps, bool payKeeper)
        internal
        pure
        returns (uint256 toUser, uint256 toKeeper, uint256 toProtocol)
    {
        // A fee-on-transfer token can make collect return less than decreaseLiquidity reported.
        // Treating that shortfall as zero fees keeps the subtraction from reverting, which would
        // also block cancel and trap the position. The owner then receives whatever actually arrived.
        uint256 fee = total > principal ? total - principal : 0;
        uint256 baseAmount = total - fee;
        toProtocol = fee * orderProtocolBps / BPS;
        if (payKeeper) {
            toKeeper = fee * orderKeeperBps / BPS;
            // The owner gets the rounding dust, so the three shares add up to `total` and nothing
            // is left sitting on this contract.
            toUser = baseAmount + (fee - toKeeper - toProtocol);
        } else {
            // Cancel has no keeper. The keeper's basis points are paid to the owner, on top of
            // principal. At the default 3000 protocol bps this is the 70/30 split.
            toUser = baseAmount + (fee - toProtocol);
        }
    }

    /// @dev Returns true when the order's trigger is met at the pool's current tick.
    function _priceCrossed(Order storage order) internal view returns (bool) {
        (, int24 tick,,,,,) = IUniswapV3Pool(order.pool).slot0();
        // The position's range is [tickLower, tickUpper). tick == tickUpper is already all token1.
        // tick == tickLower is still inside the range, so a Down trigger is not met there.
        if (order.trigger == Trigger.Up) return tick >= order.tickUpper;
        if (order.trigger == Trigger.Down) return tick < order.tickLower;
        return tick >= order.tickUpper || tick < order.tickLower;
    }

    /// @dev Transfers `amount` of `token` to `to`, skipping zero amounts.
    function _send(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(token).safeTransfer(to, amount);
    }

    /// @dev Sends the escrowed ETH tip. This is the last external call in a fill or cancel.
    function _payTip(address to, uint96 tip) internal {
        if (tip == 0) return;
        // Send only this order's tip, never the contract's whole ETH balance. Other open orders
        // keep their own escrow in the same balance. A recipient that rejects ETH reverts the
        // whole fill or cancel, so the order stays open. On a cancel the owner chooses that address.
        (bool ok,) = to.call{value: tip}("");
        if (!ok) revert TipTransferFailed();
    }
}
