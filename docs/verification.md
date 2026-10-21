# Verification and review record

The delivered contracts are `MadToken`, `MadHook` and the hook-created `MadRewards`. Local checks exercise their production code against an actual Uniswap v4 `PoolManager`. FWA, FWA V2, the official market hook, NFTs and Intake have deliberately limited mocks where no fork is available.

## Recorded checks

| Check | Result |
| --- | --- |
| `forge build --sizes`, Solidity 0.8.26 | Passed |
| `forge build --force --offline` | Passed: all 122 compiled source files resolve from the repository and the installed pinned compiler |
| `forge test` | 58 passed, zero failed, one mainnet-fork setup skipped |
| `forge fmt --check` | Passed |
| Fuzz seed | `0x7b449c27e8d50466ace5b9f57d7bf19b1d42679e5c0f653bb6cc6a4488b06a52`, pinned in `foundry.toml` |
| Fuzz cases | 256 runs per fuzz test; token cost conservation and all fee modes, including both currency orderings |
| Stateful invariants | 256 runs, 128,000 handler calls; both supply/burn conservation and separated claims/payout accounting passed |
| Runtime escape-opcode scan | Passed for all three production contracts, using the supplied floor's reachable-opcode/PUSH-data rules |
| Protocol conformance | Supplied EIP-712 digest and signature, canonical callback selectors, question-hash vector and wrong-chain rejection passed |
| Callback stipend | Actual rewards callback through the Intake mock and supplied-vector verifier both succeed under 200,000 gas |
| Free oracle wording preflight | HTTP 200, `judged: true`, `blockers: []`, `suggestions: []`; recorded in `oracle-wording-preflight.json` |
| Live mainnet integration | Not run: `MAINNET_RPC_URL` was unset; no live-integration success is claimed |

The preflight uses the concrete address and block window of a **local test deployment**, solely to screen the fixed wording. It does not claim MAD already exists on mainnet. The check API's short-form request fills in its own defaults (21 quorum, 24-hour window, 86,400-second validity); those draft defaults are not used in the contract. The submitted on-chain body fixes quorum 20, the actual closed round's absolute window, head 1 and validity 3600 as requested. A keeper/operator should inspect `questionBody(round)` with the real launched token before paying the first ask.

Runtime sizes with the pinned build:

| Contract | Runtime bytes | Creation bytes, excluding constructor arguments |
| --- | ---: | ---: |
| MadToken | 4,013 | 5,115 |
| MadHook | 10,979 | 32,517 |
| MadRewards | 18,648 | 20,228 |

All are below the 24,576-byte runtime and 49,152-byte creation limits, including their respective constructor arguments. Libraries called by production code are internal and leave no link placeholders.

## Behavioral coverage

- Both MAD/FWA orderings, both directions, exact input and exact output; closed owner trading and owner-only irreversible opening; decay at 0/15/30 minutes and fuzzed intermediate seconds; fee base, burn and rounding; no duplicate callback fees.
- Real PoolManager accounting through claim mint/burn, swaps, direct payout and unlock redemption. NFT-only conversion with a market fee, price-bound partial fill, unsold-claim retry, minimum-output failure, stale bounds and an empty native balance. The official-market **mock** mints its own ETH fee claim so that the MAD ETH-claim branch can be tested independently; this does not prove the live market hook will tolerate an empty native reserve.
- Equal 0.50% shares, no MAD tax, direct PoolManager → receiver FWA transfer, no adapter/hub dependency, idempotent payout and no cross-use of NFT claims.
- Supply and transfer behavior; freeze payment, burn/remainder, receive permission, frozen payer, reset deadlines, allowances, pool sales, liquidity additions and an unrelated unhooked pool. EIP-7702 `vm.etch` designation, ordinary code including 23-byte code, zero/self/contract targets, zero cost, lack of funds, cumulative ties and adjacent block windows.
- Real mined CREATE2 atomic launch and a spoofed late binder in the same block but a later transaction. Token constructor and initialization must share a factory call.
- Live V2 quote/blackout interfaces, immediate overpayment, refund credits, old-pool requests after a configuration change, settlement deadlines and retry after failed keep. Queue ordering follows successful keep time.
- Oracle price changes, insufficient funding, exact temporary approvals, eight-block confirmation depth, wrong callback sender/request/hash/chain/window/panel, malformed/tampered/expired signatures, future issuance, zero answer, signed-UUID replay, failure retry and six-hour timeout/supersession.
- No asset movement in a callback; 72-hour fallback; late-answer rejection; safe-transfer refusal and retry; reentrant winner callback; immutable beneficiary after a failed attempt; no duplicate award.

## Security review performed locally

The source review checked the following properties alongside the tests:

| Area | Design / evidence |
| --- | --- |
| Initialization and authentication | PoolManager-only callbacks; exact launch key and factory; token constructor's transient capability consumed once during the atomic launch. No trust in router-provided holder identities. |
| Return deltas / NoOp risk | Before-return permission is limited to the fixed specified-side fee, bounded below the gross input; after-return handles only the FWA unspecified side. Specified-side underfills revert. No owner-selected fee or arbitrary delta. |
| Delta conservation | Main fee credit offsets burn/take plus revenue claims. Internal-sale FWA debt offsets the NFT claim burn. Native output offsets take or ETH claim mint. Each redemption burns and takes the same amount inside an authenticated unlock. Real manager unlock checks and invariants exercise these paths. |
| Reentrancy | OpenZeppelin guard on external asset/state paths; swap context also spans before/after callbacks. Expected ERC-721 receipt is read-only and restricted to the collection/token being kept. Failed award restores its completion flag while keeping the beneficiary. |
| Transfer rules | FWA only leaves PoolManager for immediate burn or direct receiver payout. Frozen MAD debit checks are in the ERC-20 update path, independent of pool/router identity. |
| Oracle binding | Canonical 15-field attestation and consumer domain, saved hash, absolute block window, panel minimums, validity bounds, active Intake ID and consumed signed UUID. Fixed question and no results setter. |
| Custody and administration | Owner has only the requested opening and protocol/bound settings. No generic execute, withdrawal, rescue, proxy, upgrade, recipient setter or second mint. |
| Bounded work | FIFO index rather than queue scans; one NFT per buy/claim/award; question text and definitions have fixed bounded construction. |

This is an implementation self-review, not an independent audit. Slither/Mythril, formal verification and an independent contributor's adversarial review were not performed here.

## Verifier fixture and release dependencies

The supplied generic hook floor deploys its token probe in `setUp()` from the harness, then initializes later from a different factory probe. A genuine atomic launch deploys the token from the factory and initializes before that transaction ends. The floor's split sequence loses the transient authorization and has the wrong recorded token deployer. These are relevant security properties; the production contracts do not add a test-only or late-binding exemption. The independent verifier needs an atomic factory fixture for this task. The supplied external floor suite itself was not reported as passed.

Before release, run the provided mainnet fork suite with a working Ethereum RPC, exercise the actual launch factory's complete transaction, and perform the independent review. Confirm external pool liquidity and transfer behavior, live FWA V2 and Intake settings, owner-selected conversion bounds, keeper coverage of NFT settlement deadlines, donated IMD funding and receiver adapter operations. No protocol whitelist or receiver/hub configuration is changed by this project.

Primary technical references: [Uniswap v4 core](https://github.com/Uniswap/v4-core), [EIP-7702](https://eips.ethereum.org/EIPS/eip-7702), [IdentityMD protocol documentation](https://imd.fun/docs/). Exact vendored revisions are in `dependencies.json`; canonical oracle implementations and FWA ABI definitions came from the assignment's pinned protocol references.
