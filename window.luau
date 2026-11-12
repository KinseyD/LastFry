--!strict
-- 🍟 Last fry — window half.
-- Owns the scheduled refresh loop (read key → query → write kv), the palette
-- commands, and the lastfry:// link routes (the host block hands key-needing
-- work here via cx:open("lastfry://…") — secrets are window-half only, see
-- guides/io.md). Also registers the persistent statusline segment
-- (tern.chrome.status) showing each provider's fries balance live.
-- Every user-facing string goes through lib/i18n.luau's t().

local store = require("./lib/store")
local query = require("./lib/query")
local providers = require("./lib/providers")
local omp = require("./lib/omp")
local i18n = require("./lib/i18n")

local t = i18n.t

--------------------------------------------------------------------- helpers

local function secret_name(id: string): string
	return "provider." .. id
end

-- forward declaration: write result + sync snapshot + redraw (statusline section)
local set_result_live: (id: string, result: store.Result) -> ()

local function error_result(msg: string): store.Result
	return { status = "error", lines = tern.json.array({}), updatedAt = os.time(), error = msg }
end

-- retryable failure: keep the old data marked stale, or mark error without old data
local function stale_result(id: string, msg: string, delay: number)
	local prev = store.get_results()[id]
	if prev ~= nil and prev.status == "ok" then
		set_result_live(id, {
			status = "stale",
			lines = prev.lines,
			updatedAt = prev.updatedAt,
			error = msg .. t("result.retryIn", delay),
			kind = prev.kind,
			fiveHour = prev.fiveHour,
			weekly = prev.weekly,
			monthly = prev.monthly,
			amount = prev.amount,
			currency = prev.currency,
		})
	else
		set_result_live(id, error_result(msg))
	end
end

-- Seal the plaintext key the host block left in key_inbox into the system
-- keychain (cleared as soon as it is read)
local function drain_inbox(done: (n: number, cx: WindowCx?) -> ())
	local inbox = store.take_key_inbox()
	local ids = {}
	for id in inbox do
		table.insert(ids, id)
	end
	if #ids == 0 then
		done(0, nil)
		return
	end
	-- wait for every set before the callback: refresh must see the fresh keys
	local pending = #ids
	for _, id in ids do
		tern.secrets.set(secret_name(id), inbox[id]):next(function(_, err, cx)
			if err ~= nil then
				tern.log.warn(t("log.sealKeyFailed"), id, err)
			end
			pending -= 1
			if pending == 0 then
				done(#ids, cx)
			end
		end)
	end
end

----------------------------------------------------------------- meter ramp
-- Continuous meter colors for the manage block: a sheet lerping the meter
-- fill (--mt) over --sf-meter, the USED fraction the meter node carries —
-- the theme's green (--ok) → amber across the warn leg, amber → red by
-- 0.98. color-mix() percentages are not implemented in Tern's engine
-- (live-checked: only the fixed 50/50 form parses), so the lerp runs on
-- relative-color channel math instead — nested rgb(from …) with the amber
-- and red anchors as literals and clamp() following the value. The warn
-- position is the live warnBelowPct setting, so the sheet is baked here and
-- re-installed only when the setting changes (tern.css is window-half only;
-- a surface without the sheet, like the web tab, keeps the meters' discrete
-- warn/bad thresholds — host.luau sets them).
local ramp_warn_baked: number? = nil

local function sync_meter_ramp(warnBelowPct: number)
	-- degenerate settings stay ordered: clamp the warn leg inside (0.01, 0.97)
	local warn = math.min(math.max(1 - warnBelowPct / 100, 0.01), 0.97)
	if ramp_warn_baked == warn then
		return
	end
	ramp_warn_baked = warn
	local w = ("%.4f"):format(warn)
	local bad = "0.98"
	-- amber #d29922 and red #e3524a as literals (mid-luminance, read on
	-- light and dark themes); t1 = u / W, t2 = (u − W) / (bad − W)
	local t1 = ("clamp(0, var(--sf-meter) / %s, 1)"):format(w)
	local t2 = ("clamp(0, (var(--sf-meter) - %s) / (%s - %s), 1)"):format(w, bad, w)
	local leg1 = ("rgb(from var(--ok) calc(r + (210 - r) * %s) calc(g + (153 - g) * %s) calc(b + (34 - b) * %s))")
		:format(t1, t1, t1)
	local ramp = ("rgb(from %s calc(r + (227 - r) * %s) calc(g + (82 - g) * %s) calc(b + (74 - b) * %s))")
		:format(leg1, t2, t2, t2)
	tern.css(
		"meter-ramp",
		([[
.sf-main[data-surface='plugin.last-fry.manage'] .sf-meter,
.sf-dock[data-surface='plugin.last-fry.manage'] .sf-meter,
.sf-layer[data-surface='plugin.last-fry.manage'] .sf-meter {
	--mt: %s;
}
]]):format(ramp)
	)
end

--------------------------------------------------------------------- statusline
-- Snapshot upvalue: chrome.status formatters must be pure (no cx, 4ms
-- budget); update the snapshot on data changes and tern.chrome.refresh() to
-- drop the formatter cache and redraw.

local snap: { providers: { SnapProvider }, warnBelowPct: number } = { providers = {}, warnBelowPct = 20 }

-- Rotation cursor: index of the provider currently shown in the statusline.
-- It advances via the dedicated rotation timer below — NOT via os.time()
-- math inside the formatter, which must stay a pure function over upvalue
-- state (AGENTS.md: no clock reads in chrome.status formatters).
local rotate_idx = 0

local function sync_snapshot()
	i18n.sync()
	local settings = store.get_settings()
	local results = store.get_results()
	local list: { SnapProvider } = {}
	for _, p in store.get_providers() do
		if p.enabled then
			table.insert(list, { id = p.id, name = p.name, result = results[p.id] })
		end
	end
	-- kind rides along with the result (window / money); no result → muted tail
	snap = { providers = list, warnBelowPct = settings.warnBelowPct }
	-- the meter ramp follows the live warn threshold (no-op when unchanged)
	sync_meter_ramp(settings.warnBelowPct)
end

-- after set_result: sync the snapshot and trigger a redraw (the formatter
-- cache is keyed by input; without a refresh it would never update)
function set_result_live(id: string, result: store.Result)
	store.set_result(id, result)
	sync_snapshot()
	tern.chrome.refresh()
end

-- counts as stale: longer than two refresh periods since the last good update
local function is_stale(result: store.Result?): boolean
	if result == nil then
		return true
	end
	if result.status ~= "ok" then
		return false
	end
	local interval = store.get_settings().intervalSec
	return os.time() - result.updatedAt > interval * 2
end

-- compact countdown for a statusline window part: "52m", "2h05m", "4d"
-- (days is the max unit; or "now" once the reset has passed)
local function compact_countdown(resetAtMs: number): string
	local sec = math.floor(resetAtMs / 1000 - os.time())
	if sec <= 0 then
		return t("status.cd.now")
	end
	if sec < 3600 then
		return t("status.cd.m", sec // 60)
	end
	local h = sec // 3600
	if h < 24 then
		return t("status.cd.hm", h, (sec % 3600) // 60)
	end
	return t("status.cd.d", h // 24)
end

-- one window part of the statusline: "5h 98% left (2h05m)" — the countdown
-- rides in parentheses after its own window's pct (only when it is known)
local function window_part(tag: string, w: store.QuotaWindow): string
	local key = if tag == "5h" then "status.window5h" elseif tag == "7d" then "status.window7d" else "status.window30d"
	local part = t(key, w.remainingPct)
	if w.resetAtMs ~= nil then
		part ..= t("status.cd", compact_countdown(w.resetAtMs :: number))
	end
	return part
end

-- tone for one window part, mirroring the card meters (BAD_USED = 0.98):
-- remaining ≤ 2% error, ≤ warnBelowPct warn, else ok
local function window_tone(remainingPct: number, warnBelowPct: number): string
	if remainingPct <= 2 then
		return "error"
	end
	if remainingPct <= warnBelowPct then
		return "warn"
	end
	return "ok"
end

-- StatusSegment.text is a plain string (api-window.md: `text: string`,
-- "Its text (required)") — no rich text, and tone is per segment — so a
-- provider renders as MULTIPLE segments: the first carries the 🍟 name and
-- the first window, each further window is its own segment, each with its
-- own tone. Money stays one segment; provider-level failure/staleness
-- mutes/errors every part.
local function provider_segments(name: string, result: store.Result?, warnBelowPct: number): { { text: string, tone: string } }
	if result == nil then
		return { { text = t("status.pending", name), tone = "muted" } }
	end
	local force_tone: string? = nil
	if result.status == "error" then
		force_tone = "error"
	elseif result.status == "stale" or is_stale(result) then
		force_tone = "muted"
	end
	if result.kind == "window" then
		local wins: { { tag: string, w: store.QuotaWindow } } = {}
		if result.fiveHour ~= nil then
			table.insert(wins, { tag = "5h", w = result.fiveHour :: store.QuotaWindow })
		end
		if result.weekly ~= nil then
			table.insert(wins, { tag = "7d", w = result.weekly :: store.QuotaWindow })
		end
		if result.monthly ~= nil then
			table.insert(wins, { tag = "30d", w = result.monthly :: store.QuotaWindow })
		end
		if #wins == 0 then
			return { { text = t("status.noWindowData", name), tone = force_tone or "muted" } }
		end
		local parts: { { text: string, tone: string } } = {}
		for i, e in wins do
			local text = window_part(e.tag, e.w)
			local tone = force_tone or window_tone(e.w.remainingPct, warnBelowPct)
			if i == 1 then
				text = t("status.lead", name, text)
				if result.status == "error" then
					text ..= " ⚠"
				end
			else
				text = t("status.divider") .. text
			end
			table.insert(parts, { text = text, tone = tone })
		end
		return parts
	end
	if result.amount ~= nil then
		local body = if math.abs(result.amount) >= 100 then ("%.0f"):format(result.amount) else ("%.2f"):format(result.amount)
		local tone = if force_tone ~= nil then force_tone elseif result.amount <= 0 then "error" else "ok"
		return { { text = t("status.lead", name, t("money.fries", body)), tone = tone } }
	end
	return { { text = t("status.unknown", name), tone = force_tone or "muted" } }
end

sync_snapshot()

tern.chrome.status(function(_pane)
	local segments: { any } = {}
	if #snap.providers > 0 then
		-- exactly one provider at a time, rotating; modulo-on-read keeps the
		-- pick in range when the enabled list shrinks between rotations
		local p = snap.providers[(rotate_idx % #snap.providers) + 1]
		for _, part in provider_segments(p.name, p.result, snap.warnBelowPct) do
			table.insert(segments, {
				text = part.text,
				tone = part.tone,
				command = "plugin.last-fry.manage",
			})
		end
	else
		table.insert(segments, {
			text = t("status.none"),
			tone = "muted",
			command = "plugin.last-fry.manage",
		})
	end
	return segments
end)

--------------------------------------------------------------------- refresh

local function refresh(force: boolean)
	drain_inbox(function(_n, _cx)
		local settings = store.get_settings()
		for _, p in store.get_providers() do
			if p.enabled then
				local adapter = providers.by_id(p.type)
				if adapter == nil then
					set_result_live(p.id, error_result(t("err.unknownProviderType", p.type)))
					continue
				end
				if not force and (query.cached(p.id) ~= nil or query.backed_off(p.id)) then
					continue
				end
				tern.secrets.get(secret_name(p.id)):next(function(key, err)
					if err ~= nil then
						set_result_live(p.id, error_result(t("err.readKey", err)))
						return
					end
					if key == nil or key == "" then
						set_result_live(p.id, error_result(t("err.noKey")))
						return
					end
					query.fetch_quota(p.id, adapter, p.baseUrl, key, function(outcome)
						if outcome.ok then
							query.note_success(p.id)
							set_result_live(p.id, query.to_result(outcome.parsed, settings.warnBelowPct))
						elseif outcome.class == "retryable" or outcome.class == "transient" then
							stale_result(p.id, outcome.msg, query.note_failure(p.id))
						else
							set_result_live(p.id, error_result(outcome.msg))
						end
					end)
				end)
			end
		end
	end)
end

-- repeating timer: the interval is re-read from settings every round, so
-- changing the settings takes effect immediately
local function tick()
	-- the host half may have changed providers/settings (shared kv): re-read
	-- the snapshot and redraw every round
	sync_snapshot()
	tern.chrome.refresh()
	refresh(false)
	tern.timer(store.get_settings().intervalSec * 1000, tick)
end

-- wait a moment after load for the first round (kv is ready; keeps clear of
-- the entry-load budget)
tern.timer(1500, tick)

---------------------------------------------------------------- statusline rotate

-- Self-rearming one-shot rotation timer, separate from the query tick: each
-- round re-reads settings (rotateSec changes apply without reload) and, when
-- more than one provider is enabled, advances rotate_idx and drops the
-- formatter cache. With ≤1 provider it just re-arms — one wakeup per period
-- is fine; boring > clever. The file scope runs once per window-half load,
-- so exactly one chain is ever alive.
local function rotate_tick()
	if #snap.providers > 1 then
		rotate_idx = (rotate_idx + 1) % #snap.providers
		tern.chrome.refresh()
	end
	tern.timer(store.get_settings().rotateSec * 1000, rotate_tick)
end
tern.timer(store.get_settings().rotateSec * 1000, rotate_tick)

------------------------------------------------------------------ omp import

-- Pending-import marker: kv, NOT an upvalue — `omp auth export` can outlive
-- this VM (hot reload mid-import, a daemon upgrade in place), and only kv
-- survives the VM swap. tern.process.run gives back no pid when a callback
-- is used (tern.d.luau: `-> ()`), so the match is single-flight: this plugin
-- spawns exactly one child kind (omp auth export, the only process.run call
-- site), so any `process_exit` while the marker is fresh is that export.
-- startedAt bounds the match: the child is killed at timeout_ms = 15 s, so
-- its exit event lands well inside the TTL; an older marker is a stale
-- leftover, dropped without acting on the event.
local PENDING_IMPORT = "pending_import"
local PENDING_IMPORT_TTL_MS = 60_000

-- The single completion path, shared by the normal omp.import callback (VM
-- alive) and the process_exit event below (VM died mid-import). Only the
-- fresh cx the callback chain / event carries may toast; the command's own
-- cx is long dead by the time any of this runs.
local function finish_import(outcome: omp.ImportOutcome, tcx: WindowCx?)
	if outcome.err ~= nil then
		if tcx ~= nil then
			tcx:toast("error", t("omp.failed"), outcome.err)
		else
			tern.log.warn(t("omp.failed"), outcome.err)
		end
		return
	end
	local existing = store.get_providers()
	local n = 0
	local pending_keys = 0
	local function finish(kcx: WindowCx?, tcx_live: boolean)
		if n > 0 then
			store.set_providers(existing)
			sync_snapshot()
			tern.chrome.refresh()
			refresh(true) -- query only after every key is sealed, to avoid
			-- the "API key not set" race
		end
		-- only a cx known to be alive may toast: the await callback's new
		-- cx wins; on the async path omp's cbcx is long gone (in practice
		-- it can even be a nil cx — rather stay silent than crash)
		local toastcx: WindowCx? = if kcx ~= nil then kcx elseif tcx_live then tcx else nil
		if toastcx ~= nil then
			toastcx:toast(
				if n > 0 then "success" else "info",
				t("omp.imported", n, #outcome.skipped),
				if #outcome.skipped > 0 then table.concat(outcome.skipped, t("omp.listSep")) else nil
			)
		else
			tern.log.warn(t("log.importDone"), t("log.importDoneDetail", n, #outcome.skipped))
		end
	end
	for _, imp in outcome.imported do
		-- same name + type = same provider: update key/baseUrl instead of duplicating
		local id: string? = nil
		for _, p in existing do
			if p.name == imp.name and p.type == imp.type then
				id = p.id
				p.baseUrl = imp.baseUrl
				break
			end
		end
		if id == nil then
			id = store.next_id(imp.type)
			table.insert(existing, {
				id = id :: string,
				name = imp.name,
				type = imp.type,
				baseUrl = imp.baseUrl,
				enabled = true,
			})
		end
		pending_keys += 1
		tern.secrets.set(secret_name(id :: string), imp.key):next(function(_, err, kcx)
			if err ~= nil then
				tern.log.warn(t("log.keyWriteFailed"), id, err)
			end
			pending_keys -= 1
			if pending_keys == 0 then
				finish(kcx, false) -- the await callback carries a fresh cx
				-- (the old code misused an undefined cx, so the success
				-- toast never fired)
			end
		end)
		n += 1
	end
	if pending_keys == 0 then
		finish(nil, true) -- nothing imported: report at once (cbcx still live)
	end
end

local function run_import()
	-- Mark BEFORE spawning: if this VM dies while the child runs, the new
	-- VM's process_exit handler below needs to find the marker to finish the
	-- import.
	tern.kv.set(PENDING_IMPORT, { startedAt = tern.now() })
	omp.import(function(outcome, cbcx)
		-- The VM survived, so this callback — not process_exit — delivers the
		-- outcome (the event replaces the callback only when the VM that
		-- started the child is gone); the two completion paths are mutually
		-- exclusive by construction, and both must clear the marker.
		tern.kv.set(PENDING_IMPORT, nil)
		finish_import(outcome, cbcx)
	end)
end

-- A child that outlived its VM: its callback died with that VM, and Tern
-- re-delivers the outcome as a `process_exit` event in this (new) VM.
-- Match it against the kv marker above, then run the SAME finish path as
-- the normal callback — without this, a reload mid-import would silently
-- lose the import. pcall: tern.on is old, but this event NAME is new; an
-- older Tern may raise on it, and that must not fail the whole load.
pcall(tern.on, "process_exit", function(ev: ProcessExitEvent, cx: WindowCx?)
	local ok, marker = pcall(tern.kv.get, PENDING_IMPORT)
	if not ok or type(marker) ~= "table" or type(marker.startedAt) ~= "number" then
		return -- nothing pending (or kv unreadable): not ours, no-op
	end
	if tern.now() - marker.startedAt > PENDING_IMPORT_TTL_MS then
		tern.kv.set(PENDING_IMPORT, nil) -- stale leftover: drop, still no-op
		return
	end
	-- Ours: delete the marker FIRST (a second child from a double-triggered
	-- import must not re-run the finish), then finish like the callback did.
	tern.kv.set(PENDING_IMPORT, nil)
	finish_import(omp.outcome_from_exit(ev), cx)
end)

--------------------------------------------------------------------- commands

tern.command({
	id = "refresh",
	title = t("cmd.refresh.title"),
	icon = "repeat",
	run = function(cx)
		refresh(true)
		cx:toast("info", t("toast.refreshing"), t("toast.refreshingSub"))
	end,
})

tern.command({
	id = "manage",
	title = t("cmd.manage.title"),
	icon = "gauge",
	run = function(cx)
		local pane = cx:new_block("last-fry.manage")
		if pane == nil then
			cx:toast("error", t("toast.manageFail"), t("toast.manageFailSub"))
		end
	end,
})

tern.command({
	id = "import_omp",
	title = t("cmd.import.title"),
	icon = "download",
	run = function(_cx)
		run_import()
	end,
})

----------------------------------------------------------------- link routes
-- The host block's buttons (refresh now / import from omp / seal key /
-- delete key) arrive here via BlockCx:open("lastfry://…"); route.link
-- explicitly covers "an open requested by the host plugin".

tern.route.link(function(link, cx)
	local path = link.url:match("^lastfry://([%w%-%._/]+)$")
	if path == nil then
		return nil
	end
	if path == "refresh" then
		refresh(true)
		cx:toast("info", t("toast.refreshing"))
		return { handled = true }
	elseif path == "import" then
		run_import()
		return { handled = true }
	elseif path == "seal" then
		drain_inbox(function(n, scx)
			refresh(true)
			if n > 0 then
				-- use the fresh cx from the await callback: the route
				-- handler's own cx is long dead
				if scx ~= nil then
					scx:toast("success", t("toast.sealed", n), t("toast.sealedSub"))
				else
					tern.log.warn(t("log.sealedKeys"), t("log.sealedCount", n))
				end
			end
		end)
		return { handled = true }
	end
	local forget = path:match("^forget/(.+)$")
	if forget ~= nil then
		tern.secrets.set(secret_name(forget), nil):next(function(_, err)
			if err ~= nil then
				tern.log.warn(t("log.forgetKeyFailed"), forget, err)
			end
		end)
		return { handled = true }
	end
	return nil
end)
