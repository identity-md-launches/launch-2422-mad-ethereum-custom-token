import {
  encodeAbiParameters,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";
import { ADDR, POOL, POOL_ID, client, read, hook, token, same } from "./chain";
import { quoterAbi, stateAbi, erc20Abi, permitAbi } from "./abis";
export interface Quote {
  input: bigint;
  output: bigint;
  buy: boolean;
  block: bigint;
  created: number;
  deadline: bigint;
  minimum: bigint;
  slippage: number;
  impact: number;
  fee: bigint;
  sqrt: bigint;
  lpFee: number;
}
export function minimumOutput(output: bigint, bps: number) {
  if (!Number.isInteger(bps) || bps <= 0 || bps >= 10000)
    throw new Error("Choose a slippage tolerance between 0 and 100%.");
  const min = (output * BigInt(10000 - bps)) / 10000n;
  if (min <= 0n)
    throw new Error("The minimum output rounds to zero. Increase the amount.");
  return min;
}
export function swapInput(q: Quote): Hex {
  if (q.minimum <= 0n || q.input <= 0n)
    throw new Error("Swap amounts must be positive.");
  const swap = encodeAbiParameters(
    parseAbiParameters(
      "((address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,bytes hookData)",
    ),
    [
      {
        poolKey: POOL,
        zeroForOne: !q.buy,
        amountIn: q.input,
        amountOutMinimum: q.minimum,
        hookData: "0x",
      },
    ],
  );
  const pay = encodeAbiParameters(parseAbiParameters("address,uint256"), [
    q.buy ? ADDR.fwa : ADDR.token,
    q.input,
  ]);
  const take = encodeAbiParameters(parseAbiParameters("address,uint256"), [
    q.buy ? ADDR.token : ADDR.fwa,
    q.minimum,
  ]);
  // Verified deployed Universal Router: V4_SWAP(0x10); exact-in single(0x06), settle-all(0x0c), take-all(0x0f).
  return encodeAbiParameters(parseAbiParameters("bytes,bytes[]"), [
    "0x060c0f",
    [swap, pay, take],
  ]);
}
export async function quote(
  input: bigint,
  buy: boolean,
  slippage: number,
  minutes: number,
): Promise<Quote> {
  if (![5, 10, 20].includes(minutes))
    throw new Error("Choose a transaction deadline.");
  const started = Date.now();
  const block = await client.getBlock();
  const [enabled, liquidity, slot, fee] = await Promise.all([
    hook<boolean>("tradingEnabled", [], block.number),
    read<bigint>(
      ADDR.stateView,
      stateAbi,
      "getLiquidity",
      [POOL_ID],
      block.number,
    ),
    read<readonly [bigint, number, number, number]>(
      ADDR.stateView,
      stateAbi,
      "getSlot0",
      [POOL_ID],
      block.number,
    ),
    hook<bigint>("feeNumerator", [], block.number),
  ]);
  if (!enabled)
    throw new Error("Trading is closed. Only the hook owner can open it.");
  if (!liquidity || !slot[0])
    throw new Error(
      "The MAD/FWA pool has no active liquidity. A quote is unavailable.",
    );
  const simulation = await client.simulateContract({
    address: ADDR.quoter,
    abi: quoterAbi,
    functionName: "quoteExactInputSingle",
    blockNumber: block.number,
    args: [
      { poolKey: POOL, zeroForOne: !buy, exactAmount: input, hookData: "0x" },
    ],
  });
  const [output] = simulation.result as readonly [bigint, bigint];
  if (
    Date.now() - started > 30000 ||
    (await client.getBlockNumber()) > block.number + 2n
  )
    throw new Error(
      "The quote became stale while loading. Request a fresh quote.",
    );
  if (output <= 0n)
    throw new Error(
      "This amount has no output. Try a larger amount or wait for liquidity.",
    );
  const D = 18000000n,
    Q = 1n << 192n,
    sqrt = slot[0],
    lp = BigInt(slot[3]);
  const netInput = buy ? input - (input * fee) / D : input;
  const spot = buy
    ? (((netInput * (1000000n - lp)) / 1000000n) * Q) / (sqrt * sqrt)
    : (((input * (1000000n - lp)) / 1000000n) * (sqrt * sqrt)) / Q;
  const afterFees = buy ? spot : spot - (spot * fee) / D;
  const impact =
    afterFees > 0n
      ? Math.max(
          0,
          Number(((afterFees - output) * 1000000n) / afterFees) / 10000,
        )
      : 0;
  return {
    input,
    output,
    buy,
    block: block.number,
    created: started,
    deadline: block.timestamp + BigInt(minutes * 60),
    minimum: minimumOutput(output, slippage),
    slippage,
    impact,
    fee,
    sqrt,
    lpFee: slot[3],
  };
}
export async function allowances(account: Address, input: Address) {
  const [balance, approval, permission] = await Promise.all([
    read<bigint>(input, erc20Abi, "balanceOf", [account]),
    read<bigint>(input, erc20Abi, "allowance", [account, ADDR.permit2]),
    read<readonly [bigint, number, number]>(
      ADDR.permit2,
      permitAbi,
      "allowance",
      [account, input, ADDR.router],
    ),
  ]);
  return { balance, approval, permission };
}
export async function validateQuote(q: Quote, account: Address) {
  if (Date.now() - q.created > 30000)
    throw new Error("This quote is over 30 seconds old. Get a fresh quote.");
  const block = await client.getBlock();
  if (block.timestamp >= q.deadline)
    throw new Error("The swap deadline expired. Get a fresh quote.");
  if (!(await hook<boolean>("tradingEnabled")))
    throw new Error("Trading is closed.");
  if (
    !q.buy &&
    (await token<bigint>("frozenUntil", [account])) > block.timestamp
  )
    throw new Error("This wallet is frozen and cannot sell MAD.");
  if (
    !(await read<bigint>(ADDR.stateView, stateAbi, "getLiquidity", [POOL_ID]))
  )
    throw new Error("No active pool liquidity.");
  const a = await allowances(account, q.buy ? ADDR.fwa : ADDR.token);
  if (a.balance < q.input) throw new Error("Insufficient input balance.");
  return a;
}
