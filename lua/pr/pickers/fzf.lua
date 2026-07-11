local M = {}
local git = require("pr.provider").get_provider()
local filter = require("pr.pickers.filter")

-- ---------------------------------------------------------------------------
-- Pure line builders + confirm dispatchers.
--
-- These are UI-independent: they build the finder row STRINGS and dispatch the
-- file-open / checkout that pick_comments / pick_hunks / pick_prs feed to
-- fzf-lua's fzf_exec. They never require "fzf-lua" (that require stays deferred
-- inside the pick_* functions), so they are safe to require and exercise
-- without fzf-lua installed. `filter` is a UI-independent module (pcall-safe;
-- snacks.lua requires it at module level too), so requiring it here does not
-- break fzf.lua's require-safety.
--
-- Filtering boundary: `_build_comment_items` does NOT apply filter.apply --
-- pick_comments applies the user-toggle filter on every finder run and hands
-- the already-filtered Comments map here. Keep that split; do not fold
-- filtering into the builder.
--
-- Structural deviation from snacks/telescope (the plan's `{lines, lookup}` shape
-- yields to fzf's actual shape): fzf rows are plain display STRINGS, not item
-- tables. Two consequences:
--
--   * `_build_comment_items` / `_build_hunk_items` return a bare `string[]`.
--     Each row encodes "file:line:1:..." (fzf-lua's builtin previewer format),
--     so the confirm re-parses file+line straight out of the selected string
--     via a regex -- there is no per-row lookup. `_confirm_comment` /
--     `_confirm_hunk` therefore take only the fzf `selected` list.
--   * PR rows can't be reverse-parsed to a payload, so `_build_pr_items` returns
--     `{ lines = string[], lookup = table<string, PRSummary> }` keyed by the
--     exact row string, and `_confirm_pr(selected, lookup)` resolves the PR
--     through that lookup. Only the PR builder needs the `{lines, lookup}` pair.
--
-- fzf passes each confirm callback a *table* of selected lines; the confirms
-- read `selected[1]`, matching the inline action closures verbatim.
--
-- git_root is accepted on the comment/hunk builders for signature uniformity
-- across the three backends; the fzf rows carry the *relative* file and the
-- absolute path is resolved from the provider at confirm time.
-- ---------------------------------------------------------------------------

--- Build the comment picker rows from an already-filtered Comments map.
---@param comments Comments already-filtered (filter.apply applied by caller)
---@param git_root string absolute git root (unused here; see note above)
---@return string[]
function M._build_comment_items(comments, git_root)
	local entries = {}
	for file, threads in pairs(comments) do
		for _, thread in ipairs(threads) do
			local _, first = next(thread.comments)
			if first then
				local body = first.body:gsub("\r?\n", " ")
				if #body > 60 then
					body = body:sub(1, 60) .. "…"
				end
				local glyph = filter.state_glyph(thread)
				-- "file:line:col:text" — recognized by fzf-lua's builtin previewer
				local entry = string.format("%s:%d:1:%s %s: %s", file, first.start_line, glyph, first.author, body)
				table.insert(entries, entry)
			end
		end
	end
	return entries
end

--- Build the hunk picker rows.
---@param hunks Hunks
---@param git_root string absolute git root (unused here; see note above)
---@return string[]
function M._build_hunk_items(hunks, git_root)
	local entries = {}
	for file, hs in pairs(hunks) do
		for _, h in ipairs(hs) do
			local entry = string.format("%s:%d:1:[%s] %d-%d", file, h.hunk_start, h.type, h.hunk_start, h.hunk_end)
			table.insert(entries, entry)
		end
	end
	return entries
end

--- Build the PR picker rows plus a row-string -> PRSummary lookup. fzf rows
--- can't be reverse-parsed to a payload, so the caller keeps the lookup and
--- passes it back to `_confirm_pr` at selection time.
---@param prs PRSummary[]
---@return { lines: string[], lookup: table<string, PRSummary> }
function M._build_pr_items(prs)
	local lines = {}
	local lookup = {}
	for _, pr in ipairs(prs or {}) do
		local line = string.format("#%-5d %-8s %s  @%s", pr.number, pr.state or "", pr.title or "", pr.author or "")
		table.insert(lines, line)
		lookup[line] = pr
	end
	return { lines = lines, lookup = lookup }
end

--- Open the file targeted by a selected comment row. UI-independent: the caller
--- closes the picker; this only parses file+line from the selected row string
--- and dispatches. `selected` is fzf's table of selected lines (may be nil).
---@param selected string[]?
function M._confirm_comment(selected)
	if not selected or not selected[1] then
		return
	end
	local file, line = selected[1]:match("^([^:]+):(%d+):")
	if file then
		local abs = require("pr.provider").get_provider().git_root .. "/" .. file
		require("pr.util").open_pr_file(abs, file, { line = tonumber(line) })
	end
end

--- Open the file targeted by a selected hunk row. UI-independent (see above).
---@param selected string[]?
function M._confirm_hunk(selected)
	if not selected or not selected[1] then
		return
	end
	local file, line = selected[1]:match("^([^:]+):(%d+):")
	if file then
		local abs = require("pr.provider").get_provider().git_root .. "/" .. file
		require("pr.util").open_pr_file(abs, file, { line = tonumber(line) })
	end
end

--- Checkout the PR referenced by a selected row. UI-independent: the caller
--- closes the picker first. Resolves the PR through `lookup` (the row-string ->
--- PRSummary map from `_build_pr_items`). `selected` is fzf's selected-line
--- table (may be nil).
---@param selected string[]?
---@param lookup table<string, PRSummary>
function M._confirm_pr(selected, lookup)
	if not selected or not selected[1] then
		return
	end
	local pr = lookup[selected[1]]
	if not pr then
		return
	end
	local ok_pr, pr_list = pcall(require, "pr.pr_list")
	if not ok_pr or type(pr_list.checkout) ~= "function" then
		vim.notify("pr_list.checkout not available yet")
		return
	end
	pr_list.checkout(pr.number)
end

--- @class pr.pickers.PickCommentsConfig
--- @field filters function[] (comments: Comments): Comments

---
---@param opts? pr.pickers.PickCommentsConfig
---@return nil
function M.pick_comments(opts)
	local fzf = require("fzf-lua")

	opts = opts or {}

	git.get_comments(vim.schedule_wrap(function(raw_comments)
		-- Apply caller pre-filters ONCE; user-toggle filter applies on every build.
		local pre = raw_comments or {}
		for _, f in ipairs(opts.filters or {}) do
			pre = f(pre)
		end

		if next(filter.apply(pre)) == nil then
			vim.notify("No comments to pick")
			return
		end

		--- Build the fzf entry list from `pre` with the latest filter state.
		--- filter.apply stays here (per build); the pure row-building is in
		--- M._build_comment_items.
		local function build_entries()
			return M._build_comment_items(filter.apply(pre), require("pr.provider").get_provider().git_root)
		end

		local default_actions = fzf.defaults and fzf.defaults.actions and fzf.defaults.actions.files
			or {
				["default"] = function(selected)
					M._confirm_comment(selected)
				end,
			}

		-- `reload = true` on an action tells fzf-lua to re-run the source (a
		-- function form) after the action fires, keeping the picker open. Toggle
		-- the filter state then reload — no re-fetch needed, filter.apply runs
		-- over the cached comments.
		local actions = vim.tbl_extend("force", default_actions, {
			["ctrl-r"] = {
				fn = function()
					filter.toggle("resolved")
				end,
				reload = true,
			},
			["ctrl-o"] = {
				fn = function()
					filter.toggle("outdated")
				end,
				reload = true,
			},
		})

		fzf.fzf_exec(build_entries, {
			prompt = filter.label() .. "PR Comments> ",
			previewer = "builtin",
			actions = actions,
		})
	end))
end

---
---@param comments Comments
---@return Comments
function M.unresolved(comments)
	local c = {}
	for file, threads in pairs(comments) do
		local unresolved = {}
		for _, thread in ipairs(threads) do
			if not thread.is_resolved then
				table.insert(unresolved, thread)
			end
		end
		if #unresolved > 0 then
			c[file] = unresolved
		end
	end
	return c
end

---
---@param comments Comments
---@return Comments
function M.resolved(comments)
	local c = {}
	for file, threads in pairs(comments) do
		local resolved = {}
		for _, thread in ipairs(threads) do
			if thread.is_resolved then
				table.insert(resolved, thread)
			end
		end
		if #resolved > 0 then
			c[file] = resolved
		end
	end
	return c
end

---
---@param comments Comments
---@return Comments
function M.non_outdated(comments)
	local c = {}
	for file, threads in pairs(comments) do
		local non_outdated = {}
		for _, thread in ipairs(threads) do
			if not thread.is_outdated then
				table.insert(non_outdated, thread)
			end
		end
		if #non_outdated > 0 then
			c[file] = non_outdated
		end
	end
	return c
end

---
---@param comments Comments
---@return Comments
function M.outdated(comments)
	local c = {}
	for file, threads in pairs(comments) do
		local outdated = {}
		for _, thread in ipairs(threads) do
			if thread.is_outdated then
				table.insert(outdated, thread)
			end
		end
		if #outdated > 0 then
			c[file] = outdated
		end
	end
	return c
end

---@param opts? { filter?: "mine"|"assigned"|"review-requested"|"all" }
---@return nil
function M.pick_prs(opts)
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		vim.notify("fzf-lua not installed", vim.log.levels.WARN)
		return
	end
	if opts and opts.filter then
		filter.set_pr_filter(opts.filter)
	end

	-- Shared upvalue: latest PR list keyed by formatted display line.
	-- The `by_line` map is rebuilt on every build_entries() call so the
	-- default action always resolves to the currently-shown set. The pure
	-- row/lookup pairing lives in M._build_pr_items; the closure just swaps in
	-- the fresh lookup.
	local state = { by_line = {} }

	local function build_entries()
		local built = M._build_pr_items(state.prs)
		state.by_line = built.lookup
		return built.lines
	end

	git.list_prs(
		filter.state.pr_list_filter,
		vim.schedule_wrap(function(prs)
			if not prs or #prs == 0 then
				vim.notify("No PRs to list (filter: " .. filter.state.pr_list_filter .. ")")
				return
			end
			state.prs = prs

			-- The reload-action pattern: ctrl-f's fn runs sync, then fzf-lua
			-- re-evaluates the source (build_entries) which reads state.prs.
			-- list_prs is async, so the action fires a fetch and we set state.prs
			-- from the callback; the next reload picks it up. Net effect: cycle
			-- triggers one network call per new filter (cached afterwards) and
			-- the picker stays open with the refreshed list.
			fzf.fzf_exec(build_entries, {
				prompt = filter.pr_list_label() .. "PRs> ",
				actions = {
					["default"] = function(selected)
						M._confirm_pr(selected, state.by_line)
					end,
					["ctrl-f"] = {
						fn = function()
							filter.cycle_pr_filter()
							-- Synchronously hit the provider cache (or kick off the
							-- one-time fetch). list_prs's callback is wrapped in
							-- vim.schedule_wrap so it runs on the main loop tick.
							-- The reload happens immediately after this fn returns;
							-- if the data isn't cached yet the reload sees the OLD
							-- list this tick, and the next user keystroke will see
							-- the updated list (because state.prs gets mutated
							-- between events). For the common cache-hit path, the
							-- update is effectively instant.
							git.list_prs(filter.state.pr_list_filter, function(new_prs)
								state.prs = new_prs or {}
							end)
						end,
						reload = true,
					},
				},
			})
		end)
	)
end

function M.pick_hunks()
	local fzf = require("fzf-lua")

	git.get_hunks(vim.schedule_wrap(function(hunks)
		if next(hunks) == nil then
			vim.notify("No hunks")
			return
		end

		local entries = M._build_hunk_items(hunks, require("pr.provider").get_provider().git_root)

		fzf.fzf_exec(entries, {
			prompt = "PR Hunks> ",
			previewer = "builtin",
			actions = fzf.defaults and fzf.defaults.actions and fzf.defaults.actions.files or {
				["default"] = function(selected)
					M._confirm_hunk(selected)
				end,
			},
		})
	end))
end

return M
