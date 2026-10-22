# Mutually Assured Destruction (MAD)

Ethereum custom token and Uniswap v4 hook, paired with FWA. This project contains contracts, vendored dependencies, local integration tests and an optional mainnet fork rehearsal. It contains no website or launch manifest.

## Contracts and deployment

| Contract | Deployment | Constructor arguments |
| --- | --- | --- |
| `MadToken` | Launch factory deploys first | None |
| `MadHook` | Factory deploys at a mined CREATE2 address | `IPoolManager manager_ = $poolManager`, `IMadToken mad_ = $token`, `address owner_ = $owner`, `address factory_ = $factory` |
| `MadRewards` | Created by the hook's constructor | Supplied internally by the hook; find it through `hook.rewards()` |

The explicit owner is `0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774`. The receiver is immutable at `0x4E2B3F2D201666d29bf1CE7aA665C8fdF768b481`; neither the owner nor the factory can change it. The owner has no ownership-transfer, withdrawal, confiscation, mint, fee-setting or results-setting function.

`MadToken()` mints exactly **1,000,000,000 × 10^18 MAD** to its deploying factory. There is no subsequent mint. Preserve the launch's 10% distributor / 90% pool allocation and remainder handling; these contracts allocate no launch tokens to themselves. Preserve pool fee **12500**, tick spacing **60**, FWA pairing and the launch's price/remainder policy. The manifest's initial-price field is `79228162514264337593543950336`; the launch deployer derives the actual opening price from the policy's 2,000,000 FWA opening market cap and currency ordering. The hook accepts the initializer's price without overriding it.

Mine hook address bits **`0x20cc`**, masked by **`0x3fff`**. Enabled permissions are `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta` and `afterSwapReturnDelta`. The initialization callback authenticates the factory and exact MAD/FWA pool; swap callbacks implement the specified- and unspecified-currency fee cases. Liquidity callbacks are disabled, so initial liquidity, removals and the factory's zero-liquidity fee collection remain available while trading is closed. There is no LP-fee override.

Deploy token, deploy hook and initialize the pool **in one factory transaction**. Binding consumes a transient capability created by the token constructor. The hook checks the PoolManager, initializer, token's deploying factory and pool key, and exposes its binding context only around `token.bindHook()`. The trusted factory must not hand execution to arbitrary code between these steps. All constructor interactions are internal computation or creation of the fixed rewards helper; none call external protocol addresses. This design needs Cancun/EIP-1153, available on the launch chain.

The atomic boundary is part of binding authentication: checking only a hook's self-reported factory or owner would let an impostor bind. Deployment in a separate transaction deliberately cannot bind later, including within the same block. `test/mocks/AtomicLaunch.sol` is a test harness for this sequence, not a production factory replacement. No transaction is broadcast by this project.

**Verifier integration:** the supplied generic `Hook.protected.t.sol` constructs a token probe in `setUp()` and initializes in a subsequent test transaction; it also constructs that probe from the harness rather than the factory probe. That arrangement does not reproduce this assignment's atomic factory launch and cannot exercise its authenticated binding successfully. The delivered atomic-launch tests cover the required sequence, including a real mined CREATE2 deployment. The verifier must exercise this sequence rather than treating a separately deployed probe as an atomic launch. The production authentication has not been relaxed to accommodate that generic fixture.

## Freezing and rounds

Any holder, including a contract or an already frozen wallet, can call `freeze(target)`. The target must be another nonzero wallet with no code or exactly the 23-byte EIP-7702 `0xef0100 || address` designation. Ordinary contracts cannot be targeted.

The cost is `floor(balanceOf(target) / 100)` in MAD base units and must be positive. The caller burns `floor(cost / 2)` and pays the remainder to the target. The target's deadline becomes `block.timestamp + 24 hours`; another freeze resets that deadline. There is no transfer tax. Frozen wallets can receive, approve and pay freeze costs, but every ordinary debit through `transfer` or `transferFrom` fails until the deadline. This applies to any pool, router or liquidity deposit. Only the two internal freeze debits bypass the check. The check reads only the deadline, not the sender's current code: a wallet frozen while it had no code (for example a counterfactual CREATE2 account that already held MAD) stays frozen for the rest of the window even if its code is deployed meanwhile. Contracts can never be targeted, so no contract is ever given a deadline.

`spent(round, account)` records the full cost. A strictly greater total changes `leader(round)`, preserving the first account to reach a tied total. Round 1 starts at deployment's block. Public `hook.closeRound()` requires a current leader, an unassigned kept NFT, a round at least `MIN_ROUND_BLOCKS` (7,200 blocks, about one day) long when it ends, and a leader whose round spend is at least `MIN_LEADER_SPEND` (1,000 MAD). Without those floors a 1-wei freeze of a dust wallet bundled with `closeRound()` in a round's first block would capture each kept NFT. It closes the token round at the current block and assigns the oldest kept NFT by **successful keep order**. Freezes after closure in that block revert. The next window starts at `last + 1`, so block windows never overlap. Only the bound hook can close the token's rounds.

## Swap fees and accounting

Swaps in the launch pool start closed for everyone. Only the owner can call `enableTrading()`, once. There is no close switch.

Let `e = min(now - openedAt, 1800)`, `D = 10_000 × 1800` and `R = 9900 × 1800 - 9800 × e`. The rational rate `R / D` is 99% at opening, 50% at 15 minutes and 1% at 30 minutes and thereafter. Division is deferred until the amount calculation, avoiding basis-point stair steps.

| Swap | FWA fee base and rounding |
| --- | --- |
| Exact-input FWA → MAD | Specified gross FWA input `B`; fee `floor(B × R / D)` is deducted before the AMM swap. |
| Exact-output FWA → MAD | Actual **net** FWA input the AMM consumed is `N`. Fee is `ceil(N × R / (D - R))`; the trader pays `B = N + fee`, so `fee / B` is the schedule exactly as on the other routes. |
| Exact-input MAD → FWA | Actual gross FWA output from the AMM is `B`; `floor(B × R / D)` is deducted from output. |
| Exact-output MAD → FWA | Specified **net** FWA output is `N`. Fee is `ceil(N × R / (D - R))`; the AMM is asked for `B = N + fee`. |

Each callback charges at most once per swap. For FWA-specified swaps, a main-pool partial fill reverts atomically: v4 cannot return a correcting specified-currency delta in `afterSwap`. Unspecified-side fees use actual executed amounts. Routers should quote these conventions, respect input/output limits and allow for the pool's separate 1.25% LP fee. Every mode charges the same share of the gross FWA the trader faces: an exact-output buy of the MAD that an exact-input buy returned costs the same gross FWA, within rounding.

For every FWA base `B`, Playground and the NFT budget each receive `floor(B / 200)` FWA. They are percentages of **the fee base**, not percentages of the collected fee. The remainder of the collected fee is taken PoolManager → hook and burned with `FWA.burn(exactAmount)` during the swap when the PoolManager already holds that much FWA. A post-settling router (the Universal Router, the test router) pays the swapper's input only after the callbacks, so a burn larger than the manager's existing FWA reserves cannot be funded yet: that burn is minted as a separate hook claim (`burnClaims`, event `BurnDeferred`) and anyone calls `flushBurn()` to burn it later. It is never paid out or counted as revenue. Indivisible rounding dust also goes to the burn: at rest this can be one FWA base unit for floor-fee swaps, or up to two for the ceiling gross-up. There is no MAD protocol cut or other fee recipient.

Separate counters track Playground FWA claims, unsold NFT FWA claims and NFT ETH claims. Public `payout()` burns only Playground's ERC-6909 claims and uses `PoolManager.take(FWA, receiver, amount)` directly. It makes no restricted hook → receiver FWA transfer, ETH conversion, hub distribution or receiver adapter call. A second payout cannot spend the NFT budget. The existing receiver and its authorized adapters/hub handle subsequent conversion and distribution; this project deploys none and changes no whitelist. The launch factory's separate FWA fee distribution may require FWA's operator to authorize that factory as a distributor; this hook's direct PoolManager payout does not require that setup.

Only the NFT share is sold for ETH, through an exact-input swap inside the current PoolManager unlock. The initial conversion key is:

`(native ETH, FWA 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845, fee 0, tickSpacing 60, hook 0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444)`.

That market's own hook fee applies. Conversion burns only the number of NFT FWA claims actually sold. A price-bound partial sale leaves the unsold claims for the next launch-pool swap. The sale is decided **before** it is made and the outcome never fails the trader's swap: it is skipped when the claims are below `MIN_CONVERSION` (10^12 FWA base units), when the market is uninitialised or already at or above the bound, or when the in-range liquidity would absorb less than `MIN_CONVERSION` FWA before reaching the bound (a price parked one unit under the bound by any FWA seller, or an empty range). The bound itself caps the execution price, so `setConversionBounds` requires the minimum ETH-per-FWA to be at most the price at the bound (`ethPerFwaX128(limit)`); the market's own hook fee and rounding come off on top of it. Unsold FWA is never valued as ETH in `nftBudget()`.

Before conversion bounds are configured, swaps and Playground payout work and NFT FWA claims accumulate. An uninitialized market, a market already at/beyond the sell limit or one with no room under it also retains those claims. Nothing about the conversion can make a MAD swap revert. Configure and maintain the bound above the market before expecting NFT purchases to be funded; a bound left under the market simply retains claims.

Actual native proceeds go directly PoolManager → rewards when the manager has enough ETH. Otherwise they become separate ETH claims owned by the hook. Public `flushNftETH()` redeems them only to rewards. `buy()` can redeem just its shortfall. A redemption still requires actual ETH in the manager and can be retried when funded. Same-swap FWA burning likewise needs the manager's existing FWA reserves; otherwise the burn waits as a claim for `flushBurn()`. The official FWA market's own fee-transfer behavior remains an external dependency.

## NFTs, oracle and awards

Anyone may call these hook convenience methods, or the corresponding rewards methods:

1. `buy()` checks the live blackout and `(fee, vrf, total)` quote, then spends NFT-budget ETH on `acquire(address(rewards), 1, fee + acquisitionFeeMargin, 0, acquisitionSlippageBps)`. Immediate overpayment refunds remain in the budget. No builder or requester fee is added.
2. After FWA V2 fulfills, `claim(requestId)` checks purchaser, status and the **live** settlement window, then calls `keepNFT`. A public keeper must claim before `allocatedAt + settlementWindow()`. The pool address recorded at purchase remains authoritative after a V2 setting change. `withdrawAcquisitionRefund(pool)` retrieves credits from any recorded source pool into the NFT budget; VRF fees are not promised back.
3. `hook.closeRound()` assigns the oldest unassigned kept NFT and closes the current block window once the round is at least `MIN_ROUND_BLOCKS` long and its leader has spent at least `MIN_LEADER_SPEND`. No NFT, no freeze leader, a short round or a dust leader means no closure. A queue entry is assigned once. A physical NFT resold by a winner can be acquired as a new purchase in a future round.
4. After eight blocks, `askWinner(round)` pays **the live `Intake.priceOf`**, using donated IMD held by rewards. It requests Intake v2 success and failure callbacks. No FWA or NFT ETH budget pays for the oracle. A live ask blocks duplicates for six hours; a reported failure permits immediate retry. Each retry consumes another oracle fee, and superseded request IDs are rejected. After 72 hours, no new ask is made.
5. The callback validates its recorded Intake, pending request, question hash, chain, block window, panel and quorum, validity window, signer and EIP-712 consumer domain. It consumes the signed oracle UUID once and stores one nonzero address. It transfers nothing. Failed callbacks are not assumed to be replayed by Intake.
6. Public `award(round)` sends the NFT to a stored winner, or, if no answer arrived before the 72-hour deadline, to `token.leader(round)`. The first award attempt fixes the beneficiary. Rejected transfers return `false`, retain custody and can be retried. Success is final. Late oracle responses cannot change a fallback or a failed delivery's beneficiary.

The question is built on chain with the supplied canonical `OracleQuestion` library and a lowercase token address. It uses Ethereum chain ID 1, the absolute inclusive block window, `address[]`, head 1, chain evidence, panel 30, quorum 20 and validity 3600 seconds. The exact text is in `MadRewards.question(round)`, and `questionBody(round)` exposes both the submitted JSON and pinned hash. Evidence `chain` is the protocol's default, omitted from its canonical hash document and made explicit in the submitted body. The winner criterion and question cannot be changed by the owner.

The signed domain is **IdentityMD Oracle / version 2 / current chain / rewards contract address**, never the Intake or hook address. Intake's callback request ID and the signed UUID are different identifiers. The supplied digest/signature and question-hash vectors are tested independently of locally generated signatures.

## After launch

| Caller / contract | Action | Value or responsibility |
| --- | --- | --- |
| Owner / hook | `setConversionBounds(limit, minimumEthPerFwaX128)` | Set an acceptable upper sqrt-price for FWA→ETH and a positive minimum ETH/FWA price, encoded as `floor(ETH base units per FWA base unit × 2^128)`, at most `ethPerFwaX128(limit)`. Obtain limits from a reviewed official-pool quote and the owner's slippage policy; no guessed live price is installed. Any FWA holder can park the market just under the bound, which only defers conversion; move the bound to resume. |
| Owner / hook | `enableTrading()` | Irreversible opening; starts the 1,800-second decay. Initialization and liquidity already work. |
| Owner / hook | `setEthFwaPool(key)` | Only for a verified successor ETH/FWA market. Checks currency order and rejects this hook. Resets conversion bounds, which must then be set again. |
| Owner / rewards | `setFwaV2(pool)` | Default `0x958C41181182e76F221331b2755b77D9e1426A98`; change only to a verified compatible V2 successor. Outstanding requests retain their original source. |
| Owner / rewards | `setAcquisitionBounds(feeMargin, slippageBps)` | Default fee margin 0 (the live quoted fee is still a nonzero cap); default negative selection slippage 100 bps. Slippage must be at most 10,000 bps. |
| Owner / rewards | `setOracleSettings(intake, action, asset, maxPrice, signer)` | Defaults below. Zero `maxPrice` means no additional ceiling over the live quote; a positive ceiling can limit donated-IMD spending per ask. Asset must be an ERC-20. Signer changes invalidate answers to pending asks signed under the old setting; retry after timeout. Intake changes do not redirect already pending callbacks. |
| Donors | Transfer IMD to `hook.rewards()` | Voluntary oracle funding; no withdrawal or refund entitlement. Native ETH donations to rewards also join the NFT budget. |
| Public keepers | Payout, flushBurn, flushNftETH, buy, claim, refunds, close, ask, retry, award | Monitor FWA blackout, pending VRF fulfillment, settlement deadlines, Intake failures and transfer retries. The contracts do not schedule themselves. |

Default oracle configuration:

- Intake v2: `0xa43e6F75ee006411F79Ac1C84120606C2330DE82`.
- IMD: `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`.
- Signer: `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982`.
- Action: right-zero-padded `bytes32("oracle.request@oracle-1")`, **not** a keccak hash.

A valid signed answer is trusted to identify the winner. The owner can rotate protocol addresses and the signer, so those settings remain a trust boundary: an owner who points `setFwaV2` at a hostile contract can drain the NFT ETH budget through `buy()`, and one who sets a hostile Intake and signer can name any winner. The brief grants these setters; use a reviewed multisig and only verified successor addresses. There is no fallback based on miner randomness: after oracle unavailability, the token's deterministic event-accounting leader is used. A winner that permanently rejects ERC-721 receipt can prevent delivery of its assigned NFT; there is intentionally no owner redirect.

## Build and checks

```sh
forge build
FOUNDRY_FUZZ_SEED=0x7b449c27e8d50466ace5b9f57d7bf19b1d42679e5c0f653bb6cc6a4488b06a52 forge test
forge fmt --check
```

The root configuration pins Solidity **0.8.26**, Cancun, optimizer 200, via-IR and `bytecode_hash = "none"`. Dependencies are ordinary files under `lib/`, with exact revisions in [docs/dependencies.json](docs/dependencies.json). Building needs no network, submodule, package installation, compiler binary in this repository, FFI or filesystem permission grant.

`MainnetForkTest` runs only when `MAINNET_RPC_URL` is supplied. Its mainnet protocol code is neither mocked nor etched; it buys real FWA, creates the launch pool atomically, tests all four swap modes during decay and at rest, checks the burn and official-market NFT conversion, pays the receiver and tests a frozen seller. With no URL it reports a skip. Local mocks do not prove mainnet integration. See [docs/verification.md](docs/verification.md) for the checks actually performed and remaining release checks.
