--!strict
-- 🍟 供应商适配器注册表：每家 LLM 厂商「还剩多少薯条」怎么查、怎么读。
-- 端点与响应结构来自仓库外的逆向研究笔记（cc-switch + dsh-musage 逆向结论）。
--
-- 适配器约定：
--   requests(baseUrl, key) 返回一组候选请求（多数供应商只有一个；智谱在
--   「无 coding plan」时回退到余额端点，走第二个候选）。
--   parse(body, step, baseUrl) 解析第 step 个请求的响应：
--     · 返回 { fallback = true } → 尝试下一个候选请求；
--     · 返回 { err = "…" }      → 确定性失败（认证失败、结构不符等）；
--     · 返回 nil               → 响应无法解析（同样按确定性失败处理）。

export type QuotaWindow = {
	remainingPct: number, -- 剩余百分比 0..100（非已用）
	resetAtMs: number?, -- 窗口重置时刻（epoch 毫秒）
}

export type Parsed = {
	kind: "money" | "window"?,
	amount: number?,
	currency: string?, -- "CNY" | "USD" | ""
	fiveHour: QuotaWindow?,
	weekly: QuotaWindow?,
	-- 30d 窗口：目前没有任何 Tier A 上游证据（zhipu unit 只有 3=5h/6=周，
	-- kimi/minimax 只有 5h+7d），先打通字段，等有证据的适配器再填。
	monthly: QuotaWindow?,
	note: string?, -- 附注（套餐名、「不限量」等）
	fallback: boolean?,
	err: string?,
}

export type Req = { url: string, headers: { [string]: string } }

export type Adapter = {
	id: string,
	label: string, -- 管理面板类型下拉框里的名字
	kind: "money" | "window",
	needsBaseUrl: boolean?, -- sub2api 必填 baseUrl
	match: (baseUrl: string) -> boolean,
	requests: (baseUrl: string?, key: string) -> { Req },
	parse: (body: string, step: number, baseUrl: string?) -> Parsed?,
}

local i18n = require("./i18n")

local t = i18n.t

--------------------------------------------------------------------- helpers

local function bearer(key: string): { [string]: string }
	return { Authorization = "Bearer " .. key }
end

-- 智谱是唯一一家 Authorization 不带 Bearer 前缀的（两个仓库一致）。
local function raw(key: string): { [string]: string }
	return { Authorization = key }
end

local function decode(body: string): any
	local ok, v = pcall(tern.json.decode, body)
	if ok and type(v) == "table" then
		return v
	end
	return nil
end

local function clamp100(n: number): number
	if n < 0 then
		return 0
	elseif n > 100 then
		return 100
	end
	return n
end

local function fail(msg: string): Parsed
	return { err = msg }
end

local function money(amount: number?, currency: string?, note: string?): Parsed
	return { kind = "money", amount = amount, currency = currency, note = note }
end

-- limit/remaining 对 → 剩余百分比
local function pct(remaining: any, total: any): number?
	local r, t0 = tonumber(remaining), tonumber(total)
	if r ~= nil and t0 ~= nil and t0 > 0 then
		return clamp100(r / t0 * 100)
	end
	return nil
end

-- 重置时间：epoch 秒 / epoch 毫秒 / ISO 字符串 → epoch 毫秒
local function toMs(v: any): number?
	local n = tonumber(v)
	if n ~= nil then
		if n > 1e12 then
			return n
		end
		return n * 1000
	end
	if type(v) == "string" then
		local y, mo, d, h, mi, s = v:match("^(%d+)-(%d+)-(%d+)[Tt ](%d+):(%d+):(%d+)")
		if y then
			return os.time({
				year = tonumber(y) :: number,
				month = tonumber(mo) :: number,
				day = tonumber(d) :: number,
				hour = tonumber(h) :: number,
				minute = tonumber(mi) :: number,
				sec = tonumber(s) :: number,
				isdst = false,
			}) * 1000
		end
	end
	return nil
end

local function strip_trailing_slash_and_v1(base: string): string
	local b = (base:gsub("/+$", ""))
	b = (b:gsub("/v1$", ""))
	return b
end

--------------------------------------------------------------------- deepseek

local deepseek: Adapter = {
	id = "deepseek",
	label = t("pv.deepseek.label"),
	kind = "money",
	match = function(baseUrl)
		return baseUrl:find("deepseek", 1, true) ~= nil
	end,
	requests = function(_baseUrl, key)
		return { { url = "https://api.deepseek.com/user/balance", headers = bearer(key) } }
	end,
	parse = function(body)
		local d = decode(body)
		if not d then
			return fail(t("pv.notJson"))
		end
		local infos = d.balance_infos
		if type(infos) ~= "table" or #infos == 0 then
			return fail(t("pv.missingField", "balance_infos"))
		end
		-- 多币种钱包：有余额的钱包优先展示；全是零就显示第一个
		local best: any = nil
		for _, info in infos do
			local amt = tonumber(info.total_balance)
			if amt ~= nil and amt > 0 then
				best = info
				break
			end
		end
		if best == nil then
			best = infos[1]
		end
		local amount = tonumber(best.total_balance)
		if amount == nil then
			return fail(t("pv.balanceMissing"))
		end
		local currency = if best.currency == "CNY" then "CNY" elseif best.currency == "USD" then "USD" else tostring(best.currency)
		-- is_available:false 是「欠费/为零，无法调用」，不是 key 失效（401/403 才是）
		local note = if d.is_available == false then t("pv.balanceUnavailable") else nil
		return money(amount, currency, note)
	end,
}

------------------------------------------------------------------ openrouter

local openrouter: Adapter = {
	id = "openrouter",
	label = t("pv.openrouter.label"),
	kind = "money",
	match = function(baseUrl)
		return baseUrl:find("openrouter", 1, true) ~= nil
	end,
	requests = function(_baseUrl, key)
		-- 用 /api/v1/credits（账户余额）；/key 的 limit_remaining 是消费上限，不是余额
		return { { url = "https://openrouter.ai/api/v1/credits", headers = bearer(key) } }
	end,
	parse = function(body)
		local d = decode(body)
		if not d then
			return fail(t("pv.notJson"))
		end
		local data = d.data
		local total = tonumber(if type(data) == "table" then data.total_credits else nil)
		if total == nil then
			return fail(t("pv.missingField", "data.total_credits"))
		end
		local used = tonumber(if type(data) == "table" then data.total_usage else nil) or 0
		return money(total - used, "USD")
	end,
}

----------------------------------------------------------------- siliconflow

local siliconflow: Adapter = {
	id = "siliconflow",
	label = t("pv.siliconflow.label"),
	kind = "money",
	match = function(baseUrl)
		return baseUrl:find("siliconflow", 1, true) ~= nil
	end,
	requests = function(baseUrl, key)
		local host = if baseUrl and baseUrl:find("siliconflow.cn", 1, true) then
			"https://api.siliconflow.cn"
		else
			"https://api.siliconflow.com"
		return { { url = host .. "/v1/user/info", headers = bearer(key) } }
	end,
	parse = function(body, _step, baseUrl)
		local d = decode(body)
		if not d then
			return fail(t("pv.notJson"))
		end
		local data = d.data
		local amount = tonumber(if type(data) == "table" then data.totalBalance else nil)
		if amount == nil then
			return fail(t("pv.missingField", "data.totalBalance"))
		end
		local currency = if baseUrl and baseUrl:find("siliconflow.cn", 1, true) then "CNY" else "USD"
		return money(amount, currency)
	end,
}

----------------------------------------------------------------------- kimi

local kimi: Adapter = {
	id = "kimi",
	label = t("pv.kimi.label"),
	kind = "window",
	match = function(baseUrl)
		return baseUrl:find("kimi", 1, true) ~= nil or baseUrl:find("moonshot", 1, true) ~= nil
	end,
	requests = function(baseUrl, key)
		local host = if baseUrl and (baseUrl:find("kimi.ai", 1, true) or baseUrl:find("moonshot", 1, true))
			then "https://api.kimi.ai"
			else "https://api.kimi.com"
		return { { url = host .. "/coding/v1/usages", headers = bearer(key) } }
	end,
	parse = function(body)
		local d = decode(body)
		if not d then
			return fail(t("pv.notJson"))
		end
		local five: QuotaWindow? = nil
		if type(d.limits) == "table" then
			for _, lim in d.limits do
				if type(lim) == "table" and type(lim.detail) == "table" then
					local p = pct(lim.detail.remaining, lim.detail.limit)
					if p ~= nil then
						five = { remainingPct = p, resetAtMs = toMs(lim.detail.resetTime) }
					end
					break
				end
			end
		end
		local weekly: QuotaWindow? = nil
		if type(d.usage) == "table" then
			local p = pct(d.usage.remaining, d.usage.limit)
			if p ~= nil then
				weekly = { remainingPct = p, resetAtMs = toMs(d.usage.resetTime) }
			end
		end
		if five == nil and weekly == nil then
			return fail(t("pv.missingField", "limits/usage data"))
		end
		return { kind = "window", fiveHour = five, weekly = weekly }
	end,
}

---------------------------------------------------------------------- zhipu

local zhipu: Adapter = {
	id = "zhipu",
	label = t("pv.zhipu.label"),
	kind = "window",
	match = function(baseUrl)
		return baseUrl:find("bigmodel", 1, true) ~= nil
			or baseUrl:find("zhipu", 1, true) ~= nil
			or baseUrl:find("glm", 1, true) ~= nil
			or baseUrl:find("z.ai", 1, true) ~= nil
	end,
	requests = function(baseUrl, key)
		local host = if baseUrl and baseUrl:find("bigmodel.cn", 1, true) then
			"https://open.bigmodel.cn"
		else
			"https://api.z.ai"
		return {
			{ url = host .. "/api/monitor/usage/quota/limit", headers = raw(key) },
			{ url = host .. "/api/biz/account/query-customer-account-report", headers = raw(key) },
		}
	end,
	parse = function(body, step, baseUrl)
		local d = decode(body)
		if not d then
			return fail(t("pv.notJson"))
		end
		if step == 1 then
			if d.success == false then
				-- 业务码 40100–40199 视为认证失败（dsh-musage 的分类）
				local code = tonumber(d.code)
				if code ~= nil and code >= 40100 and code <= 40199 then
					return fail(t("pv.authFailedCode", math.floor(code)))
				end
				-- 其余 success:false（如「当前用户不存在coding plan」）→ 回退余额端点
				return { fallback = true }
			end
			local data = d.data
			local limits = if type(data) == "table" then data.limits else nil
			if type(limits) ~= "table" then
				return fail(t("pv.missingField", "data.limits"))
			end
			local five: QuotaWindow? = nil
			local weekly: QuotaWindow? = nil
			for _, lim in limits do
				if type(lim) == "table" then
					local used = tonumber(lim.percentage) -- 服务端算好的「已用 %」
					local unit = tonumber(lim.unit) -- 3 = 5h 窗口，6 = 周窗口
					if used ~= nil and unit ~= nil then
						local w: QuotaWindow = { remainingPct = clamp100(100 - used), resetAtMs = toMs(lim.nextResetTime) }
						if unit == 3 then
							five = w
						elseif unit == 6 then
							weekly = w
						end
					end
				end
			end
			if five == nil and weekly == nil then
				return fail(t("pv.missingField", "limits data"))
			end
			return { kind = "window", fiveHour = five, weekly = weekly }
		end
		-- step 2：账户余额（按量付费账户）
		local data = d.data
		local bal = tonumber(if type(data) == "table" then (data.availableBalance or data.balance) else nil)
		if bal == nil then
			local msg = if type(d.msg) == "string" and d.msg ~= "" then d.msg else t("pv.balanceUnreadable")
			return fail(msg)
		end
		local currency = if baseUrl and baseUrl:find("bigmodel.cn", 1, true) then "CNY" else "USD"
		return money(bal, currency, t("pv.payAsYouGo"))
	end,
}

-------------------------------------------------------------------- minimax

-- MiniMax 双结构：新版直接给 remaining_percent，旧版给 usage/total 计数。
-- current_weekly_status == 3 表示无周限制（跳过周窗口）。
local function minimaxWindow(remainingPctV: any, statusV: any, usedCount: any, totalCount: any, endTime: any): QuotaWindow?
	local status = tonumber(statusV)
	if status == 3 then
		return nil
	end
	local rpct = tonumber(remainingPctV)
	if rpct ~= nil then
		local remaining = if status == 2 then 0 else clamp100(rpct)
		return { remainingPct = remaining, resetAtMs = toMs(endTime) }
	end
	local used, total = tonumber(usedCount), tonumber(totalCount)
	if used ~= nil and total ~= nil and total > 0 then
		return { remainingPct = clamp100((total - used) / total * 100), resetAtMs = toMs(endTime) }
	end
	return nil
end

local minimax: Adapter = {
	id = "minimax",
	label = t("pv.minimax.label"),
	kind = "window",
	match = function(baseUrl)
		return baseUrl:find("minimax", 1, true) ~= nil
	end,
	requests = function(baseUrl, key)
		-- api.minimax.cn 是较新的推理域名、无配额 API：统一路由到 minimaxi.com / minimax.io
		local host = if baseUrl and baseUrl:find("minimax.io", 1, true) then
			"https://api.minimax.io"
		else
			"https://api.minimaxi.com"
		return { { url = host .. "/v1/api/openplatform/coding_plan/remains", headers = bearer(key) } }
	end,
	parse = function(body)
		local d = decode(body)
		if not d then
			return fail(t("pv.notJson"))
		end
		local br = d.base_resp
		if type(br) == "table" then
			local code = tonumber(br.status_code)
			if code ~= nil and code ~= 0 then
				local msg = if type(br.status_msg) == "string" and br.status_msg ~= "" then br.status_msg else ""
				if msg ~= "" then
					return fail(t("pv.apiError", math.floor(code), msg))
				end
				return fail(t("pv.apiErrorCode", math.floor(code)))
			end
		end
		local remains = d.model_remains
		local g: any = nil
		if type(remains) == "table" then
			for _, m in remains do
				if type(m) == "table" and m.model_name == "general" then
					g = m
					break
				end
			end
		end
		if g == nil then
			return fail(t("pv.missingField", "general plan data"))
		end
		local five = minimaxWindow(
			g.current_interval_remaining_percent,
			g.current_interval_status,
			g.current_interval_usage_count,
			g.current_interval_total_count,
			g.end_time
		)
		local weekly = minimaxWindow(
			g.current_weekly_remaining_percent,
			g.current_weekly_status,
			g.current_weekly_usage_count,
			g.current_weekly_total_count,
			g.weekly_end_time
		)
		if five == nil and weekly == nil then
			return fail(t("pv.missingField", "window data"))
		end
		return { kind = "window", fiveHour = five, weekly = weekly }
	end,
}

--------------------------------------------------------------------- novita

local novita: Adapter = {
	id = "novita",
	label = t("pv.novita.label"),
	kind = "money",
	match = function(baseUrl)
		return baseUrl:find("novita", 1, true) ~= nil
	end,
	requests = function(_baseUrl, key)
		return { { url = "https://api.novita.ai/v3/user/balance", headers = bearer(key) } }
	end,
	parse = function(body)
		local d = decode(body)
		if not d then
			return fail(t("pv.notJson"))
		end
		local rawBalance = tonumber(d.availableBalance)
		if rawBalance == nil then
			return fail(t("pv.missingField", "availableBalance"))
		end
		return money(rawBalance / 10000, "USD") -- 单位是 0.0001 USD
	end,
}

------------------------------------------------------------------- stepfun

local stepfun: Adapter = {
	id = "stepfun",
	label = t("pv.stepfun.label"),
	kind = "money",
	match = function(baseUrl)
		return baseUrl:find("stepfun", 1, true) ~= nil
	end,
	requests = function(_baseUrl, key)
		return { { url = "https://api.stepfun.com/v1/accounts", headers = bearer(key) } }
	end,
	parse = function(body)
		local d = decode(body)
		if not d then
			return fail(t("pv.notJson"))
		end
		local balance = tonumber(d.balance)
		if balance == nil then
			return fail(t("pv.missingField", "balance"))
		end
		return money(balance, "CNY")
	end,
}

------------------------------------------------------------------- sub2api

local sub2api: Adapter = {
	id = "sub2api",
	label = t("pv.sub2api.label"),
	kind = "money",
	needsBaseUrl = true,
	match = function(baseUrl)
		return baseUrl:find("sub2api", 1, true) ~= nil
	end,
	requests = function(baseUrl, key)
		local base = strip_trailing_slash_and_v1(baseUrl or "")
		return { { url = base .. "/v1/usage", headers = bearer(key) } }
	end,
	parse = function(body)
		local d = decode(body)
		if not d then
			return fail(t("pv.notJson"))
		end
		if d.isValid == false then
			return fail(t("pv.keyInvalid"))
		end
		local note = if type(d.planName) == "string" and d.planName ~= "" then t("pv.plan", d.planName) else nil
		local remaining = tonumber(d.remaining)
		if remaining ~= nil and remaining >= 0 then
			local unit = if type(d.unit) == "string" then d.unit else ""
			return money(remaining, unit, note)
		end
		-- remaining < 0 或缺失 = 不限量分组，不渲染数字
		local extra = t("pv.unlimited")
		if type(d.quota) == "table" then
			local limit, used = tonumber(d.quota.limit), tonumber(d.quota.used)
			if limit ~= nil and limit > 0 and used ~= nil then
				extra = t("pv.unlimitedUsed", clamp100(used / limit * 100))
			end
		end
		return { kind = "money", note = if note then note .. " · " .. extra else extra }
	end,
}

-------------------------------------------------------------------- registry

local M = {}

local list: { Adapter } = {
	deepseek,
	openrouter,
	siliconflow,
	kimi,
	zhipu,
	minimax,
	novita,
	stepfun,
	sub2api,
}

function M.list(): { Adapter }
	return list
end

function M.by_id(id: string): Adapter?
	for _, a in list do
		if a.id == id then
			return a
		end
	end
	return nil
end

-- 按 baseUrl 猜适配器（加表单时预选 / omp 导入时兜底）
function M.match(baseUrl: string): Adapter?
	local url = baseUrl or ""
	for _, a in list do
		if a.match(url) then
			return a
		end
	end
	return nil
end

-- 类型下拉框选项（select 的 options）
function M.options(): { { value: string, label: string, detail: string } }
	local opts: { { value: string, label: string, detail: string } } = {}
	for i, a in list do
		opts[i] = {
			value = a.id,
			label = a.label,
			detail = if a.needsBaseUrl then t("pv.opt.needsBaseUrl") else (if a.kind == "window" then t("pv.opt.window") else t("pv.opt.balance")),
		}
	end
	return opts
end

return M
