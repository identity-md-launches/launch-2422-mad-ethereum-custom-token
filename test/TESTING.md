# MAD test coverage

The added suites extend the existing atomic-launch fixtures and real Uniswap v4
PoolManager tests. Production contracts and configuration are unchanged. No new
dependency is needed.

| Suite | Additional guarantees checked |
| --- | --- |
| `MadTokenAdversarial.t.sol` | Failed second freeze debit restores the burn and spending records; one-wei minimum cost; frozen finite-allowance rollback and exact expiry; approval cannot pay another caller's freeze; EIP-7702 length/prefix, delegation change and revocation. |
| `MadRewardsAdversarial.t.sol` | Independent canonical question document and JSON parsing; cold-state callback under 200,000 gas; malformed signed answers; wrong consumer domain; Intake and signer changes; retry rollback at a price ceiling; exact fallback boundary; malformed acquisition data and missing NFT delivery; live settlement window; unsolicited/duplicate NFTs; acquisition reentrancy during award; resale and repurchase without reopening an awarded round. |
| `MadHookAdversarial.t.sol` | Failed FWA payout and native redemption roll back claims; FWA payout remains independent of native liquidity; market changes reset conversion permission; invalid bounds and oversized swaps; small-amount fee rounding and monotonic decay. |
| `MadRewardsInvariant.t.sol` | Purchases, overpayment refunds, draw refunds, claiming, closing, asking, failures, timeouts, callbacks and awards preserve ETH/IMD accounting, NFT custody and final round results. |

## Random sequences

The new invariant suites use 256 sequences of 80 calls, configured in Solidity.
Only explicitly selected handler actions are targeted. Unexpected reverts fail the
suite; expected failures are checked through their return status or an explicit
revert expectation. Each handler also has a deterministic walkthrough that checks
its important transitions are reachable.

- **Token ledger:** four actors, including an EIP-7702 wallet. Independent balances,
  finite/infinite allowances, expiry times, full paid costs, burns and event-order
  counters are compared with contract state. Leaders are recomputed from totals and
  the earliest order at which each actor reached its current total. Token-only
  round testing impersonates the already-bound hook; the rewards suite closes
  through the real public hook entry point.
- **Conversion accounting:** swaps, time, tight/stale/relaxed price limits, payouts
  and redemptions. Expected shares and burns are derived from gross FWA input.
  Claims must equal the separate remaining obligations; native ETH and FWA supply
  are conserved across the manager, hook, rewards and fixed receiver. Existing
  swap tests continue to cover both currency orderings and all four swap modes.
- **Rewards custody:** random buys with changing quotes, blackout and immediate
  refunds; independent draw fulfillment/refunds; claims and refund withdrawals;
  different round leaders; variable live oracle prices; successful, malformed,
  failed and timed-out asks; rejecting NFT recipients and later retries. Ghost
  totals use amounts sent and selected outcomes rather than balance differences
  from the contracts being tested. The initial state includes pending, refunded,
  assigned and oracle-pending work so the campaign reaches meaningful states.

The fee and token code-shape properties run 1,000 fuzz cases. The malformed
response properties use 256 cases over deliberately invalid alternatives. The
repository's supplied fuzz seed is used for verification:

```sh
FOUNDRY_FUZZ_SEED=0x7b449c27e8d50466ace5b9f57d7bf19b1d42679e5c0f653bb6cc6a4488b06a52 forge build
FOUNDRY_FUZZ_SEED=0x7b449c27e8d50466ace5b9f57d7bf19b1d42679e5c0f653bb6cc6a4488b06a52 forge test
```

## Outside protocols

FWA unit tests enforce restricted transfers. The real PoolManager handles swaps,
liquidity, unlocks and ERC-6909 settlement. The local market hook models its
exact-input sell restriction and ETH fee, while FWA V2 and Intake mocks model the
allocation/refund and callback interfaces in the pinned references. A mock result
is not evidence of live integration.

`MainnetFork.t.sol` runs only when `MAINNET_RPC_URL` is provided and otherwise skips
cleanly. Its two tests were also executed successfully during this assignment
against Ethereum: real FWA buys/sells during decay and at rest, immediate burn,
official ETH/FWA conversion, direct receiver payout, and frozen-wallet sale
rejection. These forks do not exercise live Chainlink fulfillment, FWA V2 NFT
acquisition, or a paid live oracle request; those flows are covered locally with
mocks and the existing canonical oracle signature vector.

```sh
MAINNET_RPC_URL=<ethereum-rpc> forge test --match-path test/MainnetFork.t.sol --no-storage-caching
```

`test/scratch/` contains only local build products/logs and is not part of the
submission. None of the delivered tests imports it or relies on its contents.

## Verification result

On 2026-10-21 with Forge 1.8.3 and the supplied seed:

- `forge build`: passed.
- Full default `forge test`: 95 passed, 0 failed, 1 optional fork suite skipped.
- Explicit Ethereum fork run: 2 passed, 0 failed, 0 skipped.
- Each added invariant campaign: 256 sequences, 20,480 calls, no unexpected reverts.
- Scope check and `git diff --check`: passed; all seven changed files are under `test/`.

No reproducible implementation defect was found in these checks.
