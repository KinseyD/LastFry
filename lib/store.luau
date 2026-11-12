--!strict
-- 🍟 kv store layer: the single source of state shared by both halves
-- (host blocks + window commands).
-- Keys:
--   providers : { Provider }                 provider configs
--   results   : { [id] = Result }             latest query result per provider
--   settings  : Settings                      refresh interval / warn threshold / UI language
--   backoff   : { [id] = { fails, untilTs } }   failure backoff (persisted across reloads)
--   key_inbox : { [id] = key }                key hand-off from the host block to the window half
-- API keys themselves live in tern.secrets (writable by the window half only),
-- named "provider.<id>".
-- All user-visible strings go through lib/i18n.luau's t() (settings.language picks the language).

export type Provider = {
	id: string,
	name: string,
	type: string, -- adapter id
	baseUrl: string?,
	enabled: boolean,
}

export type Line = { text: string, tone: string? }

export type QuotaWindow = { remainingPct: number, resetAtMs: number? }

export type Result = {
	status: "ok" | "error" | "stale",
	lines: { Line },
	updatedAt: number, -- os.time(), seconds
	error: string?,
	alert: "low" | "out"?, -- fries running low / out of fries
	kind: string?,
	fiveHour: QuotaWindow?,
	weekly: QuotaWindow?,
	monthly: QuotaWindow?,
	amount: number?,
	currency: string?,
}

export type Settings = { intervalSec: number, warnBelowPct: number, language: string, friesScale: number, rotateSec: number }

export type BackoffEntry = { fails: number, untilTs: number }

local M = {}

M.DEFAULT_SETTINGS = { intervalSec = 300, warnBelowPct = 20, language = "en", friesScale = 100, rotateSec = 8 } :: Settings

local function get(key: string, fallback: any): any
	local ok, v = pcall(tern.kv.get, key)
	if ok and v ~= nil then
		return v
	end
	return fallback
end

local function set(key: string, value: any)
	tern.kv.set(key, value)
end

------------------------------------------------------------- providers

local function valid_provider(v: any): boolean
	return type(v) == "table" and type(v.id) == "string" and type(v.name) == "string" and type(v.type) == "string"
end

function M.get_providers(): { Provider }
	local raw = get("providers", {})
	local out: { Provider } = {}
	if type(raw) == "table" then
		for _, v in raw do
			if valid_provider(v) then
				table.insert(out, {
					id = v.id,
					name = v.name,
					type = v.type,
					baseUrl = if type(v.baseUrl) == "string" and v.baseUrl ~= "" then v.baseUrl else nil,
					enabled = if v.enabled == false then false else true,
				})
			end
		end
	end
	return out
end

function M.set_providers(list: { Provider })
	set("providers", tern.json.array(list))
end

-- Remove a provider: also drop its result and backoff state (the key is
-- deleted by the window half via lastfry://forget)
function M.remove_provider(id: string)
	local list = M.get_providers()
	local out: { Provider } = {}
	for _, p in list do
		if p.id ~= id then
			table.insert(out, p)
		end
	end
	M.set_providers(out)
	M.drop_result(id)
	M.drop_backoff(id)
end

function M.next_id(typ: string): string
	local existing = M.get_providers()
	local taken: { [string]: boolean } = {}
	for _, p in existing do
		taken[p.id] = true
	end
	local n = 1
	while taken[("%s-%d"):format(typ, n)] do
		n += 1
	end
	return ("%s-%d"):format(typ, n)
end

--------------------------------------------------------------- results

function M.get_results(): { [string]: Result }
	local raw = get("results", {})
	if type(raw) == "table" then
		return raw :: any
	end
	return {}
end

function M.set_result(id: string, result: Result)
	local all = M.get_results()
	all[id] = result
	set("results", all)
end

function M.drop_result(id: string)
	local all = M.get_results()
	all[id] = nil
	set("results", all)
end

-------------------------------------------------------------- settings

function M.get_settings(): Settings
	local raw = get("settings", {})
	local s = table.clone(M.DEFAULT_SETTINGS)
	if type(raw) == "table" then
		local interval = tonumber(raw.intervalSec)
		if interval ~= nil and interval >= 30 and interval <= 86400 then
			s.intervalSec = math.floor(interval)
		end
		local warn = tonumber(raw.warnBelowPct)
		if warn ~= nil and warn >= 0 and warn <= 100 then
			s.warnBelowPct = warn
		end
		local lang = raw.language
		if type(lang) == "string" and lang ~= "" then
			s.language = lang
		end
		local scale = tonumber(raw.friesScale)
		if scale ~= nil and scale >= 1 then
			s.friesScale = scale
		end
		local rotate = tonumber(raw.rotateSec)
		if rotate ~= nil and rotate >= 2 and rotate <= 86400 then
			s.rotateSec = math.floor(rotate)
		end
	end
	return s
end

function M.set_settings(s: Settings)
	set("settings", { intervalSec = s.intervalSec, warnBelowPct = s.warnBelowPct, language = s.language, friesScale = s.friesScale, rotateSec = s.rotateSec })
end

--------------------------------------------------------------- backoff

function M.get_backoff(): { [string]: BackoffEntry }
	local raw = get("backoff", {})
	if type(raw) == "table" then
		return raw :: any
	end
	return {}
end

function M.set_backoff_entry(id: string, entry: BackoffEntry?)
	local all = M.get_backoff()
	all[id] = entry
	set("backoff", all)
end

function M.drop_backoff(id: string)
	M.set_backoff_entry(id, nil)
end

------------------------------------------------------------- key inbox

function M.put_key_inbox(id: string, key: string)
	local inbox = get("key_inbox", {})
	if type(inbox) ~= "table" then
		inbox = {}
	end
	(inbox :: any)[id] = key
	set("key_inbox", inbox)
end

-- Take all pending keys to seal (read-and-clear, so plaintext never lingers in kv.json)
function M.take_key_inbox(): { [string]: string }
	local inbox = get("key_inbox", {})
	if type(inbox) == "table" and next(inbox) ~= nil then
		set("key_inbox", {})
		return inbox :: any
	end
	return {}
end

return M
