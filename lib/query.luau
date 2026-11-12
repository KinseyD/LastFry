--!strict
-- 🍟 Query layer: tern.fetch wrapper + status classification + 30s success
-- cache + exponential backoff.
-- Classification (aligned with cc-switch / dsh-musage's error-channel semantics):
--   auth_failed  401/403            → deterministic failure, error immediately
--   retryable   429/5xx            → retry after backoff, keep old data (stale)
--   transient   network error (r.error) → same
--   error       other non-2xx / parse failure → deterministic failure

export type Outcome =
	| { ok: true, parsed: any }
	| { ok: false, class: "auth_failed" | "retryable" | "transient" | "error", msg: string }

local store = require("./store")
local i18n = require("./i18n")

local t = i18n.t
local M = {}

local TIMEOUT_MS = 15000
local CACHE_TTL_MS = 30000
local BACKOFF_BASE_S = 5
local BACKOFF_MAX_S = 1800

-- In-VM success cache (one entry per window; reads from kv don't hit the network every time)
local cache: { [string]: { at: number, parsed: any } } = {}

function M.cached(id: string): any
	local hit = cache[id]
	if hit ~= nil and (tern.now() - hit.at) < CACHE_TTL_MS then
		return hit.parsed
	end
	return nil
end

function M.clear_cache()
	cache = {}
end

--------------------------------------------------------------- backoff

function M.backed_off(id: string): boolean
	local e = store.get_backoff()[id]
	return e ~= nil and os.time() < e.untilTs
end

-- Record one retryable failure; returns the new backoff in seconds
function M.note_failure(id: string): number
	local bo = store.get_backoff()
	local e = bo[id]
	local fails = (if e ~= nil then e.fails else 0) + 1
	local delay = math.min(BACKOFF_BASE_S * 2 ^ (fails - 1), BACKOFF_MAX_S)
	bo[id] = { fails = fails, untilTs = os.time() + math.floor(delay) }
	tern.kv.set("backoff", bo)
	return math.floor(delay)
end

function M.note_success(id: string)
	if store.get_backoff()[id] ~= nil then
		store.drop_backoff(id)
	end
end

----------------------------------------------------------- fetch + parse

-- Walk adapter.requests' candidate requests in order; advance to the next
-- one when parse returns {fallback=true}.
function M.fetch_quota(
	id: string,
	adapter: any,
	baseUrl: string?,
	key: string,
	cb: (Outcome) -> ()
)
	local reqs = adapter.requests(baseUrl, key)
	local function step(i: number)
		local req = reqs[i]
		if req == nil then
			cb({ ok = false, class = "error", msg = t("q.parseFailed") })
			return
		end
		tern.fetch(req.url, { headers = req.headers, timeout_ms = TIMEOUT_MS }, function(res)
			if res.error ~= nil then
				cb({ ok = false, class = "transient", msg = res.error })
				return
			end
			local status = res.status
			if status == 401 or status == 403 then
				cb({ ok = false, class = "auth_failed", msg = t("q.authFailedHttp", status) })
				return
			end
			if status == 429 or status >= 500 then
				local why = if status == 429 then t("q.rateLimited") else t("q.serverError")
				cb({ ok = false, class = "retryable", msg = t("q.httpStatus", status, why) })
				return
			end
			if status >= 300 then
				cb({ ok = false, class = "error", msg = t("q.httpCode", status) })
				return
			end
			local okp, parsed = pcall(adapter.parse, res.body, i, baseUrl)
			if not okp or parsed == nil then
				cb({ ok = false, class = "error", msg = t("q.parseFailed") })
				return
			end
			if parsed.err ~= nil then
				cb({ ok = false, class = "error", msg = parsed.err })
				return
			end
			if parsed.fallback then
				step(i + 1)
				return
			end
			cache[id] = { at = tern.now(), parsed = parsed }
			cb({ ok = true, parsed = parsed })
		end)
	end
	step(1)
end

--------------------------------------------------------- parsed → Result

-- Balance number: ≥100 rounds to integer, otherwise two decimals
-- (currency is kept as data only, never shown in display text)
local function amount_text(amount: number): string
	local body = if math.abs(amount) >= 100 then ("%.0f"):format(amount) else ("%.2f"):format(amount)
	return body
end

-- Parsed → storable/displayable Result; below warnBelowPct → fries running low, at 0 → out of fries
function M.to_result(parsed: any, warnBelowPct: number): store.Result
	local lines: { store.Line } = {}
	local alert: "low" | "out"? = nil

	local function windowTone(pct: number?): string?
		if pct == nil then
			return nil
		end
		if pct <= 0 then
			return "error"
		end
		if pct < warnBelowPct then
			return "warning"
		end
		return nil
	end

	local function noteAlert(pct: number?)
		if pct == nil then
			return
		end
		if pct <= 0 then
			alert = "out"
		elseif pct < warnBelowPct and alert == nil then
			alert = "low"
		end
	end

	if parsed.kind == "window" then
		if parsed.fiveHour ~= nil then
			table.insert(lines, {
				text = t("result.line5h", parsed.fiveHour.remainingPct),
				tone = windowTone(parsed.fiveHour.remainingPct),
			})
			noteAlert(parsed.fiveHour.remainingPct)
		end
		if parsed.weekly ~= nil then
			table.insert(lines, {
				text = t("result.line7d", parsed.weekly.remainingPct),
				tone = windowTone(parsed.weekly.remainingPct),
			})
			noteAlert(parsed.weekly.remainingPct)
		end
		if parsed.monthly ~= nil then
			table.insert(lines, {
				text = t("result.line30d", parsed.monthly.remainingPct),
				tone = windowTone(parsed.monthly.remainingPct),
			})
			noteAlert(parsed.monthly.remainingPct)
		end
		if #lines == 0 then
			table.insert(lines, { text = t("result.noWindowData") })
		end
		if parsed.note ~= nil then
			table.insert(lines, { text = parsed.note, tone = "muted" })
		end
	else
		local amount = tonumber(parsed.amount)
		if amount == nil then
			table.insert(lines, { text = if parsed.note ~= nil then parsed.note else t("result.noBalanceData") })
		else
			table.insert(lines, {
				text = t("money.fries", amount_text(amount)),
				tone = if amount <= 0 then "error" else nil,
			})
			noteAlert(if amount <= 0 then 0 else nil)
		end
	end

	return {
		status = "ok",
		lines = lines,
		updatedAt = os.time(),
		alert = alert,
		kind = parsed.kind,
		fiveHour = parsed.fiveHour,
		weekly = parsed.weekly,
		monthly = parsed.monthly,
		amount = tonumber(parsed.amount),
		currency = parsed.currency,
	}
end

return M
