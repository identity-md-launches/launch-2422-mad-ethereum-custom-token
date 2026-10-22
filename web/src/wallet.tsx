import { useEffect, useState } from "react";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { Modal, Icon, Notice } from "./components";
import { short, message } from "./format";
import { chain, PUBLIC_RPCS } from "./chain";
const mobileLinks = [
  {
    id: "metamask",
    name: "MetaMask",
    href: (url: string) =>
      `https://link.metamask.io/dapp/${url.replace(/^https?:\/\//, "")}`,
  },
  {
    id: "coinbase",
    name: "Coinbase Wallet",
    href: (url: string) =>
      `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(url)}`,
  },
  {
    id: "rabby",
    name: "Rabby",
    href: (url: string) =>
      `https://go.rabby.io/mobile/dapp?url=${encodeURIComponent(url)}`,
  },
  {
    id: "phantom",
    name: "Phantom",
    href: (url: string) =>
      `https://phantom.app/ul/browse/${encodeURIComponent(url)}?ref=${encodeURIComponent(new URL(url).origin)}`,
  },
];
export function WalletControl() {
  const { address, isConnected, chainId, connector } = useAccount();
  const { connectAsync, connectors, isPending, variables } = useConnect();
  const { disconnectAsync, isPending: disconnecting } = useDisconnect();
  const { switchChainAsync, isPending: switching } = useSwitchChain();
  const [open, setOpen] = useState(false);
  const [error, setError] = useState("");
  const mobile =
    /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) &&
    !connectors.some((c) => c.type === "injected" && c.id !== "injected") &&
    !(window as Window & { ethereum?: unknown }).ethereum;
  useEffect(() => {
    setOpen(false);
    setError("");
  }, [address]);
  const named = connectors.some(
    (c) => c.type === "injected" && c.id !== "injected",
  );
  const listed = [
    ...connectors.filter((c) => c.type === "injected"),
    ...connectors.filter((c) => c.type !== "injected"),
  ].filter(
    (c) =>
      !(c.id === "injected" && named) && (!mobile || c.type !== "injected"),
  );
  async function switchNetwork() {
    setError("");
    try {
      await switchChainAsync({ chainId: 1 });
    } catch (e) {
      let cause: unknown = e;
      let unknownChain = false;
      for (
        let depth = 0;
        cause && typeof cause === "object" && depth < 6;
        depth++
      ) {
        const item = cause as { code?: number; cause?: unknown };
        if (item.code === 4902) unknownChain = true;
        cause = item.cause;
      }
      if (!unknownChain) {
        setError(message(e));
        setOpen(true);
        return;
      }
      try {
        const p = (await connector?.getProvider()) as
          { request: (r: unknown) => Promise<unknown> } | undefined;
        if (!p) throw e;
        await p.request({
          method: "wallet_addEthereumChain",
          params: [
            {
              chainId: "0x1",
              chainName: "Ethereum",
              rpcUrls: [...PUBLIC_RPCS],
              nativeCurrency: chain.nativeCurrency,
              blockExplorerUrls: ["https://etherscan.io"],
            },
          ],
        });
        await p.request({
          method: "wallet_switchEthereumChain",
          params: [{ chainId: "0x1" }],
        });
      } catch (err) {
        setError(message(err));
        setOpen(true);
      }
    }
  }
  return (
    <>
      <button
        className="wallet-control"
        onClick={() =>
          isConnected && chainId !== 1 ? switchNetwork() : setOpen(true)
        }
      >
        <Icon name="wallet" size={18} />
        <span>
          {isConnected && address
            ? chainId !== 1
              ? switching
                ? "Switching…"
                : "Switch to Ethereum"
              : short(address)
            : "Connect"}
        </span>
      </button>
      {open && (
        <Modal
          title={isConnected ? "Connected wallet" : "Connect a wallet"}
          onClose={() => setOpen(false)}
        >
          {isConnected && address ? (
            <>
              <p className="muted">
                {connector?.name} ·{" "}
                {chainId === 1 ? "Ethereum" : "Wrong network"}
              </p>
              <p className="address full">{address}</p>
              {chainId !== 1 && (
                <button onClick={switchNetwork}>Switch to Ethereum</button>
              )}
              <button
                className="wallet-row"
                disabled={disconnecting}
                onClick={async () => {
                  await disconnectAsync();
                  setOpen(false);
                }}
              >
                Disconnect wallet
                <Icon name="arrow" />
              </button>
            </>
          ) : (
            <>
              <p className="muted">
                Browse freely. Each transaction requires your approval.
              </p>
              {mobile &&
                mobileLinks.map((w) => (
                  <a
                    className="wallet-row"
                    key={w.id}
                    href={w.href(location.href)}
                  >
                    <img
                      src={`./wallets/${w.id}.svg`}
                      width="28"
                      height="28"
                      alt=""
                    />
                    Open in {w.name}
                    <Icon name="external" size={16} />
                  </a>
                ))}
              {listed.map((c) => (
                <button
                  key={c.uid}
                  className="wallet-row"
                  disabled={isPending}
                  onClick={async () => {
                    setError("");
                    try {
                      await connectAsync({ connector: c, chainId: 1 });
                      setOpen(false);
                    } catch (e) {
                      setError(message(e));
                    }
                  }}
                >
                  {c.icon ? (
                    <img src={c.icon} width="28" height="28" alt="" />
                  ) : c.id === "coinbaseWalletSDK" ? (
                    <img
                      src="./wallets/coinbase.svg"
                      width="28"
                      height="28"
                      alt=""
                    />
                  ) : (
                    <Icon name="wallet" size={28} />
                  )}
                  <span>
                    {c.id === "injected"
                      ? "Browser wallet"
                      : c.id === "coinbaseWalletSDK"
                        ? mobile
                          ? "Coinbase Smart Wallet"
                          : "Coinbase Wallet"
                        : c.name}
                    {isPending && variables?.connector === c
                      ? " · Opening…"
                      : ""}
                  </span>
                </button>
              ))}
            </>
          )}
          {error && <Notice kind="error">{error}</Notice>}
        </Modal>
      )}
    </>
  );
}
