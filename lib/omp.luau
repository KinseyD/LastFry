--!strict
-- 🍟 omp (oh my pi) import: `omp auth export` → provider credentials JSON,
-- plus custom baseUrls from ~/.omp/agent/models.yml (optional).
-- Export format verified on this machine (keys redacted):
--   { "version": 1,
--     "credentials": [ { "provider": "zhipu-coding-plan",
--                        "credential": { "type": "api_key", "key": "…", "source": "login" } } ] }
-- Keys are handled only inside this plugin; no log or toast ever carries a key.

local providers = require("./providers")

local i18n = require("./i18n")

local t = i18n.t

export type ImportedEntry = {
	name: string, -- omp provider name, used as the display name
	type: string, -- adapter id
	baseUrl: string?,
	key: string,
}

-- The exit quad from `omp auth export`: the ProcessResult of tern.process.run
-- (normal callback) and the ProcessExitEvent of the process_exit event (child
-- outlived its own VM, finished by the reloaded new VM) share the same fields,
-- so both go through one conversion path (outcome_from_exit).
export type ExitQuad = { status: number, stdout: string, stderr: string, timed_out: boolean }

export type ImportOutcome = {
	imported: { ImportedEntry },
	skipped: { string }, -- skip reasons (include the provider name)
	err: string?,
}

local M = {}

------------------------------------------------------------------ omp executable

-- Try the omp on PATH first (Tern launched from the desktop may see a smaller
-- environment), then fall back to Tern-managed locations.
-- USERPROFILE is resolved dynamically; never hardcode a username.
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

-- Try each candidate executable in order to run `auth export`; when no
-- candidate can even start (not on PATH, etc.) it ends with r = nil, and the
-- failure is reported uniformly in outcome_from_exit.
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
			attempt(i + 1) -- this candidate could not start at all (not on PATH); try the next
		end
	end
	attempt(1)
end

------------------------------------------------------------------ name → adapter

-- omp provider name (or custom baseUrl) → adapter id. Substring match in order.
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
	v = (v:gsub("%s+#.*$", "")) -- strip trailing comment
	if #v >= 2 and v:sub(1, 1) == '"' and v:sub(-1) == '"' then
		return v:sub(2, -2)
	end
	if #v >= 2 and v:sub(1, 1) == "'" and v:sub(-1) == "'" then
		return v:sub(2, -2)
	end
	return v
end

-- Minimal YAML scanner: only wants providers.<id>.baseUrl (two-level
-- indentation); no third-party library.
local function scan_models(text: string): { [string]: string }
	local out: { [string]: string } = {}
	local in_providers = false
	local current: string? = nil
	local current_indent = 0
	for line in text:gmatch("[^\r\n]+") do
		local indent = #(line:match("^(%s*)") or "")
		local content = (line:match("^%s*(.-)%s*$") or "")
		if content == "" or content:sub(1, 1) == "#" then
			-- blank line / comment
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

------------------------------------------------------------------ import flow

-- Parse the stdout of `omp auth export`; shared by the normal callback and the
-- process_exit late-delivery paths.
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
		-- If the name doesn't match, fall back to matching on the custom baseUrl once
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

-- Exit quad → ImportOutcome: parse only when status == 0 and there is output;
-- a killed timeout / signal exit (status = -1) and any nonzero exit both go
-- through exportFailed.
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
