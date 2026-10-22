import {
  type Address,
  type Hex,
  zeroAddress,
  zeroHash,
  formatUnits,
} from "viem";
import { ADDR, client, read, reward, token, same } from "./chain";
import { fwaV2Abi, intakeAbi, erc20Abi } from "./abis";
export async function acquisitionState() {
  const block = await client.getBlock();
  const b = block.number;
  const [pool, margin, slippage, budget] = await Promise.all([
    reward<Address>("fwaV2", [], b),
    reward<bigint>("acquisitionFeeMargin", [], b),
    reward<bigint>("acquisitionSlippageBps", [], b),
    reward<bigint>("nftBudget", [], b),
  ]);
  const [blackout, quote] = await Promise.all([
    read<boolean>(pool, fwaV2Abi, "isPurchaseBlackout", [], b),
    read<readonly [bigint, bigint, bigint]>(
      pool,
      fwaV2Abi,
      "quoteAcquisitionPrice",
      [],
      b,
    ),
  ]);
  return {
    pool,
    margin,
    slippage,
    budget,
    blackout,
    quote,
    block: b,
    time: block.timestamp,
  };
}
export async function oracleState() {
  const block = await client.getBlock();
  const b = block.number;
  const [intake, asset, action, maxPrice] = await Promise.all([
    reward<Address>("intake", [], b),
    reward<Address>("oracleAsset", [], b),
    reward<Hex>("oracleAction", [], b),
    reward<bigint>("maxOraclePrice", [], b),
  ]);
  const [price, oracleBalance, decimals, symbol] = await Promise.all([
    read<bigint>(intake, intakeAbi, "priceOf", [action, asset], b),
    read<bigint>(asset, erc20Abi, "balanceOf", [ADDR.rewards], b),
    read<number>(asset, erc20Abi, "decimals", [], b).catch(() => undefined),
    read<string>(asset, erc20Abi, "symbol", [], b).catch(() => "oracle tokens"),
  ]);
  return {
    intake,
    asset,
    action,
    maxPrice,
    price,
    oracleBalance,
    decimals,
    symbol,
    block: b,
  };
}
export async function roundState(round: bigint) {
  const block = await client.getBlock();
  const b = block.number;
  const [r, windows, leader] = await Promise.all([
    reward<readonly [bigint, bigint, Address, Address, boolean, Hex]>(
      "rounds",
      [round],
      b,
    ),
    token<readonly [bigint, bigint]>("roundBlocks", [round], b),
    token<Address>("leader", [round], b),
  ]);
  const pending =
    r[5] !== zeroHash
      ? await reward<readonly [bigint, Hex, Address, Address, bigint, boolean]>(
          "pending",
          [r[5]],
          b,
        )
      : undefined;
  const nft =
    r[0] > 0n
      ? await reward<readonly [Address, bigint]>("keptNFTs", [r[0] - 1n], b)
      : undefined;
  let askReason = "";
  let awardReason = "";
  if (r[0] === 0n) {
    askReason = "No NFT is assigned to this round.";
    awardReason = askReason;
  } else if (r[4]) {
    askReason = "This round’s NFT has already been delivered.";
    awardReason = askReason;
  } else {
    if (r[2] !== zeroAddress || r[3] !== zeroAddress)
      askReason = "A winner or beneficiary is already fixed.";
    else if (block.timestamp >= r[1] + 259200n)
      askReason =
        "The 72-hour oracle window has ended. The recorded leader is the fallback.";
    else if (b < windows[1] + 8n)
      askReason = `Wait ${windows[1] + 8n - b} more blocks for the oracle confirmation depth.`;
    else if (pending?.[5] && block.timestamp < pending[4] + 21600n)
      askReason = `An oracle ask is live until ${new Date(Number(pending[4] + 21600n) * 1000).toLocaleString()}. Failed asks can retry immediately.`;
    if (
      r[2] === zeroAddress &&
      r[3] === zeroAddress &&
      block.timestamp < r[1] + 259200n
    )
      awardReason = "Wait for an oracle answer or 72 hours after closure.";
  }
  return {
    round,
    r,
    windows,
    leader,
    pending,
    nft,
    askReason,
    awardReason,
    block: b,
    time: block.timestamp,
  };
}
export type Acquisition = {
  purchaser: Address;
  requestBlock: bigint;
  priceEscrowed: bigint;
  listingId: bigint;
  status: number;
};
export type Listing = {
  collection: Address;
  depositor: Address;
  purchaser: Address;
  tokenId: bigint;
  allocatedAt: bigint;
  status: number;
};
export async function purchaseState(request: bigint) {
  const b = await client.getBlock();
  const [pool, claimed] = await reward<readonly [Address, boolean]>(
    "purchases",
    [request],
    b.number,
  );
  if (pool === zeroAddress)
    return {
      request,
      pool,
      claimed,
      reason: "No purchase with this request ID is recorded by MAD Rewards.",
    };
  const a = await read<Acquisition>(
    pool,
    fwaV2Abi,
    "acquisitions",
    [request],
    b.number,
  );
  const [window, credit] = await Promise.all([
    read<bigint>(pool, fwaV2Abi, "settlementWindow", [], b.number),
    read<bigint>(
      pool,
      fwaV2Abi,
      "acquisitionRefundCredit",
      [ADDR.rewards],
      b.number,
    ),
  ]);
  const l =
    a.listingId > 0n
      ? await read<Listing>(pool, fwaV2Abi, "listings", [a.listingId], b.number)
      : undefined;
  let reason = "";
  if (claimed) reason = "This purchase was already kept by MAD Rewards.";
  else if (a.status !== 2 || !same(a.purchaser, ADDR.rewards) || !a.listingId)
    reason =
      "The acquisition is not allocated to MAD Rewards yet. Fulfillment or a refund may be pending.";
  else if (
    !l ||
    l.status !== 2 ||
    !same(l.purchaser, ADDR.rewards) ||
    l.collection === zeroAddress
  )
    reason = "The listing is not eligible to keep.";
  else if (b.timestamp >= l.allocatedAt + window)
    reason =
      "The live settlement window has closed. This NFT can no longer be kept.";
  return {
    request,
    pool,
    claimed,
    a,
    l,
    window,
    credit,
    reason,
    deadline: l ? l.allocatedAt + window : undefined,
  };
}
export const assetAmount = (
  v: bigint,
  decimals: number | undefined,
  symbol: string,
) =>
  decimals === undefined
    ? `${v} base units of ${symbol}`
    : `${formatUnits(v, decimals)} ${symbol}`;
