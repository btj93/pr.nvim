local M = {}
local git = require("pr.provider").get_provider()

-- ---------------------------------------------------------------------------
-- Pure entry builders + confirm dispatchers.
--
-- These are UI-independent: they build the finder entries and dispatch the
-- file-open / checkout that pick_comments / pick_hunks / pick_prs feed to
-- telescope. They never require any `telescope.*` module, so they are safe to
-- require and exercise without telescope.nvim installed (telescope's own
-- requires stay deferred inside the pick_* functions).
--
-- Filtering boundary: `_build_comment_items` does NOT apply filter.apply --
-- pick_comments applies the user-toggle filter on every finder run and hands
-- the already-filtered Comments map here. Keep that split; do not fold
-- filtering into the builder.
--
-- git_root is accepted for signature uniformity across the three backends. The
-- telescope entries carry the *relative* path under `path` (and its start line
-- under `lnum`); the absolute path is resolved from the provider at confirm
-- time (`_confirm_comment` / `_confirm_hunk`), so the telescope builders don't
-- embed git_root into their entries.
--
-- Entry shape (telescope): each entry carries `value` (the payload consumed at
-- confirm / by the display fn), `path`/`lnum` (previewer target), `ordinal`
-- (fuzzy-sort key) and `display`. `display` is a *function* (M.format_comments
-- / M.format_hunks) for comments/hunks and a *string* for PRs.
-- ---------------------------------------------------------------------------

--- Build the comment picker entries from an already-filtered Comments map.
---@param comments Comments already-filtered (filter.apply applied by caller)
---@param git_root string absolute git root (unused here; see note above)
---@return table[]
function M._build_comment_items(comments, git_root)
	local items = {}
	for file, threads in pairs(comments) do
		for _, thread in ipairs(threads) do
			local _, first = next(thread.comments)
			if first then
				table.insert(items, {
					value = {
						file = file,
						author = first.author,
						body = first.body,
						start_line = first.start_line,
						end_line = first.end_line,
						is_resolved = thread.is_resolved,
						is_outdated = thread.is_outdated,
					},
					path = file,
					lnum = first.start_line,
					display = M.format_comments,
					ordinal = first.author .. first.body .. file,
				})
			end
		end
	end
	return items
end

--- Build the hunk picker entries.
---@param hunks Hunks
---@param git_root string absolute git root (unused here; see note above)
---@return table[]
function M._build_hunk_items(hunks, git_root)
	local items = {}
	for file, hs in pairs(hunks) do
		for _, h in ipairs(hs) do
			table.insert(items, {
				value = {
					file = file,
					hunk_start = h.hunk_start,
					hunk_end = h.hunk_end,
					type = h.type,
				},
				path = file,
				lnum = h.hunk_start,
				display = M.format_hunks,
				ordinal = file .. " " .. h.hunk_start .. ":" .. h.hunk_end,
			})
		end
	end
	return items
end

--- Build the PR picker entries.
---@param prs PRSummary[]
---@return table[]
function M._build_pr_items(prs)
	local items = {}
	for _, pr in ipairs(prs) do
		local display = string.format("#%-5d %-8s %s  @%s", pr.number, pr.state or "", pr.title or "", pr.author or "")
		table.insert(items, {
			value = {
				number = pr.number,
				title = pr.title or "",
				author = pr.author or "",
				state = pr.state or "",
				branch = pr.branch or "",
				url = pr.url or "",
			},
			display = display,
			ordinal = tostring(pr.number) .. " " .. (pr.title or "") .. " " .. (pr.author or ""),
		})
	end
	return items
end

--- Open the file targeted by a selected comment entry. UI-independent: the
--- caller closes the picker; this only resolves the absolute path and
--- dispatches. Takes the selected telescope entry (may be nil).
---@param selection table?
function M._confirm_comment(selection)
	if selection then
		local rel = selection.value.file
		local abs = require("pr.provider").get_provider().git_root .. "/" .. rel
		require("pr.util").open_pr_file(abs, rel, { line = selection.value.start_line })
	end
end

--- Open the file targeted by a selected hunk entry. UI-independent (see above).
---@param selection table?
function M._confirm_hunk(selection)
	if selection then
		local rel = selection.value.file
		local abs = require("pr.provider").get_provider().git_root .. "/" .. rel
		require("pr.util").open_pr_file(abs, rel, { line = selection.value.hunk_start })
	end
end

--- Checkout the PR referenced by a selected entry. UI-independent: the caller
--- closes the picker first. Takes the selected telescope entry (may be nil).
---@param selection table?
function M._confirm_pr(selection)
	if not selection or not selection.value then
		return
	end
	local ok_pr, pr_list = pcall(require, "pr.pr_list")
	if not ok_pr or type(pr_list.checkout) ~= "function" then
		vim.notify("pr_list.checkout not available yet")
		return
	end
	pr_list.checkout(selection.value.number)
end

--- @class pr.pickers.PickCommentsConfig
--- @field filters function[] (comments: Comments): Comments
--- @field format function (entry: table): table

---
---@param opts? pr.pickers.PickCommentsConfig
---@return nil
function M.pick_comments(opts)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local sorters = require("telescope.sorters")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local filter = require("pr.pickers.filter")

	opts = opts or {}

	git.get_comments(vim.schedule_wrap(function(raw_comments)
		-- Apply caller-side pre-filters ONCE; user-toggle filter applies per build.
		local pre = raw_comments or {}
		for _, f in ipairs(opts.filters or {}) do
			pre = f(pre)
		end

		if next(filter.apply(pre)) == nil then
			vim.notify("No comments to pick")
			return
		end

		-- filter.apply stays here (per finder run); the pure entry-building is in
		-- M._build_comment_items.
		local function build_items()
			return M._build_comment_items(filter.apply(pre), require("pr.provider").get_provider().git_root)
		end

		local function new_finder()
			return finders.new_table({
				results = build_items(),
				entry_maker = function(entry)
					return entry
				end,
			})
		end

		pickers
			.new({ previewer = true }, {
				prompt_title = filter.label() .. "PR Comments",
				finder = new_finder(),
				sorter = sorters.get_generic_fuzzy_sorter(),
				previewer = require("telescope.config").values.grep_previewer({ preview = true }),
				attach_mappings = function(prompt_bufnr, map)
					actions.select_default:replace(function()
						local selection = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						M._confirm_comment(selection)
					end)
					-- Toggle filter state then refresh the picker in place.
					-- No re-fetch — filter.apply runs over the cached comments.
					local function toggle(kind)
						filter.toggle(kind)
						local picker = action_state.get_current_picker(prompt_bufnr)
						if picker then
							picker:refresh(new_finder(), { reset_prompt = false })
						end
					end
					local function toggle_resolved()
						toggle("resolved")
					end
					local function toggle_outdated()
						toggle("outdated")
					end
					map("n", "R", toggle_resolved)
					map("i", "<C-r>", toggle_resolved)
					map("n", "O", toggle_outdated)
					map("i", "<C-o>", toggle_outdated)
					return true
				end,
			})
			:find()
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
		local unresolved = {}
		for _, thread in ipairs(threads) do
			if thread.is_resolved then
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
function M.non_outdated(comments)
	local c = {}
	for file, threads in pairs(comments) do
		local outdated = {}
		for _, thread in ipairs(threads) do
			if not thread.is_outdated then
				table.insert(outdated, thread)
			end
		end
		if #outdated > 0 then
			c[file] = outdated
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

function M.format_comments(entry)
	-- Assumes you have 'nvim-web-devicons' installed
	local icon, _ = require("nvim-web-devicons").get_icon(entry.value.file)
	local body_truncated = entry.value.body:gsub("\n", " "):sub(1, 40)
	local glyph = require("pr.pickers.filter").state_glyph(entry.value)
	return string.format("%s %s %-15s %-40s %s", glyph, icon or " ", entry.value.author, body_truncated, entry.value.file)
end

---
---@param format? fun(item: table): string
---@return nil
function M.pick_hunks(format)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local sorters = require("telescope.sorters")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	format = format or M.format_hunks

	---@param hunks Hunks
	git.get_hunks(vim.schedule_wrap(function(hunks)
		if next(hunks) == nil then
			vim.notify("No hunks")
			return
		end

		local items = M._build_hunk_items(hunks, require("pr.provider").get_provider().git_root)
		-- Honor a caller-supplied custom formatter (defaults to M.format_hunks,
		-- which the builder already embeds). Kept at the call site so the builder
		-- stays formatter-agnostic and uniform with the other backends.
		if format ~= M.format_hunks then
			for _, item in ipairs(items) do
				item.display = format
			end
		end

		pickers
			.new({ previewer = true }, {
				prompt_title = "Hunks",
				finder = finders.new_table({
					results = items,
					entry_maker = function(entry)
						return entry
					end,
				}),
				sorter = sorters.get_generic_fuzzy_sorter(),
				previewer = require("telescope.config").values.grep_previewer({ preview = true }),
				attach_mappings = function(prompt_bufnr, map)
					actions.select_default:replace(function()
						local selection = action_state.get_selected_entry()
						actions.close(prompt_bufnr)
						M._confirm_hunk(selection)
					end)
					return true
				end,
			})
			:find()
	end))
end

function M.format_hunks(entry)
	-- Assumes you have 'nvim-web-devicons' installed
	-- TODO: format to let user know if it is add / change / del
	local icon, _ = require("nvim-web-devicons").get_icon(entry.value.file)
	return string.format("%s %-80s %s:%s", icon or " ", entry.value.file, entry.value.hunk_start, entry.value.hunk_end)
end

---@param opts? { filter?: "mine"|"assigned"|"review-requested"|"all" }
---@return nil
function M.pick_prs(opts)
	local ok_t, _ = pcall(require, "telescope")
	if not ok_t then
		vim.notify("telescope.nvim not installed", vim.log.levels.WARN)
		return
	end
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local sorters = require("telescope.sorters")
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local filter = require("pr.pickers.filter")
	if opts and opts.filter then
		filter.set_pr_filter(opts.filter)
	end

	-- Shared upvalue so the cycle action can swap in a new list without
	-- closing/re-opening the picker.
	local state = { prs = {} }

	local function build_items()
		return M._build_pr_items(state.prs)
	end

	local function new_finder()
		return finders.new_table({
			results = build_items(),
			entry_maker = function(entry)
				return entry
			end,
		})
	end

	git.list_prs(
		filter.state.pr_list_filter,
		vim.schedule_wrap(function(prs)
			if not prs or #prs == 0 then
				vim.notify("No PRs to list (filter: " .. filter.state.pr_list_filter .. ")")
				return
			end
			state.prs = prs

			pickers
				.new({}, {
					prompt_title = filter.pr_list_label() .. "PRs",
					finder = new_finder(),
					sorter = sorters.get_generic_fuzzy_sorter(),
					attach_mappings = function(prompt_bufnr, map)
						actions.select_default:replace(function()
							local selection = action_state.get_selected_entry()
							actions.close(prompt_bufnr)
							M._confirm_pr(selection)
						end)

						-- Cycle filter then refresh in place. list_prs is cached per
						-- filter on the provider; first cycle to a new filter triggers
						-- one network call, subsequent cycles hit the cache.
						local cycle = function()
							filter.cycle_pr_filter()
							git.list_prs(
								filter.state.pr_list_filter,
								vim.schedule_wrap(function(new_prs)
									state.prs = new_prs or {}
									local picker = action_state.get_current_picker(prompt_bufnr)
									if picker then
										picker:refresh(new_finder(), { reset_prompt = false })
									end
								end)
							)
						end
						map("i", "<C-f>", cycle)
						map("n", "<C-f>", cycle)
						return true
					end,
				})
				:find()
		end)
	)
end

return M
