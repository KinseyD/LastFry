--!strict
-- 🍟 omp（oh my pi）导入：`omp auth export` → 供应商凭据 JSON，
-- 加上 ~/.omp/agent/models.yml（可选）里的自定义 baseUrl。
-- 本机验证过 export 格式（密钥已打码）：
--   { "version": 1,
--     "credentials": [ { "provider": "zhipu-coding-plan",
--                        "credential": { "type": "api_key", "key": "…", "source": "login" } } ] }
-- 只在本插件内处理密钥；任何日志/提示都不带 key 本体。

local providers = require("./providers")

local i18n = require("./i18n")

local t = i18n.t

export type ImportedEntry = {
	name: string, -- omp 供应商名，作为显示名
	type: string, -- 适配器 id
	baseUrl: string?,
	key: string,
}

-- `omp auth export` 的退出四元组：tern.process.run 的 ProcessResult（正常
-- 回调）与 process_exit 事件的 ProcessExitEvent（子进程活过了自己的 VM，
-- 由重载后的新 VM 收尾）字段相同，共用同一条转换路径（outcome_from_exit）。
export type ExitQuad = { status: number, stdout: string, stderr: string, timed_out: boolean }

export type ImportOutcome = {
	imported: { ImportedEntry },
	skipped: { string }, -- 跳过原因（含供应商名）
	err: string?,
}

local M = {}

------------------------------------------------------------------ omp 可执行文件

-- 先试 PATH 上的 omp（从桌面启动的 Tern 环境可能更小），再落到 Tern 托管的位置。
-- USERPROFILE 动态解析，绝不硬编码用户名。
local function exe_candidates(): { string }
	local c: { string } = { "omp" }
	local home = tern.getenv("USERPROFILE")
	if home ~= nil and home ~= "" then
		table.insert(c, (home:gsub("\\+$", "/")) .. "/AppData/Local/Tern/omp/bin/omp.exe")
	end
	return c
end

local function first_line(s: string?): string
	if s == nil or s == "" then
		return ""
	end
	return (s:match("^[^\r\n]+")) or ""
end

-- 依次尝试候选可执行文件跑 `auth export`；所有候选都起不来（不在 PATH
-- 等）时以 r = nil 收尾，失败状态在 outcome_from_exit 里统一报。
local function run_export(cb: (r: ExitQuad?, cx: any) -> ())
	local candidates = exe_candidates()
	local function attempt(i: number)
		local exe = candidates[i]
		if exe == nil then
			cb(nil, nil)
			return
		end
		local ok = pcall(tern.process.run, { exe, "auth", "export" }, { timeout_ms = 15000 }, cb)
		if not ok then
			attempt(i + 1) -- 这个候选根本起不来（不在 PATH），换下一个
		end
	end
	attempt(1)
end

------------------------------------------------------------------ 名称 → 适配器

-- omp 供应商名（或自定义 baseUrl）→ 适配器 id。按顺序子串匹配。
type Rule = { pat: string, adapter: string }

local NAME_RULES: { Rule } = {
	{ pat = "zhipu", adapter = "zhipu" },
	{ pat = "bigmodel", adapter = "zhipu" },
	{ pat = "glm", adapter = "zhipu" },
	{ pat = "z.ai", adapter = "zhipu" },
	{ pat = "deepseek", adapter = "deepseek" },
	{ pat = "moonshot", adapter = "kimi" },
	{ pat = "kimi", adapter = "kimi" },
	{ pat = "siliconflow", adapter = "siliconflow" },
	{ pat = "openrouter", adapter = "openrouter" },
	{ pat = "minimax", adapter = "minimax" },
	{ pat = "novita", adapter = "novita" },
	{ pat = "stepfun", adapter = "stepfun" },
	{ pat = "sub2api", adapter = "sub2api" },
}

function M.map_provider(name: string): string?
	local lower = name:lower()
	for _, rule in NAME_RULES do
		if lower:find(rule.pat, 1, true) ~= nil then
			return rule.adapter
		end
	end
	return nil
end

------------------------------------------------------------------ models.yml

local function agent_dir(): string
	local env = tern.getenv("PI_CODING_AGENT_DIR")
	if env ~= nil and env ~= "" then
		return (env:gsub("\\+$", "/"):gsub("/+$", ""))
	end
	local home = tern.getenv("USERPROFILE") or ""
	return (home:gsub("\\+$", "/")) .. "/.omp/agent"
end

local function strip_value(v: string): string
	v = v:match("^%s*(.-)%s*$") or v
	v = (v:gsub("%s+#.*$", "")) -- 去行尾注释
	if #v >= 2 and v:sub(1, 1) == '"' and v:sub(-1) == '"' then
		return v:sub(2, -2)
	end
	if #v >= 2 and v:sub(1, 1) == "'" and v:sub(-1) == "'" then
		return v:sub(2, -2)
	end
	return v
end

-- 极小 YAML 扫描器：只要 providers.<id>.baseUrl（两层缩进结构），不引第三方库。
local function scan_models(text: string): { [string]: string }
	local out: { [string]: string } = {}
	local in_providers = false
	local current: string? = nil
	local current_indent = 0
	for line in text:gmatch("[^\r\n]+") do
		local indent = #(line:match("^(%s*)") or "")
		local content = (line:match("^%s*(.-)%s*$") or "")
		if content == "" or content:sub(1, 1) == "#" then
			-- 空行 / 注释
		elseif indent == 0 then
			in_providers = content == "providers:"
			current = nil
		elseif in_providers then
			local entry = content:match("^([%w][%w_%-%.]*):$")
			if entry ~= nil and (current == nil or indent <= current_indent) then
				current = entry
				current_indent = indent
			else
				local k, v = content:match("^([%w_]+):%s*(.+)$")
				if k == "baseUrl" and v ~= nil and current ~= nil and indent > current_indent then
					out[current] = strip_value(v)
				end
			end
		end
	end
	return out
end

function M.read_models_baseurls(): { [string]: string }
	local dir = agent_dir()
	for _, name in { "models.yml", "models.yaml" } do
		local ok, text = pcall(tern.fs.read, dir .. "/" .. name)
		if ok and type(text) == "string" and text ~= "" then
			return scan_models(text)
		end
	end
	return {}
end

------------------------------------------------------------------ 导入主流程

-- 解析 `omp auth export` 的 stdout；正常回调与 process_exit 补送两条路共用。
function M.parse_export(stdout: string): ImportOutcome
	local ok, doc = pcall(tern.json.decode, stdout)
	if not ok or type(doc) ~= "table" or type(doc.credentials) ~= "table" then
		return { imported = {}, skipped = {}, err = t("omp.badJson") }
	end
	local baseurls = M.read_models_baseurls()
	local imported: { ImportedEntry } = {}
	local skipped: { string } = {}
	for _, cred in doc.credentials do
		if type(cred) ~= "table" or type(cred.provider) ~= "string" then
			continue
		end
		local pname = cred.provider
		local c = cred.credential
		if type(c) ~= "table" or c.type ~= "api_key" or type(c.key) ~= "string" or c.key == "" then
			table.insert(skipped, t("omp.skip.notApiKey", pname))
			continue
		end
		local base = baseurls[pname]
		-- 名字匹配不到时，再用自定义 baseUrl 兜底匹配一次
		local adapter_id = M.map_provider(pname)
		if adapter_id == nil and base ~= nil then
			local a = providers.match(base)
			adapter_id = if a ~= nil then a.id else nil
		end
		if adapter_id == nil then
			table.insert(skipped, t("omp.skip.unsupported", pname))
		elseif adapter_id == "sub2api" and (base == nil or base == "") then
			table.insert(skipped, t("omp.skip.sub2apiNoBase", pname))
		else
			table.insert(imported, {
				name = pname,
				type = adapter_id,
				baseUrl = if base ~= nil and base ~= "" then base else nil,
				key = c.key,
			})
		end
	end
	return { imported = imported, skipped = skipped }
end

-- 退出四元组 → ImportOutcome：status == 0 且有输出才解析；超时被杀 / 信号
-- 退出（status = -1）与非零退出统一走 exportFailed。
function M.outcome_from_exit(r: ExitQuad): ImportOutcome
	if r.status == 0 and r.timed_out ~= true and r.stdout ~= "" then
		return M.parse_export(r.stdout)
	end
	return { imported = {}, skipped = {}, err = t("omp.exportFailed", tostring(r.status), first_line(r.stderr)) }
end

function M.import(cb: (outcome: ImportOutcome, cx: any) -> ())
	run_export(function(r, cx)
		if r == nil then
			cb({ imported = {}, skipped = {}, err = t("omp.notFound") }, cx)
			return
		end
		cb(M.outcome_from_exit(r), cx)
	end)
end

return M
