/** Read-only contract preflight. No signing or broadcast methods are used. */
import { readFile } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import {
  createPublicClient,
  custom,
  keccak256,
  toBytes,
  parseAbi,
  erc20Abi,
} from "viem";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const load = (p) => readFile(resolve(root, p), "utf8").then(JSON.parse);
const dep = await load("web/src/deployment.json");
const sourceRecord = await load("artifacts/source-verification.json");
const abis = {};
for (const k of ["token", "hook", "rewards", "quoter", "stateView"])
  abis[k] = await load(`web/src/${k}Abi.json`);
const A = Object.fromEntries(
  Object.entries(dep.contracts).map(([k, v]) => [k, v.address]),
);
const rpc = process.argv.includes("--rpc")
  ? process.argv[process.argv.indexOf("--rpc") + 1]
  : dep.sourceRpc;
const transport = custom({
  request: async ({ method, params }) => {
    if (
      ![
        "eth_call",
        "eth_chainId",
        "eth_getCode",
        "eth_getBlockByNumber",
        "eth_getBalance",
        "eth_blockNumber",
      ].includes(method)
    )
      throw new Error("Only read RPC methods are allowed.");
    return new Promise((resolve, reject) => {
      const args = [
        "-sS",
        "--max-time",
        "40",
        "-H",
        "Content-Type: application/json",
        "--data-binary",
        "@-",
      ];
      if (rpc.startsWith("http://127.0.0.1:") && process.env.HTTP_PROXY)
        args.push("-x", process.env.HTTP_PROXY, "--noproxy", "");
      args.push(rpc);
      const p = spawn("curl", args);
      let out = "";
      p.stdout.on("data", (x) => (out += x));
      p.on("error", reject);
      p.on("close", () => {
        try {
          const r = JSON.parse(out);
          if (r.error) reject(new Error(r.error.message));
          else resolve(r.result);
        } catch (e) {
          reject(e);
        }
      });
      p.stdin.end(JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }));
    });
  },
});
const c = createPublicClient({ transport });
const checks = [];
const eq = (a, b) => a.toLowerCase() === b.toLowerCase();
const canonical = (x) =>
  Array.isArray(x)
    ? x.map(canonical)
    : x && typeof x === "object"
      ? Object.fromEntries(
          Object.keys(x)
            .sort()
            .map((k) => [k, canonical(x[k])]),
        )
      : x;
function check(name, ok, details) {
  checks.push({ name, passed: !!ok, details });
  if (!ok) throw new Error(name);
}
const r = (key, fn, args = []) =>
  c.readContract({ address: A[key], abi: abis[key], functionName: fn, args });
check("Ethereum chain ID", (await c.getChainId()) === 1);
for (const item of sourceRecord) {
  const key = { MadToken: "token", MadHook: "hook", MadRewards: "rewards" }[
    item.name
  ];
  const hash = keccak256(toBytes(JSON.stringify(canonical(abis[key])))).slice(
    2,
  );
  check(`${item.name} ABI hash`, hash === item.canonicalAbiHash, {
    canonicalAbiHash: hash,
    manifestMatch: item.manifestAbiHash ? hash === item.manifestAbiHash : null,
  });
}
for (const [name, entry] of Object.entries(dep.contracts)) {
  const code = await c.getCode({ address: entry.address });
  check(
    `${name} deployed code hash`,
    !!code && keccak256(code) === entry.codeHash,
  );
}
check("Token hook binding", eq(await r("token", "hook"), A.hook));
check("Hook token", eq(await r("hook", "mad"), A.token));
check("Discovered Rewards", eq(await r("hook", "rewards"), A.rewards));
check("Rewards hook", eq(await r("rewards", "hook"), A.hook));
check("Rewards token", eq(await r("rewards", "mad"), A.token));
check("Fee receiver immutable", eq(await r("hook", "receiver"), A.receiver));
check("MAD decimals", (await r("token", "decimals")) === 18);
check(
  "FWA decimals",
  (await c.readContract({
    address: A.fwa,
    abi: erc20Abi,
    functionName: "decimals",
  })) === 18,
);
const receiverAbi = parseAbi([
  "function playground() view returns (address)",
  "function projectId() view returns (uint256)",
]);
const [hub, id] = await Promise.all(
  ["playground", "projectId"].map((functionName) =>
    c.readContract({ address: A.receiver, abi: receiverAbi, functionName }),
  ),
);
const project = await c.readContract({
  address: A.hub,
  abi: parseAbi([
    "function projects(uint256) view returns (address creator,address receiver)",
  ]),
  functionName: "projects",
  args: [1n],
});
check("Receiver playground", eq(hub, A.hub));
check("Receiver project ID", id === 1n);
check("Registered project receiver", eq(project[1], A.receiver));
check("Parent paidBy matches receiver", eq(dep.parentPaidBy, A.receiver));
const owner = await r("hook", "owner"),
  rewardOwner = await r("rewards", "owner");
const [enabled, liquidity, round, leader, budget, hasNFT, poolId, supply] =
  await Promise.all([
    r("hook", "tradingEnabled"),
    r("stateView", "getLiquidity", [dep.poolId]),
    r("token", "currentRound"),
    r("token", "leader", [await r("token", "currentRound")]),
    r("rewards", "nftBudget"),
    r("rewards", "hasUnassignedNFT"),
    r("hook", "poolId"),
    r("token", "totalSupply"),
  ]);
check("Pool key matches deployment", poolId === dep.poolId);
async function simulation(name, key, fn, args, account, shouldSucceed) {
  try {
    await c.simulateContract({
      address: A[key],
      abi: abis[key],
      functionName: fn,
      args,
      account,
    });
    check(name, shouldSucceed, "eth_call success; no transaction sent");
  } catch (e) {
    if (e.message === name) throw e;
    check(name, !shouldSucceed, (e.shortMessage || e.message).slice(0, 700));
  }
}
if (!enabled)
  await simulation(
    "Owner can simulate irreversible trading enable",
    "hook",
    "enableTrading",
    [],
    owner,
    true,
  );
await simulation(
  "Non-owner trading enable reverts",
  "hook",
  "enableTrading",
  [],
  A.receiver,
  false,
);
await simulation(
  "Self-freeze reverts",
  "token",
  "freeze",
  [owner],
  owner,
  false,
);
await simulation(
  "Contract target freeze reverts",
  "token",
  "freeze",
  [A.hook],
  owner,
  false,
);
await simulation(
  "Public payout is simulated without redirect",
  "hook",
  "payout",
  [],
  owner,
  true,
);
if (!enabled || !liquidity) {
  try {
    await c.simulateContract({
      address: A.quoter,
      abi: abis.quoter,
      functionName: "quoteExactInputSingle",
      args: [
        {
          poolKey: dep.poolKey,
          zeroForOne: false,
          exactAmount: 10n ** 18n,
          hookData: "0x",
        },
      ],
    });
    check("Unavailable route refuses a quote", false);
  } catch (e) {
    check(
      "Unavailable route refuses a quote",
      true,
      (e.shortMessage || e.message).slice(0, 500),
    );
  }
}
const block = await c.getBlock();
console.log(
  JSON.stringify(
    {
      sourceRpc: dep.sourceRpc,
      block: block.number,
      timestamp: block.timestamp,
      realTransactionsBroadcast: 0,
      state: {
        owner,
        rewardOwner,
        enabled,
        liquidity,
        round,
        leader,
        budget,
        hasNFT,
        poolId,
        supply,
      },
      checks,
    },
    (_, v) => (typeof v === "bigint" ? v.toString() : v),
    2,
  ),
);
