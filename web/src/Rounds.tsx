import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { decodeEventLog, type Address } from "viem";
import {
  ADDR,
  hook,
  reward,
  token,
  client,
  same,
  zeroAddress,
  type Snapshot,
} from "./chain";
import { hookAbi, rewardsAbi } from "./abis";
import {
  acquisitionState,
  oracleState,
  roundState,
  purchaseState,
  assetAmount,
} from "./rewards";
import { integer, amount, exact, dateTime, message } from "./format";
import { PageTitle, Notice, Metric, AddressLink, Icon } from "./components";
import { WriteButton } from "./transactions";
export function Rounds({
  state,
  refreshKey,
}: {
  state?: Snapshot;
  refreshKey: number;
}) {
  const [roundInput, setRoundInput] = useState("1");
  const [selected, setSelected] = useState(1n);
  const [roundError, setRoundError] = useState("");
  const [requestInput, setRequestInput] = useState("");
  const [request, setRequest] = useState<bigint>();
  const [requestError, setRequestError] = useState("");
  const acquisition = useQuery({
    queryKey: ["acquisition", refreshKey],
    queryFn: acquisitionState,
    refetchInterval: 30000,
    retry: 1,
  });
  const oracle = useQuery({
    queryKey: ["oracle", refreshKey],
    queryFn: oracleState,
    refetchInterval: 30000,
    retry: 1,
  });
  const round = useQuery({
    queryKey: ["round", selected.toString(), refreshKey],
    queryFn: () => roundState(selected),
    refetchInterval: 15000,
    retry: 1,
  });
  const purchase = useQuery({
    queryKey: ["purchase", request?.toString(), refreshKey],
    queryFn: () => purchaseState(request!),
    enabled: request !== undefined,
    refetchInterval: 15000,
    retry: 1,
  });
  const next = useQuery({
    queryKey: ["nextNFT", state?.nextNFT.toString(), state?.hasNFT, refreshKey],
    queryFn: () =>
      reward<readonly [Address, bigint]>("keptNFTs", [state!.nextNFT]),
    enabled: !!state?.hasNFT,
  });
  let closeReason = "Reading current round…";
  if (state) {
    if (!state.hasNFT) closeReason = "No kept NFT is available to assign.";
    else if (same(state.leader, zeroAddress))
      closeReason = "The round needs a freeze leader.";
    else if (state.leaderSpent < 1000n * 10n ** 18n)
      closeReason = "The leader must spend at least 1,000 MAD this round.";
    else if (state.block + 1n < state.windows[0] + 7200n)
      closeReason = `${state.windows[0] + 7200n - state.block - 1n} more blocks before this round can close.`;
    else closeReason = "";
  }
  const a = acquisition.data;
  const o = oracle.isError ? undefined : oracle.data;
  const r = round.data;
  const p = purchase.data;
  let buyReason = !a
    ? "Reading the live acquisition quote…"
    : a.blackout
      ? "FWA V2 is in a purchase blackout."
      : a.quote[2] === 0n
        ? "No acquisition quote is available."
        : a.budget < a.quote[2]
          ? "NFT funding is below the live acquisition cost."
          : "";
  return (
    <>
      <PageTitle title="Spend MAD. Lead the round.">
        Follow the freeze leader and help keep NFT rewards moving.
      </PageTitle>
      <section className="round-overview">
        <div>
          <h2>Round {state?.round.toString() || "…"}</h2>
          <p className="muted">
            Highest cumulative freeze spend leads. Ties go to the first wallet
            to reach the total.
          </p>
        </div>
        <div className="metrics">
          <Metric
            label="Current leader"
            value={
              state ? (
                state.leader === zeroAddress ? (
                  "No freezer yet"
                ) : (
                  <AddressLink address={state.leader} />
                )
              ) : (
                "Reading…"
              )
            }
          />
          <Metric
            label="Leader spend"
            value={amount(state?.leaderSpent, "MAD")}
          />
          <Metric
            label="Next NFT"
            value={
              state?.hasNFT
                ? next.isError
                  ? "NFT unavailable"
                  : next.data
                    ? `Token #${next.data[1]}`
                    : "Reading…"
                : state
                  ? "None kept yet"
                  : "Reading…"
            }
            sub={next.data ? <AddressLink address={next.data[0]} /> : undefined}
          />
        </div>
        <p className="caption">
          Closure requires 7,200 blocks, at least 1,000 MAD spent by the leader
          and an unassigned kept NFT. These are rules enforced by the deployed
          hook.
        </p>
        <WriteButton
          title="Close the current round"
          disabled={!!closeReason}
          build={async () => {
            const round = await token<bigint>("currentRound");
            const leader = await token<Address>("leader", [round]);
            const spend = await token<bigint>("spent", [round, leader]);
            const [first] = await token<readonly [bigint, bigint]>(
              "roundBlocks",
              [round],
            );
            const b = await client.getBlock();
            if (
              leader === zeroAddress ||
              spend < 1000n * 10n ** 18n ||
              b.number + 1n < first + 7200n ||
              !(await reward<boolean>("hasUnassignedNFT"))
            )
              throw new Error(
                "The current round does not satisfy its leader, spend, block-age and NFT requirements.",
              );
            return {
              address: ADDR.hook,
              abi: hookAbi,
              functionName: "closeRound",
              notes: {
                Round: round.toString(),
                Leader: leader,
                "Leader spend": exact(spend, "MAD"),
                Effect:
                  "Closes at the execution block and assigns the oldest kept NFT. Freezes are blocked for the rest of that block; the next round starts the following block.",
              },
            };
          }}
        >
          Review round closure
        </WriteButton>
        <p className="caption">
          {closeReason ||
            "This round is eligible to close. Anyone may submit the transaction."}
        </p>
      </section>
      <div className="two-column">
        <section className="panel">
          <h2>Settle a round</h2>
          <form
            className="lookup-form"
            onSubmit={(e) => {
              e.preventDefault();
              try {
                const n = integer(roundInput, "a round number");
                if (n < 1n) throw new Error("Round numbers start at 1.");
                setSelected(n);
                setRoundError("");
              } catch (e) {
                setRoundError(message(e));
              }
            }}
          >
            <label htmlFor="round-number">Round number</label>
            <div className="input-action">
              <input
                id="round-number"
                inputMode="numeric"
                value={roundInput}
                onChange={(e) => setRoundInput(e.target.value)}
              />
              <button type="submit">Inspect</button>
            </div>
          </form>
          {roundError && <Notice kind="error">{roundError}</Notice>}
          {round.isPending ? (
            <p>Reading round…</p>
          ) : round.isError ? (
            <Notice kind="error">
              Round unavailable. {message(round.error)}
              <button onClick={() => round.refetch()}>Retry</button>
            </Notice>
          ) : (
            r && (
              <>
                <dl className="details">
                  <div>
                    <dt>Round</dt>
                    <dd>{selected.toString()}</dd>
                  </div>
                  <div>
                    <dt>Block window</dt>
                    <dd>
                      {r.windows[0] === 0n
                        ? "Not started"
                        : `${r.windows[0].toLocaleString()} to ${r.windows[1] === 0n ? "open" : r.windows[1].toLocaleString()}`}
                    </dd>
                  </div>
                  <div>
                    <dt>Reward</dt>
                    <dd>
                      {r.nft ? (
                        <>
                          <AddressLink address={r.nft[0]} /> · #
                          {r.nft[1].toString()}
                        </>
                      ) : (
                        "No NFT assigned"
                      )}
                    </dd>
                  </div>
                  <div>
                    <dt>Oracle winner</dt>
                    <dd>
                      {r.r[2] === zeroAddress ? (
                        "No answer"
                      ) : (
                        <AddressLink address={r.r[2]} />
                      )}
                    </dd>
                  </div>
                  <div>
                    <dt>Beneficiary</dt>
                    <dd>
                      {r.r[3] === zeroAddress ? (
                        "Not fixed"
                      ) : (
                        <AddressLink address={r.r[3]} />
                      )}
                    </dd>
                  </div>
                  <div>
                    <dt>Delivery</dt>
                    <dd>{r.r[4] ? "Delivered" : "Not delivered"}</dd>
                  </div>
                  {r.r[1] > 0n && (
                    <div>
                      <dt>Fallback available</dt>
                      <dd>{dateTime(r.r[1] + 259200n)}</dd>
                    </div>
                  )}
                </dl>
                <WriteButton
                  title="Ask the oracle for this round’s winner"
                  disabled={
                    !!r.askReason ||
                    !o ||
                    o.oracleBalance < o.price ||
                    (o.maxPrice > 0n && o.price > o.maxPrice)
                  }
                  build={async () => {
                    const live = await roundState(selected);
                    const funding = await oracleState();
                    if (live.askReason) throw new Error(live.askReason);
                    if (
                      funding.oracleBalance < funding.price ||
                      (funding.maxPrice > 0n &&
                        funding.price > funding.maxPrice)
                    )
                      throw new Error(
                        "The donated oracle funds or configured price cap cannot cover the current quote.",
                      );
                    return {
                      address: ADDR.rewards,
                      abi: rewardsAbi,
                      functionName: "askWinner",
                      args: [selected],
                      notes: {
                        Round: selected.toString(),
                        "Oracle fee": assetAmount(
                          funding.price,
                          funding.decimals,
                          funding.symbol,
                        ),
                        "Paid from":
                          "Existing donated oracle tokens held by MAD Rewards; not your wallet.",
                        Intake: funding.intake,
                        "Oracle asset": funding.asset,
                        "Execution price":
                          funding.maxPrice === 0n
                            ? "The contract pays the live oracle price at execution from donated tokens, with no additional price ceiling."
                            : `The live execution price must fit the configured cap: ${assetAmount(funding.maxPrice, funding.decimals, funding.symbol)}.`,
                        "Trust and retry":
                          "The configured signer attests the answer. A failed ask may retry immediately; an unanswered ask waits 6 hours. Each retry spends another fee.",
                      },
                    };
                  }}
                >
                  Review oracle request
                </WriteButton>
                <p className="caption">
                  {r.askReason ||
                    (!o
                      ? "Oracle funding unavailable."
                      : o.oracleBalance < o.price
                        ? "Donated oracle tokens are below the live ask price."
                        : o.maxPrice > 0n && o.price > o.maxPrice
                          ? "The live oracle price exceeds the owner’s cap."
                          : "Ready to ask. Donated oracle tokens pay the fee.")}
                </p>
                <WriteButton
                  title="Deliver the round’s NFT"
                  disabled={!!r.awardReason}
                  build={async () => {
                    const live = await roundState(selected);
                    if (live.awardReason) throw new Error(live.awardReason);
                    return {
                      address: ADDR.rewards,
                      abi: rewardsAbi,
                      functionName: "award",
                      args: [selected],
                      notes: {
                        Round: selected.toString(),
                        Beneficiary:
                          live.r[3] !== zeroAddress
                            ? live.r[3]
                            : live.r[2] !== zeroAddress
                              ? live.r[2]
                              : live.leader,
                        NFT: live.nft
                          ? `${live.nft[0]} · #${live.nft[1]}`
                          : "Unavailable",
                        Effect:
                          "Sends the NFT to the stored winner, or the recorded freeze leader after 72 hours without an answer. A rejected NFT transfer keeps custody and fixes the beneficiary for a retry.",
                      },
                      receiptMessage: (receipt) => {
                        for (const log of receipt.logs) {
                          if (!same(log.address, ADDR.rewards)) continue;
                          try {
                            const event = decodeEventLog({
                              abi: rewardsAbi,
                              data: log.data,
                              topics: log.topics,
                            });
                            if (event.eventName === "AwardAttempt") {
                              const args = event.args as unknown as {
                                success: boolean;
                              };
                              return args.success
                                ? "NFT delivery confirmed."
                                : "Transaction confirmed, but the beneficiary rejected the NFT. Custody remains in MAD Rewards; delivery can be retried.";
                            }
                          } catch {
                            /* Other events. */
                          }
                        }
                        return "Transaction confirmed. Refresh the round’s delivery status.";
                      },
                    };
                  }}
                >
                  Review NFT delivery
                </WriteButton>
                <p className="caption">
                  {r.awardReason ||
                    "The NFT can be delivered. Anyone may submit the transaction."}
                </p>
              </>
            )
          )}
        </section>
        <section className="panel">
          <h2>Acquire the next NFT</h2>
          <p className="muted">
            Trading funds this budget. Anyone can submit the keeper calls; no
            automation is promised.
          </p>
          {acquisition.isPending ? (
            <p>Reading the live FWA V2 acquisition quote…</p>
          ) : acquisition.isError ? (
            <Notice kind="error">
              Acquisition quote unavailable. {message(acquisition.error)}
              <button onClick={() => acquisition.refetch()}>Retry</button>
            </Notice>
          ) : (
            a && (
              <>
                <dl className="details">
                  <div>
                    <dt>NFT ETH budget</dt>
                    <dd>{exact(a.budget, "ETH")}</dd>
                  </div>
                  <div>
                    <dt>Acquisition total</dt>
                    <dd>{exact(a.quote[2], "ETH")}</dd>
                  </div>
                  <div>
                    <dt>Acquisition fee</dt>
                    <dd>{exact(a.quote[0], "ETH")}</dd>
                  </div>
                  <div>
                    <dt>VRF fee</dt>
                    <dd>{exact(a.quote[1], "ETH")}</dd>
                  </div>
                  <div>
                    <dt>Selection slippage</dt>
                    <dd>{Number(a.slippage) / 100}%</dd>
                  </div>
                </dl>
                <WriteButton
                  title="Buy an NFT for the reward queue"
                  disabled={!!buyReason}
                  build={async () => {
                    const live = await acquisitionState();
                    if (
                      live.blackout ||
                      !live.quote[2] ||
                      live.budget < live.quote[2]
                    )
                      throw new Error(
                        "The live blackout, acquisition quote or NFT budget prevents this purchase.",
                      );
                    return {
                      address: ADDR.rewards,
                      abi: rewardsAbi,
                      functionName: "buy",
                      notes: {
                        "Source pool": live.pool,
                        "Total NFT budget spent": exact(live.quote[2], "ETH"),
                        "Quote timing":
                          "The contract obtains a live acquisition quote at execution. The budget spend may change before mining; you pay only gas.",
                        "Fee cap": exact(live.quote[0] + live.margin, "ETH"),
                        "Selection slippage": `${Number(live.slippage) / 100}%`,
                        "Paid from":
                          "The NFT budget held by MAD Rewards, including redeemable ETH claims. You pay only transaction gas.",
                        "Next step":
                          "Wait for FWA V2 fulfillment, then inspect the request ID from the Bought event and keep the NFT before its settlement deadline.",
                      },
                    };
                  }}
                >
                  Review NFT acquisition
                </WriteButton>
                <p className="caption">
                  {buyReason || "The NFT budget covers the current quote."}
                </p>
              </>
            )
          )}
          {oracle.isPending ? (
            <p>Reading oracle funding…</p>
          ) : oracle.isError ? (
            <Notice kind="error">
              Oracle funding unavailable. {message(oracle.error)}
              <button onClick={() => oracle.refetch()}>
                Retry oracle read
              </button>
            </Notice>
          ) : (
            o && (
              <dl className="details">
                <div>
                  <dt>Oracle funding</dt>
                  <dd>{assetAmount(o.oracleBalance, o.decimals, o.symbol)}</dd>
                </div>
                <div>
                  <dt>Oracle ask price</dt>
                  <dd>{assetAmount(o.price, o.decimals, o.symbol)}</dd>
                </div>
              </dl>
            )
          )}
          <p className="caption">
            Oracle funding is held at{" "}
            <AddressLink address={ADDR.rewards} full />. Donations are voluntary
            and have no withdrawal or refund right.
          </p>
        </section>
      </div>
      <section className="panel keeper-panel">
        <h2>Keep a fulfilled purchase</h2>
        <p className="muted">
          Use the request ID from a MAD Rewards Bought event in Activity. Each
          purchase keeps its original FWA V2 pool, even after a setting change.
        </p>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            try {
              setRequest(integer(requestInput, "a request ID"));
              setRequestError("");
            } catch (e) {
              setRequestError(message(e));
            }
          }}
        >
          <label htmlFor="request-id">Acquisition request ID</label>
          <div className="input-action">
            <input
              id="request-id"
              inputMode="numeric"
              value={requestInput}
              onChange={(e) => setRequestInput(e.target.value)}
              placeholder="Request ID from Bought event"
            />
            <button>Inspect purchase</button>
          </div>
        </form>
        {requestError && <Notice kind="error">{requestError}</Notice>}
        {purchase.isFetching && !p && (
          <p>Reading purchase and settlement window…</p>
        )}
        {purchase.isError && (
          <Notice kind="error">
            Purchase unavailable. {message(purchase.error)}
          </Notice>
        )}
        {p && (
          <>
            <dl className="details">
              <div>
                <dt>Original pool</dt>
                <dd>
                  {p.pool === zeroAddress ? (
                    "No recorded purchase"
                  ) : (
                    <AddressLink address={p.pool} />
                  )}
                </dd>
              </div>
              {p.deadline && (
                <div>
                  <dt>Keep before</dt>
                  <dd>{dateTime(p.deadline)}</dd>
                </div>
              )}
              {p.credit !== undefined && (
                <div>
                  <dt>Refund credit</dt>
                  <dd>{exact(p.credit, "ETH")}</dd>
                </div>
              )}
            </dl>
            <div className="button-row">
              <WriteButton
                title="Keep the allocated NFT"
                disabled={!!p.reason}
                build={async () => {
                  const live = await purchaseState(request!);
                  if (live.reason) throw new Error(live.reason);
                  return {
                    address: ADDR.rewards,
                    abi: rewardsAbi,
                    functionName: "claim",
                    args: [request!],
                    notes: {
                      "Request ID": request!.toString(),
                      "Original pool": live.pool,
                      "Keep before": dateTime(live.deadline!),
                      Effect:
                        "Moves the allocated NFT into MAD Rewards custody and the FIFO reward queue. This is not a personal NFT claim.",
                    },
                  };
                }}
              >
                Review keep NFT
              </WriteButton>
              <WriteButton
                title="Return acquisition refund to NFT budget"
                disabled={!p.credit || p.pool === zeroAddress}
                build={async () => {
                  const live = await purchaseState(request!);
                  if (!live.credit)
                    throw new Error(
                      "There is no refund credit at this purchase’s recorded pool.",
                    );
                  return {
                    address: ADDR.rewards,
                    abi: rewardsAbi,
                    functionName: "withdrawAcquisitionRefund",
                    args: [live.pool],
                    notes: {
                      Pool: live.pool,
                      "Refund credit": exact(live.credit, "ETH"),
                      Destination: ADDR.rewards,
                      Effect:
                        "Returns the pool’s acquisition refund credit to the NFT budget. It does not pay the caller; VRF fees are not promised back.",
                    },
                  };
                }}
              >
                Review refund recovery
              </WriteButton>
            </div>
            <p className="caption">
              {p.reason ||
                "This NFT is allocated and within the live settlement window."}
            </p>
          </>
        )}
      </section>
    </>
  );
}
