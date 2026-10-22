import { useEffect, useRef, type ReactNode } from "react";
import { short } from "./format";
export function Icon({ name, size = 20 }: { name: string; size?: number }) {
  const paths: Record<string, ReactNode> = {
    freeze: (
      <>
        <path d="M12 2v20M3.34 7l17.32 10M3.34 17 20.66 7M8 4l4 4 4-4M8 20l4-4 4 4M3 11l5-1-1-5M21 13l-5 1 1 5M3 13l5 1-1 5M21 11l-5-1 1-5" />
      </>
    ),
    trade: (
      <>
        <path d="M4 7h16l-4-4M20 17H4l4 4" />
      </>
    ),
    rounds: (
      <>
        <path d="M8 3h8v7a4 4 0 0 1-8 0V3ZM8 5H4v3a4 4 0 0 0 4 4m8-7h4v3a4 4 0 0 1-4 4m-4 2v6m-4 1h8" />
      </>
    ),
    activity: (
      <>
        <path d="M3 12h4l3-8 4 16 3-8h4" />
      </>
    ),
    protocol: (
      <>
        <circle cx="12" cy="12" r="9" />
        <path d="M12 11v6m0-11v1" />
      </>
    ),
    manage: (
      <>
        <path d="M4 7h16M4 17h16M9 4v6m6 4v6" />
      </>
    ),
    arrow: <path d="M5 12h14m-6-6 6 6-6 6" />,
    external: (
      <>
        <path d="M14 4h6v6m0-6L10 14M10 4H4v16h16v-6" />
      </>
    ),
    refresh: (
      <>
        <path d="M20 7v5h-5M4 17v-5h5" />
        <path d="M6 6a8 8 0 0 1 13 2M5 16a8 8 0 0 0 13 2" />
      </>
    ),
    wallet: (
      <>
        <path d="M3 6h17v15H3V6Zm0 0V3h14v3m-2 6h5v5h-5v-5Z" />
      </>
    ),
    check: <path d="m5 12 4 4L19 6" />,
    clock: (
      <>
        <circle cx="12" cy="12" r="9" />
        <path d="M12 6v6l4 2" />
      </>
    ),
    close: <path d="m6 6 12 12M6 18 18 6" />,
  };
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {paths[name] || paths.arrow}
    </svg>
  );
}
export function Modal({
  title,
  children,
  onClose,
}: {
  title: string;
  children: ReactNode;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const prev = document.activeElement as HTMLElement;
    ref.current?.showModal();
    return () => {
      ref.current?.close();
      prev?.focus?.();
    };
  }, []);
  return (
    <dialog
      ref={ref}
      className="modal"
      aria-label={title}
      onCancel={onClose}
      onClose={onClose}
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="modal-inner">
        <div className="section-head">
          <h2>{title}</h2>
          <button
            className="icon-button"
            aria-label="Close dialog"
            onClick={onClose}
          >
            <Icon name="close" />
          </button>
        </div>
        {children}
      </div>
    </dialog>
  );
}
export function AddressLink({
  address,
  full = false,
  label,
}: {
  address: string;
  full?: boolean;
  label?: string;
}) {
  return (
    <a
      className={full ? "address full" : "address"}
      href={`https://etherscan.io/address/${address}`}
      target="_blank"
      rel="noreferrer"
      title={address}
    >
      {label || (full ? address : short(address))}
      <Icon name="external" size={14} />
    </a>
  );
}
export const TxLink = ({ hash }: { hash: string }) => (
  <a
    className="address"
    href={`https://etherscan.io/tx/${hash}`}
    target="_blank"
    rel="noreferrer"
  >
    {short(hash)}
    <Icon name="external" size={14} />
  </a>
);
export const Notice = ({
  children,
  kind = "info",
}: {
  children: ReactNode;
  kind?: "info" | "error" | "success";
}) => (
  <div
    className={`notice ${kind}`}
    role={kind === "error" ? "alert" : undefined}
  >
    {children}
  </div>
);
export const Metric = ({
  label,
  value,
  sub,
}: {
  label: string;
  value: ReactNode;
  sub?: ReactNode;
}) => (
  <div className="metric">
    <span className="muted">{label}</span>
    <strong>{value}</strong>
    {sub && <span className="caption">{sub}</span>}
  </div>
);
export const PageTitle = ({
  title,
  children,
}: {
  title: string;
  children?: ReactNode;
}) => (
  <div className="page-title">
    <h1>{title}</h1>
    {children && <p>{children}</p>}
  </div>
);
export const Empty = ({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) => (
  <div className="empty">
    <Icon name="clock" size={28} />
    <h3>{title}</h3>
    <p>{children}</p>
  </div>
);
