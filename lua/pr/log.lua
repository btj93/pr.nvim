local config = require("pr.config")
local M = {}

-- A value *derived* by scanning argv is never used as a substring redaction
-- pattern below this length. A two-character comment body would otherwise be
-- scrubbed out of unrelated argv elements (endpoints, ids, shas) and destroy
-- the diagnostic; the argv element carrying it is still redacted positionally.
-- Secrets a provider passes explicitly are honored at any length.
local MIN_SECRET_LEN = 6

-- A CLOSED allowlist: a flag absent here has its value printed verbatim in
-- debug mode. Add any new credential- or payload-bearing curl/gh/glab flag
-- (--proxy-user, --cookie, --cert, --key, --data-urlencode, ...) before using
-- it in a provider.
local SENSITIVE_VALUE_FLAGS = {
	["-u"] = true,
	["--user"] = true,
	["-d"] = true,
	["--data"] = true,
	["--data-raw"] = true,
	["--data-binary"] = true,
}

-- Normal mode shows one line of cause so a default user learns *why* a command
-- failed -- an HTTP 422 is not an install problem, and the hint alone would say
-- otherwise. Capped so a stderr line carrying a wrapped body can never fill the
-- notification; the full (redacted) stderr is still debug-mode only.
local MAX_CAUSE_LEN = 160

-- Request-payload keys whose values are user-authored. Everything else in a
-- payload (paths, ids, line numbers) is structural and must stay readable.
local PAYLOAD_SECRET_KEYS = {
	raw = true,
	body = true,
	title = true,
	description = true,
	query = true,
}

local function escape_pattern(value)
	return (value:gsub("([^%w])", "%%%1"))
end

local function is_sensitive_key(key)
	key = key:lower()
	return key == "body"
		or key == "query"
		or key == "authorization"
		or key:find("cookie", 1, true) ~= nil
		or key:find("token", 1, true) ~= nil
		or key:find("password", 1, true) ~= nil
		or key:find("secret", 1, true) ~= nil
end

local function append_secret(out, value, explicit)
	if type(value) ~= "string" or value == "" then
		return
	end
	if explicit or #value >= MIN_SECRET_LEN then
		table.insert(out, value)
	end
end

local function collect_secrets(args, explicit)
	local out = {}
	for _, value in ipairs(explicit or {}) do
		append_secret(out, value, true)
	end
	local redact_next = false
	for _, raw in ipairs(args or {}) do
		local arg = tostring(raw)
		if redact_next then
			append_secret(out, arg)
			redact_next = false
		elseif SENSITIVE_VALUE_FLAGS[arg] then
			redact_next = true
		else
			local key, value = arg:match("^([^=]+)=(.*)$")
			if key and is_sensitive_key(key) then
				append_secret(out, value)
			end
		end
	end
	table.sort(out, function(a, b)
		return #a > #b
	end)
	return out
end

local function lines_to_text(value)
	if type(value) ~= "table" then
		return value == nil and "" or tostring(value)
	end
	local lines = {}
	for _, line in ipairs(value) do
		table.insert(lines, tostring(line))
	end
	return table.concat(lines, "\n")
end

-- The first line of `text` holding a non-space character, trimmed and capped.
-- CLI errors put the actionable message on the first line and hint/usage noise
-- below it, so one line is both the most useful cause and the least likely to
-- spill a wrapped body into the notification.
---@param text string
---@return string
local function first_cause_line(text)
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		local trimmed = vim.trim(line)
		if trimmed ~= "" then
			if #trimmed <= MAX_CAUSE_LEN then
				return trimmed
			end
			-- Cap is in bytes; back off while the byte *after* the cut is a UTF-8
			-- continuation byte (0x80-0xBF) so a multi-byte character is never
			-- split in half.
			local cut = MAX_CAUSE_LEN
			while cut > 0 do
				local next_byte = trimmed:byte(cut + 1)
				if not next_byte or next_byte < 0x80 or next_byte >= 0xC0 then
					break
				end
				cut = cut - 1
			end
			return trimmed:sub(1, cut) .. "…"
		end
	end
	return ""
end

--- Collect the user-authored strings out of a request payload table so they can
--- be passed as explicit secrets. Structural fields are deliberately skipped.
---@param payload any
---@param out string[]|nil
---@return string[]
function M.payload_secrets(payload, out)
	out = out or {}
	if type(payload) ~= "table" then
		return out
	end
	for key, value in pairs(payload) do
		if type(value) == "table" then
			M.payload_secrets(value, out)
		elseif type(value) == "string" and PAYLOAD_SECRET_KEYS[key] then
			table.insert(out, value)
		end
	end
	return out
end

---@param value string|string[]|nil
---@param secrets string[]|nil
---@return string
function M.redact_text(value, secrets)
	local out = lines_to_text(value)
	for _, secret in ipairs(collect_secrets({}, secrets)) do
		out = out:gsub(escape_pattern(secret), "<redacted>")
	end
	out = out:gsub("([%a][%w+.-]*://)[^/@%s]+@", "%1<redacted>@")
	-- `[ \t]*` rather than `%s*`: `%s` matches newlines, so a bare header name at
	-- the end of a line would otherwise swallow the whole next line of output.
	out = out:gsub("([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[ \t]*)[^\r\n]+", "%1<redacted>")
	out = out:gsub("([Cc][Oo][Oo][Kk][Ii][Ee]:[ \t]*)[^\r\n]+", "%1<redacted>")
	out = out:gsub("([Bb][Ee][Aa][Rr][Ee][Rr][ \t]+)[%w%._%-]+", "%1<redacted>")
	-- Any other sensitive header name (PRIVATE-TOKEN, X-Auth-Token, Set-Cookie).
	local lines = vim.split(out, "\n", { plain = true })
	for i, line in ipairs(lines) do
		local name, gap, rest = line:match("^[ \t>]*([%w%-]+):([ \t]*)(.+)$")
		if name and rest and is_sensitive_key(name) then
			lines[i] = name .. ":" .. gap .. "<redacted>"
		end
	end
	out = table.concat(lines, "\n")
	out = out:gsub("([Tt][Oo][Kk][Ee][Nn]=)[^%s&]+", "%1<redacted>")
	out = out:gsub("([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]=)[^%s&]+", "%1<redacted>")
	out = out:gsub("([Ss][Ee][Cc][Rr][Ee][Tt]=)[^%s&]+", "%1<redacted>")
	-- Bodies and GraphQL documents contain spaces, so these run to end of line.
	out = out:gsub("([Bb][Oo][Dd][Yy]=)[^\r\n]+", "%1<redacted>")
	out = out:gsub("([Qq][Uu][Ee][Rr][Yy]=)[^\r\n]+", "%1<redacted>")
	return out
end

---@param args string[]|nil
---@param secrets string[]|nil
---@return string[]
function M.redact_argv(args, secrets)
	local effective_secrets = collect_secrets(args, secrets)
	local out = {}
	local redact_next = false
	for i, raw in ipairs(args or {}) do
		local arg = tostring(raw)
		if redact_next then
			out[i] = "<redacted>"
			redact_next = false
		elseif SENSITIVE_VALUE_FLAGS[arg] then
			out[i] = arg
			redact_next = true
		else
			local key = arg:match("^([^=]+)=")
			if key and is_sensitive_key(key) then
				out[i] = key .. "=<redacted>"
			else
				out[i] = M.redact_text(arg, effective_secrets)
			end
		end
	end
	return out
end

--- A provider response that exited 0 but could not be decoded or normalized:
--- malformed JSON, or a schema the normalizer indexed into and raised on. The
--- response body is NEVER echoed -- it is the full API payload, carrying
--- unpublished review text. `operation` names the provider and the call, which
--- is what a user needs to place the failure. The raised Lua error is
--- `debug`-gated and redacted like every other diagnostic detail.
---@param operation string
---@param err any The value a `pcall` returned as its failure.
function M.response_unreadable(operation, err)
	vim.notify(operation .. " returned an unreadable response.", vim.log.levels.ERROR)
	if not config.opts.debug then
		return
	end
	vim.notify(M.redact_text(tostring(err)), vim.log.levels.INFO)
end

---@param operation string
---@param command string
---@param args string[]|nil
---@param stderr string|string[]|nil
---@param opts { hint: string?, secrets: string[]?, code: integer? }|nil
function M.command_failed(operation, command, args, stderr, opts)
	opts = opts or {}
	-- Redacted once, before the debug gate: the one-line cause shown in normal
	-- mode and the full stderr shown in debug mode are the same sanitized text.
	local secrets = collect_secrets(args, opts.secrets)
	local safe_stderr = M.redact_text(stderr, secrets)

	local message = operation .. " failed."
	local cause = first_cause_line(safe_stderr)
	if cause ~= "" then
		message = message .. " " .. cause
	end
	if opts.hint and opts.hint ~= "" then
		message = message .. " " .. opts.hint
	end
	vim.notify(message, vim.log.levels.ERROR)
	if not config.opts.debug then
		return
	end

	local detail = command
	if opts.code ~= nil then
		detail = detail .. " (exit " .. tostring(opts.code) .. ")"
	end
	if args and #args > 0 then
		detail = detail .. " " .. table.concat(M.redact_argv(args, secrets), " ")
	end
	vim.notify(detail, vim.log.levels.INFO)
	if safe_stderr:match("%S") then
		vim.notify(safe_stderr, vim.log.levels.INFO)
	end
end

return M
