--!strict
-- 🍟 Last fry — host half: the manage block (last-fry.manage).
-- All state lives in kv (shared with the window half): this block only reads
-- and writes config/results and never touches an API key itself — actions
-- that need one (seal / delete / query / import) are routed to the window
-- half via cx:open("lastfry://…") (secrets are window-half only).
-- Every user-facing string goes through lib/i18n.luau's t().
-- Providers render as one card each: head = name (type · updated in meta)
-- with the status badge and actions at its end; body = quota cells
-- "label <growing bar> pct … trailing": 5h and 7d as equal halves of one
-- row (30d full-width below, a lone window fills the row), the countdown
-- right-aligned to its half's edge; money = Balance label with the amount
-- at the row's end. Bars fill with the USED fraction so thresholds read
-- naturally (motion.md: value ≥ warn/bad).

local store = require("./lib/store")
local providers = require("./lib/providers")
local i18n = require("./lib/i18n")

local t = i18n.t

local ui = tern.ui

type Form = {
	id: string?, -- set = editing an existing provider
	name: string,
	nameCur: number,
	typename: string,
	baseUrl: string,
	baseUrlCur: number,
	apiKey: string,
	apiKeyCur: number,
	focus: string?,
}

type Notice = { text: string, tone: string }

type State = {
	form: Form?,
	formNotice: string?,
	interval: string,
	intervalCur: number,
	warn: string,
	warnCur: number,
	scale: string,
	scaleCur: number,
	focus: string?, -- without a form: interval / warn / scale
	setNotice: Notice?,
}

local POLL_MS = 5000 -- background poll: the window half writes kv, the table follows

------------------------------------------------------------------ utilities

local function clamp_cursor(s: string, cur: number): number
	if cur < 0 then
		return 0
	elseif cur > #s then
		return #s
	end
	return cur
end

local function is_cont(b: number): boolean
	-- UTF-8 continuation byte: 128..191 (b - b % 64 == 128, avoiding bitwise ops)
	return b >= 128 and (b - b % 64) == 128
end

-- Cursor model: cur = bytes before the cursor (0..#s).
-- prev_boundary returns the start byte (1-based) of the character before the
-- cursor (0 = no character before it).
local function prev_boundary(s: string, cur: number): number
	if cur <= 0 then
		return 0
	end
	local i = cur
	while i > 1 and is_cont(s:byte(i) :: number) do
		i -= 1
	end
	return i
end

-- New cursor after moving right (= end byte of the character after the
-- cursor; returning cur = there is no next character).
local function next_boundary(s: string, cur: number): number
	if cur >= #s then
		return cur
	end
	local j = cur + 1
	while j < #s and is_cont(s:byte(j + 1) :: number) do
		j += 1
	end
	return j
end

-- byte offset → UTF-16 offset for input nodes
local function utf16_at(s: string, byte_i: number): number
	local n = 0
	for _, cp in utf8.codes(s:sub(1, byte_i)) do
		n += if cp > 0xFFFF then 2 else 1
	end
	return n
end

local function countdown(resetAtMs: number): string
	local sec = math.floor(resetAtMs / 1000 - os.time())
	if sec <= 0 then
		return t("countdown.soon")
	end
	local h, m = sec // 3600, (sec % 3600) // 60
	if h >= 24 then
		return t("countdown.d", h // 24)
	elseif h > 0 then
		return t("countdown.hms", h, m)
	end
	return t("countdown.m", m)
end

local function with_props(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

-- pct text for a window row: "94% left"
local function pct_text(pct: number): string
	return t("quota.pct", pct)
end

-- meter thresholds read on the FILL (motion.md: "value ≥ bad sets
-- data-level=bad, else value ≥ warn sets warn"), so every meter is fed the
-- USED fraction (1 − remaining): warn fires at remaining ≤ warnBelowPct,
-- bad at remaining ≤ 2%.
local BAD_USED = 0.98

local function clamp01(n: number): number
	if n < 0 then
		return 0
	elseif n > 1 then
		return 1
	end
	return n
end

-- the pct reads "96% left," and the trailing text (countdown) follows it
-- right-aligned; the Balance row has no pct, so its trailing is bare.

-- one quota cell: label sits immediately before a growing bar (fill = used
-- fraction) with the pct right after it; when there is a pct, it ends in a
-- comma ("96% left,") and the countdown is right-aligned to the cell's
-- edge; without a pct (Balance) the trailing amount stands bare.
local function quota_cell(
	key: string,
	label: string,
	meter_props: { [string]: any },
	pct: string?,
	trailing: string?
): Node
	local mid: { Node } = { ui.node("meter", meter_props) }
	if pct ~= nil then
		table.insert(mid, ui.node("text", { key = "pct", spans = { ui.span(pct .. ",") } }))
	end
	local children: { Node } = {
		ui.node("text", { key = "label", spans = { ui.span(label) } }),
		ui.node("row", { key = "mid", gap = "sm", align = "center", grow = 1 }, mid),
	}
	if trailing ~= nil then
		table.insert(children, ui.node("text", { key = "end", spans = { ui.span(trailing) } }))
	end
	return ui.node("row", { key = key, gap = "sm", align = "center" }, children)
end

-- balance number: integers at ≥100, else two decimals (currencies stay data)
local function amount_text(amount: number): string
	return (if math.abs(amount) >= 100 then ("%.0f") else ("%.2f")):format(amount)
end

-- meter props for a "good fraction" (remaining or balance/scale): fill =
-- the USED fraction, thresholds on it (see BAD_USED above).
local function used_meter(value_good: number, settings: store.Settings): { [string]: any }
	return {
		key = "bar",
		value = clamp01(1 - value_good),
		thresholds = { warn = 1 - settings.warnBelowPct / 100, bad = BAD_USED },
	}
end

-- first stored line, for fallbacks like "Unlimited group" notes
local function first_line(r: store.Result): string?
	if #r.lines > 0 then
		return r.lines[1].text
	end
	return nil
end

-- the reported windows in display order: 5h, 7d, 30d
type WindowRow = { tag: string, w: store.QuotaWindow }

local function reported_windows(r: store.Result): { WindowRow }
	local wins: { WindowRow } = {}
	if r.fiveHour ~= nil then
		table.insert(wins, { tag = "5h", w = r.fiveHour :: store.QuotaWindow })
	end
	if r.weekly ~= nil then
		table.insert(wins, { tag = "7d", w = r.weekly :: store.QuotaWindow })
	end
	if r.monthly ~= nil then
		table.insert(wins, { tag = "30d", w = r.monthly :: store.QuotaWindow })
	end
	return wins
end

------------------------------------------------------------------ form logic

local function blank_form(): Form
	return {
		id = nil,
		name = "",
		nameCur = 0,
		typename = "",
		baseUrl = "",
		baseUrlCur = 0,
		apiKey = "",
		apiKeyCur = 0,
		focus = "name",
	}
end

type Box = {
	text: () -> string,
	cur: () -> number,
	set: (text: string, cur: number) -> (),
}

-- Accessor pair for the current typing target (a form field or a settings field)
local function field_box(state: State, field: string): Box?
	local form = state.form
	if form ~= nil then
		if field == "name" then
			return {
				text = function()
					return form.name
				end,
				cur = function()
					return form.nameCur
				end,
				set = function(t2, c)
					form.name, form.nameCur = t2, c
				end,
			}
		elseif field == "baseUrl" then
			return {
				text = function()
					return form.baseUrl
				end,
				cur = function()
					return form.baseUrlCur
				end,
				set = function(t2, c)
					form.baseUrl, form.baseUrlCur = t2, c
				end,
			}
		elseif field == "apiKey" then
			return {
				text = function()
					return form.apiKey
				end,
				cur = function()
					return form.apiKeyCur
				end,
				set = function(t2, c)
					form.apiKey, form.apiKeyCur = t2, c
				end,
			}
		end
	elseif field == "interval" then
		return {
			text = function()
				return state.interval
			end,
			cur = function()
				return state.intervalCur
			end,
			set = function(t2, c)
				state.interval, state.intervalCur = t2, c
			end,
		}
	elseif field == "warn" then
		return {
			text = function()
				return state.warn
			end,
			cur = function()
				return state.warnCur
			end,
			set = function(t2, c)
				state.warn, state.warnCur = t2, c
			end,
		}
	elseif field == "scale" then
		return {
			text = function()
				return state.scale
			end,
			cur = function()
				return state.scaleCur
			end,
			set = function(t2, c)
				state.scale, state.scaleCur = t2, c
			end,
		}
	end
	return nil
end

local function save_form(state: State, cx: BlockCx)
	local form = state.form
	if form == nil then
		return
	end
	if form.name:match("^%s*$") then
		state.formNotice = t("form.err.nameRequired")
		return
	end
	local adapter = providers.by_id(form.typename)
	if adapter == nil then
		state.formNotice = t("form.err.typeRequired")
		return
	end
	if adapter.needsBaseUrl and form.baseUrl:match("^%s*$") then
		state.formNotice = t("form.err.baseUrlRequired", adapter.label)
		return
	end
	local list = store.get_providers()
	local id = form.id
	if id == nil then
		id = store.next_id(form.typename)
		table.insert(list, {
			id = id :: string,
			name = form.name,
			type = form.typename,
			baseUrl = if form.baseUrl ~= "" then form.baseUrl else nil,
			enabled = true,
		})
	else
		for _, p in list do
			if p.id == id then
				p.name = form.name
				p.type = form.typename
				p.baseUrl = if form.baseUrl ~= "" then form.baseUrl else nil
				break
			end
		end
	end
	store.set_providers(list)
	state.form = nil
	state.formNotice = nil
	-- The key travels through kv for the window half to seal into the system
	-- keychain (lastfry://seal)
	if form.apiKey ~= "" then
		store.put_key_inbox(id :: string, form.apiKey)
		cx:open("lastfry://seal")
	else
		cx:open("lastfry://refresh")
	end
end

local function save_settings(state: State)
	local interval = tonumber(state.interval)
	if interval == nil or interval < 30 or interval > 86400 then
		state.setNotice = { text = t("settings.err.intervalRange"), tone = "error" }
		return
	end
	local warn = tonumber(state.warn)
	if warn == nil or warn < 0 or warn > 100 then
		state.setNotice = { text = t("settings.err.warnRange"), tone = "error" }
		return
	end
	local scale = tonumber(state.scale)
	if scale == nil or scale < 1 then
		state.setNotice = { text = t("settings.err.scaleRange"), tone = "error" }
		return
	end
	local s = store.get_settings()
	s.intervalSec = math.floor(interval)
	s.warnBelowPct = warn
	s.friesScale = scale
	store.set_settings(s)
	state.setNotice = { text = t("settings.saved"), tone = "success" }
end

--------------------------------------------------------------------- views

local function status_badge(r: store.Result?): { text: string, tone: string }
	if r == nil then
		return { text = t("badge.none"), tone = "muted" }
	elseif r.status == "ok" then
		if r.alert == "out" then
			return { text = t("badge.out"), tone = "error" }
		elseif r.alert == "low" then
			return { text = t("badge.low"), tone = "warning" }
		end
		return { text = t("badge.ok"), tone = "success" }
	elseif r.status == "stale" then
		return { text = t("badge.stale"), tone = "warning" }
	end
	return { text = t("badge.error"), tone = "error" }
end

-- The card body: 5h and 7d share one row as equal halves (each keeps the
-- label <growing bar> pct … countdown grid inside its half); 30d, when
-- reported, gets its own full-width row below. A single reported window
-- fills the whole row. Money is one row: Balance label <growing bar> with
-- the amount right-aligned. The query error, if any, rides along.
local function quota_nodes(r: store.Result?, settings: store.Settings): { Node }
	if r == nil then
		return { ui.text({ ui.span("—", "muted") }) }
	end
	local out: { Node } = {}
	local window_cell = function(e: WindowRow): Node
		local reset: string? = if e.w.resetAtMs ~= nil then countdown(e.w.resetAtMs :: number) else nil
		return quota_cell(
			e.tag,
			e.tag,
			used_meter(e.w.remainingPct / 100, settings),
			pct_text(e.w.remainingPct),
			reset
		)
	end
	if r.kind == "window" then
		local wins = reported_windows(r)
		if #wins == 1 then
			table.insert(out, window_cell(wins[1]))
		elseif #wins >= 2 then
			table.insert(out, ui.node("row", { key = "win", gap = "lg" }, {
				with_props(window_cell(wins[1]), { grow = 1, basis = 0 }),
				with_props(window_cell(wins[2]), { grow = 1, basis = 0 }),
			}))
			if wins[3] ~= nil then
				table.insert(out, window_cell(wins[3]))
			end
		end
	elseif r.amount ~= nil then
		table.insert(out, quota_cell(
			"bal",
			t("quota.balLabel"),
			used_meter(clamp01(r.amount / settings.friesScale), settings),
			nil,
			t("money.fries", amount_text(r.amount))
		))
	end
	if #out == 0 then
		table.insert(out, ui.text({ ui.span(first_line(r) or "—", "muted") }))
	end
	if r.error ~= nil then
		table.insert(out, ui.text({ ui.span(r.error, "error") }))
	end
	return out
end

-- One self-contained card per provider. The card's tone ring carries the
-- state (muted = disabled, warning/error = low/out of fries or a failed
-- query); the status badge and the row actions sit at the head's end.
local function provider_cards(settings: store.Settings): Node
	local provs = store.get_providers()
	local results = store.get_results()

	if #provs == 0 then
		return with_props(
			ui.node("empty", { variant = "inline", icon = "gauge", title = t("table.empty") }),
			{ key = "table" }
		)
	end

	local cards: { Node } = {}
	for _, p in provs do
		local r = results[p.id]
		local sb = status_badge(r)
		local meta = p.type
		if r ~= nil then
			meta = meta .. " · " .. os.date("%m-%d %H:%M", r.updatedAt)
		end
		local tone: string? = nil
		if not p.enabled then
			tone = "muted"
		elseif r ~= nil and r.status == "error" then
			tone = "error"
		elseif r ~= nil and r.status == "ok" then
			if r.alert == "out" then
				tone = "error"
			elseif r.alert == "low" then
				tone = "warning"
			end
		end
		-- the badge + actions row is the card's "end" child: named by its
		-- block id (main.<col key>.<card key>.end) and drawn at the head's end
		local end_row = ui.node("row", { key = "end", gap = "sm" }, {
			ui.node("badge", { key = "badge", text = sb.text, tone = sb.tone }),
			ui.button(
				if p.enabled then t("btn.rowEnabled") else t("btn.rowDisabled"),
				{
					size = "sm",
					variant = if p.enabled then "default" else "quiet",
					actions = { click = "toggle=" .. p.id },
				}
			),
			ui.button(t("btn.edit"), { size = "sm", actions = { click = "edit=" .. p.id } }),
			ui.button(t("btn.delete"), { size = "sm", variant = "danger", actions = { click = "del=" .. p.id } }),
		})
		local body = quota_nodes(r, settings)
		table.insert(body, 1, end_row)
		table.insert(cards, ui.card(
			{ ui.span(p.name, if p.enabled then "strong" else "muted") },
			body,
			{
				key = p.id,
				icon = "gauge",
				meta = meta,
				tone = tone,
				["end"] = "main.table." .. p.id .. ".end",
			}
		))
	end
	return with_props(ui.node("col", { gap = "sm" }, cards), { key = "table" })
end

local function form_card(state: State): Node
	local form = state.form :: Form
	local adapter = providers.by_id(form.typename)
	local base_hint = if adapter ~= nil and adapter.needsBaseUrl
		then t("form.hint.baseUrlRequired")
		else t("form.hint.baseUrlOptional")
	local key_hint = if form.id ~= nil then t("form.hint.keyKeep") else t("form.hint.keyNew")

	local kids: { Node } = {
		ui.node(
			"field",
			{ key = "f_name", label = t("form.label.name"), required = true, hint = t("form.hint.name") },
			{
				ui.node("input", {
					key = "name",
					text = form.name,
					cursor = utf16_at(form.name, form.nameCur),
					placeholder = t("form.placeholder.name"),
					icon = "tag",
				}),
			}
		),
		ui.node(
			"field",
			{ key = "f_type", label = t("form.label.type"), hint = t("form.hint.type") },
			{
				ui.node("select", {
					key = "type",
					value = if form.typename ~= "" then form.typename else nil,
					options = providers.options() :: any,
					placeholder = t("form.placeholder.type"),
				}),
			}
		),
		ui.node(
			"field",
			{ key = "f_base", label = t("form.label.baseUrl"), hint = base_hint },
			{
				ui.node("input", {
					key = "baseUrl",
					text = form.baseUrl,
					cursor = utf16_at(form.baseUrl, form.baseUrlCur),
					placeholder = "https://…",
					mono = true,
				}),
			}
		),
		ui.node(
			"field",
			{ key = "f_key", label = t("form.label.apiKey"), hint = key_hint },
			{
				ui.node("input", {
					key = "apiKey",
					text = form.apiKey,
					cursor = utf16_at(form.apiKey, form.apiKeyCur),
					placeholder = "sk-…",
					secret = true,
				}),
			}
		),
		ui.row({
			ui.button(t("form.btn.save"), { variant = "primary", keys = { "enter" }, actions = { click = "save" } }),
			ui.button(t("form.btn.cancel"), { variant = "quiet", keys = { "esc" }, actions = { click = "cancel" } }),
		}),
	}
	if state.formNotice ~= nil then
		table.insert(kids, ui.text({ ui.span(state.formNotice, "error") }))
	end
	return with_props(
		ui.card({ ui.span(if form.id ~= nil then t("form.title.edit") else t("form.title.add")) }, kids, { icon = "plus" }),
		{ key = "form" }
	)
end

local function settings_card(state: State): Node
	local kids: { Node } = {
		ui.node(
			"field",
			{ key = "s_interval", label = t("settings.label.interval"), hint = t("settings.hint.interval") },
			{
				ui.node("input", {
					key = "interval",
					text = state.interval,
					cursor = utf16_at(state.interval, state.intervalCur),
					unit = t("settings.unit.sec"),
					mono = true,
				}),
			}
		),
		ui.node(
			"field",
			{ key = "s_warn", label = t("settings.label.warn"), hint = t("settings.hint.warn") },
			{
				ui.node("input", {
					key = "warn",
					text = state.warn,
					cursor = utf16_at(state.warn, state.warnCur),
					unit = "%",
					mono = true,
				}),
			}
		),
		ui.node(
			"field",
			{ key = "s_scale", label = t("settings.label.scale"), hint = t("settings.hint.scale") },
			{
				ui.node("input", {
					key = "scale",
					text = state.scale,
					cursor = utf16_at(state.scale, state.scaleCur),
					unit = t("settings.unit.fries"),
					mono = true,
				}),
			}
		),
		ui.button(t("settings.btn.save"), { icon = "save", actions = { click = "settings-save" } }),
	}
	if state.setNotice ~= nil then
		table.insert(kids, ui.text({ ui.span(state.setNotice.text, state.setNotice.tone) }))
	end
	return with_props(ui.card({ ui.span(t("settings.title")) }, kids, { icon = "gear" }), { key = "settings" })
end

------------------------------------------------------------------ block def

-- Is the block's pane still alive (liveness check for the background poll,
-- following the pattern of guides/blocks.md)
local function pane_running(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local manage: BlockDef<State> = {
	font = "sans",

	init = function(cx, _args, saved)
		local defaults = store.get_settings()
		i18n.sync()
		local restored: Form? = if saved ~= nil and type((saved :: any).form) == "table"
				and type((saved :: any).form.name) == "string"
			then (saved :: any).form
			else nil
		if restored ~= nil and restored.focus == nil then
			(restored :: Form).focus = "name"
		end
		local state: State = {
			form = restored,
			formNotice = nil,
			interval = tostring(if saved ~= nil and (saved :: any).interval ~= nil
				then (saved :: any).interval
				else defaults.intervalSec),
			intervalCur = 0,
			warn = tostring(if saved ~= nil and (saved :: any).warn ~= nil
				then (saved :: any).warn
				else defaults.warnBelowPct),
			warnCur = 0,
			scale = tostring(if saved ~= nil and (saved :: any).scale ~= nil
				then (saved :: any).scale
				else defaults.friesScale),
			scaleCur = 0,
			focus = nil,
			setNotice = nil,
		}
		state.intervalCur = #state.interval
		state.warnCur = #state.warn
		state.scaleCur = #state.scale
		-- The window half writes kv; re-render so the table follows it
		local function poll()
			if pane_running(cx.pane) then
				cx:render()
				tern.timer(POLL_MS, poll)
			end
		end
		tern.timer(POLL_MS, poll)
		return state
	end,

	title = function(_state)
		return t("block.title")
	end,

	view = function(state, _cx)
		i18n.sync()
		local settings = store.get_settings()
		local provs = store.get_providers()
		local results = store.get_results()

		local kids: { Node } = {
			ui.row({
				ui.text({
					ui.span(t("header.title"), "title strong"),
					ui.span(t("header.tagline"), "muted"),
				}),
			}),
			ui.row({
				ui.button(t("btn.refresh"), { icon = "repeat", actions = { click = "refresh" } }),
				ui.button(t("btn.import"), { icon = "download", actions = { click = "import" } }),
				ui.button(t("btn.add"), { icon = "plus", variant = "primary", actions = { click = "new" } }),
			}),
		provider_cards(settings),
	}

		if state.form ~= nil then
			table.insert(kids, form_card(state))
		end
		table.insert(kids, settings_card(state))

		return {
			main = ui.col(kids),
			dock = ui.text({
				ui.span("🍟 ", "muted"),
				ui.span(
					t("dock.summary", #provs, settings.intervalSec, settings.warnBelowPct),
					"muted"
				),
			}),
		}
	end,

	key = function(state, key, cx)
		if key.name == "escape" then
			if state.form ~= nil then
				state.form = nil
				state.formNotice = nil
				return nil
			end
			return false
		end
		if key.name == "enter" then
			if state.form ~= nil then
				save_form(state, cx)
				return nil
			end
			if state.focus ~= nil then
				save_settings(state)
				return nil
			end
			return false
		end
		if key.name == "tab" then
			local order: { string } = if state.form ~= nil
				then { "name", "baseUrl", "apiKey" }
				else { "interval", "warn", "scale" }
			local cur = if state.form ~= nil then (state.form :: Form).focus else state.focus
			local idx = 0
			for i, f in order do
				if f == cur then
					idx = i
					break
				end
			end
			local next_f = order[(idx % #order) + 1]
			if state.form ~= nil then
				(state.form :: Form).focus = next_f
			else
				state.focus = next_f
			end
			return nil
		end

		local field = if state.form ~= nil then (state.form :: Form).focus else state.focus
		local box = if field ~= nil then field_box(state, field) else nil
		if box == nil then
			return false
		end
		local text = box.text()
		local cur = clamp_cursor(text, box.cur())

		if key.name == "backspace" then
			local st = prev_boundary(text, cur)
			if st == 0 then
				return false
			end
			box.set(text:sub(1, st - 1) .. text:sub(cur + 1), st - 1)
		elseif key.name == "delete" then
			local en = next_boundary(text, cur)
			if en == cur then
				return false
			end
			box.set(text:sub(1, cur) .. text:sub(en + 1), cur)
		elseif key.name == "left" then
			local st = prev_boundary(text, cur)
			box.set(text, if st > 0 then st - 1 else 0)
		elseif key.name == "right" then
			box.set(text, next_boundary(text, cur))
		elseif key.name == "home" then
			box.set(text, 0)
		elseif key.name == "end" then
			box.set(text, #text)
		elseif key.text ~= nil and key.text ~= "" and not (key.ctrl or key.alt or key.meta) then
			local ins = key.text
			box.set(text:sub(1, cur) .. ins .. text:sub(cur + 1), cur + #ins)
		else
			return false
		end
		-- editing clears the related notice
		if state.form ~= nil then
			state.formNotice = nil
		else
			state.setNotice = nil
		end
		return nil
	end,

	event = function(state, ev, cx)
		if ev.ev == "action" then
			local act = ev.act
			if act == "refresh" then
				cx:open("lastfry://refresh")
			elseif act == "import" then
				cx:open("lastfry://import")
			elseif act == "new" then
				state.form = blank_form()
				state.formNotice = nil
			elseif act == "save" then
				save_form(state, cx)
			elseif act == "cancel" then
				state.form = nil
				state.formNotice = nil
			elseif act == "settings-save" then
				save_settings(state)
			elseif act == "toggle" then
				local list = store.get_providers()
				for _, p in list do
					if p.id == ev.value then
						p.enabled = not p.enabled
						break
					end
				end
				store.set_providers(list)
			elseif act == "edit" then
				for _, p in store.get_providers() do
					if p.id == ev.value then
						local f = blank_form()
						f.id = p.id
						f.name = p.name
						f.nameCur = #p.name
						f.typename = p.type
						f.baseUrl = p.baseUrl or ""
						f.baseUrlCur = #f.baseUrl
						state.form = f
						state.formNotice = nil
						break
					end
				end
			elseif act == "del" then
				store.remove_provider(ev.value :: string)
				cx:open("lastfry://forget/" .. ev.value)
			end
		elseif ev.ev == "change" then
			-- type dropdown: sync the chosen option into the form
			if state.form ~= nil and ev.id ~= nil and (ev.id :: string):match("%.type$") ~= nil and ev.value ~= nil then
				(state.form :: Form).typename = tostring(ev.value)
				state.formNotice = nil
			end
		elseif ev.ev == "focus" and ev.id ~= nil then
			local field = (ev.id :: string):match("%.([%w_]+)$")
			local is_form_field = field == "name" or field == "baseUrl" or field == "apiKey"
			local is_set_field = field == "interval" or field == "warn" or field == "scale"
			if state.form ~= nil and is_form_field then
				(state.form :: Form).focus = field
			elseif state.form == nil and is_set_field then
				state.focus = field
			else
				return
			end
			cx:frame({ { "focus", ev.id :: string } })
		end
	end,

	save = function(state)
		return { form = state.form, interval = state.interval, warn = state.warn, scale = state.scale }
	end,
}

tern.block.define("manage", manage)
