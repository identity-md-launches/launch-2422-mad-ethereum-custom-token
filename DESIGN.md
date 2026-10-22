# MAD interface design

## Overview

The website is a working Ethereum interface for Mutually Assured Destruction: freezing wallets, trading MAD/FWA, following NFT rounds and running supported keeper or owner actions. Its main visual idea is a restrained control room: cool backgrounds, dark navigation and one orange freeze action beside a snowflake diagram. The tool appears before the explanatory material.

The implemented source is `web/src/`. `styles.css` defines the shared visual system; `components.tsx` supplies small reusable components. There is one light theme. No font or image service is required for the interface.

## Colors

The semantic custom properties in `web/src/styles.css:1` are the source of truth.

| Token | Value | Role |
| --- | --- | --- |
| `--color-page` | `#edf2f5` | Page background |
| `--color-surface` | `#fffefa` | Forms, panels and dialogs |
| `--color-ink` | `#1d2b33` | Primary text and neutral filled controls |
| `--color-muted` | `#536570` | Descriptions, labels and secondary data |
| `--color-line` | `#c9d3da` | Structural dividers and input boundaries |
| `--color-accent` | `#f57b51` | Primary action fill and decorative freeze illustration |
| `--color-accent-hover` | `#f8906d` | Primary hover/pressed fill |
| `--color-accent-ink` | `#29190f` | Text and illustration strokes on orange |
| `--color-sidebar` | `#182a34` | Desktop navigation background |
| `--color-sidebar-ink` | `#e2eaf0` | Strong navigation text |
| `--color-sidebar-muted` | `#b1c3ce` | Secondary navigation text |
| `--color-sidebar-active` | `#2c414d` | Active/hover navigation fill |
| `--color-info` | `#e3edf4` | Informational messages and pending banner |
| `--color-error` / `--color-error-bg` | `#8e301f` / `#fce9e2` | Errors and irreversible-action warnings |
| `--color-success` / `--color-success-bg` | `#236044` / `#e2f1e7` | Confirmation messages |
| `--color-focus` | `#285f9a` | Keyboard focus outline |

Status always includes text. Orange on the snowflake is decorative; orange filled controls identify the main action. The pinned contrast probe and route accessibility scans measured the rendered text pairs; see `artifacts/validation.md` for coverage and limits.

## Typography

The body stack is `Arial, Helvetica, sans-serif`; there are no downloadable fonts. Actual fallback rendering depends on the device. CSS requests weights 400 and 600, with synthesis disabled. Addresses and function data use `ui-monospace, SFMono-Regular, Consolas, monospace`, never long prose.

The roles are 14px secondary text/buttons, 16px body/forms, 20px section headings and main metrics, 28px preview amounts/mobile brand, and a responsive page heading: 44px normally, 36px at 900px and below, 32px at 720px and below. At a given reviewed width, five or fewer sizes are used. Body line-height is 1.55; headings are 1.2. Display tracking is slightly negative; body tracking is natural. Headings balance their lines. Body paragraphs have a 70-character maximum measure; selected protocol explanations can reach 85 characters. Long onchain values wrap, and financial amounts remain available in full in transaction review. All numbers use tabular spacing.

## Layout

`App` in `main.tsx` owns a desktop sidebar, utility header, main content and footer. Hash navigation supports static hosting under a subpath. The desktop sidebar is 232px, reducing to 196px at 1180px and 166px at 900px. The main container is capped at 1260px, with 48px normal side padding. Common spacing steps are 4, 8, 12, 16, 20, 24, 28, 32, 40, 48 and 64px.

`play-grid` places the freeze form before its illustration in DOM order. `two-column` groups related tools; `rules-grid` groups explanations; `metrics` aligns live values. Groups use at least twice their internal text spacing. Panels have 28px padding, reduced at narrower widths.

At 900px, the secondary tools become one column. At 720px, the sidebar becomes six visible navigation links in two rows, the header retains the product and wallet control, the main padding becomes 20px, and the freeze form comes before its illustration. The primary action is within the first 390×844 screen. Dialogs become bottom sheets with safe-area padding. At 350px, details and dense metrics become single columns, the chain label leaves the header, and side padding becomes 16px. No navigation items are hidden in an undiscoverable menu. Reviewed widths are 320, 390, 768 and 1440 CSS pixels; the pinned probe also checks 320, 390 and 1440.

## Elevation & depth

The page is deliberately flat. Panels use a single structural border and no shadow. Dividers organize data rows. The modal is the only elevated surface: a shadow without a border, plus a dark translucent native dialog backdrop. The background becomes inert through `dialog.showModal()`. There is no sticky mobile overlay covering page content. A minimized pending-transaction banner stays in document flow.

## Shapes

`--radius` is 12px for panels and the main illustration. `--radius-control` is 7px for inputs and buttons. Navigation uses 8px, informational messages 8px and dialogs 16px. Mobile dialogs keep only their upper corners rounded. The snowflake uses one SVG path family, with concentric circles clipped only within decorative art. Critical text is never clipped to fit a card.

## Components

- `Icon` (`components.tsx`): a consistent 1.7px SVG stroke with `currentColor`; decorative icons are hidden from accessibility APIs.
- `Modal`: native dialog semantics, focus containment, Escape/backdrop/close control and focus return. Transaction dialogs can be minimized while tracking continues. Wallet rows have local or discovered wallet marks and at least 56px height.
- `Notice`: info, error and success surfaces. Errors use `role="alert"`; routine transaction updates use a stable status region.
- `Metric`: aligned label, value and optional context. Unknown balances say “Unavailable”; zero is rendered only after a successful read.
- `AddressLink` / `TxLink`: explorer links. Compact addresses retain a full title and explorer destination; critical contract directories and reviews show full wrapping addresses.
- `PageTitle`: one task-specific h1 and one plain explanation.
- `WriteButton` (`transactions.tsx`): delegates to the shared verification, fresh-state review, simulation and explicit wallet-confirmation flow. Disconnected/wrong-network/pending states disable writes.
- Forms: persistent labels, 48px inputs, 16px input text, inline recovery messages and native selects. Freeze costs, swap minimums and consequences are repeated in the transaction review before sending.
- Buttons: at least 44px tall, visible rest/hover/pressed/disabled/focus states. Focus uses a 3px outline with 3px offset. Primary controls use orange; secondary actions remain neutral. Navigation and text links keep distinct placement and underline cues.

Color transitions are 120ms and enabled only without a reduced-motion preference. Press feedback uses a 0.96 scale. There are no entrance sequences, carousels, autoplay or endless animations. Forced-colors mode preserves native control behavior.

## Do’s and don’ts

Start another page with `PageTitle`, an existing layout primitive and the same `Notice`/`Metric` components. Use `WriteButton` or the shared transaction context for any supported write. Keep exact units, full review amounts, current role checks and unavailable states. Use semantic color tokens and existing type roles.

Keep the primary tool on the first mobile screen. Do not add a marketing hero above it, invent a token balance or NFT, label held funds as personal claims, put long prose in monospace, introduce a second accent system, or add border-plus-shadow cards. Add a new route only through the shared hash-navigation list and verify its narrow layout and keyboard path.
