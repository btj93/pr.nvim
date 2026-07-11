-- Fake CLI executables for provider-layer specs. Each stub is a generated
-- /bin/sh script: it first logs its argv, then walks the ordered routes; the
-- first route whose match tokens appear in argv as an ordered subsequence
-- wins. No match -> exit 99 with argv echoed to stderr, so failures are
-- self-diagnosing.
--
-- Matching semantics: a match token is found as a substring of the
-- \x1f-delimited argv (ordered, left-to-right, consuming past each hit). The
-- \x1f delimiters keep tokens apart, so a token without a \x1f byte can only
-- match within a single argv token -- e.g. `{ "/user" }` matches the argv
-- token `https://api/x/user`. This is required by the locked spec (curl's
-- `/user` route against a URL); pure whole-token equality cannot express it.
-- A route with an empty or absent `match` has no tokens to fail, so it matches
-- every argv: use it as an always-matching catch-all (order it last).
local M = {}

-- \x1e (record) and \x1f (field) separators used in the argv log. Kept out of
-- band from normal CLI argv, so they never collide with real tokens.
local RS, FS = "\30", "\31"

-- Wrap a string so /bin/sh reads it as a single literal word. Callers only
-- pass newline-free segments, so this never has to survive an embedded NL
-- (vim.fn.writefile would corrupt those into NUL bytes).
local function sh_quote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Emit `s` verbatim to fd `redirect` ("" = stdout, " >&2" = stderr). Newlines
-- become their own `printf '\n'` lines so no script line ever carries a raw
-- NL (writefile would turn one into a NUL and truncate the C string).
local function emit_text(lines, s, redirect)
	local segs = vim.split(s, "\n", { plain = true })
	for i, seg in ipairs(segs) do
		if i > 1 then
			lines[#lines + 1] = "\tprintf '\\n'" .. redirect
		end
		lines[#lines + 1] = "\tprintf '%s' " .. sh_quote(seg) .. redirect
	end
end

-- Append the sh block that decides + serves one route to `lines`.
local function emit_route(lines, route)
	local quoted = {}
	for _, tok in ipairs(route.match or {}) do
		quoted[#quoted + 1] = sh_quote(tok)
	end
	lines[#lines + 1] = "ok=1; rest=$argv"
	if #quoted > 0 then
		lines[#lines + 1] = "for tok in " .. table.concat(quoted, " ") .. "; do"
		lines[#lines + 1] = '\tcase "$rest" in'
		lines[#lines + 1] = '\t\t*"$tok"*) rest=${rest#*"$tok"} ;;'
		lines[#lines + 1] = "\t\t*) ok=0; break ;;"
		lines[#lines + 1] = "\tesac"
		lines[#lines + 1] = "done"
	end
	lines[#lines + 1] = 'if [ "$ok" = 1 ]; then'
	if route.stdout_file then
		lines[#lines + 1] = "\tcat " .. sh_quote(route.stdout_file)
	elseif route.stdout ~= nil then
		emit_text(lines, route.stdout, "")
	end
	if route.stderr then
		emit_text(lines, route.stderr .. "\n", " >&2")
	end
	lines[#lines + 1] = "\texit " .. tostring(route.exit or 0)
	lines[#lines + 1] = "fi"
end

function M.new()
	local bindir = vim.fn.tempname()
	vim.fn.mkdir(bindir, "p")
	local shim = { bindir = bindir, _logs = {}, _saved_path = nil }

	function shim.stub(name, routes)
		local exe = bindir .. "/" .. name
		local log = exe .. ".log"
		shim._logs[name] = log
		local lines = {
			"#!/bin/sh",
			-- byte separators are materialised at runtime so the script file
			-- itself stays printable ASCII.
			"sep=$(printf '\\037')",
			-- one log record per invocation: fields joined by \x1f, record
			-- terminated by \x1e (empty argv still emits a bare terminator).
			'{ first=1; for a in "$@"; do if [ "$first" = 1 ]; then printf \'%s\' "$a"; first=0; else printf \'\\037%s\' "$a"; fi; done; printf \'\\036\'; } >> '
				.. sh_quote(log),
			-- \x1f-delimited argv for ordered-subsequence matching.
			"argv=$sep",
			'for a in "$@"; do argv=$argv$a$sep; done',
		}
		for _, route in ipairs(routes) do
			emit_route(lines, route)
		end
		lines[#lines + 1] = "printf 'no route matched: %s\\n' \"$*\" >&2"
		lines[#lines + 1] = "exit 99"
		vim.fn.writefile(lines, exe)
		local uv = vim.uv or vim.loop
		uv.fs_chmod(exe, tonumber("755", 8))
	end

	function shim.install()
		assert(not shim._saved_path, "cli_shim: already installed")
		shim._saved_path = vim.env.PATH
		vim.env.PATH = bindir .. ":" .. vim.env.PATH
	end

	function shim.calls(name)
		local log = shim._logs[name]
		if not log or vim.fn.filereadable(log) == 0 then
			return {}
		end
		-- \x1e/\x1f are not newlines, so rejoin readfile's binary lines and
		-- split on the separators ourselves.
		local raw = table.concat(vim.fn.readfile(log, "b"), "\n")
		local out = {}
		local start = 1
		while true do
			local rs = raw:find(RS, start, true)
			if not rs then
				break
			end
			local record = raw:sub(start, rs - 1)
			start = rs + 1
			if record == "" then
				out[#out + 1] = {}
			else
				out[#out + 1] = vim.split(record, FS, { plain = true })
			end
		end
		return out
	end

	function shim.uninstall()
		if shim._saved_path then
			vim.env.PATH = shim._saved_path
			shim._saved_path = nil
		end
		vim.fn.delete(bindir, "rf")
	end

	return shim
end

return M
