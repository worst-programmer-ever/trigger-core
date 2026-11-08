# Test coverage notes

For each function or class exercised by tests in `test/`: what is tested, how, and known holes (untested paths, skipped cases). Do not document tests under `lib/`.

## How the tests run

- `test/LimitOrderManager.fork.t.sol` forks Arbitrum One and uses the real WETH/USDC 0.05% pool (`0xC696…E8D0`, the pool the UI reads), the canonical Uniswap V3 factory, and the position manager. `setUp` asserts the factory resolves to that pool.
- `test/LimitOrderManager.tokens.fork.t.sol` forks the same chain but creates fresh pools for mock tokens with odd transfer behavior.
- RPC: `ARBITRUM_RPC_URL`, falling back to `arbitrum-one-rpc.publicnode.com` when unset or empty. Block: `ARBITRUM_FORK_BLOCK`, or the latest block when unset or 0. CI passes both from repo secrets.
- Prices are moved by swapping toward a TickMath sqrt price, so the tick lands exactly where a trigger should flip. Payout checks preview the position's withdrawal, roll it back, then compare balances and `fill`'s return values.

## `createOrder`

- Tested: single-sided Up and Down orders pull only the input token; straddling orders spend both tokens, refund the surplus, and enforce the minimums (Uniswap's "Price slippage check"). Reverts: `TriggerAlreadyMet` for each trigger whose condition already holds, `PoolNotFound`, `TokenOrder`, `DeadlinePassed`, and `ZeroLiquidity` for empty deposits. Creation is refused with `CreationIsPaused` while paused.
- Odd tokens: a fee-on-transfer token makes creation revert inside Uniswap with `STF`, and nothing is stored.
- Gaps: tips near the `uint96` limit are not tested.

## `fill` and `isFillable`

- Tested:
  - after the price crosses, fill pays the owner, the keeper and protocol split, and the tip, and its return values match the balances;
  - Both fills on either edge, while Up and Down fill only in their own direction;
  - fill reverts when the order is not fillable, and a zero tip sends no ETH;
  - a price returning before anyone fills restores the position to the input token and `isFillable` turns false again;
  - a price stopping exactly on `tickUpper` coming from above reports tick `tickUpper - 1`: the position holds only token1 but is not fillable;
  - fill still works while creation is paused.
- Forced fill: `test_forcedFillRoundTripLogsAttackerNet` buys through an Up order, fills it, and sells back, then logs the attacker's net WETH and USDC with `console2`. It asserts the tip and the owner's payout, not that the attack loses money; read the logs with `forge test -vvv`.
- Odd tokens: a blacklisted owner makes fill revert.
- Gaps: no race between two keepers; no test of a fill in the same block as creation.

## `cancelOrder`

- Tested: cancelling a partly crossed order splits fees, refunds the tip, and enforces the minimums. Reverts: `NotOrderOwner`, the slippage check, `ZeroAddress` recipient, `OrderNotOpen` on a second cancel, and `TipTransferFailed` when the recipient rejects ETH. Cancel works while creation is paused; cancel on the exact upper boundary pays the owner in token1.
- Odd tokens: a blacklisted owner can still cancel to another recipient; a negative rebase makes cancel revert with Uniswap's `TF` and the order stays open; a positive rebase does not raise the cancel payout.
- Gaps: none known beyond the suite-wide holes below.

## `setSplit`, `setTreasury`, `pauseCreation`

- Tested: a new split applies only to orders created afterwards; an invalid split reverts with `InvalidSplit`; non-owners get `OwnableUnauthorizedAccount` on all three; a new treasury receives the protocol share; pausing blocks creation but not fill or cancel.
- Gaps: only the split values in `test_setSplitAffectsNewOrdersOnlyAndAdminGuards` are tried; no sweep of the bounds.

## Known holes across both suites

- With no pinned block, results depend on the live pool's price and liquidity at run time.
- No fuzz or invariant tests.
