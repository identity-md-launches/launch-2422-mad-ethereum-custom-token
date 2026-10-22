import {
  createPublicClient,
  fallback,
  http,
  keccak256,
  type Address,
  type Abi,
  type Hex,
  zeroAddress,
} from "viem";
import { mainnet } from "viem/chains";
import { createConfig } from "wagmi";
import { injected, coinbaseWallet } from "@wagmi/connectors";
import deployment from "./deployment.json";
import {
  tokenAbi,
  hookAbi,
  rewardsAbi,
  stateAbi,
  erc20Abi,
  hubAbi,
  receiverAbi,
} from "./abis";
export const chain = mainnet;
export const PUBLIC_RPCS = [
  "https://ethereum-rpc.publicnode.com",
  "https://eth.drpc.org",
] as const;
const transport = () =>
  fallback(
    PUBLIC_RPCS.map((url) =>
      http(url, {
        timeout: 14000,
        retryCount: 1,
        batch: { batchSize: 80, wait: 20 },
      }),
    ),
    { rank: false },
  );
export const client = createPublicClient({ chain, transport: transport() });
export const config = createConfig({
  chains: [chain],
  multiInjectedProviderDiscovery: true,
  connectors: [
    injected(),
    coinbaseWallet({
      appName: "MAD · Mutually Assured Destruction",
      preference: "all",
    }),
  ],
  transports: { [chain.id]: transport() },
});
export const ADDR = Object.fromEntries(
  Object.entries(deployment.contracts).map(([k, v]) => [k, v.address]),
) as Record<keyof typeof deployment.contracts, Address>;
export const POOL = deployment.poolKey as {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
};
export const POOL_ID = deployment.poolId as Hex;
export const START_BLOCK = BigInt(deployment.deploymentBlock);
export const same = (a: string, b: string) =>
  a.toLowerCase() === b.toLowerCase();
export async function read<T>(
  address: Address,
  abi: Abi,
  functionName: string,
  args: readonly unknown[] = [],
  blockNumber?: bigint,
): Promise<T> {
  return (await client.readContract({
    address,
    abi,
    functionName,
    args,
    blockNumber,
  })) as T;
}
export const token = <T>(
  fn: string,
  args: readonly unknown[] = [],
  block?: bigint,
) => read<T>(ADDR.token, tokenAbi, fn, args, block);
export const hook = <T>(
  fn: string,
  args: readonly unknown[] = [],
  block?: bigint,
) => read<T>(ADDR.hook, hookAbi, fn, args, block);
export const reward = <T>(
  fn: string,
  args: readonly unknown[] = [],
  block?: bigint,
) => read<T>(ADDR.rewards, rewardsAbi, fn, args, block);
export async function verifyDeployment() {
  if ((await client.getChainId()) !== 1)
    throw new Error(
      "The RPC is not on Ethereum mainnet. Transactions are disabled.",
    );
  await Promise.all(
    Object.values(deployment.contracts).map(async ({ address, codeHash }) => {
      const code = await client.getCode({ address: address as Address });
      if (!code || keccak256(code) !== codeHash)
        throw new Error(
          `Deployed code could not be verified at ${address}. Transactions are disabled.`,
        );
    }),
  );
  const [bound, mad, rewards, manager, receiver, hub, id, project] =
    await Promise.all([
      token<Address>("hook"),
      hook<Address>("mad"),
      hook<Address>("rewards"),
      hook<Address>("poolManager"),
      hook<Address>("receiver"),
      read<Address>(ADDR.receiver, receiverAbi, "playground"),
      read<bigint>(ADDR.receiver, receiverAbi, "projectId"),
      read<readonly [Address, Address]>(ADDR.hub, hubAbi, "projects", [1n]),
    ]);
  if (
    !same(bound, ADDR.hook) ||
    !same(mad, ADDR.token) ||
    !same(rewards, ADDR.rewards) ||
    !same(manager, ADDR.poolManager) ||
    !same(receiver, ADDR.receiver) ||
    !same(hub, ADDR.hub) ||
    id !== 1n ||
    !same(project[1], ADDR.receiver)
  )
    throw new Error(
      "Deployment relationships do not match the verified project. Transactions are disabled.",
    );
}
export async function snapshot(wallet?: Address) {
  await verifyDeployment();
  const block = await client.getBlock();
  const b = block.number;
  const [
    round,
    supply,
    enabled,
    openedAt,
    fee,
    owner,
    rewardOwner,
    budget,
    pg,
    nftFwa,
    nftEth,
    burn,
    hasNFT,
    nextNFT,
    limit,
    minPrice,
    poolId,
  ] = await Promise.all([
    token<bigint>("currentRound", [], b),
    token<bigint>("totalSupply", [], b),
    hook<boolean>("tradingEnabled", [], b),
    hook<bigint>("openedAt", [], b),
    hook<bigint>("feeNumerator", [], b),
    hook<Address>("owner", [], b),
    reward<Address>("owner", [], b),
    reward<bigint>("nftBudget", [], b),
    hook<bigint>("playgroundClaims", [], b),
    hook<bigint>("nftFwaClaims", [], b),
    hook<bigint>("nftEthClaims", [], b),
    hook<bigint>("burnClaims", [], b),
    reward<boolean>("hasUnassignedNFT", [], b),
    reward<bigint>("nextUnassigned", [], b),
    hook<bigint>("sqrtPriceLimitX96", [], b),
    hook<bigint>("minEthPerFwaX128", [], b),
    hook<Hex>("poolId", [], b),
  ]);
  if (poolId !== POOL_ID)
    throw new Error("The live pool does not match this project.");
  const [leader, windows, pool] = await Promise.all([
    token<Address>("leader", [round], b),
    token<readonly [bigint, bigint]>("roundBlocks", [round], b),
    read<readonly [bigint, number, number, number]>(
      ADDR.stateView,
      stateAbi,
      "getSlot0",
      [POOL_ID],
      b,
    ),
  ]);
  const [leaderSpent, liquidity] = await Promise.all([
    token<bigint>("spent", [round, leader], b),
    read<bigint>(ADDR.stateView, stateAbi, "getLiquidity", [POOL_ID], b),
  ]);
  let walletState:
    | {
        address: Address;
        mad: bigint;
        fwa: bigint;
        eth: bigint;
        spent: bigint;
        frozenUntil: bigint;
      }
    | undefined;
  if (wallet) {
    const [mad, fwa, eth, spent, frozenUntil] = await Promise.all([
      token<bigint>("balanceOf", [wallet], b),
      read<bigint>(ADDR.fwa, erc20Abi, "balanceOf", [wallet], b),
      client.getBalance({ address: wallet, blockNumber: b }),
      token<bigint>("spent", [round, wallet], b),
      token<bigint>("frozenUntil", [wallet], b),
    ]);
    walletState = { address: wallet, mad, fwa, eth, spent, frozenUntil };
  }
  return {
    block: b,
    time: block.timestamp,
    round,
    supply,
    enabled,
    openedAt,
    fee,
    owner,
    rewardOwner,
    budget,
    pg,
    nftFwa,
    nftEth,
    burn,
    hasNFT,
    nextNFT,
    limit,
    minPrice,
    leader,
    windows,
    leaderSpent,
    pool,
    liquidity,
    wallet: walletState,
    updatedAt: Date.now(),
  };
}
export type Snapshot = Awaited<ReturnType<typeof snapshot>>;
export async function inspectTarget(target: Address) {
  const b = await client.getBlock();
  const [balance, cost, eligible, until, round] = await Promise.all([
    token<bigint>("balanceOf", [target], b.number),
    token<bigint>("freezeCost", [target], b.number),
    token<boolean>("isWallet", [target], b.number),
    token<bigint>("frozenUntil", [target], b.number),
    token<bigint>("currentRound", [], b.number),
  ]);
  return {
    target,
    balance,
    cost,
    eligible,
    until,
    round,
    block: b.number,
    time: b.timestamp,
  };
}
export { zeroAddress, deployment };
