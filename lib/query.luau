--!strict
-- 🍟 查询层：tern.fetch 包装 + 状态分类 + 30s 成功缓存 + 指数退避。
-- 分类（对齐 cc-switch / dsh-musage 的错误通道语义）：
--   auth_failed  401/403            → 确定性失败，立刻报错
--   retryable   429/5xx            → 退避后重试，保留旧数据（stale）
--   transient   网络错误（r.error） → 同上
--   error       其余非 2xx / 解析失败 → 确定性失败

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

-- 本 VM 内的成功缓存（每窗口各自一份，读 kv 不必每次都打网络）
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

-- 记一次可重试失败，返回新的退避秒数
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

-- 依次尝试 adapter.requests 的候选请求；parse 返回 {fallback=true} 时前进到下一个。
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

-- 余额数字：≥100 取整，否则两位小数（币种只留数据，不再进显示文案）
local function amount_text(amount: number): string
	local body = if math.abs(amount) >= 100 then ("%.0f"):format(amount) else ("%.2f"):format(amount)
	return body
end

-- 解析结果 → 可存储/可展示的 Result；warnBelowPct 以下 → 薯条不多了，为 0 → 薯条没了
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
