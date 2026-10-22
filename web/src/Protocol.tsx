import { useQuery } from "@tanstack/react-query";
import { ADDR, client, read, hook, type Snapshot, deployment } from "./chain";
import { hookAbi, erc20Abi } from "./abis";
import { amount, exact, message } from "./format";
import { PageTitle, Metric, Notice, AddressLink, Icon } from "./components";
import { WriteButton } from "./transactions";
export function Protocol({
  state,
  refreshKey,
}: {
  state?: Snapshot;
  refreshKey: number;
}) {
  const held = useQuery({
    queryKey: ["receiver-held", refreshKey],
    queryFn: async () => {
      const b = await client.getBlockNumber();
      const [fwa, eth, rewardsETH] = await Promise.all([
        read<bigint>(ADDR.fwa, erc20Abi, "balanceOf", [ADDR.receiver], b),
        client.getBalance({ address: ADDR.receiver, blockNumber: b }),
        client.getBalance({ address: ADDR.rewards, blockNumber: b }),
      ]);
      return { fwa, eth, rewardsETH, block: b };
    },
    refetchInterval: 30000,
  });
  return (
    <>
      <PageTitle title="The rules behind MAD.">
        Mutually Assured Destruction is a token game with real, irreversible
        costs.
      </PageTitle>
      <div className="rules-grid">
        <section className="reading">
          <h2>Freeze another wallet</h2>
          <p>
            You pay 1% of the target’s MAD balance, rounded down in 18-decimal
            base units. Half of that cost burns, rounded down; the remainder
            goes to the target. A zero cost reverts.
          </p>
          <p>
            The target must be another nonzero wallet with no code, or an exact
            23-byte EIP-7702 designation. Ordinary contracts cannot be targeted.
          </p>
          <p>
            For 24 hours after execution the target cannot transfer, sell,
            transfer through an allowance, or add liquidity on any pool. It can
            receive MAD and pay freeze costs. Another freeze resets the deadline
            to 24 hours from that execution; it does not add 24 hours.
          </p>
          <Notice>
            The freeze function has no maximum-cost parameter. The target’s
            balance at execution determines what you pay, which can differ from
            a preview.
          </Notice>
        </section>
        <section className="reading">
          <h2>Lead a round, earn an NFT</h2>
          <p>
            Your full freeze spend adds to your round total. The highest total
            leads, with ties won by the first to reach that total. This is spend
            accounting, not staking or a refundable deposit.
          </p>
          <p>
            A public keeper closes the round when it has a kept NFT, spans at
            least 7,200 blocks and its leader has spent at least 1,000 MAD. The
            oldest kept NFT is assigned. The next round starts in the next
            block.
          </p>
          <p>
            After eight blocks, a keeper may ask the IMD oracle, using donated
            oracle tokens. The signed answer stores a winner. Anyone can deliver
            the NFT, or use the token’s recorded leader after 72 hours without
            an answer. A failed delivery can be retried; its beneficiary stays
            fixed.
          </p>
          <a href="#rounds" className="inline-link">
            Inspect rounds and NFT custody
            <Icon name="arrow" size={16} />
          </a>
        </section>
      </div>
      <section className="supply-section">
        <div className="metrics">
          <Metric
            label="Initial MAD supply"
            value="1,000,000,000"
            sub="18 decimals · minted once at launch"
          />
          <Metric
            label="Current MAD supply"
            value={amount(state?.supply, "MAD")}
            sub={
              state &&
              exact(state.supply, "MAD") !==
                amount(state.supply, "MAD").replace(/,/g, "")
                ? exact(state.supply, "MAD")
                : undefined
            }
          />
          <Metric
            label="MAD burned by freezing"
            value={
              state ? amount(10n ** 27n - state.supply, "MAD") : "Unavailable"
            }
          />
        </div>
      </section>
      <section className="panel">
        <h2>Where trading fees go</h2>
        <p className="muted">
          The hook charges only the FWA side. Its fee decays from 99% to 1% over
          the first 30 minutes; the pool separately charges 1.25% to liquidity
          providers.
        </p>
        <div className="fee-rows">
          <div>
            <strong>0.50%</strong>
            <div>
              <h3>Playground revenue</h3>
              <p>
                Accrues as FWA claims, then public payout sends it directly from
                PoolManager to the immutable receiver.
              </p>
            </div>
          </div>
          <div>
            <strong>0.50%</strong>
            <div>
              <h3>NFT funding</h3>
              <p>
                Converts FWA into ETH within owner-set bounds on the configured
                ETH/FWA pool. Unsold FWA waits for a later trade. Only ETH
                proceeds and ETH claims enter the NFT budget.
              </p>
            </div>
          </div>
          <div>
            <strong>Excess</strong>
            <div>
              <h3>FWA burn</h3>
              <p>
                The hook burns fees above the resting 1% and rounding dust. When
                reserves cannot cover the burn in that swap, separate burn-only
                claims wait for a public flush.
              </p>
            </div>
          </div>
        </div>
        <p className="caption">
          The two 0.50% shares use the gross FWA fee base, not the collected
          fee. This website adds no fee and changes no destination.
        </p>
      </section>
      <section className="panel">
        <div className="section-head">
          <h2>Public keeper actions</h2>
          <span className="caption">Caller pays Ethereum gas</span>
        </div>
        <div className="keeper-rows">
          {[
            {
              name: "Pay Playground FWA",
              key: "pg" as const,
              fn: "payout",
              symbol: "FWA",
              effect: `Redeems only Playground FWA claims directly to ${ADDR.receiver}. This is not a personal claim or an ETH conversion.`,
            },
            {
              name: "Flush deferred FWA burn",
              key: "burn" as const,
              fn: "flushBurn",
              symbol: "FWA",
              effect:
                "Redeems deferred burn-only claims and burns the FWA. No reward or revenue is paid to the caller.",
            },
            {
              name: "Redeem NFT ETH claims",
              key: "nftEth" as const,
              fn: "flushNftETH",
              symbol: "ETH",
              effect: `Redeems all pending NFT ETH claims from PoolManager into MAD Rewards (${ADDR.rewards}). This does not pay your wallet.`,
            },
          ].map((action) => (
            <div className="keeper-row" key={action.fn}>
              <div>
                <h3>{action.name}</h3>
                <p className="caption">{action.effect}</p>
                <strong
                  title={
                    state ? exact(state[action.key], action.symbol) : undefined
                  }
                >
                  {amount(state?.[action.key], action.symbol)}
                </strong>
              </div>
              <div>
                <WriteButton
                  title={action.name}
                  disabled={!state || state[action.key] === 0n}
                  build={async () => {
                    const getter = {
                      pg: "playgroundClaims",
                      burn: "burnClaims",
                      nftEth: "nftEthClaims",
                    }[action.key];
                    const current = await hook<bigint>(getter);
                    if (!current)
                      throw new Error(
                        "No claims are available for this action.",
                      );
                    return {
                      address: ADDR.hook,
                      abi: hookAbi,
                      functionName: action.fn,
                      notes: {
                        Amount: exact(current, action.symbol),
                        Effect: action.effect,
                        "Reserve dependency":
                          "PoolManager must hold the underlying asset. Simulation checks the present reserve state; a failed redemption can be retried.",
                      },
                    };
                  }}
                >
                  Review action
                </WriteButton>
                <p className="caption">
                  {!state
                    ? "State unavailable"
                    : state[action.key] === 0n
                      ? "No pending claims"
                      : "Claims are pending"}
                </p>
              </div>
            </div>
          ))}
        </div>
      </section>
      <section className="reading wide">
        <h2>Held funds are not personal claims</h2>
        <div className="metrics">
          <Metric
            label="Receiver-held FWA"
            value={
              held.isPending
                ? "Reading…"
                : held.isError
                  ? "Unavailable"
                  : amount(held.data?.fwa, "FWA")
            }
          />
          <Metric
            label="Receiver-held ETH"
            value={
              held.isPending
                ? "Reading…"
                : held.isError
                  ? "Unavailable"
                  : amount(held.data?.eth, "ETH")
            }
          />
          <Metric
            label="Rewards-held ETH"
            value={
              held.isPending
                ? "Reading…"
                : held.isError
                  ? "Unavailable"
                  : amount(held.data?.rewardsETH, "ETH")
            }
          />
          <Metric
            label="NFT FWA waiting to convert"
            value={amount(state?.nftFwa, "FWA")}
          />
        </div>
        {held.isError && (
          <Notice kind="error">
            Held balances unavailable. {message(held.error)}
          </Notice>
        )}
        <p>
          FWA revenue stays at the receiver until the Playground owner
          configures an adapter and an active member or authorized swap operator
          converts it. Conversion needs a nonzero minimum ETH output and a live
          deadline. The caller earns 0.5% of newly converted ETH; the remainder
          is deposited into the existing hub.
        </p>
        <p>
          Plain ETH received by the receiver is held until anyone calls its
          depositETH function. Alternatively the hub accepts its payable deposit
          function with the project ID. A plain ETH send to the hub reverts.
        </p>
        <p>
          The hub distributes deposited ETH: 50% to the original creator, 30%
          among other active members and 20% to its fixed Tokenworks splitter.
          With no other active members the creator gets 80%. Hub accounting
          determines membership, rounding and claims. The balances above are
          held funds, not your claimable ETH.
        </p>
        <p className="caption">
          This site exposes the project’s FWA payout only. Receiver adapter
          configuration, conversion and hub claims remain separate. Standard
          launch requester fees already accrue to the existing receiver and are
          not charged again.
        </p>
      </section>
      <section className="rules-grid">
        <section className="reading">
          <h2>Understand the risks</h2>
          <p>
            Spending MAD is permanent. Freezes restrict your wallet, and another
            holder can reset your deadline. A high launch fee, low liquidity,
            slippage and Ethereum gas can make a trade expensive.
          </p>
          <p>
            Owner-controlled conversion, FWA V2 and oracle settings are trust
            boundaries. A hostile successor pool could drain the NFT budget; a
            hostile Intake and signer could determine winners. A winner that
            rejects NFTs can block its own delivery. There is no owner rescue or
            beneficiary redirect.
          </p>
          <p>
            No contract schedules itself. Keepers must handle acquisition
            fulfillment, settlement windows, retries and awards. There is no
            guaranteed reward, price or resale value.
          </p>
        </section>
        <section className="reading">
          <h2>Verified project contracts</h2>
          <dl className="details contract-directory">
            {(["token", "hook", "rewards", "receiver", "hub"] as const).map(
              (key) => (
                <div key={key}>
                  <dt>
                    {
                      {
                        token: "MAD token",
                        hook: "MAD hook",
                        rewards: "MAD Rewards",
                        receiver: "Revenue receiver",
                        hub: "Playground hub",
                      }[key]
                    }
                  </dt>
                  <dd>
                    <AddressLink full address={ADDR[key]} />
                  </dd>
                </div>
              ),
            )}
          </dl>
          <p className="caption">
            Ethereum mainnet · Playground project 1. Token and hook ABIs match
            the manifest. Rewards is discovered from the hook and checked
            against its source runtime.
          </p>
          <p className="caption">
            Launch allocation claims are unavailable here: the supplied
            deployment manifest does not include a verified distributor ABI or
            allocation proofs. No claim entitlement is assumed.
          </p>
          <a
            className="inline-link"
            href={`https://github.com/identity-md-launches/launch-2422-mad-ethereum-custom-token/tree/${deployment.sourceCommit}`}
            target="_blank"
            rel="noreferrer"
          >
            Read the contract source
            <Icon name="external" size={16} />
          </a>
        </section>
      </section>
    </>
  );
}
