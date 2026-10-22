import { useEffect, useState } from "react";
import { useAccount } from "wagmi";
import { useQuery } from "@tanstack/react-query";
import { ADDR, client, type Snapshot } from "./chain";
import { erc20Abi, permitAbi, routerAbi } from "./abis";
import {
  quote,
  allowances,
  swapInput,
  validateQuote,
  type Quote,
} from "./trading";
import { units, amount, exact, dateTime, message } from "./format";
import { PageTitle, Notice, AddressLink, Icon, Metric } from "./components";
import { useTransaction } from "./transactions";
export function Trade({
  state,
  refreshKey,
}: {
  state?: Snapshot;
  refreshKey: number;
}) {
  const { address, chainId } = useAccount();
  const { start, busy } = useTransaction();
  const [buy, setBuy] = useState(true);
  const [value, setValue] = useState("");
  const [slippage, setSlippage] = useState("");
  const [minutes, setMinutes] = useState("");
  const [q, setQ] = useState<Quote>();
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, []);
  useEffect(() => {
    setQ(undefined);
    setError("");
  }, [buy, value, slippage, minutes, refreshKey, address]);
  const input = buy ? ADDR.fwa : ADDR.token;
  const inputSymbol = buy ? "FWA" : "MAD";
  const outputSymbol = buy ? "MAD" : "FWA";
  const a = useQuery({
    queryKey: ["allowances", address, input, refreshKey],
    queryFn: () => allowances(address!, input),
    enabled: !!address,
    refetchInterval: 20000,
  });
  const stale = !!q && now - q.created > 30000;
  const closed = state && !state.enabled;
  const empty = state && state.liquidity === 0n;
  const needsApproval = !!q && a.data && a.data.approval < q.input;
  const needsPermission =
    !!q &&
    a.data &&
    (a.data.permission[0] < q.input ||
      BigInt(a.data.permission[1]) <= BigInt(Math.floor(Date.now() / 1000)));
  async function getQuote() {
    setError("");
    setQ(undefined);
    try {
      const input = units(value);
      if (!slippage) throw new Error("Choose a slippage tolerance.");
      if (!minutes) throw new Error("Choose a transaction deadline.");
      setLoading(true);
      setQ(await quote(input, buy, Number(slippage), Number(minutes)));
    } catch (e) {
      setError(message(e));
    } finally {
      setLoading(false);
    }
  }
  function approveToken() {
    if (!q) return;
    start(`Approve ${inputSymbol} for Permit2`, async (account) => {
      const fresh = await validateQuote(q, account);
      return {
        address: input,
        abi: erc20Abi,
        functionName: "approve",
        args: [ADDR.permit2, q.input],
        notes: {
          Token: input,
          Spender: ADDR.permit2,
          Amount: exact(q.input, inputSymbol),
          "Existing allowance": exact(fresh.approval, inputSymbol),
          Effect:
            "Replaces the ERC20 allowance with exactly this amount. A separate Permit2 permission authorizes the router. Refresh the quote after confirmation.",
        },
      };
    });
  }
  function approveRouter() {
    if (!q) return;
    start("Authorize Universal Router", async (account) => {
      await validateQuote(q, account);
      return {
        address: ADDR.permit2,
        abi: permitAbi,
        functionName: "approve",
        args: [input, ADDR.router, q.input, Number(q.deadline)],
        notes: {
          Token: input,
          Spender: ADDR.router,
          Amount: exact(q.input, inputSymbol),
          Expires: dateTime(q.deadline),
          Effect:
            "Permit2 allows this router to spend only this amount until expiry. Refresh the quote after confirmation.",
        },
      };
    });
  }
  function swap() {
    if (!q) return;
    start(buy ? "Buy MAD" : "Sell MAD", async (account) => {
      const allowance = await validateQuote(q, account);
      const b = await client.getBlock();
      if (
        allowance.approval < q.input ||
        allowance.permission[0] < q.input ||
        BigInt(allowance.permission[1]) <= b.timestamp
      )
        throw new Error(
          "Allowances changed. Refresh and complete the required approvals.",
        );
      return {
        address: ADDR.router,
        abi: routerAbi,
        functionName: "execute",
        args: ["0x10", [swapInput(q)], q.deadline],
        notes: {
          Pay: exact(q.input, inputSymbol),
          "Quoted output": exact(q.output, outputSymbol),
          "Minimum output": exact(q.minimum, outputSymbol),
          "Slippage tolerance": `${q.slippage / 100}%`,
          Deadline: dateTime(q.deadline),
          Recipient: account,
          Spender: ADDR.router,
          Route:
            "Direct verified MAD/FWA Uniswap v4 pool. No added website fee.",
        },
        validate: () => validateQuote(q, account).then(() => {}),
      };
    });
  }
  return (
    <>
      <PageTitle title="Trade MAD with FWA.">
        Buy or sell through the project’s verified Uniswap v4 pool.
      </PageTitle>
      <div className="two-column">
        <section className="panel">
          <div className="segmented">
            <button aria-pressed={buy} onClick={() => setBuy(true)}>
              Buy MAD
            </button>
            <button aria-pressed={!buy} onClick={() => setBuy(false)}>
              Sell MAD
            </button>
          </div>
          {closed && (
            <Notice>
              Trading is closed. Only the hook owner can open it, once.
            </Notice>
          )}
          {empty && (
            <Notice>
              The pool has no active liquidity. Quotes and swaps are
              unavailable.
            </Notice>
          )}
          <form
            onSubmit={(e) => {
              e.preventDefault();
              void getQuote();
            }}
          >
            <label htmlFor="trade-amount">You pay ({inputSymbol})</label>
            <div className="amount-input">
              <input
                id="trade-amount"
                inputMode="decimal"
                value={value}
                onChange={(e) => setValue(e.target.value)}
                placeholder="0.00"
                autoComplete="off"
              />
              <span>{inputSymbol}</span>
            </div>
            <p className="caption">
              Balance:{" "}
              {address
                ? a.isPending
                  ? "Reading…"
                  : a.isError
                    ? "Unavailable"
                    : amount(a.data?.balance, inputSymbol)
                : "Connect to read balance"}
            </p>
            <div className="field-pair">
              <div>
                <label htmlFor="slippage">Slippage tolerance</label>
                <select
                  id="slippage"
                  value={slippage}
                  onChange={(e) => setSlippage(e.target.value)}
                >
                  <option value="">Choose tolerance</option>
                  <option value="50">0.5%</option>
                  <option value="100">1%</option>
                  <option value="300">3%</option>
                  <option value="500">5%</option>
                </select>
              </div>
              <div>
                <label htmlFor="deadline">Transaction deadline</label>
                <select
                  id="deadline"
                  value={minutes}
                  onChange={(e) => setMinutes(e.target.value)}
                >
                  <option value="">Choose deadline</option>
                  <option value="5">5 minutes</option>
                  <option value="10">10 minutes</option>
                  <option value="20">20 minutes</option>
                </select>
              </div>
            </div>
            <button
              className="full-button"
              disabled={loading || !!closed || !!empty || !state}
            >
              {loading ? "Reading quote…" : "Get current quote"}
              <Icon name="refresh" size={16} />
            </button>
          </form>
          {error && <Notice kind="error">{error}</Notice>}
          {q && (
            <div className="quote">
              <Metric
                label={`You receive (${outputSymbol})`}
                value={amount(q.output, outputSymbol)}
                sub={exact(q.output, outputSymbol)}
              />
              <dl className="details">
                <div>
                  <dt>Minimum output</dt>
                  <dd>{exact(q.minimum, outputSymbol)}</dd>
                </div>
                <div>
                  <dt>Estimated price impact</dt>
                  <dd>{q.impact.toFixed(3)}%</dd>
                </div>
                <div>
                  <dt>Hook fee on FWA</dt>
                  <dd>{(Number(q.fee) / 180000).toFixed(3)}%</dd>
                </div>
                <div>
                  <dt>Pool LP fee</dt>
                  <dd>{q.lpFee / 10000}%</dd>
                </div>
                <div>
                  <dt>Quote block</dt>
                  <dd>{q.block.toString()}</dd>
                </div>
                <div>
                  <dt>Quote validity</dt>
                  <dd>
                    {stale
                      ? "Expired · refresh quote"
                      : `${Math.max(0, 30 - Math.floor((now - q.created) / 1000))} seconds`}
                  </dd>
                </div>
              </dl>
              <p className="caption">
                Price impact compares the quote with spot output after estimated
                hook and LP fees. Gas is separate.
              </p>
              {q.impact > 5 && (
                <Notice kind="error">
                  High price impact. This trade moves the price by more than 5%.
                </Notice>
              )}
              {a.isError && (
                <Notice kind="error">
                  Allowance read failed. Refresh before approving or swapping.
                </Notice>
              )}
              {a.data && a.data.balance < q.input && (
                <Notice kind="error">
                  Insufficient {inputSymbol} balance.
                </Notice>
              )}
              <p className="caption">
                ERC20 spender: <AddressLink address={ADDR.permit2} full />
                Router spender: <AddressLink address={ADDR.router} full />
              </p>
              {needsApproval ? (
                <button
                  className="primary full-button"
                  disabled={
                    busy ||
                    stale ||
                    !address ||
                    chainId !== 1 ||
                    a.isError ||
                    !a.data ||
                    a.data.balance < q.input
                  }
                  onClick={approveToken}
                >
                  Review {inputSymbol} approval
                </button>
              ) : needsPermission ? (
                <button
                  className="primary full-button"
                  disabled={
                    busy ||
                    stale ||
                    !address ||
                    chainId !== 1 ||
                    a.isError ||
                    !a.data ||
                    a.data.balance < q.input
                  }
                  onClick={approveRouter}
                >
                  Review router permission
                </button>
              ) : (
                <button
                  className="primary full-button"
                  disabled={
                    busy ||
                    stale ||
                    !address ||
                    chainId !== 1 ||
                    a.isError ||
                    !a.data ||
                    a.data.balance < q.input
                  }
                  onClick={swap}
                >
                  Review {buy ? "buy" : "sell"}
                </button>
              )}
            </div>
          )}
        </section>
        <aside className="reading">
          <h2>Know what you’re paying.</h2>
          <p>
            The hook fee starts at 99% when trading opens, then falls linearly
            to 1% over 30 minutes. The pool also charges a 1.25% LP fee.
          </p>
          <div className="fee-diagram">
            <span>99%</span>
            <svg
              viewBox="0 0 280 100"
              role="img"
              aria-label="Hook fee falls linearly from 99% to 1% over 30 minutes"
            >
              <path
                d="M5 8 235 90h35"
                fill="none"
                stroke="currentColor"
                strokeWidth="3"
              />
              <path
                d="M5 95h270"
                stroke="currentColor"
                strokeWidth="1"
                strokeDasharray="3 5"
              />
            </svg>
            <span>1%</span>
          </div>
          <p>
            Of the FWA fee base, 0.5% funds Playground and 0.5% funds NFTs. The
            excess burns, or waits in burn-only claims when PoolManager reserves
            cannot cover it yet.
          </p>
          <h3>Frozen wallets cannot sell.</h3>
          <p>
            You can still buy MAD or pay freeze costs. Receiving MAD does not
            end your freeze.
          </p>
          <p className="caption">
            This page supports the direct MAD/FWA route. Native ETH trading is
            unavailable: the hook’s internal NFT conversion is a separate flow.
          </p>
          <a
            className="inline-link"
            href={`https://etherscan.io/address/${ADDR.hook}`}
            target="_blank"
            rel="noreferrer"
          >
            Inspect the live hook
            <Icon name="external" size={16} />
          </a>
        </aside>
      </div>
    </>
  );
}
