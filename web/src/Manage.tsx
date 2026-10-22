import { useEffect, useState } from "react";
import { useAccount } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import {
  keccak256,
  encodeAbiParameters,
  parseAbiParameters,
  isHex,
  type Address,
  type Hex,
} from "viem";
import {
  ADDR,
  client,
  hook,
  reward,
  read,
  same,
  zeroAddress,
  type Snapshot,
} from "./chain";
import { hookAbi, rewardsAbi, stateAbi, fwaV2Abi, intakeAbi } from "./abis";
import { integer, validAddress, message } from "./format";
import { PageTitle, Notice, AddressLink } from "./components";
import { useTransaction, type Plan } from "./transactions";
export async function settings() {
  const [
    pool,
    limit,
    minimum,
    fwaV2,
    margin,
    slippage,
    intake,
    action,
    asset,
    cap,
    signer,
  ] = await Promise.all([
    hook<readonly [Address, Address, number, number, Address]>("ethFwaPool"),
    hook<bigint>("sqrtPriceLimitX96"),
    hook<bigint>("minEthPerFwaX128"),
    reward<Address>("fwaV2"),
    reward<bigint>("acquisitionFeeMargin"),
    reward<bigint>("acquisitionSlippageBps"),
    reward<Address>("intake"),
    reward<Hex>("oracleAction"),
    reward<Address>("oracleAsset"),
    reward<bigint>("maxOraclePrice"),
    reward<Address>("oracleSigner"),
  ]);
  return {
    pool,
    limit,
    minimum,
    fwaV2,
    margin,
    slippage,
    intake,
    action,
    asset,
    cap,
    signer,
  };
}
type Settings = Awaited<ReturnType<typeof settings>>;
type Action =
  | "enableTrading"
  | "setConversionBounds"
  | "setEthFwaPool"
  | "setFwaV2"
  | "setAcquisitionBounds"
  | "setOracleSettings";
const labels: Record<Action, string> = {
  enableTrading: "Open trading permanently",
  setConversionBounds: "Set NFT conversion bounds",
  setEthFwaPool: "Set ETH/FWA conversion pool",
  setFwaV2: "Set FWA V2 acquisition pool",
  setAcquisitionBounds: "Set acquisition bounds",
  setOracleSettings: "Set oracle configuration",
};
const fields: Record<Action, readonly [string, string, string][]> = {
  enableTrading: [],
  setConversionBounds: [
    ["limit", "Sqrt price limit X96", "uint160 · upper execution bound"],
    [
      "minimum",
      "Minimum ETH per FWA X128",
      "uint256 · ETH base units per FWA base unit × 2^128",
    ],
  ],
  setEthFwaPool: [
    ["fee", "Pool LP fee", "Integer in millionths; 12500 means 1.25%"],
    ["spacing", "Tick spacing", "Positive int24"],
    [
      "poolHook",
      "Pool hook address",
      "A verified compatible ETH/FWA successor hook",
    ],
  ],
  setFwaV2: [
    ["fwaV2", "FWA V2 pool address", "A verified compatible acquisition pool"],
  ],
  setAcquisitionBounds: [
    [
      "margin",
      "Acquisition fee margin",
      "ETH base units (wei) added to the live fee cap",
    ],
    [
      "slippage",
      "Maximum negative selection slippage",
      "Basis points, 0 to 10000",
    ],
  ],
  setOracleSettings: [
    ["intake", "Intake address", "A verified compatible Intake v2 contract"],
    [
      "action",
      "Oracle action",
      "Exactly 32 bytes, 0x-prefixed; not an action-name hash",
    ],
    [
      "asset",
      "Oracle ERC20 asset",
      "The token held by Rewards that pays oracle asks",
    ],
    [
      "cap",
      "Maximum oracle price",
      "Token base units; zero means no additional price cap",
    ],
    ["signer", "Oracle signer", "Nonzero address that attests oracle answers"],
  ],
};
function values(s: Settings): Record<string, string> {
  return {
    limit: String(s.limit),
    minimum: String(s.minimum),
    fee: String(s.pool[2]),
    spacing: String(s.pool[3]),
    poolHook: s.pool[4],
    fwaV2: s.fwaV2,
    margin: String(s.margin),
    slippage: String(s.slippage),
    intake: s.intake,
    action: s.action,
    asset: s.asset,
    cap: String(s.cap),
    signer: s.signer,
  };
}
async function contractAddress(value: string, label: string) {
  if (!validAddress(value))
    throw new Error(`Enter a nonzero ${label} address.`);
  const code = await client.getCode({ address: value as Address });
  if (!code || code === "0x")
    throw new Error(`${label} has no deployed code on Ethereum.`);
  return value as Address;
}
export function Manage({
  state,
  refreshKey,
}: {
  state?: Snapshot;
  refreshKey: number;
}) {
  const { address, chainId } = useAccount();
  const { start, busy } = useTransaction();
  const s = useQuery({
    queryKey: ["settings", refreshKey],
    queryFn: settings,
    refetchInterval: 30000,
    retry: 1,
  });
  const [action, setAction] = useState<Action>("enableTrading");
  const [form, setForm] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const authorized =
    !!address &&
    !!state &&
    (same(address, state.owner) || same(address, state.rewardOwner));
  useEffect(() => {
    if (s.data) setForm(values(s.data));
  }, [s.data]);
  async function review() {
    setError("");
    start(labels[action], async (account) => {
      const current = await settings();
      const role = [
        "setFwaV2",
        "setAcquisitionBounds",
        "setOracleSettings",
      ].includes(action)
        ? "rewards"
        : "hook";
      const owner =
        role === "hook"
          ? await hook<Address>("owner")
          : await reward<Address>("owner");
      if (!same(owner, account))
        throw new Error(
          "This wallet is not the current owner of this contract.",
        );
      const plan: Plan = {
        address: role === "hook" ? ADDR.hook : ADDR.rewards,
        abi: role === "hook" ? hookAbi : rewardsAbi,
        functionName: action,
        role,
        notes: {},
      };
      if (action === "enableTrading") {
        if (await hook<boolean>("tradingEnabled"))
          throw new Error("Trading is already enabled and cannot be closed.");
        plan.notes = {
          Effect:
            "Permanently opens MAD trading for everyone. It starts a 99% FWA hook fee decaying to 1% over 30 minutes. There is no function to close trading again.",
        };
      }
      if (action === "setConversionBounds") {
        const limit = integer(
          form.limit,
          "sqrt price limit",
          (1n << 160n) - 1n,
        );
        const min = integer(form.minimum, "minimum ETH/FWA price");
        const max = await hook<bigint>("ethPerFwaX128", [limit]);
        if (min === 0n || min > max)
          throw new Error(
            "The minimum must be positive and at most ethPerFwaX128(limit).",
          );
        plan.args = [limit, min];
        plan.notes = {
          "Current sqrt limit": String(current.limit),
          "New sqrt limit": String(limit),
          "Current minimum X128": String(current.minimum),
          "New minimum X128": String(min),
          Effect:
            "Authorizes NFT-budget FWA conversion within the bound. This minimum is checked against the bound’s price; it is not a guaranteed net ETH output after the external hook’s fees.",
        };
      }
      if (action === "setEthFwaPool") {
        const fee = integer(form.fee, "pool fee", 1000000n);
        const spacing = integer(form.spacing, "tick spacing", 8388607n);
        if (spacing === 0n) throw new Error("Tick spacing must be positive.");
        const poolHook = await contractAddress(form.poolHook, "pool hook");
        if (same(poolHook, ADDR.hook))
          throw new Error("The conversion pool cannot use the MAD hook.");
        const key = {
          currency0: zeroAddress,
          currency1: ADDR.fwa,
          fee: Number(fee),
          tickSpacing: Number(spacing),
          hooks: poolHook,
        };
        const id = keccak256(
          encodeAbiParameters(
            parseAbiParameters("address,address,uint24,int24,address"),
            Object.values(key) as [Address, Address, number, number, Address],
          ),
        );
        const slot = await read<readonly [bigint, number, number, number]>(
          ADDR.stateView,
          stateAbi,
          "getSlot0",
          [id],
        );
        if (!slot[0])
          throw new Error(
            "This ETH/FWA pool is not initialized. Verify its pool key.",
          );
        plan.args = [key];
        plan.notes = {
          "Current pool hook": current.pool[4],
          "New pool hook": poolHook,
          Currencies: `Native ETH / ${ADDR.fwa}`,
          Fee: String(fee),
          "Tick spacing": String(spacing),
          Effect:
            "Changes only the internal NFT funding conversion pool. Both conversion bounds reset to zero and must be configured again. Verify the successor and its hook fees independently.",
        };
      }
      if (action === "setFwaV2") {
        const pool = await contractAddress(form.fwaV2, "FWA V2 pool");
        await Promise.all([
          read(pool, fwaV2Abi, "quoteAcquisitionPrice"),
          read(pool, fwaV2Abi, "isPurchaseBlackout"),
        ]);
        plan.args = [pool];
        plan.notes = {
          "Current FWA V2": current.fwaV2,
          "New FWA V2": pool,
          Effect:
            "Future NFT purchases use this pool. Outstanding requests retain their recorded source pool. A hostile pool can drain the NFT ETH budget; interface reads do not establish trust.",
        };
      }
      if (action === "setAcquisitionBounds") {
        const margin = integer(form.margin, "fee margin");
        const slippage = integer(form.slippage, "selection slippage", 10000n);
        plan.args = [margin, slippage];
        plan.notes = {
          "Current margin (wei)": String(current.margin),
          "New margin (wei)": String(margin),
          "Current slippage (bps)": String(current.slippage),
          "New slippage (bps)": String(slippage),
          Effect:
            "Sets the added acquisition fee cap and maximum negative NFT selection slippage. Future buy calls use the live quote plus this fee margin.",
        };
      }
      if (action === "setOracleSettings") {
        const intake = await contractAddress(form.intake, "Intake");
        const asset = await contractAddress(form.asset, "oracle ERC20 asset");
        if (!validAddress(form.signer))
          throw new Error("Enter a nonzero oracle signer address.");
        if (
          !isHex(form.action) ||
          form.action.length !== 66 ||
          /^0x0+$/.test(form.action)
        )
          throw new Error(
            "Enter a nonzero action encoded as exactly 32 bytes.",
          );
        const cap = integer(form.cap, "maximum oracle price");
        await read(intake, intakeAbi, "priceOf", [form.action, asset]);
        plan.args = [intake, form.action, asset, cap, form.signer];
        plan.notes = {
          "Current Intake": current.intake,
          "New Intake": intake,
          "Current action": current.action,
          "New action": form.action,
          "Current asset": current.asset,
          "New asset": asset,
          "Current price cap": String(current.cap),
          "New price cap": String(cap),
          "Current signer": current.signer,
          "New signer": form.signer,
          Effect:
            "Changes future oracle funding and trusted answers. A signer change invalidates pending answers under the previous signer; retry after timeout. Intake changes do not redirect already pending callbacks. A hostile Intake and signer can determine winners.",
        };
      }
      return plan;
    });
  }
  return (
    <>
      <PageTitle title="Manage the live contracts.">
        Controls are available only to the owner read from Ethereum.
      </PageTitle>
      <section className="panel">
        <h2>Current authority</h2>
        <dl className="details">
          <div>
            <dt>Hook owner</dt>
            <dd>
              {state ? (
                <AddressLink address={state.owner} full />
              ) : (
                "Unavailable"
              )}
            </dd>
          </div>
          <div>
            <dt>Rewards owner</dt>
            <dd>
              {state ? (
                <AddressLink address={state.rewardOwner} full />
              ) : (
                "Unavailable"
              )}
            </dd>
          </div>
          <div>
            <dt>Trading</dt>
            <dd>
              {state
                ? state.enabled
                  ? "Open permanently"
                  : "Closed"
                : "Unavailable"}
            </dd>
          </div>
          <div>
            <dt>NFT conversion</dt>
            <dd>
              {state
                ? state.limit === 0n
                  ? "Bounds not configured"
                  : "Bounds configured"
                : "Unavailable"}
            </dd>
          </div>
        </dl>
        <p className="muted">
          The owner can open trading and update supported protocol settings. It
          cannot change fee rates, freeze rules, supply, revenue receiver or
          results, withdraw arbitrarily, or transfer ownership.
        </p>
        {!authorized && (
          <Notice>
            {!address
              ? "Connect the current owner wallet to access management."
              : !state
                ? "Owner permissions are unavailable. Refresh the live state."
                : "This connected wallet is not a contract owner. Management controls are unavailable."}{" "}
            The project creator and Playground owner do not receive
            administration by assumption.
          </Notice>
        )}
      </section>
      {authorized && (
        <section className="panel manage-form">
          <h2>Update a supported setting</h2>
          {chainId !== 1 && (
            <Notice>
              Switch your wallet to Ethereum before sending a change.
            </Notice>
          )}
          {s.isError ? (
            <Notice kind="error">
              Current settings unavailable. {message(s.error)}
              <button onClick={() => s.refetch()}>Retry settings</button>
            </Notice>
          ) : !s.data ? (
            <p>Reading current settings…</p>
          ) : (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                void review();
              }}
            >
              <label htmlFor="admin-action">Action</label>
              <select
                id="admin-action"
                value={action}
                onChange={(e) => {
                  setAction(e.target.value as Action);
                  setForm(values(s.data!));
                  setError("");
                }}
              >
                {Object.entries(labels)
                  .filter(([key]) =>
                    [
                      "setFwaV2",
                      "setAcquisitionBounds",
                      "setOracleSettings",
                    ].includes(key)
                      ? same(address!, state!.rewardOwner)
                      : same(address!, state!.owner),
                  )
                  .map(([key, label]) => (
                    <option value={key} key={key}>
                      {label}
                    </option>
                  ))}
              </select>
              {action === "enableTrading" ? (
                <Notice kind={state?.enabled ? "info" : "error"}>
                  {state?.enabled
                    ? "Trading is already open. It cannot be closed again."
                    : "Opening is irreversible. The fee starts at 99% and decays to 1% over 30 minutes. Check liquidity before proceeding."}
                </Notice>
              ) : (
                fields[action].map(([key, label, hint]) => (
                  <div className="form-field" key={key}>
                    <label htmlFor={`admin-${key}`}>{label}</label>
                    <input
                      id={`admin-${key}`}
                      value={form[key] || ""}
                      onChange={(e) =>
                        setForm({ ...form, [key]: e.target.value })
                      }
                      autoComplete="off"
                      spellCheck="false"
                    />
                    <p className="caption">
                      {hint}. Current:{" "}
                      <span className="wrap">{values(s.data!)[key]}</span>
                    </p>
                  </div>
                ))
              )}
              {error && <Notice kind="error">{error}</Notice>}
              <button
                className="primary"
                disabled={
                  busy ||
                  chainId !== 1 ||
                  (action === "enableTrading" && state?.enabled)
                }
              >
                Review change
              </button>
              <p className="caption">
                Every change is revalidated, simulated and presented for
                explicit wallet confirmation.
              </p>
            </form>
          )}
        </section>
      )}
      {s.data && (
        <section className="reading wide">
          <h2>Current protocol settings</h2>
          <dl className="details">
            <div>
              <dt>FWA V2</dt>
              <dd>
                <AddressLink address={s.data.fwaV2} full />
              </dd>
            </div>
            <div>
              <dt>NFT conversion hook</dt>
              <dd>
                <AddressLink address={s.data.pool[4]} full />
              </dd>
            </div>
            <div>
              <dt>Intake</dt>
              <dd>
                <AddressLink address={s.data.intake} full />
              </dd>
            </div>
            <div>
              <dt>Oracle asset</dt>
              <dd>
                <AddressLink address={s.data.asset} full />
              </dd>
            </div>
            <div>
              <dt>Oracle signer</dt>
              <dd>
                <AddressLink address={s.data.signer} full />
              </dd>
            </div>
            <div>
              <dt>Oracle price cap</dt>
              <dd>
                {s.data.cap === 0n
                  ? "No additional ceiling"
                  : `${s.data.cap} base units`}
              </dd>
            </div>
          </dl>
        </section>
      )}
    </>
  );
}
