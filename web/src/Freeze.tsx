import { useState, useEffect } from "react";
import { useQuery } from "@tanstack/react-query";
import { useAccount } from "wagmi";
import { type Address } from "viem";
import {
  ADDR,
  inspectTarget,
  token,
  client,
  same,
  type Snapshot,
} from "./chain";
import { tokenAbi } from "./abis";
import { validAddress, amount, exact, dateTime, message } from "./format";
import { PageTitle, Icon, Metric, Notice, AddressLink } from "./components";
import { useTransaction } from "./transactions";
export function Freeze({
  state,
  refreshKey,
}: {
  state?: Snapshot;
  refreshKey: number;
}) {
  const { address, chainId } = useAccount();
  const { start, busy } = useTransaction();
  const [target, setTarget] = useState("");
  const [debounced, setDebounced] = useState("");
  const [error, setError] = useState("");
  useEffect(() => {
    const id = setTimeout(() => setDebounced(target.trim()), 450);
    return () => clearTimeout(id);
  }, [target]);
  const check = useQuery({
    queryKey: ["target", debounced, refreshKey],
    queryFn: () => inspectTarget(debounced as Address),
    enabled: validAddress(debounced),
    refetchInterval: 20000,
    retry: 1,
  });
  const result = target.trim() === debounced ? check.data : undefined;
  const wallet =
    state?.wallet && address && same(state.wallet.address, address)
      ? state.wallet
      : undefined;
  const self = !!address && same(target.trim(), address);
  const invalid = result && (!result.eligible || result.cost === 0n || self);
  const lowBalance = wallet && result && wallet.mad < result.cost;
  function review() {
    setError("");
    if (!validAddress(target.trim())) {
      setError("Enter a nonzero Ethereum wallet address.");
      document.getElementById("freeze-target")?.focus();
      return;
    }
    if (!address) {
      setError(
        "Connect a wallet using the Connect control above. You can inspect a target without connecting.",
      );
      return;
    }
    if (chainId !== 1) {
      setError(
        "Switch your wallet to Ethereum using the network control above.",
      );
      return;
    }
    start("Freeze a wallet", async (account) => {
      const t = target.trim() as Address;
      const info = await inspectTarget(t);
      if (same(t, account))
        throw new Error("Choose a wallet other than your connected account.");
      if (!info.eligible)
        throw new Error(
          "This address is a contract. Only wallets and exact EIP-7702 designations can be frozen.",
        );
      if (!info.cost)
        throw new Error(
          "This wallet holds too little MAD for a nonzero freeze cost.",
        );
      const balance = await token<bigint>("balanceOf", [account]);
      if (balance < info.cost)
        throw new Error("Insufficient MAD to pay this freeze cost.");
      const [first] = await token<readonly [bigint, bigint]>("roundBlocks", [
        info.round,
      ]);
      if (info.block < first)
        throw new Error(
          "A round closed in this block. Wait for the next Ethereum block and review again.",
        );
      return {
        address: ADDR.token,
        abi: tokenAbi,
        functionName: "freeze",
        args: [t],
        notes: {
          Target: t,
          "Cost now": exact(info.cost, "MAD"),
          Burned: exact(info.cost / 2n, "MAD"),
          "Paid to target": exact(info.cost - info.cost / 2n, "MAD"),
          Effect:
            "Resets the target’s freeze until 24 hours after execution. Transfers, sales and liquidity deposits are blocked.",
          "Cost can change":
            "The contract recalculates 1% of the target’s balance at execution. It has no maximum-cost parameter. A balance increase can increase your payment. No token approval is needed.",
        },
      };
    });
  }
  return (
    <>
      <PageTitle title="Freeze a wallet.">
        Spend MAD to stop another wallet’s transfers for 24 hours.
      </PageTitle>
      <div className="quick-stats">
        <span>
          <span className="dot" />
          {state ? `Round ${state.round}` : "Reading current round…"}
        </span>
        <span>1% of target’s balance</span>
        <span>24-hour freeze</span>
      </div>
      <div className="play-grid">
        <section
          className="panel freeze-panel"
          aria-labelledby="target-heading"
        >
          <div className="section-head">
            <h2 id="target-heading">Choose your target</h2>
            <Icon name="freeze" />
          </div>
          <form
            onSubmit={(e) => {
              e.preventDefault();
              review();
            }}
            noValidate
          >
            <label htmlFor="freeze-target">Target wallet</label>
            <input
              id="freeze-target"
              name="target"
              value={target}
              placeholder="Ethereum address · 0x…"
              autoComplete="off"
              spellCheck="false"
              aria-invalid={!!error || !!invalid}
              aria-describedby="target-help target-error"
              onChange={(e) => {
                setTarget(e.target.value);
                setError("");
              }}
            />
            <p id="target-help" className="caption">
              Paste another wallet address to read its balance and cost.
            </p>
            <div className="target-preview" aria-live="polite">
              {!target ? (
                <>
                  <span className="muted">Freeze cost</span>
                  <strong className="preview-amount">Enter a target</strong>
                  <span className="caption">
                    Half burns. The rest goes to the target.
                  </span>
                </>
              ) : check.isFetching && !result ? (
                <p>Reading target from Ethereum…</p>
              ) : check.isError ? (
                <Notice kind="error">
                  Target unavailable. {message(check.error)}{" "}
                  <button
                    type="button"
                    className="text-button"
                    onClick={() => check.refetch()}
                  >
                    Retry target read
                  </button>
                </Notice>
              ) : result ? (
                <>
                  <span className="muted">Freeze cost</span>
                  <strong
                    className="preview-amount"
                    title={exact(result.cost, "MAD")}
                  >
                    {amount(result.cost, "MAD", 6)}
                  </strong>
                  <dl className="details compact">
                    <div>
                      <dt>Target balance</dt>
                      <dd title={exact(result.balance, "MAD")}>
                        {amount(result.balance, "MAD")}
                      </dd>
                    </div>
                    <div>
                      <dt>Burned</dt>
                      <dd title={exact(result.cost / 2n, "MAD")}>
                        {amount(result.cost / 2n, "MAD")}
                      </dd>
                    </div>
                    <div>
                      <dt>Paid to target</dt>
                      <dd title={exact(result.cost - result.cost / 2n, "MAD")}>
                        {amount(result.cost - result.cost / 2n, "MAD")}
                      </dd>
                    </div>
                  </dl>
                  {result.until > result.time && (
                    <p className="caption">
                      Already frozen until {dateTime(result.until)}. Freezing
                      again resets the deadline.
                    </p>
                  )}
                  {!result.eligible && (
                    <p className="error-text">Contracts cannot be targeted.</p>
                  )}
                  {result.cost === 0n && (
                    <p className="error-text">
                      Target balance is too small. The cost must be nonzero.
                    </p>
                  )}
                  {self && (
                    <p className="error-text">
                      Choose another wallet. You cannot freeze yourself.
                    </p>
                  )}
                  {lowBalance && (
                    <p className="error-text">
                      Your MAD balance is below this cost.
                    </p>
                  )}
                </>
              ) : (
                <p className="muted">
                  Enter a complete Ethereum address to inspect it.
                </p>
              )}
            </div>
            <div id="target-error">
              {error && (
                <p className="error-text" role="alert">
                  {error}
                </p>
              )}
            </div>
            <button
              className="primary full-button"
              type="submit"
              disabled={
                busy ||
                !!invalid ||
                !!lowBalance ||
                (!!address && (chainId !== 1 || !state))
              }
            >
              <Icon name="freeze" size={18} />
              Review freeze
              <Icon name="arrow" size={18} />
            </button>
            <p className="caption form-note">
              {!address
                ? "Connect above to send a freeze. Inspection is read-only."
                : chainId !== 1
                  ? "Switch to Ethereum before sending."
                  : "You pay MAD plus Ethereum gas. No token approval required."}
            </p>
          </form>
        </section>
        <aside className="freeze-aside">
          <div className="freeze-art" aria-hidden="true">
            <div className="art-ring ring-one" />
            <div className="art-ring ring-two" />
            <Icon name="freeze" size={180} />
            <span className="art-cross cross-one">+</span>
            <span className="art-cross cross-two">+</span>
          </div>
          <div className="aside-copy">
            <h2>Every freeze has a cost.</h2>
            <p>
              You burn half the payment and give the rest to your target. Your
              full spend counts toward this round’s lead.
            </p>
            <a href="#protocol" className="inline-link">
              Read the rules
              <Icon name="arrow" size={16} />
            </a>
          </div>
        </aside>
      </div>
      <section className="wallet-section" aria-labelledby="position-heading">
        <div className="section-head">
          <h2 id="position-heading">Your position</h2>
          {address && <AddressLink address={address} />}
        </div>
        {!address ? (
          <p className="muted">
            Connect a wallet to see your MAD, freeze status and round spend.
          </p>
        ) : !wallet ? (
          <p className="muted">
            {state
              ? "Wallet data unavailable. Refresh to retry."
              : "Reading wallet balances…"}
          </p>
        ) : (
          <>
            <div className="metrics">
              <Metric
                label="MAD balance"
                value={amount(wallet.mad, "MAD")}
                sub={exact(wallet.mad, "MAD")}
              />
              <Metric
                label="This round’s spend"
                value={amount(wallet.spent, "MAD")}
              />
              <Metric
                label="Transfer status"
                value={wallet.frozenUntil > state!.time ? "Frozen" : "Unfrozen"}
                sub={
                  wallet.frozenUntil > state!.time
                    ? `Until ${dateTime(wallet.frozenUntil)}`
                    : "Can send, sell and add liquidity"
                }
              />
            </div>
            {wallet.frozenUntil > state!.time && (
              <Notice>
                You can receive MAD and pay freeze costs while frozen.
                Transfers, sells and liquidity deposits resume at the onchain
                deadline.
              </Notice>
            )}
          </>
        )}
      </section>
      <section className="round-strip">
        <div>
          <span className="muted">Current leader</span>
          <strong>
            {state ? (
              same(
                state.leader,
                "0x0000000000000000000000000000000000000000",
              ) ? (
                "No freezer yet"
              ) : (
                <AddressLink address={state.leader} />
              )
            ) : (
              "Reading…"
            )}
          </strong>
        </div>
        <div>
          <span className="muted">Leader spend</span>
          <strong>{amount(state?.leaderSpent, "MAD")}</strong>
        </div>
        <a href="#rounds" className="inline-link">
          Explore NFT rounds
          <Icon name="arrow" size={16} />
        </a>
      </section>
    </>
  );
}
