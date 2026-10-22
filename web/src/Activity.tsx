import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { decodeEventLog, type Abi, type Address } from "viem";
import { ADDR, START_BLOCK, client, same } from "./chain";
import { tokenAbi, hookAbi, rewardsAbi } from "./abis";
import { amount, dateTime, message } from "./format";
import {
  PageTitle,
  Icon,
  Empty,
  Notice,
  TxLink,
  AddressLink,
} from "./components";
const known = new Set([
  "Frozen",
  "FeeCharged",
  "HookBound",
  "RoundClosed",
  "TradingEnabled",
  "PlaygroundPaid",
  "BurnDeferred",
  "BurnFlushed",
  "NFTEthRedeemed",
  "NFTConverted",
  "Bought",
  "Kept",
  "RefundReceived",
  "RoundAssigned",
  "Asked",
  "AskFailed",
  "WinnerStored",
  "AwardAttempt",
  "FwaV2Set",
  "AcquisitionBoundsSet",
  "OracleSettingsSet",
  "MarketSet",
  "ConversionBoundsSet",
]);
export async function loadActivity(toBlock?: bigint) {
  const head = await client.getBlockNumber();
  const to = toBlock ?? head;
  const from = to - 4999n > START_BLOCK ? to - 4999n : START_BLOCK;
  if (to < START_BLOCK)
    return { events: [], from: START_BLOCK, to: START_BLOCK, head };
  const logs = await client.getLogs({
    address: [ADDR.token, ADDR.hook, ADDR.rewards],
    fromBlock: from,
    toBlock: to,
  });
  const decoded = logs
    .flatMap((log) => {
      try {
        const abi: Abi = same(log.address, ADDR.token)
          ? tokenAbi
          : same(log.address, ADDR.hook)
            ? hookAbi
            : rewardsAbi;
        const event = decodeEventLog({
          abi,
          data: log.data,
          topics: log.topics,
        });
        if (!event.eventName || !known.has(event.eventName)) return [];
        return [
          {
            ...log,
            eventName: event.eventName as string,
            args: event.args as unknown as Record<string, unknown>,
          },
        ];
      } catch {
        return [];
      }
    })
    .sort(
      (a, b) =>
        Number(b.blockNumber! - a.blockNumber!) ||
        Number(b.logIndex! - a.logIndex!),
    );
  const events = decoded.slice(0, 100);
  const blocks = [...new Set(events.map((e) => e.blockNumber!))];
  const times = new Map(
    await Promise.all(
      blocks.map(async (b) => {
        const block = await client.getBlock({ blockNumber: b });
        return [b, block.timestamp] as const;
      }),
    ),
  );
  return {
    events: events.map((e) => ({ ...e, time: times.get(e.blockNumber!) })),
    from,
    to,
    head,
    truncated: decoded.length > 100,
  };
}
const group = (name: string) =>
  name === "Frozen"
    ? "freezes"
    : /Bought|Kept|Round|Asked|Ask|Winner|Award|Refund/.test(name)
      ? "rewards"
      : /Set|Enabled|Bound/.test(name)
        ? "settings"
        : "fees";
const title: Record<string, string> = {
  FeeCharged: "Swap fee charged",
  Frozen: "Wallet frozen",
  HookBound: "Token bound to hook",
  RoundClosed: "Round closed",
  TradingEnabled: "Trading opened",
  PlaygroundPaid: "FWA paid to receiver",
  BurnDeferred: "FWA burn deferred",
  BurnFlushed: "Deferred FWA burned",
  NFTEthRedeemed: "NFT ETH claims redeemed",
  NFTConverted: "NFT funding converted",
  Bought: "NFT acquisition requested",
  Kept: "NFT kept in reward queue",
  RefundReceived: "NFT refund recovered",
  RoundAssigned: "NFT assigned to round",
  Asked: "Oracle request submitted",
  AskFailed: "Oracle request failed",
  WinnerStored: "Oracle winner stored",
  AwardAttempt: "NFT delivery attempted",
  FwaV2Set: "FWA V2 pool updated",
  AcquisitionBoundsSet: "Acquisition bounds updated",
  OracleSettingsSet: "Oracle settings updated",
  MarketSet: "Conversion market updated",
  ConversionBoundsSet: "Conversion bounds updated",
};
function eventAmount(event: string, key: string, value: bigint) {
  if (event === "Asked") return `${value.toString()} oracle asset base units`;
  const symbol =
    event === "Frozen"
      ? "MAD"
      : event === "Bought" ||
          event === "RefundReceived" ||
          event === "NFTEthRedeemed" ||
          key === "ethReceived"
        ? "ETH"
        : "FWA";
  return amount(value, symbol, 8);
}
export function Activity({ refreshKey }: { refreshKey: number }) {
  const [to, setTo] = useState<bigint>();
  const [filter, setFilter] = useState("all");
  const q = useQuery({
    queryKey: ["activity", to?.toString(), refreshKey],
    queryFn: () => loadActivity(to),
    refetchInterval: to ? false : 30000,
    retry: 1,
  });
  const events = q.isError
    ? undefined
    : q.data?.events.filter(
        (e) => filter === "all" || group(e.eventName) === filter,
      );
  return (
    <>
      <PageTitle title="Activity, on Ethereum.">
        Verified events from the MAD token, hook and rewards contracts.
      </PageTitle>
      <section className="panel activity-panel">
        <div className="section-head">
          <div>
            <label htmlFor="event-filter">Show events</label>
            <select
              id="event-filter"
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
            >
              <option value="all">All activity</option>
              <option value="freezes">Freezes</option>
              <option value="rewards">Rounds and rewards</option>
              <option value="fees">Fees and funding</option>
              <option value="settings">Contract settings</option>
            </select>
          </div>
          <button
            className="icon-button"
            aria-label="Refresh activity"
            disabled={q.isFetching}
            onClick={() => q.refetch()}
          >
            <Icon name="refresh" />
          </button>
        </div>
        <p className="caption">
          {q.data
            ? `Blocks ${q.data.from.toLocaleString()}–${q.data.to.toLocaleString()}. ${q.data.truncated ? "Showing the latest 100 matching events." : "Up to 5,000 blocks per page."}`
            : "Reading recent Ethereum logs…"}
        </p>
        {q.isError && (
          <Notice kind="error">
            Activity unavailable. {message(q.error)}
            <button onClick={() => q.refetch()}>Retry event read</button>
          </Notice>
        )}
        {q.isPending && (
          <div className="loading-block" role="status">
            Reading verified event logs…
          </div>
        )}
        {!q.isError && events?.length === 0 && (
          <Empty title="No matching events in this range">
            {filter === "all"
              ? "The contracts have no displayed events in these blocks. Check an older range or refresh after a transaction."
              : "Choose All activity or an older range to see other verified events."}
          </Empty>
        )}
        <ol className="event-list">
          {events?.map((e) => (
            <li key={`${e.transactionHash}-${e.logIndex}`}>
              <span className="event-icon">
                <Icon
                  name={
                    group(e.eventName) === "freezes"
                      ? "freeze"
                      : group(e.eventName) === "rewards"
                        ? "rounds"
                        : "activity"
                  }
                />
              </span>
              <div className="event-content">
                <h3>{title[e.eventName] || e.eventName}</h3>
                <div className="event-fields">
                  {Object.entries(e.args).map(([key, value]) => (
                    <span key={key}>
                      <span className="muted">{key}: </span>
                      {typeof value === "string" &&
                      /^0x[\da-f]{40}$/i.test(value) ? (
                        <AddressLink address={value as Address} />
                      ) : typeof value === "bigint" &&
                        [
                          "cost",
                          "amount",
                          "paid",
                          "sold",
                          "ethReceived",
                          "unsold",
                          "fwaBase",
                          "totalFee",
                          "playground",
                          "nft",
                          "burned",
                        ].includes(key) ? (
                        eventAmount(e.eventName, key, value)
                      ) : typeof value === "boolean" ? (
                        value ? (
                          "Yes"
                        ) : (
                          "No"
                        )
                      ) : (
                        String(value)
                      )}
                    </span>
                  ))}
                </div>
                <div className="caption event-meta">
                  <span>
                    {e.time ? dateTime(e.time) : `Block ${e.blockNumber}`}
                  </span>
                  {e.transactionHash && <TxLink hash={e.transactionHash} />}
                </div>
              </div>
            </li>
          ))}
        </ol>
        <div className="pagination">
          <button
            disabled={!q.data || q.isFetching || q.data.from <= START_BLOCK}
            onClick={() => setTo(q.data!.from - 1n)}
          >
            Older blocks
          </button>
          {to && (
            <button onClick={() => setTo(undefined)}>Back to latest</button>
          )}
        </div>
      </section>
    </>
  );
}
