# Decisions

Locked 2026-10-17. These override earlier notes about an allowlist or about treating odd tokens inside `LimitOrderManager`.

## Chain

The contract is deployed and tested on Arbitrum One. Fork tests resolve the Uniswap V3 factory and position manager there. The UI reads the Arbitrum WETH/USDC 0.05% pool (`0xC6962004f452bE9203591991D15f6b388e09E8D0`).

## No allowlist

Any pool the Uniswap V3 factory returns can take an order. There is no pool allowlist and no token allowlist. The owner pause stops new orders on every pool at once. Fill and cancel stay open while creation is paused.

## Odd tokens

`LimitOrderManager` does not detect or block fee-on-transfer tokens, rebasing tokens, or blacklisted addresses. Behavior is whatever Uniswap V3 already does, plus the cancel recipient below.

### Fee-on-transfer

The pool requires its token balance to rise by the amount it asked for. A token that keeps a fee on transfer fails that check, so the mint reverts and `createOrder` reverts with it. The user's tokens stay in their wallet.

### Rebasing tokens

Uniswap V3 accepts rebasing tokens such as stETH. `createOrder` succeeds. A positive rebase leaves the extra tokens in the pool, and the position is not credited, because V3 has no skim. A negative rebase can make the pool's burn or collect revert, which leaves the order open. That risk stays in the Uniswap pool. The non-rebasing token used in practice is the wrapper, wstETH.

### Blacklisted addresses

A token that refuses an address, including after a hack or a sanctions list, is outside this contract's responsibility. Fill pays the order's owner. If that transfer reverts, the fill reverts and the order stays open.

The owner chooses the exit in `cancelOrder`. The `recipient` argument receives the owner's tokens and the escrowed ETH tip, and it can be any address other than the zero address. An owner who can no longer receive the token, or who cannot receive ETH, cancels and names an address that can.
