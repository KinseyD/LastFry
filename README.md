# 🍟 Last fry

A [Tern](https://docs.stencil.so/tern/) terminal plugin that monitors LLM API
quota — or, as we call it here, your 🍟 fries.

Think of every provider's quota as a basket of fries: 5-hour windows, weekly
windows, pay-as-you-go balances — all of it is "how many fries are left". The
plugin polls each provider's quota endpoint on a schedule, renders the results
in a native manage block, and keeps a live segment in the status line. When
quota runs low it says **"Fries running low"**, and when it's gone it says
**"Out of fries"** — quietly, in the panel and the status line.

## Features

- **Statusline segments** (`tern.chrome.status`): one or more segments per
  enabled provider — `StatusSegment.text` is a plain string (no rich text)
  and tone is per segment, so each reported window is its own segment: the
  first carries the provider, `🍟 zhipu-coding-plan 5h 99% left (2h05m)`,
  further windows follow as `· 7d 80% left (4d)` segments (the compact
  countdown is omitted when the reset time is unknown; every percentage
  carries the `left` qualifier — the numbers are remaining). Balance
  providers show one `🍟 DeepSeek 42.69 fries` segment (no currency
  symbols anywhere).
  - Per-segment tones mirroring the card meters: `ok` normally; `warn` when
    that window's remaining is at or below the warn threshold; `error` at
    ≤ 2%, when the balance is ≤ 0, or on query failure (⚠ on the first
    segment); `muted` when data is stale or not fetched yet.
  - Clicking any segment opens the manage block (`plugin.last-fry.manage`);
    with no providers configured the segment shows `🍟 No fries providers yet`
    and opens the same block.
  - Follows the documented snapshot pattern: the formatter is a pure function
    over an upvalue snapshot; `tern.chrome.refresh()` redraws after every
    change (timer tick, omp import, host-half edits via shared kv).
- **Scheduled checks**: the window half keeps a self-rearming timer
  (`tern.timer`) and queries every enabled provider at the configured
  interval (default 300 s, 30–86400 s); "Refresh now" triggers one
  immediately.
- **Manage block** (`last-fry.manage`, native UI, sans font) — one card per
  provider (the old table is gone: a table cell cannot hold a bar with
  text — cells never wrap and meter cells carry no label):
  - card head: provider name, `type · updated` meta, and at its end the
    status badge (OK · Fries running low · Out of fries · Stale · Failed ·
    Not queried) plus the Enabled toggle, Edit and Delete buttons;
  - card body: quota cells `label <bar> pct, trailing` — the 5h and 7d
    windows share one row as two clearly separated halves (wide gap; a
    lone window fills the whole row; a reported 30d gets its own
    full-width row below). Inside each cell the label (`5h` / `7d` /
    `30d`) sits immediately before a growing bar that fills the space up
    to the percentage (remaining, always qualified `left`, its comma
    before the countdown when the reset is known), right-aligned to that
    half's right edge. Bars fill with the USED
    fraction and the meter thresholds read on it, so the bar turns
    warn-colored when remaining drops to the warn threshold and
    error-colored near zero. Pay-as-you-go providers get one row with a
    `Quota` label, a bar scaled by `balance / friesScale` (same warn /
    error colors relative to the scale), and the
    amount (`42.69 fries`) right-aligned at the row's end. A failed
    query's error line rides along;
  - the card's tone ring carries the state: muted = disabled,
    warning/error = fries running low / out or query failed;
  - add/edit form (name, type dropdown, optional baseUrl, secret API-key
    input), empty state when no provider is configured;
  - settings card: refresh interval, fries warn threshold (default 20%),
    quota bar full scale `friesScale` (default 100, minimum 1 — the money
    bar fills at this many fries).
- **omp (oh my pi) one-click import**: runs `omp auth export`, maps the
  credentials to this plugin's providers (keys sealed straight into the
  system keychain) and reads custom base URLs from
  `~/.omp/agent/models.yml`. Toasts `🍟 Imported N fries providers, skipped M`.
- **Palette commands** (group "Last fry"):
  - `plugin.last-fry.refresh` — 🍟 Refresh fries quota
  - `plugin.last-fry.manage` — 🍟 Open the fries manager
  - `plugin.last-fry.import_omp` — 🍟 Import providers from omp
- **i18n**: every user-facing string comes from `lib/i18n.luau` via `t(key, …)`,
  selected by the `language` setting (default `"en"`; unknown values fall
  back to English). English ships now; another language is one string table
  dropped in beside `en` — no call-site changes.

## Install

Requires [Tern](https://docs.stencil.so/tern/) (developed and verified on
0.9.9). The package is this repository's root, so a repo link installs it
as-is:

```sh
tern plugin install github.com/OWNER/LastFry
```

(The same line works in Tern's Preferences › Plugins › **Install…**. For
another git host give the full URL; a git URL always installs from the
repository root — which is where `plugin.toml` sits.)

For development, link the checkout and edit with ~300 ms hot reload:

```sh
tern plugin link /absolute/path/to/this/repo
```

`tern plugin dir` shows the plugins folder; `tern plugin list` should print:

```text
last-fry 0.3.9 Last fry — 1 blocks, 0 lenses, window  ready
```

### Upgrading from the pre-rename "fries" plugin (≤ 0.1.0)

The id change moves the data folder and the keychain namespace:

```sh
tern plugin unlink fries
# copy providers/results/settings across:
cp "%LOCALAPPDATA%/Tern/plugin-data/fries/kv.json" "%LOCALAPPDATA%/Tern/plugin-data/last-fry/kv.json"
tern plugin link /absolute/path/to/this/repo
```

## Supported providers (Tier A: baseUrl + API key is enough)

| Type | Provider | Endpoint | Shows |
| --- | --- | --- | --- |
| `deepseek` | DeepSeek | `api.deepseek.com/user/balance` | Balance in fries (the multi-currency wallet with funds wins; response currency kept as data only) |
| `openrouter` | OpenRouter | `openrouter.ai/api/v1/credits` | Balance in fries (`total_credits − total_usage`) |
| `siliconflow` | SiliconFlow | `api.siliconflow.{cn,com}/v1/user/info` | Balance in fries |
| `kimi` | Kimi / Moonshot | `api.kimi.{com,ai}/coding/v1/usages` | 5h / 7d remaining % |
| `zhipu` | Zhipu / Z.ai | `…/api/monitor/usage/quota/limit`, falls back to `…/api/biz/account/query-customer-account-report` without a coding plan | 5h / 7d remaining %; pay-as-you-go accounts show the balance in fries. **Authorization sends the raw key, no Bearer prefix** |
| `minimax` | MiniMax | `api.minimaxi.com` (`.cn` inference domain rerouted) / `api.minimax.io` `…/coding_plan/remains` | 5h / 7d remaining % (new percentage + legacy count layouts; weekly window skipped when unlimited) |
| `novita` | Novita AI | `api.novita.ai/v3/user/balance` | Balance in fries (`availableBalance / 10000`) |
| `stepfun` | StepFun | `api.stepfun.com/v1/accounts` | Balance in fries |
| `sub2api` | Sub2API | `{baseUrl without trailing / and /v1}/v1/usage` | Remaining quota in its own unit; `remaining < 0` means an unlimited group (no number shown). **baseUrl required** |

Balances render as plain numbers with a `fries` suffix (`42.69 fries`) — no
currency symbols anywhere in the UI; the response's currency code is kept in
kv as data only.

### Monthly (30d) windows

The 30d window is plumbed end to end (adapter `Parsed.monthly` → kv
`Result.monthly` → a `30d 87%` line in the Quota cell, the bar strip and the
statusline segment). No Tier A provider documents a monthly window yet, so no
adapter fills it today:

| Provider | Windows it can report |
| --- | --- |
| `zhipu` | 5h, 7d (`limits[]` units 3 and 6 — no monthly unit in the upstream evidence) |
| `kimi` | 5h, 7d (`limits[].detail` + `usage`) |
| `minimax` | 5h, 7d (`current_interval_*` / `current_weekly_*`; no `current_monthly_*` documented) |
| money kinds | a single balance row |

When evidence lands for a provider, its adapter starts filling `monthly` and
the `30d` rows appear everywhere without further changes.

omp import mapping: a name or baseUrl containing `zhipu`/`bigmodel`/`glm`/
`z.ai` → Zhipu; `deepseek`; `moonshot`/`kimi`; `siliconflow`; `openrouter`;
`minimax`; `novita`; `stepfun`; `sub2api`. Anything unmappable (OAuth
credentials, the built-in openai/anthropic, …) is skipped and the reason
appears in the toast.

## Query behavior

- 15 s timeout per request; HTTP 401/403 → auth failure (terminal); 429/5xx
  and network errors → retryable, with exponential backoff `5s × 2ⁿ` (capped
  at 30 min) persisted in kv across reloads; successful results are cached
  in-window for 30 s; a success clears the backoff.
- On a retryable failure the previous good data is kept and badged "Stale";
  if there was none, the error reason is shown instead.

## Security (please read)

- **API keys live in the system keychain** (Windows Credential Manager /
  macOS Keychain / Linux Secret Service) under
  `plugin.last-fry.provider.<id>`, read and written through `tern.secrets` —
  an API only the window half can use.
- The host half (manage block) **never touches keys**: key-needing work
  (query, import, seal, delete) runs in the window half, bridged by
  `BlockCx:open("lastfry://…")` → the window's `tern.route.link` handler
  (which the docs state explicitly covers host-plugin-initiated opens).
- The one caveat: a key typed into the form briefly passes through the
  plugin's `kv.json` (`key_inbox`, sealed and cleared the moment the window
  half drains it). That is the trade-off under the SDK's "secrets are
  window-writable only" rule — use the omp import instead if you'd rather
  keys never touch kv (they don't there).
- **Changing the plugin id orphans old keychain entries**: secrets are
  namespaced per plugin id (`plugin.<id>.*`), so the pre-rename
  `plugin.fries.*` entries are not readable by `last-fry`. After the 0.2.0
  rename, rerun the omp import once to re-seal (that's how this repo
  migrated). The orphaned entries stay in the keychain until you remove them
  yourself.
- The plugin never writes key material to logs, toasts or kv results.

## Verified / not yet verified

Verified on the developer machine (Windows, Tern 0.9.9, omp 18.14.2):

- `tern plugin list` loads ready; host + window halves load without errors;
- omp import of a real credential (`zhipu-coding-plan`) → provider stored,
  key sealed, immediate live query;
- the Zhipu adapter parses real endpoint responses into 5h / 7d remaining
  percentages and the reset countdown (values change across refreshes);
- 401 auth-failure classification; connection-refused transient
  classification + kv-persisted backoff;
- manage block: opening, cards rendering real data, add / edit / toggle /
  delete (buttons verified by driven clicks), key sealing, the type
  dropdown, CJK input, backspace / arrow-key editing, saving settings,
  UI-triggered "Refresh now" and "Import from omp";
- the 0.2.0 rebrand end-to-end: unlink → rename → link, kv migration, omp
  re-seal under the new id, English statusline segment and manage block;
- the 0.3.x quota rework: per-provider cards whose bodies hold the meter
  rows themselves (real 5h/7d numbers + real countdowns as trailing text on
  the bars), a synthetic money provider (`42.69`, default scale 100)
  rendering exactly one `42.69 fries` bar with no currency symbols
  (injected into kv, verified, removed), meter rects inside the card bounds
  at both wide and ~470px block widths, toggle + Edit actions driven by
  harness clicks.

Adapters implemented from reverse-engineered upstream notes (cc-switch and
dsh-musage research, kept outside this repo) but **not** exercised with real
keys (no accounts): openrouter, siliconflow, kimi, minimax, novita, stepfun,
sub2api. Corrections welcome as issues.

Not supported yet (Tier B, needs an accessToken, signing or OAuth per
provider): NewAPI/OneAPI relays, Alibaba Bailian, Volcengine Ark,
Anthropic / Codex / Gemini subscriptions, Command Code, OpenCode Go, ZenMux.
To be revisited when there's a real need.

## Development

```sh
tern plugin types .         # writes ./tern.d.luau (gitignored) for luau-lsp
tern plugin reload last-fry # or just save a file — hot reload within ~300 ms
```

Logs: `%LOCALAPPDATA%\Tern\Logs\tern-daemon.log` (host half), `tern.log`
(window half). Plugin data / kv: `%LOCALAPPDATA%\Tern\plugin-data\last-fry\`.

Adding a language: copy the `en` table in `lib/i18n.luau`, translate the
values (keys and `%s`/`%d` placeholders stay), register it in `tables`, and
set `"language"` in kv settings. Nothing else changes.
