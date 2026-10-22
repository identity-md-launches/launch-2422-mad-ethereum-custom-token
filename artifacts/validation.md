# Website validation

This is the worker’s own evidence record, not independent certification.

## Scope and completion

The delivered site covers freezing, the direct MAD/FWA trading route, NFT rounds and keepers, verified activity, project rules/revenue accounting and current-owner management. It retains the existing contracts and economics. Source and lockfile are under `web/`; the production static export is the root `dist/` with relative assets and hash navigation. No publishing or chain deployment was performed.

**Complete for the website scope.** Live actions remain subject to actual deployed conditions. At the recorded preflight trading was closed, active liquidity was zero, and reward funding/NFT custody were empty. The interface explains these states. External runtime and real-wallet limitations are listed below.

## Recorded checks

| Check | Result |
| --- | --- |
| Fresh `npm ci --prefix web` with a temporary npm cache | Passed; installed from the delivered lockfile |
| `npm run typecheck --prefix web` | Passed, no TypeScript errors |
| `npm run build --prefix web` | Passed; Vite production output in root `dist/` |
| Production export under `/preview/` | All local assets resolved; relative URLs and hash routes worked |
| `node web/tests/browser.mjs` with the assignment’s Ethereum read provider | 59 passed, zero failed; no real transaction broadcast |
| Route reflow at 320, 390, 768 and 1440 CSS pixels | Six routes checked at each width; no horizontal document overflow |
| Axe WCAG A/AA scans at 390 | Six route scans passed with zero reported violations |
| `node web/scripts/verify-deployment.mjs` | 34 live checks passed; chain, code, ABI hashes, bindings, decimals, receiver registration and permission simulations |
| `forge build --out test/scratch/forge-out --cache-path test/scratch/forge-cache` | Passed; existing contract compiler/lint warnings retained |
| Token tests, same scratch output/cache paths, `--match-path test/MadToken.t.sol` | 12 passed, zero failed |
| Hook/rewards tests, same scratch paths, `--match-contract 'MadHookTest\|MadRewardsTest'` | 32 passed, zero failed |
| Pinned taste probe on `dist/` | 16/16 passed after corrections |
| Uncaught application exceptions | None observed in the browser suite |
| Shared-link metadata | Title, favicon, description, og:title and local og:image present and resolved |

Build warnings were upstream Rollup annotation notices in dependency code, not application errors. The existing Solidity lint warnings were not edited in this website assignment. No contract source/build configuration or existing dependency tree was modified.

The pinned probe command was:

```sh
node .imd/reads/skills/design-critic/scripts/taste.mjs --out test/scratch/taste
```

Playwright was installed outside the Git deliverable, with its browser path/module supplied to the probe. The preserved result is `artifacts/design-probe.json`. The probe measured zero horizontal overflow, overlaps, clipped text or covered controls; all measured text met its contrast threshold; five or fewer sizes appeared at a reviewed width. It measured 37 first-screen prose words at 390 and 69 at 1440. Some text links/navigation targets are below its 44px comfort recommendation but meet the measured 24px-or-spacing criterion.

## Primary interaction evidence

The Chromium suite served the actual production export under `/preview/`. It checked the first-screen freeze action at 390×844, invalid-address focus, a real zero-cost target, contract-target rejection, dialog keyboard containment/Escape/focus return, navigation, all six route layouts, live empty/closed states, acquisition request inspection, event filtering and disconnected permissions.

Isolated EIP-6963 providers tested two named extension rows, generic-row suppression, recoverable connect rejection, a wrong-network wallet, network switching, owner-only controls, account changes during review and rejected wallet transactions. Fixture flows checked exact freeze payment/burn/target review, one send despite repeated activation, confirmed balance/spend refresh, required slippage/deadline selection, exact ERC20 approval, expiring Permit2 permission, nonzero swap output protection and quote invalidation after confirmation. Advancing the browser clock tested the 30-second expiry without waiting in real time.

A held receipt tested pending-state write blocking, minimizing tracking, reload recovery from session storage and eventual refresh without a duplicate send. A substituted confirmed calldata fixture was refused as the reviewed action. Four mobile wallet-browser links and Coinbase Smart Wallet were present in an emulated iPhone browser. An intentional RPC failure produced “unavailable” state, never a fabricated zero position.

Fixture calls cannot be forwarded as real transactions: the validation RPC handler permits read methods only. Fixture balances, liquidity, quotes and receipts are contained in `web/tests/browser.mjs`; none is part of the application. Live checks used actual deployed code and read calls. On the assignment’s provider, event reads needed 10-block chunks; the test forwarding helper fetched and combined real logs within that limit. The production activity view was also observed against its public provider through the supplied browser tool, showing the real HookBound deployment transaction.

## Better Interface coverage

The pinned workflow and the core principles of all six domains were read and applied during implementation. Review covered source, the rendered export, keyboard interaction and the pinned probe.

| Domain | Coverage | Evidence and limits |
| --- | --- | --- |
| Accessibility | Checked | Native forms, labels, landmarks, button names, focus styling, native modal containment and return, live errors, disabled explanations; keyboard interaction and six automated route scans. No screen-reader session or full compliance claim. |
| Layout | Checked | Tool-first mobile composition, shared alignment, adaptive columns, wrapping addresses and normal-flow pending banner; six routes at four widths plus first-screen screenshots. Native browser zoom and RTL were not tested. English is the implemented language. |
| Writing | Checked | Plain task headings, verb-first controls, exact payment/custody distinctions, actionable loading/empty/error text, irreversible-action reviews and onchain limitations. No fabricated activity, balances, claims or NFT art. |
| Typography | Checked | Source scale/weights/measure, 16px inputs, tabular numbers, full review amounts and wrapping addresses; computed-size probe and real narrow layouts. System fallback fonts vary by device. |
| Colors | Checked | Semantic tokens, error/success text alongside color, rendered contrast probe and route scans. One light theme is implemented; dark-theme testing is not applicable. |
| UI | Checked | Rest/hover/pressed/disabled/focus, read loading/empty/failure, review/wallet/pending/confirmed/rejected states, bottom-sheet wallet layout and reduced-motion rules. No staged/endless animation exists to replay at slow speed. |

The supplied browser tool was also used on the export at 390×844: target inspection, wallet sheet/Escape, Trade, NFT rounds, Activity and disconnected Manage. Console inspection in that session reported zero errors and warnings. The automated Chromium suite subsequently covered all six routes and the corrected final source.

## Findings, corrections and rechecks

| Severity/domain | Source location | Finding and fix | Recheck |
| --- | --- | --- | --- |
| High / Accessibility | `web/src/components.tsx:88` | Dialog cleanup initially captured focus after opening, returning it to a hidden dialog control. Capture the trigger before `showModal()` and restore it on cleanup. | Browser keyboard/Escape/focus-return check passed. |
| High / Layout | `web/src/styles.css:758` | A 100%-wide, nonshrinking SVG plus fee labels overflowed Trade. Give the SVG flexible remaining width instead. | Trade passed 320/390/768/1440 reflow. |
| High / Layout/Typography | `web/src/styles.css:95` | Long receiver addresses in keeper prose escaped narrow layouts. Wrap long prose/data values without clipping or reducing type. | Protocol passed 320/390 reflow; exact addresses remain visible. |
| Medium / UI | `web/src/rewards.ts:10`, `web/src/rewards.ts:40` | NFT acquisition and oracle reads were coupled, allowing one unrelated external read to block the other action. Separate their queries, errors and preparation paths. | Source dataflow checked; both live read paths and the route scan passed. An isolated external-protocol outage was not executed. |
| High / UI/Safety | `web/src/transactions.tsx:221` | Tracking failure/reload needed to preserve the send lock and expected transaction, rather than allowing another write or treating changed calldata as the reviewed action. Persist expected to/data/value/account, retain unresolved state and inspect confirmed transactions. | Pending/reload/no-duplicate and substituted-calldata checks passed. A real network replacement or four-minute timeout was not performed. |
| Medium / UI | `web/src/wallet.tsx:56` | A rejected network switch could fall through into a chain-add prompt. Limit the add-chain fallback to error 4902; await disconnect completion. | Source rejection branch checked; wrong-network switching and disconnect tests passed. Real extension chain-add approval was not performed. |
| Medium / Data accuracy | `web/src/trading.ts:62` | Quote metadata/state needed one block and freshness measured from request start. Pin fee, pool state and quoter simulation to the same block; reject delayed/old quotes. | Fixture quotes, approvals, swap protection and clock-based expiry passed. Actual funded live quoting remains unavailable. |
| Medium / UI | `web/src/Freeze.tsx:247` | The freeze submit handler refused the wrong network but its review button remained enabled. Disable that review control for a connected wallet on another chain. | Wrong-network fixture now explicitly checks the disabled control before switching. |
| High / UI (revision) | `web/src/trading.ts:91`, `web/src/Trade.tsx:52`, `web/src/Trade.tsx:232` | Quotes and pre-write validation refused the pool whenever StateView in-range liquidity was 0. The live launch position is single-sided MAD at ticks [-62100, 887220] with the price at tick -62150: in-range liquidity is 0, but a buy crosses into it and fills. Removed the in-range liquidity gate (kept the uninitialized-pool check); the block-pinned Quoter simulation decides, and a Quoter revert reads "Not enough liquidity in the pool for this amount." | Live StateView read: slot0 tick -62150, `getLiquidity` 0, `getTickInfo(-62100)` liquidityNet 4.03e25. New fixture check quotes with zero in-range liquidity and maps a Quoter revert; closed-trading notice still disables quotes. |
| Low / Layout (revision) | `web/src/styles.css:733` | `.reading h3` used three-value `margin-block`, which is invalid, so the Trade aside heading had 0px top margin. Use `28px 12px`. | Rendered at 390: computed margin-top 28px, 28px gap above "Frozen wallets cannot sell." |
| Low / Writing (revision) | `web/src/Rounds.tsx:237`, `web/src/Protocol.tsx:93` | Block window printed ungrouped digits; current supply repeated itself as an exact sub-line. Group block numbers like the header; show the exact supply only when it differs from the rounded value. | Rendered against live reads: "26,248,829 to open"; supply metric shows one line. |
| Medium / Safety | `web/src/Rounds.tsx:365` | NFT delivery status must come from the verified Rewards contract, not an identically shaped foreign log. Check the emitting address before decoding the result. | Source guard checked; no live NFT award was available. |

The original mobile form already placed its primary action within the first screen; this was confirmed again after responsive corrections. The final screenshots are `artifacts/mobile.png` and `artifacts/desktop.png`. Full local test/probe screenshots and logs were written under `test/scratch/` and are intentionally excluded from submission.

## Remaining limitations

- WebKit was downloaded and launch was attempted, but required host shared libraries were missing. No WebKit interaction success is claimed.
- Real browser-extension signing, Coinbase passkey creation, wallet-app deep-link handoff, physical devices, screen readers and native 200% zoom were not exercised. Wallet flows used explicit isolated providers and emulated mobile browsing.
- No real financial transaction was sent. Live trading is closed and in-range liquidity is zero (the launch MAD sits 50 ticks above the price, reachable by a buy); a live Quoter fill cannot be shown until trading opens; NFT/oracle funding and custody were empty. Successful swaps/approvals, receipt recovery and refresh are fixture validation, not proof of funded live execution. Existing Solidity unit tests exercise contract behavior separately.
- No new live FWA V2 fulfillment, paid oracle response, external NFT delivery, receiver adapter conversion or hub claim was performed. Receiver-held assets are not represented as personal claimability.
- The verified manifest supplies no distributor ABI or allocation proofs. The site explicitly leaves those allocation claims unavailable.
- Public RPC availability, external protocol settings and permissionless keeper participation remain external dependencies. Exact freeze costs and acquisition/oracle prices can change before mining because the existing functions do not accept a caller-selected cap for those amounts.

Submission packaging was audited below the 8 MiB limit; see `artifacts/package-budget.json` for the final file/export byte counts. Generated dependency and browser-cache directories were moved out of the repository. The repository ignore file adds only a named evidence-file allowlist to override a local `artifacts/` exclusion. Its explicit per-file budgets total at most 512 KiB for `artifacts/`, with 4 KiB reserved for `.gitignore`; actual sizes and the allowlist are recorded in the package budget. No dependency or cache directory is allowed by that exception.

No known required website defect remains after the final local checks. See `artifacts/deployment-review.md` for contract reconciliation and `DESIGN.md` for the implemented design system.
