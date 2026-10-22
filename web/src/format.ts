import { formatUnits, isAddress, parseUnits, zeroAddress } from "viem";
export const short = (value: string) =>
  `${value.slice(0, 6)}…${value.slice(-4)}`;
export function amount(
  value: bigint | undefined | null,
  symbol = "",
  precision = 4,
): string {
  if (value === undefined || value === null) return "Unavailable";
  const raw = formatUnits(value, 18);
  const [whole, fraction = ""] = raw.split(".");
  const digits = fraction.slice(0, precision).replace(/0+$/, "");
  const number = `${BigInt(whole).toLocaleString("en-US")}${digits ? `.${digits}` : ""}`;
  return `${value > 0n && BigInt(whole) === 0n && !digits ? `<0.${"0".repeat(precision - 1)}1` : number}${symbol ? ` ${symbol}` : ""}`;
}
export const exact = (value: bigint, symbol = "") =>
  `${formatUnits(value, 18)}${symbol ? ` ${symbol}` : ""}`;
export const validAddress = (s: string) =>
  isAddress(s, { strict: false }) && s.toLowerCase() !== zeroAddress;
export function units(value: string) {
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,18})?$/.test(value.trim()))
    throw new Error("Enter a positive amount with at most 18 decimal places.");
  const n = parseUnits(value.trim(), 18);
  if (n <= 0n || n > (1n << 127n) - 1n)
    throw new Error(
      "Enter a positive amount within the pool’s supported range.",
    );
  return n;
}
export function integer(value: string, label: string, max = (1n << 256n) - 1n) {
  if (!/^\d+$/.test(value))
    throw new Error(`Enter ${label} as a whole number.`);
  const n = BigInt(value);
  if (n > max) throw new Error(`${label} is too large.`);
  return n;
}
export const dateTime = (seconds: bigint | number) =>
  new Date(Number(seconds) * 1000).toLocaleString(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  });
export function message(error: unknown): string {
  if (error && typeof error === "object") {
    const e = error as {
      shortMessage?: string;
      message?: string;
      details?: string;
      cause?: unknown;
    };
    const text = e.shortMessage || e.message || "";
    if (/reject|denied|4001/i.test(text))
      return "Wallet request rejected. Nothing was submitted.";
    return (
      (
        text + (e.details && !text.includes(e.details) ? ` ${e.details}` : "")
      ).slice(0, 550) ||
      "The request failed. Refresh the page state and try again."
    );
  }
  return "The request failed. Refresh the page state and try again.";
}
export const json = (x: unknown) =>
  JSON.stringify(x, (_, v) => (typeof v === "bigint" ? v.toString() : v));
