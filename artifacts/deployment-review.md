# Deployment reconciliation

## Inputs and lineage

The reviewed continuation is the existing Ethereum MAD launch, source commit `09a61c7f3023f920655bbabe7a3855c2e6a7598a`, parent job `75a9e0a5-b2dd-48c0-9aa1-2bb05916cf92`. The complete original objective and project versions were read from the parent’s public job record at [the IdentityMD API](https://api.imd.fun/jobs/75a9e0a5-b2dd-48c0-9aa1-2bb05916cf92), in addition to the pinned project/deployment/network inputs, contract source, interfaces, generated ABIs and tests. The parent has no earlier parent. Its only continuation in that record is this website assignment. No unrelated project or network was integrated.

The original “No website” request is historical. This delivery adds a website only and changes no contract source, deployment, token supply policy, launch allocation, pool/remainder setting or fee destination.

## Addresses and verification

| Role | Ethereum address | Evidence |
| --- | --- | --- |
| MAD token | `0x1e1878c58c2da2645eb494e152fa708067e18c5e` | Pinned deployment, matching canonical ABI and creation code hashes, matching source runtime |
| MAD hook | `0x2aa2eb22ac48e745e93fecbd42e2b76111cea0cc` | Same checks; token binding, PoolManager and pool ID read onchain |
| MAD Rewards | `0x687ce94fC20FD08d464A0d006AD187D81efDC8C3` | Discovered through `hook.rewards()`; runtime matches compiled helper with immutable slots masked; `hook()` and `mad()` match |
| FWA | `0xa0df17b5ac76ababa36e1450e2cbcd18a620c845` | Pinned paired currency; code and 18 decimals verified |
| Revenue receiver | `0x4e2b3f2d201666d29bf1ce7aa665c8fdf768b481` | Hook immutable receiver; registered Playground project 1 receiver; parent job `paidBy` |
| Playground hub | `0xdd4a83daf532778c55f8806c9adf9a0f0ebb62de` | Receiver `playground()` and hub `projects(1)` |

The public RPC source is `https://ethereum-rpc.publicnode.com`, with `https://eth.drpc.org` as the site fallback. Verification was recorded at block **26,249,971**, timestamp **1792693955** (2026-10-22 18:32:35 UTC). The site performs its own live verification rather than treating this recorded state as a current balance.

`web/src/deployment.json` retains the permitted public addresses and runtime hashes. `artifacts/source-verification.json` records canonical ABI Keccak hashes, creation-code matches and source/runtime comparisons. The token and hook match both manifest ABI hashes. The helper has no separate manifest ABI hash; it is identified through the verified hook and its matching compiled runtime. Runtime comparisons mask only compiler-reported immutable slots; live relationship getters separately validate their important bindings.

## Route and availability

The verified pool is MAD/FWA with fee `12500`, tick spacing `60`, and the MAD hook. Its derived pool ID and live hook `poolId()` agree:

`0x7db264fee40a18a2ced348fd1a43f89ab600c3b94c5ef2de99588cc67cbedfb2`

Its live initialized price is read from StateView. The original 1:1 initial-price field is not used as a market quote. The verified pool currently has **zero active liquidity** and the hook’s `tradingEnabled()` is **false**. The site therefore disables quotes and swaps with those reasons. The quoter simulation also refused the unavailable route. No actual successful live swap is claimed.

Universal Router, Permit2, StateView and Quoter addresses come from the pinned network facts; their live code is hashed. Their ABIs were checked against Sourcify’s matched Ethereum records, including the [deployed Universal Router source](https://sourcify.dev/server/v2/contract/1/0x66a9893cc07d91d95644aedd05d03f95e1dba8af?fields=abi,metadata,sources). The deployed router’s exact-input-single tuple has five fields, without the extra field in newer upstream source. The site uses that deployed encoding: Universal Router command `0x10`, v4 actions `0x06`, `0x0c`, `0x0f`, exact input settlement and nonzero minimum output. Each exact allowance has a distinct review and wallet confirmation. Native ETH trading is not inferred from the separate internal NFT conversion pool.

## Historical wording versus deployed behavior

The site follows the actual deployed implementation where it adds details to the original brief:

- Round closure enforces a minimum 7,200-block window and 1,000 MAD leader spend, as well as a leader and kept NFT. These limits are explained next to closure and in the rules.
- A burn can be deferred as separate burn-only claims when PoolManager lacks the FWA needed in the callback. Public flushing is available; neither Playground nor the NFT budget can spend those claims.
- The configured minimum ETH/FWA value is checked against the conversion price bound, not guaranteed net ETH proceeds after the external market’s fee. The owner review states that distinction.
- A freeze has no maximum-cost argument. Target balance changes before execution can change the caller’s payment. The review exposes this limitation.
- NFT purchases and oracle asks obtain live prices during execution. Reviews identify whose existing budget pays and whether an additional oracle cap exists.

## Permissions, custody and revenue

Both live owner getters return `0xFc3C962FAD2C1cC77f1a0d46e7B8a2De79A21774`. Management visibility uses these getters, not the project creator, receiver, factory or Playground owner. Supported settings are the irreversible trading enable, internal conversion pool/bounds, FWA V2 pool, acquisition bounds and oracle settings. There is no mint, confiscation, withdrawal, recipient change or ownership-transfer control.

NFT custody stays with Rewards until a successful award. Oracle callbacks store an answer without transferring the NFT. Failed NFT delivery retains custody and fixes the beneficiary for retry. The site checks verified Rewards `AwardAttempt` logs before describing delivery success.

The project’s public payout redeems only Playground FWA claims directly from PoolManager to the immutable receiver. It does not convert FWA, deposit ETH or pay the caller. Receiver-held FWA/ETH is labeled as held funds, not personal claimability. The existing receiver and hub handle adapters, authorized conversion, deposits, rounding, membership and claims; the site does not duplicate those economics. No new payment or revenue-conversion interface was added.

The manifest lacks a verified distributor ABI and allocation proofs. The website explicitly marks launch-allocation claims unavailable instead of inventing a claim integration.

## Evidence limits

All chain writes in the live preflight were `eth_call` simulations. Successful browser writes and receipts were isolated fixtures with an RPC read allowlist. No real transaction, paid oracle request, FWA V2 acquisition, external NFT fulfillment or revenue conversion was broadcast. The live launch’s closed/empty state prevents meaningful funded swap and NFT settlement rehearsals; those limitations remain visible in the interface and validation record.
