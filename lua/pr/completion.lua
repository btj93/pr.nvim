-- Omnifunc-compatible completion for @user and #issue triggers.
-- Reads cached lists from the provider; first call after a clear triggers
-- an async fetch and returns an empty list while the fetch is in flight.

local M = {}

local cached_collaborators = nil
local cached_issues = nil

-- Test seams ----------------------------------------------------------------

local test_line = nil
local test_col = nil

---@param line string
---@param col integer  -- 0-indexed byte column (matches nvim_win_get_cursor)
function M._test_set_line(line, col)
	test_line = line
	test_col = col
end

---@param list any
function M._set_collaborators(list)
	cached_collaborators = list
end

---@param list any
function M._set_issues(list)
	cached_issues = list
end

---Drop in-memory test caches.
function M._reset()
	test_line = nil
	test_col = nil
	cached_collaborators = nil
	cached_issues = nil
end

---Drop just the collaborators cache. Called by :PRRefreshUsers so the next
---completion triggers a fresh fetch from the provider.
function M._clear_collaborators()
	cached_collaborators = nil
end

---Drop just the issues cache. Called by :PRRefreshIssues.
function M._clear_issues()
	cached_issues = nil
end

-- Helpers --------------------------------------------------------------------

local function get_line_col()
	if test_line ~= nil then
		return test_line, test_col
	end
	return vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[2]
end

local function is_word_char(ch)
	return ch:match("[%w%-_]") ~= nil
end

---Walk back from `col` (0-indexed) to find the start column of an `@`/`#`
---triggered word. Returns the byte column of the trigger char (0-indexed),
---or `col` itself when no trigger is found.
local function find_trigger_start(line, col)
	local i = col
	while i > 0 do
		local ch = line:sub(i, i)
		if ch == "@" or ch == "#" then
			return i - 1
		end
		if not is_word_char(ch) then
			return col
		end
		i = i - 1
	end
	return col
end

local function get_collaborators()
	if cached_collaborators then
		return cached_collaborators
	end
	local ok, provider = pcall(require, "pr.provider")
	if not ok then
		return {}
	end
	local git = provider.get_provider()
	if type(git.list_collaborators) ~= "function" then
		return {}
	end
	git.list_collaborators(function(list)
		cached_collaborators = list or {}
	end)
	return cached_collaborators or {}
end

local function get_issues()
	if cached_issues then
		return cached_issues
	end
	local ok, provider = pcall(require, "pr.provider")
	if not ok then
		return {}
	end
	local git = provider.get_provider()
	if type(git.list_issues) ~= "function" then
		return {}
	end
	git.list_issues(function(list)
		cached_issues = list or {}
	end)
	return cached_issues or {}
end

-- Public ---------------------------------------------------------------------

---Omnifunc compatible with Neovim's <C-x><C-o>.
---
---@param findstart integer  1 to return startcol, 0 to return items
---@param base string        the text matched so far (when findstart == 0)
function M.omnifunc(findstart, base)
	local config_ok, config = pcall(require, "pr.config")
	if config_ok and config.opts.completion and config.opts.completion.enabled == false then
		if findstart == 1 then
			return -1
		end
		return {}
	end

	local line, col = get_line_col()

	if findstart == 1 then
		return find_trigger_start(line, col)
	end

	-- base = the full word matched so far (e.g. "@al" or "#4")
	local trigger = base:sub(1, 1)
	local prefix = base:sub(2):lower()
	local items = {}

	if trigger == "@" then
		for _, u in ipairs(get_collaborators()) do
			if u.login and u.login:lower():sub(1, #prefix) == prefix then
				table.insert(items, {
					word = "@" .. u.login,
					menu = u.name or "",
				})
			end
		end
	elseif trigger == "#" then
		local issues = get_issues()
		-- Exact match takes precedence: if any issue number string equals the
		-- prefix verbatim, only that one is returned (so picking #42 doesn't
		-- also surface #421, #4200, etc.). When no exact match exists, fall
		-- back to prefix filtering.
		local exact = nil
		for _, i in ipairs(issues) do
			if i.number and tostring(i.number) == prefix then
				exact = i
				break
			end
		end
		if exact then
			table.insert(items, {
				word = "#" .. tostring(exact.number),
				menu = exact.title or "",
			})
		else
			for _, i in ipairs(issues) do
				if i.number then
					local num_str = tostring(i.number)
					if num_str:sub(1, #prefix) == prefix then
						table.insert(items, {
							word = "#" .. num_str,
							menu = i.title or "",
						})
					end
				end
			end
		end
	end

	return items
end

return M
