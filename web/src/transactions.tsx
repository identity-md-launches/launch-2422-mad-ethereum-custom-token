import {
  createContext,
  useContext,
  useEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { getAccount, getWalletClient } from "@wagmi/core";
import { useAccount } from "wagmi";
import {
  encodeFunctionData,
  type Address,
  type Abi,
  type Hex,
  type TransactionReceipt,
} from "viem";
import {
  client,
  config,
  verifyDeployment,
  hook,
  reward,
  same,
  chain,
} from "./chain";
import { message, json } from "./format";
import { Modal, Notice, AddressLink, TxLink } from "./components";
export interface Plan {
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
  notes: Record<string, string>;
  role?: "hook" | "rewards";
  value?: bigint;
  validate?: () => Promise<void>;
  receiptMessage?: (receipt: TransactionReceipt) => string;
}
export type BuildPlan = (account: Address) => Promise<Plan>;
interface TxState {
  title: string;
  stage: "simulating" | "review" | "wallet" | "pending" | "confirmed" | "error";
  plan?: Plan;
  hash?: Hex;
  error?: string;
  result?: string;
  replaced?: boolean;
}
interface ExpectedTransaction {
  to: Address;
  data: Hex;
  value: string;
  account: Address;
}
const savePending = (value: unknown) => {
  try {
    sessionStorage.setItem("mad-pending", json(value));
  } catch {
    /* Tracking continues in memory if storage is unavailable. */
  }
};
const clearPending = () => {
  try {
    sessionStorage.removeItem("mad-pending");
  } catch {
    /* Storage is optional. */
  }
};
const Context = createContext<{
  start: (title: string, build: BuildPlan) => void;
  busy: boolean;
}>({ start: () => {}, busy: false });
const fingerprint = (p: Plan) =>
  json({
    address: p.address,
    args: p.args,
    fn: p.functionName,
    notes: p.notes,
    value: p.value,
  });
export function Transactions({
  children,
  onSuccess,
}: {
  children: ReactNode;
  onSuccess: () => void;
}) {
  const [state, setState] = useState<TxState>();
  const [open, setOpen] = useState(true);
  const [unresolved, setUnresolved] = useState(false);
  const lock = useRef(false);
  const restored = useRef(false);
  const expectedRef = useRef<ExpectedTransaction | undefined>(undefined);
  const buildRef = useRef<BuildPlan | undefined>(undefined);
  const initial = useRef<Address | undefined>(undefined);
  const { address, chainId } = useAccount();
  useEffect(() => {
    if (
      state?.stage === "review" &&
      (!address ||
        !initial.current ||
        !same(address, initial.current) ||
        chainId !== 1)
    ) {
      setState((s) =>
        s
          ? {
              ...s,
              stage: "error",
              error: "Wallet or network changed. Review the action again.",
            }
          : s,
      );
      lock.current = false;
    }
  }, [address, chainId, state?.stage]);
  async function guard(plan?: Plan) {
    const a = getAccount(config);
    if (!a.address || a.chainId !== 1)
      throw new Error("Connect a wallet on Ethereum to continue.");
    if (initial.current && !same(a.address, initial.current))
      throw new Error("Wallet changed. Review the action again.");
    await verifyDeployment();
    if (plan?.role) {
      const owner =
        plan.role === "hook"
          ? await hook<Address>("owner")
          : await reward<Address>("owner");
      if (!same(a.address, owner))
        throw new Error("This wallet is not the current contract owner.");
    }
    await plan?.validate?.();
    return a.address;
  }
  async function simulate(plan: Plan, account: Address) {
    const data = encodeFunctionData({
      abi: plan.abi,
      functionName: plan.functionName,
      args: plan.args,
    });
    await client.simulateContract({
      account,
      address: plan.address,
      abi: plan.abi,
      functionName: plan.functionName,
      args: plan.args,
      value: plan.value || 0n,
    });
    return data;
  }
  async function start(title: string, build: BuildPlan) {
    if (lock.current) return;
    lock.current = true;
    setOpen(true);
    initial.current = undefined;
    buildRef.current = build;
    setState({ title, stage: "simulating" });
    try {
      const account = await guard();
      initial.current = account;
      const plan = await build(account);
      await guard(plan);
      await simulate(plan, account);
      setState({ title, stage: "review", plan });
    } catch (e) {
      lock.current = false;
      setState({ title, stage: "error", error: message(e) });
    }
  }
  async function confirm() {
    if (!state?.plan || state.stage !== "review" || !buildRef.current) return;
    const previous = state;
    setState({ ...state, stage: "wallet" });
    try {
      const account = await guard(previous.plan);
      const fresh = await buildRef.current(account);
      if (fingerprint(fresh) !== fingerprint(previous.plan!))
        throw new Error(
          "The amounts or contract state changed. Close this dialog, refresh and review again.",
        );
      await guard(fresh);
      const data = await simulate(fresh, account);
      const w = await getWalletClient(config, { chainId: 1 });
      const accounts = await w.getAddresses();
      if (
        !w.account ||
        !accounts.some((a) => same(a, account)) ||
        !same(w.account.address, account) ||
        (await w.getChainId()) !== 1
      )
        throw new Error("Wallet or network changed. Review the action again.");
      const hash = await w.sendTransaction({
        account,
        to: fresh.address,
        data,
        value: fresh.value || 0n,
        chain,
      });
      const expected = {
        to: fresh.address,
        data,
        value: String(fresh.value || 0n),
        account,
      };
      expectedRef.current = expected;
      setUnresolved(true);
      setState({ ...previous, stage: "pending", hash });
      savePending({ hash, title: previous.title, expected });
      await track(hash, previous.title, fresh, expected);
    } catch (e) {
      lock.current = false;
      setState((s) => ({
        ...previous,
        hash: s?.hash,
        stage: "error",
        error: message(e),
      }));
    }
  }
  async function track(
    hash: Hex,
    title: string,
    plan?: Plan,
    expected = expectedRef.current,
  ) {
    let resolved = false;
    try {
      const receipt = await client.waitForTransactionReceipt({
        hash,
        confirmations: 1,
        timeout: 240000,
        onReplaced: (r) => {
          setState((s) =>
            s ? { ...s, hash: r.transaction.hash, replaced: true } : s,
          );
          savePending({ hash: r.transaction.hash, title, expected });
        },
      });
      resolved = true;
      setUnresolved(false);
      clearPending();
      if (receipt.status !== "success")
        throw new Error(
          "The transaction reverted on chain. Open the receipt for details.",
        );
      if (expected) {
        const tx = await client.getTransaction({
          hash: receipt.transactionHash,
        });
        if (
          !tx.to ||
          !same(tx.to, expected.to) ||
          !same(tx.from, expected.account) ||
          tx.input !== expected.data ||
          tx.value !== BigInt(expected.value)
        )
          throw new Error(
            "The pending transaction was replaced by a different action. Check its receipt.",
          );
      }
      setState((s) => ({
        ...s!,
        title,
        stage: "confirmed",
        hash: receipt.transactionHash,
        result:
          plan?.receiptMessage?.(receipt) ||
          "Confirmed on Ethereum. Live balances and contract state are refreshing.",
      }));
      onSuccess();
    } catch (e) {
      setState((s) => ({
        ...s!,
        title,
        stage: "error",
        hash: s?.hash || hash,
        error:
          message(e) +
          (resolved
            ? ""
            : " The transaction remains unresolved. New writes are paused; check the receipt again."),
      }));
    } finally {
      lock.current = !resolved;
      if (!resolved) setUnresolved(true);
    }
  }
  useEffect(() => {
    if (restored.current) return;
    restored.current = true;
    let saved: string | null = null;
    try {
      saved = sessionStorage.getItem("mad-pending");
    } catch {
      return;
    }
    if (!saved) return;
    try {
      const p = JSON.parse(saved);
      lock.current = true;
      initial.current = p.expected?.account;
      expectedRef.current = p.expected;
      setUnresolved(true);
      setState({ title: p.title, stage: "pending", hash: p.hash });
      void track(p.hash, p.title, undefined, p.expected);
    } catch {
      clearPending();
    }
  }, []);
  const busy =
    unresolved ||
    (!!state &&
      ["simulating", "review", "wallet", "pending"].includes(state.stage));
  return (
    <Context.Provider value={{ start, busy }}>
      {state && !open && (
        <div className="transaction-banner" role="status">
          <span>
            {unresolved
              ? "A transaction is still being tracked. New writes are paused."
              : state.stage === "confirmed"
                ? "Transaction confirmed."
                : "A transaction needs your attention."}
          </span>
          <button onClick={() => setOpen(true)}>View transaction</button>
        </div>
      )}
      {children}
      {state && open && (
        <Modal
          title={state.title}
          onClose={() => {
            if (
              !["wallet", "pending", "simulating"].includes(state.stage) &&
              !unresolved
            ) {
              setState(undefined);
              lock.current = false;
            } else setOpen(false);
          }}
        >
          <p className="tx-status" role="status">
            {
              {
                simulating: "Checking current state and simulating…",
                review: "Simulation passed. Review this transaction.",
                wallet: "Confirm this action in your wallet.",
                pending: "Submitted. Waiting for a confirmed receipt…",
                confirmed: "Transaction confirmed",
                error: "Action needs attention",
              }[state.stage]
            }
          </p>
          {state.plan && (
            <>
              <dl className="details">
                <div>
                  <dt>Network</dt>
                  <dd>Ethereum mainnet (1)</dd>
                </div>
                <div>
                  <dt>Contract</dt>
                  <dd>
                    <AddressLink address={state.plan.address} full />
                  </dd>
                </div>
                <div>
                  <dt>Function</dt>
                  <dd>
                    <code>{state.plan.functionName}</code>
                  </dd>
                </div>
                {Object.entries(state.plan.notes).map(([k, v]) => (
                  <div key={k}>
                    <dt>{k}</dt>
                    <dd>{v}</dd>
                  </div>
                ))}
              </dl>
              <p className="caption">
                Ethereum gas is paid separately. Review the final transaction
                details in your wallet.
              </p>
            </>
          )}
          {state.hash && (
            <p>
              <TxLink hash={state.hash} />
              {state.replaced && " · Replacement detected"}
            </p>
          )}
          {state.error && <Notice kind="error">{state.error}</Notice>}
          {state.result && <Notice kind="success">{state.result}</Notice>}
          {state.stage === "review" && (
            <button className="primary full-button" onClick={confirm}>
              Confirm in wallet
            </button>
          )}
          {state.stage === "error" && state.hash && (
            <button
              onClick={() => {
                lock.current = true;
                setState({ ...state, stage: "pending", error: undefined });
                void track(state.hash!, state.title, state.plan);
              }}
            >
              Check receipt again
            </button>
          )}
          {["confirmed", "error"].includes(state.stage) && (
            <button
              className="full-button"
              onClick={() =>
                unresolved ? setOpen(false) : setState(undefined)
              }
            >
              {unresolved ? "Hide details and keep tracking" : "Close"}
            </button>
          )}
        </Modal>
      )}
    </Context.Provider>
  );
}
export function useTransaction() {
  return useContext(Context);
}
export function WriteButton({
  title,
  build,
  disabled,
  children,
  primary = false,
}: {
  title: string;
  build: BuildPlan;
  disabled?: boolean;
  children: ReactNode;
  primary?: boolean;
}) {
  const { start, busy } = useTransaction();
  const { address, chainId } = useAccount();
  return (
    <button
      className={primary ? "primary full-button" : ""}
      disabled={disabled || busy || !address || chainId !== 1}
      onClick={() => start(title, build)}
    >
      {children}
    </button>
  );
}
