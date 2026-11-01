--!strict
-- 🍟 i18n — every user-facing string lives in the table below and is looked
-- up with t(key, …). English ("en") is fully populated and the fallback; a
-- future language drops in as one more table beside `en` (plus its value in
-- settings) without touching any call site. The active language comes from
-- the `language` setting (default "en"; unknown values fall back to "en")
-- and is cached here, so hot paths like the statusline formatter never
-- touch kv.

local store = require("./store")

local en: { [string]: string } = {
	-- statusline segments (window half)
	["status.pending"] = "🍟 %s …",
	["status.lead"] = "🍟 %s %s",
	-- compact countdown in a statusline window part: days is the max unit
	["status.cd.now"] = "now",
	["status.cd.m"] = "%dm",
	["status.cd.hm"] = "%dh%02dm",
	["status.cd.d"] = "%dd",
	-- countdown rides in parentheses after its own window's pct
	["status.cd"] = " (%s)",
	-- divider opening each continuation window segment (after a provider's first)
	["status.divider"] = "· ",
	["status.window5h"] = "5h %.0f%% left",
	["status.window7d"] = "7d %.0f%% left",
	["status.window30d"] = "30d %.0f%% left",
	["status.noWindowData"] = "🍟 %s no window data",
	["status.unknown"] = "🍟 %s ?",
	["status.none"] = "🍟 No fries providers yet",

	-- query result lines (window half; stored in kv, shown in table + segment)
	["result.line5h"] = "5h %.2f%%",
	["result.line7d"] = "7d %.2f%%",
	["result.line30d"] = "30d %.2f%%",
	["result.noWindowData"] = "No window data",
	["result.noBalanceData"] = "No balance data",
	["result.retryIn"] = ", retrying in %ds",
	["money.fries"] = "%s fries",

	-- query errors (window half)
	["err.unknownProviderType"] = "Unknown provider type %s",
	["err.readKey"] = "Failed to read key: %s",
	["err.noKey"] = "API key not set",

	-- omp import (window half)
	["omp.failed"] = "🍟 omp import failed",
	["omp.imported"] = "🍟 Imported %d fries providers, skipped %d",
	["omp.listSep"] = ", ",
	["omp.notFound"] = "omp not found (on PATH or at %USERPROFILE%\\AppData\\Local\\Tern\\omp\\bin\\omp.exe)",
	["omp.exportFailed"] = "omp auth export failed (exit %s) %s",
	["omp.badJson"] = "omp auth export did not return the expected JSON",
	["omp.skip.notApiKey"] = "%s (not an API-key credential)",
	["omp.skip.unsupported"] = "%s (unsupported provider)",
	["omp.skip.sub2apiNoBase"] = "%s (sub2api needs a baseUrl)",

	-- palette commands (window half)
	["cmd.refresh.title"] = "🍟 Refresh fries quota",
	["cmd.manage.title"] = "🍟 Open the fries manager",
	["cmd.import.title"] = "🍟 Import providers from omp",

	-- toasts (window half)
	["toast.refreshing"] = "🍟 Refreshing fries…",
	["toast.refreshingSub"] = "Low-fries warnings appear in the manage panel",
	["toast.manageFail"] = "🍟 Cannot open the fries manager",
	["toast.manageFailSub"] = "Host half not ready",
	["toast.sealed"] = "🍟 Sealed %d keys",
	["toast.sealedSub"] = "Stored in the system keychain",

	-- log lines (window half)
	["log.sealKeyFailed"] = "🍟 Failed to seal key",
	["log.importDone"] = "🍟 omp import finished",
	["log.importDoneDetail"] = "imported %d, skipped %d",
	["log.keyWriteFailed"] = "🍟 Failed to write key",
	["log.sealedKeys"] = "🍟 Sealed keys",
	["log.sealedCount"] = "%d keys",
	["log.forgetKeyFailed"] = "🍟 Failed to delete key",

	-- manage block: header, buttons, dock (host half)
	["block.title"] = "🍟 Fries quota",
	["header.title"] = "🍟 Last fry",
	["header.tagline"] = "  watch your LLM API fries",
	["btn.refresh"] = "Refresh now",
	["btn.import"] = "Import from omp",
	["btn.add"] = "Add provider",
	["dock.summary"] = "%d providers · refresh every %ds · warn below %d%%",

	-- provider cards (host half)
	["table.empty"] = "No providers yet — add one or import from omp",
	["quota.pct"] = "%.0f%% left",
	["quota.balLabel"] = "Quota",
	["btn.rowEnabled"] = "Enabled",
	["btn.rowDisabled"] = "Disabled",
	["btn.edit"] = "Edit",
	["btn.delete"] = "Delete",

	-- status badges (host half)
	["badge.none"] = "Not queried",
	["badge.out"] = "Out of fries",
	["badge.low"] = "Fries running low",
	["badge.ok"] = "OK",
	["badge.stale"] = "Stale",
	["badge.error"] = "Failed",

	-- countdown next to a window row (host half); days is the max unit
	["countdown.soon"] = "resetting soon",
	["countdown.d"] = "resets in %dd",
	["countdown.hms"] = "resets in %dh%02dm",
	["countdown.m"] = "resets in %dm",

	-- provider form (host half)
	["form.title.add"] = "Add provider",
	["form.title.edit"] = "Edit provider",
	["form.label.name"] = "Name",
	["form.hint.name"] = "Display name",
	["form.placeholder.name"] = "e.g. Zhipu Coding Plan",
	["form.label.type"] = "Type",
	["form.hint.type"] = "Quota endpoint adapter",
	["form.placeholder.type"] = "Choose a provider type…",
	["form.label.baseUrl"] = "baseUrl",
	["form.hint.baseUrlRequired"] = "Required: relay endpoint, e.g. https://relay.example.com/v1",
	["form.hint.baseUrlOptional"] = "Optional: custom gateway URL; empty uses the official endpoint",
	["form.label.apiKey"] = "API Key",
	["form.hint.keyKeep"] = "Leave empty to keep the current key",
	["form.hint.keyNew"] = "Stored only in the system keychain (tern.secrets)",
	["form.btn.save"] = "Save",
	["form.btn.cancel"] = "Cancel",
	["form.err.nameRequired"] = "Name is required",
	["form.err.typeRequired"] = "Choose a provider type",
	["form.err.baseUrlRequired"] = "%s needs a baseUrl",

	-- settings card (host half)
	["settings.title"] = "Settings",
	["settings.label.interval"] = "Refresh interval",
	["settings.hint.interval"] = "Seconds (30–86400), default 300",
	["settings.unit.sec"] = "s",
	["settings.label.warn"] = "Fries warn threshold",
	["settings.hint.warn"] = 'Alert "Fries running low" when remaining % drops below this',
	["settings.btn.save"] = "Save settings",
	["settings.err.intervalRange"] = "Refresh interval must be 30–86400 seconds",
	["settings.err.warnRange"] = "Warn threshold must be 0–100",
	["settings.saved"] = "Saved 🍟",
	["settings.label.scale"] = "Quota bar full scale",
	["settings.hint.scale"] = "The Quota bar fills at this many fries",
	["settings.unit.fries"] = "fries",
	["settings.err.scaleRange"] = "Quota bar scale must be at least 1",

	-- provider adapters: dropdown labels, option details, parse errors
	["pv.deepseek.label"] = "DeepSeek",
	["pv.openrouter.label"] = "OpenRouter",
	["pv.siliconflow.label"] = "SiliconFlow",
	["pv.kimi.label"] = "Kimi / Moonshot",
	["pv.zhipu.label"] = "Zhipu / Z.ai",
	["pv.minimax.label"] = "MiniMax",
	["pv.novita.label"] = "Novita AI",
	["pv.stepfun.label"] = "StepFun",
	["pv.sub2api.label"] = "Sub2API",
	["pv.opt.needsBaseUrl"] = "needs baseUrl",
	["pv.opt.window"] = "window quota",
	["pv.opt.balance"] = "balance",
	["pv.notJson"] = "Response is not JSON",
	["pv.missingField"] = "Response missing %s",
	["pv.balanceMissing"] = "Balance field missing",
	["pv.balanceUnavailable"] = "Balance unavailable (overdrawn or zero)",
	["pv.authFailedCode"] = "Auth failed (%d)",
	["pv.balanceUnreadable"] = "Cannot read balance",
	["pv.payAsYouGo"] = "Pay-as-you-go balance",
	["pv.apiError"] = "API error %d: %s",
	["pv.apiErrorCode"] = "API error %d",
	["pv.keyInvalid"] = "Key invalid or expired",
	["pv.plan"] = "Plan %s",
	["pv.unlimited"] = "Unlimited group",
	["pv.unlimitedUsed"] = "Unlimited group, %.1f%% used",

	-- fetch/parse classification (query layer, window half)
	["q.parseFailed"] = "Failed to parse response",
	["q.authFailedHttp"] = "Auth failed (HTTP %d)",
	["q.rateLimited"] = "rate limited",
	["q.serverError"] = "server error",
	["q.httpStatus"] = "HTTP %d (%s)",
	["q.httpCode"] = "HTTP %d",
}

-- One table per language; `en` above is the fallback for missing keys.
-- A future language (e.g. zh) drops in here plus its settings value.
local tables: { [string]: { [string]: string } } = {
	en = en,
}

local M = {}

local lang = "en"

-- Re-read the language from settings; an unknown value falls back to "en".
function M.sync()
	local l = store.get_settings().language
	if tables[l] ~= nil then
		lang = l
	else
		lang = "en"
	end
end

-- t("key") → the string; t("key", …) → the string formatted with the
-- arguments. An unknown key returns the key itself, so a gap is visible
-- instead of a crash.
function M.t(key: string, ...: any): string
	local s: string? = nil
	local tbl = tables[lang]
	if tbl ~= nil then
		s = tbl[key]
	end
	if s == nil then
		s = en[key]
	end
	if s == nil then
		return key
	end
	if select("#", ...) == 0 then
		return s
	end
	return (s:format(...))
end

M.sync()

return M
