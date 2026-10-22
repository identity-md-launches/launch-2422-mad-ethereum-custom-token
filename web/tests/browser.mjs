/** Production-export validation. Wallets and successful sends are isolated fixtures;
 * forwarding to Ethereum is restricted to read methods. No real transaction is broadcast.
 * Run from the repository root: node web/tests/browser.mjs [--rpc public-ethereum-rpc]
 */
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { resolve, dirname, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { chromium, webkit, expect } from "playwright/test";
import AxeBuilder from "@axe-core/playwright";
import {
  decodeFunctionData,
  encodeFunctionResult,
  encodeAbiParameters,
  parseAbiParameters,
  keccak256,
  toBytes,
  erc20Abi,
  zeroAddress,
  toHex,
} from "viem";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const out = resolve(root, "test/scratch/website-tests");
await mkdir(out, { recursive: true });
const dep = JSON.parse(
  await readFile(resolve(root, "web/src/deployment.json"), "utf8"),
);
const A = Object.fromEntries(
  Object.entries(dep.contracts).map(([k, v]) => [k, v.address.toLowerCase()]),
);
const OWNER = "0xfc3c962fad2c1cc77f1a0d46e7b8a2de79a21774";
const TARGET = "0x5598aa9146215bc13eb26f2c692ad1461fd32982";
const abi = {};
for (const k of [
  "token",
  "hook",
  "rewards",
  "router",
  "quoter",
  "stateView",
  "permit2",
])
  abi[k] = JSON.parse(
    await readFile(resolve(root, `web/src/${k}Abi.json`), "utf8"),
  );
const rpcUrl = process.argv.includes("--rpc")
  ? process.argv[process.argv.indexOf("--rpc") + 1]
  : "https://ethereum-rpc.publicnode.com";
const safeMethods = new Set([
  "eth_chainId",
  "eth_getCode",
  "eth_call",
  "eth_getBlockByNumber",
  "eth_blockNumber",
  "eth_getBalance",
  "eth_getLogs",
  "eth_getTransactionByHash",
  "eth_getTransactionReceipt",
  "eth_estimateGas",
  "eth_gasPrice",
  "eth_maxPriorityFeePerGas",
  "eth_feeHistory",
  "eth_getTransactionCount",
]);
const cache = new Map();
let rpcCalls = 0;
async function rpc(method, params = []) {
  assert(safeMethods.has(method), `A write RPC was blocked: ${method}`);
  const key = JSON.stringify([method, params]);
  if (cache.has(key)) return cache.get(key);
  const promise = new Promise((resolve, reject) => {
    const args = [
      "-sS",
      "--max-time",
      "35",
      "-H",
      "Content-Type: application/json",
      "--data-binary",
      "@-",
    ];
    if (rpcUrl.startsWith("http://127.0.0.1:") && process.env.HTTP_PROXY)
      args.push("-x", process.env.HTTP_PROXY, "--noproxy", "");
    args.push(rpcUrl);
    const p = spawn("curl", args);
    let data = "";
    p.stdout.on("data", (x) => (data += x));
    p.on("error", reject);
    p.on("close", () => {
      try {
        const r = JSON.parse(data);
        if (r.error)
          reject(Object.assign(new Error(r.error.message), { rpc: r.error }));
        else resolve(r.result);
      } catch (e) {
        reject(e);
      }
    });
    p.stdin.end(JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }));
    rpcCalls++;
  });
  cache.set(key, promise);
  try {
    return await promise;
  } catch (e) {
    cache.delete(key);
    if (method === "eth_getLogs" && /10 block range/.test(e.message)) {
      const f = params[0];
      const start = BigInt(f.fromBlock),
        end =
          f.toBlock === "latest"
            ? BigInt(await rpc("eth_blockNumber"))
            : BigInt(f.toBlock);
      const chunks = [];
      for (let n = start; n <= end; n += 10n)
        chunks.push({
          fromBlock: toHex(n),
          toBlock: toHex(n + 9n > end ? end : n + 9n),
        });
      const logs = [];
      let next = 0;
      await Promise.all(
        Array.from({ length: 6 }, async () => {
          while (next < chunks.length) {
            const chunk = chunks[next++];
            logs.push(...(await rpc(method, [{ ...f, ...chunk }])));
          }
        }),
      );
      return logs;
    }
    throw e;
  }
}
const block = await rpc("eth_getBlockByNumber", ["latest", false]);
const fixture = {
  height: BigInt(block.number),
  on: false,
  trading: true,
  liquidity: 10n ** 28n,
  quoterReverts: false,
  mad: 10000n * 10n ** 18n,
  fwa: 1000n * 10n ** 18n,
  target: 1000n * 10n ** 18n,
  spent: 0n,
  burned: 0n,
  erc20: 0n,
  permit: 0n,
  expiration: 0,
  hold: false,
  receiptAvailable: true,
  changedTransaction: false,
  sent: [],
  txs: new Map(),
};
const results = [];
const failures = [];
async function check(name, fn) {
  try {
    await fn();
    results.push({ name, passed: true });
    console.log("PASS", name);
  } catch (e) {
    results.push({ name, passed: false, error: e.message });
    failures.push(e);
    console.error("FAIL", name, e.message);
  }
}
const server = createServer(async (req, res) => {
  try {
    const u = new URL(req.url, "http://local");
    if (!u.pathname.startsWith("/preview/")) throw new Error("subpath");
    const file = resolve(root, "dist", u.pathname.slice(9) || "index.html");
    if (!file.startsWith(resolve(root, "dist") + "/")) throw new Error("path");
    const data = await readFile(file);
    res.writeHead(200, {
      "Content-Type":
        {
          ".html": "text/html",
          ".js": "application/javascript",
          ".css": "text/css",
          ".svg": "image/svg+xml",
          ".png": "image/png",
        }[extname(file)] || "application/octet-stream",
    });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end("Not found");
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = `http://127.0.0.1:${server.address().port}/preview/`;
function decodeCall(tx) {
  const to = tx.to?.toLowerCase();
  const key = Object.keys(A).find((k) => A[k] === to);
  const contractAbi = abi[key] || erc20Abi;
  try {
    return {
      key,
      abi: contractAbi,
      ...decodeFunctionData({ abi: contractAbi, data: tx.data }),
    };
  } catch {
    return {};
  }
}
function encoded(call, result) {
  return encodeFunctionResult({
    abi: call.abi,
    functionName: call.functionName,
    result,
  });
}
function mockCall(tx) {
  const c = decodeCall(tx);
  const f = c.functionName;
  const arg = c.args || [];
  const who = String(arg[0]).toLowerCase();
  if (!fixture.on) return;
  if (c.key === "token") {
    if (f === "balanceOf" && who === OWNER) return encoded(c, fixture.mad);
    if (f === "balanceOf" && who === TARGET) return encoded(c, fixture.target);
    if (f === "freezeCost" && who === TARGET)
      return encoded(c, fixture.target / 100n);
    if (f === "spent" && String(arg[1]).toLowerCase() === OWNER)
      return encoded(c, fixture.spent);
    if (f === "leader" && fixture.spent) return encoded(c, OWNER);
    if (f === "totalSupply") return encoded(c, 10n ** 27n - fixture.burned);
    if (f === "freeze") return "0x";
    if (f === "approve") return encoded(c, true);
  }
  if (c.key === "fwa") {
    if (f === "balanceOf" && who === OWNER) return encoded(c, fixture.fwa);
    if (f === "allowance" && who === OWNER) return encoded(c, fixture.erc20);
    if (f === "approve") return encoded(c, true);
  }
  if (c.key === "hook") {
    if (f === "tradingEnabled") return encoded(c, fixture.trading);
    if (f === "feeNumerator") return encoded(c, 180000n);
  }
  if (c.key === "stateView" && f === "getLiquidity")
    return encoded(c, fixture.liquidity);
  if (c.key === "permit2") {
    if (f === "allowance")
      return encoded(c, [fixture.permit, fixture.expiration, 0]);
    if (f === "approve") return "0x";
  }
  if (c.key === "quoter" && f === "quoteExactInputSingle") {
    if (fixture.quoterReverts)
      throw Object.assign(new Error("execution reverted"), {
        rpc: { code: 3, message: "execution reverted", data: "0x6190b2b0" },
      });
    const q = arg[0];
    const sqrt = BigInt(dep.slot0[0]);
    const n = q.exactAmount;
    let out = q.zeroForOne
      ? (((((n * 9875n) / 10000n) * sqrt * sqrt) / (1n << 192n)) * 99n) / 100n
      : (((((n * 99n) / 100n) * 9875n) / 10000n) * (1n << 192n)) /
        (sqrt * sqrt);
    out = (out * 995n) / 1000n;
    return encoded(c, [out, 180000n]);
  }
  if (c.key === "router" && f === "execute") return "0x";
}
function submit(tx) {
  const c = decodeCall({ ...tx, data: tx.data || tx.input });
  const hash = keccak256(
    toBytes(`isolated browser fixture ${fixture.sent.length}`),
  );
  const value = {
    ...tx,
    from: OWNER,
    hash,
    nonce: "0x1",
    type: "0x2",
    chainId: "0x1",
    gas: tx.gas || "0x30d40",
    gasPrice: "0x3b9aca00",
    maxFeePerGas: "0x77359400",
    maxPriorityFeePerGas: "0x3b9aca00",
    value: tx.value || "0x0",
    input: tx.data,
    blockHash: block.hash,
    blockNumber: block.number,
    transactionIndex: "0x0",
    r: "0x1",
    s: "0x1",
    v: "0x0",
    yParity: "0x0",
    accessList: [],
  };
  fixture.sent.push(tx);
  fixture.txs.set(hash, value);
  if (c.key === "token" && c.functionName === "freeze") {
    const cost = fixture.target / 100n;
    fixture.mad -= cost;
    fixture.spent += cost;
    fixture.burned += cost / 2n;
    fixture.target += cost - cost / 2n;
  }
  if (c.key === "fwa" && c.functionName === "approve")
    fixture.erc20 = c.args[1];
  if (c.key === "permit2" && c.functionName === "approve") {
    fixture.permit = c.args[2];
    fixture.expiration = Number(c.args[3]);
  }
  if (c.key === "router" && c.functionName === "execute") {
    fixture.fwa -= 100n * 10n ** 18n;
  }
  return hash;
}
async function respond(request) {
  const { id, method, params = [] } = request;
  try {
    if (fixture.on && method === "eth_blockNumber")
      return { jsonrpc: "2.0", id, result: toHex(fixture.height) };
    if (
      fixture.on &&
      method === "eth_getBlockByNumber" &&
      params[0] === "latest"
    )
      return {
        jsonrpc: "2.0",
        id,
        result: {
          ...block,
          number: toHex(fixture.height),
          timestamp: toHex(
            BigInt(block.timestamp) +
              (fixture.height - BigInt(block.number)) * 12n,
          ),
        },
      };

    if (
      fixture.on &&
      method === "eth_getTransactionReceipt" &&
      fixture.txs.has(params[0])
    ) {
      if (fixture.hold) return { jsonrpc: "2.0", id, result: null };
      const tx = fixture.txs.get(params[0]);
      return {
        jsonrpc: "2.0",
        id,
        result: {
          transactionHash: tx.hash,
          transactionIndex: "0x0",
          blockHash: block.hash,
          blockNumber: block.number,
          from: OWNER,
          to: tx.to,
          cumulativeGasUsed: "0x186a0",
          gasUsed: "0x186a0",
          effectiveGasPrice: "0x3b9aca00",
          contractAddress: null,
          logs: [],
          logsBloom: "0x" + "0".repeat(512),
          status: "0x1",
          type: "0x2",
        },
      };
    }
    if (
      fixture.on &&
      method === "eth_getTransactionByHash" &&
      fixture.txs.has(params[0])
    ) {
      const tx = fixture.txs.get(params[0]);
      return {
        jsonrpc: "2.0",
        id,
        result: { ...tx, input: fixture.changedTransaction ? "0x" : tx.input },
      };
    }
    if (fixture.on && method === "eth_call") {
      const value = mockCall(params[0]);
      if (value !== undefined) return { jsonrpc: "2.0", id, result: value };
    }
    return { jsonrpc: "2.0", id, result: await rpc(method, params) };
  } catch (e) {
    return {
      jsonrpc: "2.0",
      id,
      error: e.rpc || { code: -32000, message: e.message },
    };
  }
}
async function routeRPC(page) {
  await page.route(
    /https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)\/?$/,
    async (route) => {
      const payload = route.request().postDataJSON();
      const result = Array.isArray(payload)
        ? await Promise.all(payload.map(respond))
        : await respond(payload);
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify(result),
      });
    },
  );
}
async function walletInit(page) {
  await page.exposeFunction("__fixtureSubmit", submit);
  await page.addInitScript(
    ({ owner, other }) => {
      const handlers = new Map();
      const state = {
        account: owner,
        chain: "0x1",
        mode: "reject",
        connected: localStorage.getItem("validation-connected") === "true",
        methods: [],
        rejectConnect: false,
      };
      const emit = (name, value) => {
        for (const fn of handlers.get(name) || []) fn(value);
      };
      const provider = {
        on: (n, fn) => {
          handlers.set(n, [...(handlers.get(n) || []), fn]);
        },
        removeListener: (n, fn) =>
          handlers.set(
            n,
            (handlers.get(n) || []).filter((f) => f !== fn),
          ),
        request: async ({ method, params }) => {
          state.methods.push(method);
          if (method === "eth_accounts")
            return state.connected ? [state.account] : [];
          if (method === "eth_requestAccounts") {
            if (state.rejectConnect)
              throw Object.assign(new Error("User rejected the request"), {
                code: 4001,
              });
            state.connected = true;
            localStorage.setItem("validation-connected", "true");
            return [state.account];
          }
          if (method === "eth_chainId") return state.chain;
          if (method === "wallet_switchEthereumChain") {
            state.chain = params[0].chainId;
            emit("chainChanged", state.chain);
            return null;
          }
          if (method === "wallet_addEthereumChain") return null;
          if (method === "wallet_getCapabilities") return {};
          if (method === "eth_sendTransaction") {
            if (state.mode === "reject")
              throw Object.assign(new Error("User rejected the request"), {
                code: 4001,
              });
            return window.__fixtureSubmit(params[0]);
          }
          if (method === "eth_getTransactionCount") return "0x1";
          if (method === "eth_estimateGas") return "0x30d40";
          if (method === "eth_gasPrice") return "0x3b9aca00";
          throw new Error("Unexpected wallet method: " + method);
        },
      };
      const icon =
        "data:image/svg+xml," +
        encodeURIComponent(
          '<svg xmlns="http://www.w3.org/2000/svg" width="28" height="28"><rect width="28" height="28" fill="#285f9a"/></svg>',
        );
      const announce = () => {
        for (const [uuid, name, rdns] of [
          [
            "48dd67c9-63b6-49ef-afb0-40f046a7db35",
            "Validation wallet",
            "test.validation",
          ],
          [
            "5b93fb90-a350-4a61-a017-d2b7f6497383",
            "Second validation wallet",
            "test.second",
          ],
        ])
          window.dispatchEvent(
            new CustomEvent("eip6963:announceProvider", {
              detail: {
                info: { uuid, name, icon, rdns },
                provider:
                  name === "Validation wallet"
                    ? provider
                    : {
                        ...provider,
                        request: (r) =>
                          r.method === "eth_accounts"
                            ? Promise.resolve([])
                            : provider.request(r),
                      },
              },
            }),
          );
      };
      window.addEventListener("eip6963:requestProvider", announce);
      window.ethereum = provider;
      window.__validation = { state, emit, other };
      announce();
    },
    { owner: OWNER, other: A.receiver },
  );
}
const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 390, height: 844 },
});
const page = await context.newPage();
await routeRPC(page);
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
try {
  await page.goto(url);
  await expect(page.locator(".quick-stats")).toContainText("Round 1", {
    timeout: 60000,
  });
  await check(
    "Live verified deployment reads and primary action at 390",
    async () => {
      const box = await page
        .getByRole("button", { name: "Review freeze" })
        .boundingBox();
      assert(box && box.y + box.height <= 844);
      assert.equal(await page.title(), "MAD · Mutually Assured Destruction");
      await page.screenshot({ path: resolve(out, "390-home.png") });
    },
  );
  await check("Invalid freeze address is explained and focused", async () => {
    await page.getByRole("button", { name: "Review freeze" }).click();
    await expect(page.locator("#target-error")).toContainText(
      "nonzero Ethereum",
    );
    await expect(page.locator("#freeze-target")).toBeFocused();
  });
  await check(
    "Live wallet target balance zero remains an ineligible zero-cost freeze",
    async () => {
      await page.locator("#freeze-target").fill(OWNER);
      await expect(page.locator(".target-preview")).toContainText(
        "cost must be nonzero",
        { timeout: 30000 },
      );
      await expect(
        page.getByRole("button", { name: "Review freeze" }),
      ).toBeDisabled();
    },
  );
  await check("Live contract target is rejected", async () => {
    await page.locator("#freeze-target").fill(A.hook);
    await expect(page.locator(".target-preview")).toContainText(
      "Contracts cannot be targeted",
      { timeout: 30000 },
    );
  });
  await check(
    "Connect sheet keyboard focus, Escape and focus return",
    async () => {
      await page.locator(".wallet-control").click();
      await expect(page.getByRole("dialog")).toBeVisible();
      await page.keyboard.press("Tab");
      assert(
        await page.evaluate(() => !!document.activeElement.closest("dialog")),
      );
      await page.keyboard.press("Escape");
      await expect(page.getByRole("dialog")).toHaveCount(0);
      await expect(page.locator(".wallet-control")).toBeFocused();
    },
  );
  for (const width of [320, 390, 768, 1440]) {
    await page.setViewportSize({ width, height: 900 });
    for (const hash of [
      "freeze",
      "trade",
      "rounds",
      "activity",
      "protocol",
      "manage",
    ]) {
      await page.goto(url + "#" + hash);
      await expect(page.locator("h1")).toHaveText(
        {
          freeze: "Freeze a wallet.",
          trade: "Trade MAD with FWA.",
          rounds: "Spend MAD. Lead the round.",
          activity: "Activity, on Ethereum.",
          protocol: "The rules behind MAD.",
          manage: "Manage the live contracts.",
        }[hash],
      );
      await check(`${hash} reflows at ${width}`, async () => {
        const overflow = await page.evaluate(() =>
          document.documentElement.scrollWidth > innerWidth
            ? [...document.querySelectorAll("main *")]
                .filter((e) => e.getBoundingClientRect().right > innerWidth + 1)
                .map((e) => ({
                  tag: e.tagName,
                  cls: e.className,
                  right: e.getBoundingClientRect().right,
                  text: e.innerText?.slice(0, 100),
                }))
            : [],
        );
        assert.deepEqual(overflow, []);
      });
      if (width === 390) {
        await check(`${hash} accessibility scan`, async () => {
          const scan = await new AxeBuilder({ page })
            .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
            .analyze();
          assert.deepEqual(
            scan.violations.map((v) => ({
              id: v.id,
              nodes: v.nodes.map((n) => n.target),
            })),
            [],
          );
        });
      }
    }
  }
  await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(url + "#trade");
  await check(
    "Actual closed trading disables quotes without a liquidity pre-gate",
    async () => {
      await expect(page.locator("main")).toContainText("Trading is closed");
      await expect(page.locator("main")).not.toContainText(
        "no active liquidity",
      );
      await expect(
        page.getByRole("button", { name: "Get current quote" }),
      ).toBeDisabled();
      await page.getByRole("button", { name: "Sell MAD", exact: true }).click();
      await expect(page.locator("label[for=trade-amount]")).toContainText(
        "MAD",
      );
    },
  );
  await page.goto(url + "#rounds");
  await check(
    "Actual no-NFT and unfunded states prevent keeper writes",
    async () => {
      await expect(page.locator("main")).toContainText(
        "No kept NFT is available",
        { timeout: 30000 },
      );
      await expect(page.locator("main")).toContainText("NFT funding is below", {
        timeout: 30000,
      });
      await expect(
        page.getByRole("button", { name: "Review NFT acquisition" }),
      ).toBeDisabled();
      await page.locator("#request-id").fill("0");
      await page.getByRole("button", { name: "Inspect purchase" }).click();
      await expect(page.locator("main")).toContainText(
        "No purchase with this request ID",
        { timeout: 30000 },
      );
    },
  );
  await page.goto(url + "#activity");
  await check("Verified event history and filters", async () => {
    await expect(page.locator("main")).toContainText("Token bound to hook", {
      timeout: 30000,
    });
    await page.locator("#event-filter").selectOption("freezes");
    await expect(page.locator("main")).toContainText("No matching events");
  });
  await page.goto(url + "#manage");
  await check("Disconnected visitors have no management fields", async () => {
    await expect(page.locator("main")).toContainText(
      "Connect the current owner wallet",
      { timeout: 30000 },
    );
    assert.equal(await page.locator("main input").count(), 0);
  });
  await check("No uncaught application exceptions", async () =>
    assert.deepEqual(errors, []),
  );
  // All following writes are mocked wallet sends against isolated browser fixture state.
  fixture.on = true;
  const walletContext = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
  });
  const w = await walletContext.newPage();
  await routeRPC(w);
  await walletInit(w);
  await w.goto(url);
  await expect(w.locator(".quick-stats")).toContainText("Round 1", {
    timeout: 30000,
  });
  await check(
    "EIP-6963 names both discovered wallets and hides generic row",
    async () => {
      await w.locator(".wallet-control").click();
      await expect(
        w.getByRole("button", { name: "Validation wallet", exact: true }),
      ).toBeVisible();
      await expect(
        w.getByRole("button", {
          name: "Second validation wallet",
          exact: true,
        }),
      ).toBeVisible();
      assert.equal(
        await w
          .getByRole("button", { name: "Browser wallet", exact: true })
          .count(),
        0,
      );
    },
  );
  await check("Wallet connection rejection is recoverable", async () => {
    await w.evaluate(() => (window.__validation.state.rejectConnect = true));
    await w
      .getByRole("button", { name: "Validation wallet", exact: true })
      .click();
    await expect(w.getByRole("dialog")).toContainText("rejected");
    await w.evaluate(() => (window.__validation.state.rejectConnect = false));
    await w
      .getByRole("button", { name: "Validation wallet", exact: true })
      .click();
    await expect(w.getByRole("dialog")).toHaveCount(0);
  });
  await check(
    "Wrong network gates writes and switch uses wallet request",
    async () => {
      await w.evaluate(() => {
        window.__validation.state.chain = "0x2105";
        window.__validation.emit("chainChanged", "0x2105");
      });
      await expect(w.locator(".wallet-control")).toContainText(
        "Switch to Ethereum",
      );
      await expect(w.locator("main")).toContainText("writes are disabled");
      await expect(
        w.getByRole("button", { name: "Review freeze" }),
      ).toBeDisabled();
      await w.locator(".wallet-control").click();
      await expect(w.locator(".wallet-control")).toContainText("0xFc3C");
      assert(
        await w.evaluate(() =>
          window.__validation.state.methods.includes(
            "wallet_switchEthereumChain",
          ),
        ),
      );
    },
  );
  await w.goto(url + "#manage");
  await check(
    "Actual owner permissions reveal supported setting controls",
    async () => {
      await expect(w.locator("#admin-action")).toBeVisible({ timeout: 30000 });
      assert.equal(await w.locator("#admin-action option").count(), 6);
    },
  );
  await w.selectOption("#admin-action", "setAcquisitionBounds");
  await w.fill("#admin-margin", "0");
  await w.fill("#admin-slippage", "100");
  await check(
    "Owner action simulates and requires explicit wallet confirmation",
    async () => {
      await w.getByRole("button", { name: "Review change" }).click();
      await expect(w.getByRole("dialog")).toContainText("Simulation passed", {
        timeout: 30000,
      });
      assert.equal(fixture.sent.length, 0);
      await expect(w.getByRole("dialog")).toContainText("setAcquisitionBounds");
    },
  );
  await check(
    "Account change invalidates an existing management review",
    async () => {
      await w.evaluate(() => {
        window.__validation.state.account = window.__validation.other;
        window.__validation.emit("accountsChanged", [
          window.__validation.other,
        ]);
      });
      await expect(w.getByRole("dialog")).toContainText(
        "Wallet or network changed",
      );
      assert.equal(await w.locator("#admin-action").count(), 0);
      await w.getByRole("button", { name: "Close", exact: true }).click();
      await w.evaluate((owner) => {
        window.__validation.state.account = owner;
        window.__validation.emit("accountsChanged", [owner]);
      }, OWNER);
    },
  );
  await w.goto(url + "#freeze");
  await w.fill("#freeze-target", TARGET);
  await expect(w.locator(".target-preview")).toContainText("10 MAD", {
    timeout: 30000,
  });
  await check(
    "Freeze review presents exact cost and both payment destinations",
    async () => {
      await w.getByRole("button", { name: "Review freeze" }).click();
      await expect(w.getByRole("dialog")).toContainText("Simulation passed", {
        timeout: 30000,
      });
      await expect(w.getByRole("dialog")).toContainText("10 MAD");
      await expect(w.getByRole("dialog")).toContainText("5 MAD");
      await expect(w.getByRole("dialog")).toContainText(
        "no maximum-cost parameter",
      );
    },
  );
  await check("Rejected wallet transaction sends nothing", async () => {
    await w.getByRole("button", { name: "Confirm in wallet" }).click();
    await expect(w.getByRole("dialog")).toContainText(
      "Wallet request rejected",
      { timeout: 30000 },
    );
    assert.equal(fixture.sent.length, 0);
    await w.getByRole("button", { name: "Close", exact: true }).click();
  });
  await check(
    "Confirmed fixture freeze sends once and refreshes wallet state",
    async () => {
      await w.evaluate(() => (window.__validation.state.mode = "success"));
      await w.getByRole("button", { name: "Review freeze" }).click();
      await expect(w.getByRole("dialog")).toContainText("Simulation passed", {
        timeout: 30000,
      });
      await w.getByRole("button", { name: "Confirm in wallet" }).dblclick();
      await expect(w.getByRole("dialog")).toContainText(
        "Transaction confirmed",
        { timeout: 30000 },
      );
      assert.equal(fixture.sent.length, 1);
      await w.getByRole("button", { name: "Close", exact: true }).click();
      await expect(w.locator(".wallet-section")).toContainText("9,990 MAD", {
        timeout: 30000,
      });
      await expect(w.locator(".wallet-section")).toContainText("10 MAD");
    },
  );
  await w.goto(url + "#trade");
  await w.fill("#trade-amount", "100");
  await check("Quote requires selected slippage and deadline", async () => {
    await w.getByRole("button", { name: "Get current quote" }).click();
    await expect(w.locator("main")).toContainText(
      "Choose a slippage tolerance",
    );
    await w.selectOption("#slippage", "100");
    await w.getByRole("button", { name: "Get current quote" }).click();
    await expect(w.locator("main")).toContainText(
      "Choose a transaction deadline",
    );
    await w.selectOption("#deadline", "5");
    await w.getByRole("button", { name: "Get current quote" }).click();
    await expect(
      w.getByRole("button", { name: "Review FWA approval" }),
    ).toBeVisible({ timeout: 30000 });
  });
  async function confirmAction(name) {
    await w.getByRole("button", { name, exact: true }).click();
    await expect(w.getByRole("dialog")).toContainText("Simulation passed", {
      timeout: 30000,
    });
    await w.getByRole("button", { name: "Confirm in wallet" }).click();
    await expect(w.getByRole("dialog")).toContainText("Transaction confirmed", {
      timeout: 30000,
    });
    await w.getByRole("button", { name: "Close", exact: true }).click();
  }
  await check(
    "Exact ERC20 approval and refreshed quote after confirmation",
    async () => {
      await confirmAction("Review FWA approval");
      assert.equal(fixture.erc20, 100n * 10n ** 18n);
      assert.equal(await w.locator(".quote").count(), 0);
      await w.getByRole("button", { name: "Get current quote" }).click();
      await expect(
        w.getByRole("button", { name: "Review router permission" }),
      ).toBeVisible({ timeout: 30000 });
    },
  );
  await check(
    "Exact expiring Permit2 approval and nonzero swap minimum",
    async () => {
      await confirmAction("Review router permission");
      assert.equal(fixture.permit, 100n * 10n ** 18n);
      assert(BigInt(fixture.expiration) > BigInt(block.timestamp));
      await w.getByRole("button", { name: "Get current quote" }).click();
      await expect(w.getByRole("button", { name: "Review buy" })).toBeVisible({
        timeout: 30000,
      });
      await w.getByRole("button", { name: "Review buy" }).click();
      await expect(w.getByRole("dialog")).toContainText("Simulation passed", {
        timeout: 30000,
      });
      await expect(w.getByRole("dialog")).toContainText("Minimum output");
      await expect(w.getByRole("dialog")).toContainText(A.router);
      await w.getByRole("button", { name: "Confirm in wallet" }).click();
      await expect(w.getByRole("dialog")).toContainText(
        "Transaction confirmed",
        { timeout: 30000 },
      );
      await w.getByRole("button", { name: "Close", exact: true }).click();
      assert.equal(fixture.sent.length, 4);
    },
  );
  await check("30-second quote expiry disables sending", async () => {
    await w.getByRole("button", { name: "Get current quote" }).click();
    await expect(w.locator(".quote")).toBeVisible({ timeout: 30000 });
    await w.clock.install();
    await w.clock.fastForward(31000);
    await expect(w.locator(".quote")).toContainText("Expired");
    const primary = w.locator(".quote button.primary");
    await expect(primary).toBeDisabled();
    await w.clock.resume();
  });
  await check(
    "Zero in-range liquidity still quotes; a Quoter revert reads as insufficient liquidity",
    async () => {
      fixture.liquidity = 0n;
      await w.getByRole("button", { name: "Get current quote" }).click();
      await expect(w.locator(".quote")).toContainText("Minimum output", {
        timeout: 30000,
      });
      fixture.quoterReverts = true;
      await w.getByRole("button", { name: "Get current quote" }).click();
      await expect(w.locator("main")).toContainText(
        "Not enough liquidity in the pool for this amount.",
        { timeout: 30000 },
      );
      assert.equal(await w.locator(".quote").count(), 0);
      fixture.quoterReverts = false;
      fixture.liquidity = 10n ** 28n;
    },
  );

  await w.goto(url + "#freeze");
  await w.fill("#freeze-target", TARGET);
  await check(
    "Pending receipt persists across reload and prevents duplicate sends",
    async () => {
      fixture.hold = true;
      const count = fixture.sent.length;
      await expect(w.locator(".target-preview")).toContainText("MAD", {
        timeout: 30000,
      });
      await w.getByRole("button", { name: "Review freeze" }).click();
      await expect(w.getByRole("dialog")).toContainText("Simulation passed", {
        timeout: 30000,
      });
      await w.getByRole("button", { name: "Confirm in wallet" }).click();
      await expect(w.getByRole("dialog")).toContainText(
        "Waiting for a confirmed receipt",
        { timeout: 30000 },
      );
      assert.equal(fixture.sent.length, count + 1);
      await expect(w.locator("main button.primary")).toBeDisabled();
      await w.getByRole("button", { name: "Close dialog" }).click();
      await expect(w.locator(".transaction-banner")).toContainText(
        "still being tracked",
      );
      await w.reload();
      await expect(w.getByRole("dialog")).toContainText(
        "Waiting for a confirmed receipt",
        { timeout: 30000 },
      );
      assert.equal(fixture.sent.length, count + 1);
      fixture.hold = false;
      fixture.height += 1n;
      await expect(w.getByRole("dialog")).toContainText(
        "Transaction confirmed",
        { timeout: 30000 },
      );
      await w.getByRole("button", { name: "Close", exact: true }).click();
    },
  );
  await w.evaluate(() => (window.__validation.state.mode = "success"));
  await w.fill("#freeze-target", TARGET);
  await check(
    "A confirmed transaction with substituted calldata is not reported as the reviewed action",
    async () => {
      await expect(w.locator(".target-preview")).toContainText("MAD", {
        timeout: 30000,
      });
      fixture.changedTransaction = true;
      await w.getByRole("button", { name: "Review freeze" }).click();
      await expect(w.getByRole("dialog")).toContainText("Simulation passed", {
        timeout: 30000,
      });
      await w.getByRole("button", { name: "Confirm in wallet" }).click();
      await expect(w.getByRole("dialog")).toContainText(
        "replaced by a different action",
        { timeout: 30000 },
      );
      assert.equal(
        await w.getByText("Transaction confirmed", { exact: true }).count(),
        0,
      );
      await w.getByRole("button", { name: "Close", exact: true }).click();
      fixture.changedTransaction = false;
    },
  );
  await check("Disconnect removes management access", async () => {
    await w.locator(".wallet-control").click();
    await w.getByRole("button", { name: "Disconnect wallet" }).click();
    await expect(w.locator(".wallet-control")).toHaveText("Connect");
    await w.goto(url + "#manage");
    await expect(w.locator("main")).toContainText(
      "Connect the current owner wallet",
      { timeout: 30000 },
    );
    assert.equal(await w.locator("#admin-action").count(), 0);
  });
  await walletContext.close();
  const mobile = await browser.newContext({
    viewport: { width: 390, height: 844 },
    userAgent:
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1",
  });
  const m = await mobile.newPage();
  await routeRPC(m);
  await m.goto(url);
  await check(
    "Phone sheet includes four wallet-browser links and Coinbase Smart Wallet",
    async () => {
      await m.locator(".wallet-control").click();
      for (const name of ["MetaMask", "Coinbase Wallet", "Rabby", "Phantom"])
        await expect(
          m.getByRole("link", { name: "Open in " + name }),
        ).toBeVisible();
      await expect(
        m.getByRole("button", { name: "Coinbase Smart Wallet" }),
      ).toBeVisible();
      await m.screenshot({ path: resolve(out, "390-mobile-wallets.png") });
    },
  );
  await mobile.close();
  await check("RPC failure is unavailable, never a zero position", async () => {
    const failure = await browser.newContext();
    const p = await failure.newPage();
    await p.route(
      /https:\/\/(ethereum-rpc\.publicnode\.com|eth\.drpc\.org)\/?$/,
      (r) =>
        r.fulfill({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({
            jsonrpc: "2.0",
            id: r.request().postDataJSON().id,
            error: { code: -32000, message: "Intentional validation outage" },
          }),
        }),
    );
    await p.goto(url);
    await expect(p.locator("main")).toContainText(
      "Live contract state unavailable",
      { timeout: 60000 },
    );
    await expect(p.locator(".round-strip")).toContainText("Unavailable");
    await failure.close();
  });
  // WebKit is optional on machines without its system libraries; retain the actual launch result.
  try {
    const safari = await webkit.launch();
    const p = await safari.newPage({ viewport: { width: 390, height: 844 } });
    await routeRPC(p);
    await p.goto(url);
    await check("WebKit primary interaction and reflow", async () => {
      await p.getByRole("button", { name: "Review freeze" }).click();
      await expect(p.locator("#target-error")).toContainText(
        "nonzero Ethereum",
      );
      assert.equal(
        await p.evaluate(
          () => document.documentElement.scrollWidth > innerWidth,
        ),
        false,
      );
    });
    await safari.close();
  } catch (e) {
    results.push({
      name: "WebKit launch",
      passed: null,
      limitation: e.message.slice(0, 1800),
    });
    console.log("LIMITATION WebKit system libraries unavailable");
  }
} finally {
  await browser.close();
  await new Promise((r) => server.close(r));
  await writeFile(
    resolve(out, "results.json"),
    JSON.stringify(
      { results, rpcCalls, realTransactionsBroadcast: 0 },
      null,
      2,
    ),
  );
}
console.log(
  `${results.filter((r) => r.passed === true).length} checks passed; ${failures.length} failed. Report: test/scratch/website-tests/results.json`,
);
if (failures.length) process.exitCode = 1;
