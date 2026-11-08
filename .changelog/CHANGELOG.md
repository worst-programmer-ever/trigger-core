# Changelog

Newest entries first. Each entry records what was done, the decision, and how it was implemented.

## 2026-11-08 — Track docs/ and test/docs/

- Done: the hand-written `docs/README.md` and `test/docs/README.md` are now committed. They were silently ignored before.
- Decision: the `docs/` line in `.gitignore` (Foundry's default for `forge doc` output) matched every `docs` folder, including the records the project rule requires. Only `forge doc`'s generated book is ignored now.
- Implementation: `.gitignore` ignores `/docs/book/` instead of `docs/`.

## 2026-11-08 — Fork tests on Arbitrum One, boundary, forced-fill, and odd-token tests

- Done:
  - The fork suite moved from Base to the Arbitrum One WETH/USDC 0.05% pool the UI reads; `setUp` asserts that pool address.
  - New tests: the price returning before a fill, a price stopping exactly on the upper edge, and a forced-fill round trip that logs the attacker's net.
  - New suite `test/LimitOrderManager.tokens.fork.t.sol`: fee-on-transfer, rebasing, and blacklist tokens.
  - `foundry.toml` gained an `arbitrum` RPC endpoint and Arbiscan key; CI passes `ARBITRUM_RPC_URL` and `ARBITRUM_FORK_BLOCK` from secrets.
  - `forge test`: 17 passed, 0 failed.
- Decision: test against the chain and pool the product targets. The fork block is optional so local runs use the latest state, while CI can pin a block for repeatable runs. No contract code changed.
- Implementation: `test/LimitOrderManager.fork.t.sol`, `test/LimitOrderManager.tokens.fork.t.sol`, `foundry.toml`, `.github/workflows/test.yml`, coverage notes in `test/docs/README.md`.

## 2026-10-17 — Add project record rule

- Done: always-on rule plus changelog, docs index, and test-docs index.
- Decision: one changelog file at `.changelog/CHANGELOG.md`; Foundry coverage notes live in `test/docs/`.
- Implementation: `.cursor/rules/project-records.mdc`, `docs/README.md`, `test/docs/README.md`.
