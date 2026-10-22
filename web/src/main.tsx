import React, { useEffect, useState } from "react";
import ReactDOM from "react-dom/client";
import { WagmiProvider, useAccount } from "wagmi";
import {
  QueryClient,
  QueryClientProvider,
  useQuery,
} from "@tanstack/react-query";
import { config, snapshot } from "./chain";
import { WalletControl } from "./wallet";
import { Transactions } from "./transactions";
import { Icon, Notice } from "./components";
import { Freeze } from "./Freeze";
import { Trade } from "./Trade";
import { Rounds } from "./Rounds";
import { Activity } from "./Activity";
import { Protocol } from "./Protocol";
import { Manage } from "./Manage";
import { message } from "./format";
import "./styles.css";
const queryClient = new QueryClient({
  defaultOptions: {
    queries: { retry: 1, staleTime: 12000, refetchOnWindowFocus: true },
  },
});
const pages = [
  ["freeze", "Freeze"],
  ["trade", "Trade"],
  ["rounds", "NFT rounds"],
  ["activity", "Activity"],
  ["protocol", "How it works"],
  ["manage", "Manage"],
] as const;
function App() {
  const [route, setRoute] = useState(
    pages.some(([p]) => p === location.hash.slice(1))
      ? location.hash.slice(1)
      : "freeze",
  );
  const [refreshKey, setRefreshKey] = useState(0);
  const { address, chainId } = useAccount();
  const data = useQuery({
    queryKey: ["snapshot", address, refreshKey],
    queryFn: () => snapshot(address),
    refetchInterval: 30000,
    retry: 1,
  });
  useEffect(() => {
    function navigate() {
      const next = location.hash.slice(1) || "freeze";
      setRoute(pages.some(([p]) => p === next) ? next : "freeze");
      window.scrollTo(0, 0);
      requestAnimationFrame(() =>
        document.getElementById("main-content")?.focus(),
      );
    }
    window.addEventListener("hashchange", navigate);
    return () => window.removeEventListener("hashchange", navigate);
  }, []);
  function refresh() {
    setRefreshKey((k) => k + 1);
    void queryClient.invalidateQueries();
  }
  const state = data.data;
  const stale =
    !!state && (data.isError || Date.now() - state.updatedAt > 90000);
  const current = !data.isError && !stale ? state : undefined;
  const props = { state: current, refreshKey };
  return (
    <Transactions onSuccess={refresh}>
      <a
        className="skip-link"
        href="#main-content"
        onClick={(e) => {
          e.preventDefault();
          document.getElementById("main-content")?.focus();
        }}
      >
        Skip to content
      </a>
      <div className="app-shell">
        <aside className="sidebar">
          <a className="brand" href="#freeze" aria-label="MAD home">
            <span className="brand-mark">
              <Icon name="freeze" size={29} />
            </span>
            <strong>
              MAD<span className="brand-period">.</span>
            </strong>
          </a>
          <p className="brand-description">
            Mutually Assured
            <br />
            Destruction
          </p>
          <nav aria-label="Primary navigation">
            {pages.map(([key, label]) => (
              <a
                key={key}
                href={`#${key}`}
                aria-current={route === key ? "page" : undefined}
              >
                <Icon name={key} />
                <span>{label}</span>
                {route === key && <Icon name="arrow" size={16} />}
              </a>
            ))}
          </nav>
          <div className="sidebar-bottom">
            <span className="network-dot" />
            Ethereum mainnet
            <p>
              A token game.
              <br />
              Real consequences.
            </p>
            <a
              href="https://etherscan.io/token/0x1e1878c58c2da2645eb494e152fa708067e18c5e"
              target="_blank"
              rel="noreferrer"
            >
              MAD on Etherscan
              <Icon name="external" size={14} />
            </a>
          </div>
        </aside>
        <div className="main-shell">
          <header className="topbar">
            <a href="#freeze" className="mobile-brand" aria-label="MAD home">
              <Icon name="freeze" size={24} />
              <strong>MAD.</strong>
            </a>
            <div className="chain-status">
              <span className="network-dot" />
              <span>
                Ethereum<span className="desktop-only"> mainnet</span>
              </span>
              <span className="caption block-number">
                {data.isError
                  ? "RPC unavailable"
                  : data.isPending
                    ? "Reading chain…"
                    : stale
                      ? "Stale data"
                      : `Block ${state?.block.toLocaleString()}`}
              </span>
            </div>
            <div className="topbar-actions">
              <button
                className="icon-button"
                aria-label="Refresh live contract state"
                disabled={data.isFetching}
                onClick={refresh}
              >
                <Icon name="refresh" size={18} />
              </button>
              <WalletControl />
            </div>
          </header>
          <nav className="mobile-nav" aria-label="Mobile navigation">
            {pages.map(([key, label]) => (
              <a
                key={key}
                href={`#${key}`}
                aria-current={route === key ? "page" : undefined}
              >
                {label}
              </a>
            ))}
          </nav>
          <main id="main-content" tabIndex={-1}>
            <div className="status-region" aria-live="polite">
              {address && chainId !== 1 && (
                <Notice kind="error">
                  Your wallet is on a different network. Use “Switch to
                  Ethereum” above. Public Ethereum data remains available;
                  writes are disabled.
                </Notice>
              )}
              {data.isError && (
                <Notice kind="error">
                  Live contract state unavailable. {message(data.error)}
                  {state && (
                    <span>
                      {" "}
                      The previous snapshot from block {state.block.toString()}{" "}
                      is stale and is not used for actions.
                    </span>
                  )}
                  <button onClick={refresh}>Retry live reads</button>
                </Notice>
              )}
              {stale && !data.isError && (
                <Notice>
                  Contract state is stale. Refresh to continue.
                  <button onClick={refresh}>Refresh</button>
                </Notice>
              )}
            </div>
            {route === "freeze" ? (
              <Freeze {...props} />
            ) : route === "trade" ? (
              <Trade {...props} />
            ) : route === "rounds" ? (
              <Rounds {...props} />
            ) : route === "activity" ? (
              <Activity refreshKey={refreshKey} />
            ) : route === "protocol" ? (
              <Protocol {...props} />
            ) : (
              <Manage {...props} />
            )}
          </main>
          <footer>
            <span>Mutually Assured Destruction</span>
            <div>
              <span>Ethereum · 18 decimals</span>
              <a href="#protocol">
                Rules & risks
                <Icon name="arrow" size={14} />
              </a>
            </div>
          </footer>
        </div>
      </div>
    </Transactions>
  );
}
class Boundary extends React.Component<
  { children: React.ReactNode },
  { error: boolean }
> {
  state = { error: false };
  static getDerivedStateFromError() {
    return { error: true };
  }
  render() {
    return this.state.error ? (
      <main className="fatal">
        <h1>Unable to load the interface</h1>
        <p>Reload to retry. No transaction is sent by this message.</p>
        <button onClick={() => location.reload()}>Reload</button>
      </main>
    ) : (
      this.props.children
    );
  }
}
ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <Boundary>
      <WagmiProvider config={config}>
        <QueryClientProvider client={queryClient}>
          <App />
        </QueryClientProvider>
      </WagmiProvider>
    </Boundary>
  </React.StrictMode>,
);
