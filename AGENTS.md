# Last fry

A [Tern](https://docs.stencil.so/tern/) terminal plugin (Luau) that monitors
LLM API quota and shows it in a statusline segment and a manage block.
The package is this repository's root (`plugin.toml` sits here).

**Fun rule:** quota is called 🍟 **fries** everywhere — statusline,
cards, toasts ("Fries running low", "Out of fries", `42.69 fries`). Keep it
playful but not spammy: one 🍟 per segment/card, no extra emoji noise.

## User rules (from project history — keep them)

- All UI strings are English and go through `lib/i18n.luau` `t(key, …)`,
  selected by the `language` kv setting. Another language later = add one
  table there; **zero call-site changes**.
- Balance amounts display as plain "fries" units (`42.69 fries`) — never any
  currency symbol; the response's currency code is kv data only.
- Percentages are always qualified `left` (`87% left`) — the numbers mean
  remaining.
- Countdowns' max unit is days (`(4d)`, `(2h05m)`).
- Meter `value` is the **USED** fraction; thresholds read on it:
  `warn = 1 - warnBelowPct/100`, `bad = 0.98`; `value >= threshold` sets the
  level (docs semantics). So the bar goes warn at the warn threshold and
  error near zero.

## Architecture

`plugin.toml` declares two halves:

- `host.luau` — blocks/forms: the `last-fry.manage` block (one card per
  provider, add/edit form, settings card).
- `window.luau` — chrome/commands/secrets/timers: statusline segments,
  palette commands, the self-rearming query timer, secrets, omp import.

`tern.secrets` is **window-half-only**. The host never touches keys: key
work (query, import, seal, delete) bridges via `BlockCx:open("lastfry://…")`
→ the window's `tern.route.link` handler. New keys from the host form transit
kv key `key_inbox`, are sealed into the system keychain
(`plugin.last-fry.provider.<id>`) and cleared by the window half promptly.

kv schema (in `lib/store.luau`): `providers`, `results`, `settings`
(`language`, `friesScale`, `warnBelowPct`, `intervalSec`).

Provider adapters live in `lib/providers.luau`:

- `requests(baseUrl, key)` → ordered candidate requests (Zhipu falls back to
  the balance endpoint when there's no coding plan).
- `parse(body, step, baseUrl)` → `{ fallback = true }` walks to the next
  candidate; `{ err = "…" }` / `nil` = deterministic failure.
- Evidence-based endpoints only — the reverse-engineered schemas came from
  cc-switch and dsh-musage research notes (kept outside this repo). Never
  add an endpoint without evidence.

Query classification (`lib/query.luau`): HTTP 401/403 → auth failure
(terminal); 429/5xx/network → retryable with `5s × 2ⁿ` backoff capped at
30 min, persisted in kv across reloads; success clears backoff and is cached
in-window for 30 s.

## Build and test

```sh
tern plugin link .            # dev-link the repo root; ~300 ms hot reload on save
tern plugin reload last-fry   # explicit reload
tern plugin types .           # writes ./tern.d.luau (gitignored) for luau-lsp
tern plugin list              # expect: last-fry … ready
```

Verify UI by driving the real window, not by eyeballing code:

```sh
tern ctl tree <selector>      # dump the live node tree / rects
tern ctl click x y            # drive clicks
tern ctl palette              # command palette
```

Check node rects for any alignment claim (bars inside card bounds, etc.).
After moving files, `tern plugin unlink last-fry` then link the new path.

Logs: `%LOCALAPPDATA%/Tern/Logs/tern.log` (window half) and
`tern-daemon.log` (host half). Plugin data / kv:
`%LOCALAPPDATA%/Tern/plugin-data/last-fry/`. Never print or log API keys.

## Doc fetching (how this project was built)

- Official Tern docs: https://docs.stencil.so/tern/ — an mdBook; every page
  is also served as Markdown at the same path + `.md` (curl `…/guides/blocks.md`).
  The local SDK type-definitions repo is
  [stencil-hq/tern-sdk](https://github.com/stencil-hq/tern-sdk).
- omp (the coding agent): docs at https://omp.sh/docs.
- Provider keys: `omp auth export` is the import path (`lib/omp.luau` maps
  credentials to providers) — never read omp's sqlite directly.
- **Never invent SDK APIs** — the docs are the truth. Grep the doc pages for
  a member before using it, and feature-check newer members
  (`if tern.chrome then … end`) when relying on something recent.

## Conventions

- Layout: `plugin.toml`, `host.luau`, `window.luau`, `lib/` at the repo
  root; the repo installs as-is (`tern plugin install github.com/KinseyD/LastFry`).
- Bump `version` in `plugin.toml` for every release; keep the default branch
  installable.
- Statusline formatter is a pure function over an upvalue snapshot; call
  `tern.chrome.refresh()` after every change (timer tick, import, kv edit).
- Adding a provider: adapter in `lib/providers.luau` + i18n strings; keep
  the omp-import mapping in `lib/omp.luau` in sync.
