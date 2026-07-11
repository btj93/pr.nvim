local M = {}
local git = require("pr.provider").get_provider()
local filter = require("pr.pickers.filter")

local function safe_require(mod)
	local ok, m = pcall(require, mod)
	return ok and m or nil
end
local Snacks = safe_require("snacks")

-- ---------------------------------------------------------------------------
-- Pure item builders + confirm dispatchers.
--
-- These are UI-independent: they build the finder rows and dispatch the
-- file-open / checkout that pick_comments / pick_hunks / pick_prs feed to
-- Snacks.picker(). They never touch the (optional) `Snacks` upvalue, so they
-- are safe to require and exercise without snacks.nvim installed.
--
-- Filtering boundary: `_build_comment_items` does NOT apply filter.apply --
-- pick_comments applies the user-toggle filter on every finder run and hands
-- the already-filtered Comments map here. Keep that split; do not fold
-- filtering into the builder.
--
-- git_root is accepted for signature uniformity across the three backends.
-- The snacks rows carry the *relative* `file` (that's what format_* renders in
-- the picker); the absolute path is resolved from the provider at confirm time
-- (`_confirm_comment` / `_confirm_hunk`), so the snacks builders don't embed
-- git_root into their rows.
-- ---------------------------------------------------------------------------

--- Build the comment picker rows from an already-filtered Comments map.
---@param comments Comments already-filtered (filter.apply applied by caller)
---@param git_root string absolute git root (unused here; see note above)
---@return snacks.picker.finder.Item[]
function M._build_comment_items(comments, git_root)
	local items = {}
	for file, threads in pairs(comments) do
		for _, thread in ipairs(threads) do
			local _, first = next(thread.comments)
			if first then
				table.insert(items, {
					file = file,
					["data"] = {
						["author"] = first.author,
						["body"] = first.body,
						["is_resolved"] = thread.is_resolved,
						["is_outdated"] = thread.is_outdated,
					},
					text = first.author .. first.body .. file,
					pos = { first.start_line, 0 },
					end_pos = { first.end_line, 0 },
				})
			end
		end
	end
	return items
end

--- Build the hunk picker rows.
---@param hunks Hunks
---@param git_root string absolute git root (unused here; see note above)
---@return snacks.picker.finder.Item[]
function M._build_hunk_items(hunks, git_root)
	local items = {}
	for file, hs in pairs(hunks) do
		for _, h in ipairs(hs) do
			table.insert(items, {
				file = file,
				["data"] = {
					["hunk_start"] = h.hunk_start,
					["hunk_end"] = h.hunk_end,
					["type"] = h.type,
				},
				text = file .. " " .. h.hunk_start .. ":" .. h.hunk_end,
				pos = { h.hunk_start, 0 },
				end_pos = { h.hunk_end, 0 },
			})
		end
	end
	return items
end

--- Build the PR picker rows.
---@param prs PRSummary[]
---@return snacks.picker.finder.Item[]
function M._build_pr_items(prs)
	local items = {}
	for _, pr in ipairs(prs) do
		table.insert(items, {
			text = string.format("#%d %s %s", pr.number, pr.title or "", pr.author or ""),
			data = {
				number = pr.number,
				title = pr.title or "",
				author = pr.author or "",
				state = pr.state or "",
				branch = pr.branch or "",
				url = pr.url or "",
			},
		})
	end
	return items
end

--- Open the file targeted by a comment picker row. UI-independent: the caller
--- closes the picker; this only resolves the absolute path and dispatches.
---@param item snacks.picker.finder.Item?
function M._confirm_comment(item)
	if not item then
		return
	end
	local abs = require("pr.provider").get_provider().git_root .. "/" .. item.file
	local line = item.pos and item.pos[1] or nil
	require("pr.util").open_pr_file(abs, item.file, { line = line })
end

--- Open the file targeted by a hunk picker row. UI-independent (see above).
---@param item snacks.picker.finder.Item?
function M._confirm_hunk(item)
	if not item then
		return
	end
	local abs = require("pr.provider").get_provider().git_root .. "/" .. item.file
	local line = item.pos and item.pos[1] or nil
	require("pr.util").open_pr_file(abs, item.file, { line = line })
end

--- Checkout the PR referenced by a PR picker row. UI-independent: the caller
--- closes the picker first.
---@param item snacks.picker.finder.Item?
function M._confirm_pr(item)
	if not item then
		return
	end
	local ok, pr_list = pcall(require, "pr.pr_list")
	if not ok or type(pr_list.checkout) ~= "function" then
		vim.notify("pr_list.checkout not available yet")
		return
	end
	pr_list.checkout(item.data.number)
end

--- @class pr.pickers.PickCommentsConfig
--- @field filters function[] (comments: Comments): Comments
--- @field format function (item: snacks.picker.Item, _: snacks.Picker): table

---
---@param opts? pr.pickers.PickCommentsConfig
---@return nil
function M.pick_comments(opts)
	if not Snacks then
		vim.notify("snacks.nvim not installed; configure a different picker or install snacks", vim.log.levels.WARN)
		return
	end

	opts = opts or {}

	local format = opts.format or M.format_comments

	git.get_comments(vim.schedule_wrap(function(raw_comments)
		-- Apply caller-side pre-filters ONCE; the user-toggle filter applies
		-- on every finder run so it can change without a re-fetch.
		local pre = raw_comments or {}
		for _, f in ipairs(opts.filters or {}) do
			pre = f(pre)
		end

		-- If the initial visible set is empty (with current filter state), bail.
		if next(filter.apply(pre)) == nil then
			vim.notify("No comments to pick")
			return
		end

		--- Build the picker items from `pre` with the latest filter state.
		--- filter.apply stays here (per finder run); the pure row-building is in
		--- M._build_comment_items.
		---@return snacks.picker.finder.Item[]
		local function build_items()
			return M._build_comment_items(filter.apply(pre), require("pr.provider").get_provider().git_root)
		end

		return Snacks.picker({
			title = filter.label() .. "PR Comments",
			-- Toggle filter state then re-run the finder in place via picker:find().
			-- No re-fetch — filter is purely client-side over the cached comments.
			actions = {
				toggle_resolved = function(picker)
					filter.toggle("resolved")
					picker:find()
				end,
				toggle_outdated = function(picker)
					filter.toggle("outdated")
					picker:find()
				end,
			},
			win = {
				input = {
					keys = {
						["R"] = { "toggle_resolved", mode = "n", desc = "Toggle resolved threads" },
						["O"] = { "toggle_outdated", mode = "n", desc = "Toggle outdated threads" },
						-- <C-r>/<C-o> alias matches fzf-lua and telescope so muscle memory
						-- carries across pickers. Bound in both insert and normal so
						-- they work while typing the filter prompt.
						["<C-r>"] = { "toggle_resolved", mode = { "i", "n" }, desc = "Toggle resolved threads" },
						["<C-o>"] = { "toggle_outdated", mode = { "i", "n" }, desc = "Toggle outdated threads" },
					},
				},
				list = {
					keys = {
						["R"] = { "toggle_resolved", mode = "n", desc = "Toggle resolved threads" },
						["O"] = { "toggle_outdated", mode = "n", desc = "Toggle outdated threads" },
						["<C-r>"] = { "toggle_resolved", mode = "n", desc = "Toggle resolved threads" },
						["<C-o>"] = { "toggle_outdated", mode = "n", desc = "Toggle outdated threads" },
					},
				},
			},
			---@return snacks.picker.finder.Item[]
			finder = build_items,
			-- layout = {
			-- 	layout = {
			-- 		box = "horizontal",
			-- 		width = 0.5,
			-- 		height = 0.5,
			-- 		{
			-- 			box = "vertical",
			-- 			border = "rounded",
			-- 			title = "Find directory",
			-- 			{ win = "input", height = 1, border = "bottom" },
			-- 			{ win = "list", border = "none" },
			-- 		},
			-- 	},
			-- },
			format = format,
			confirm = function(picker, item)
				picker:close()
				M._confirm_comment(item)
			end,
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

function M.format_comments(item, _)
	local ret = {}
	local a = Snacks.picker.util.align
	local icon, icon_hl = Snacks.util.icon(item.file.ft)
	local glyph, glyph_hl = filter.state_glyph(item.data)
	ret[#ret + 1] = { glyph, glyph_hl }
	ret[#ret + 1] = { " " }
	ret[#ret + 1] = { a(icon, 3), icon_hl }
	ret[#ret + 1] = { " " }
	ret[#ret + 1] = { a(item.data.author, 15), "@variable.builtin" }
	ret[#ret + 1] = { " " }
	ret[#ret + 1] = { Snacks.picker.util.truncate(item.data.body, 20), "@text.literal" }
	ret[#ret + 1] = { "  " }
	ret[#ret + 1] = { item.file, "SnacksPickerComment" }

	return ret
end

---
---@param format? fun(item: snacks.picker.Item, _: snacks.Picker): table
---@return nil
function M.pick_hunks(format)
	if not Snacks then
		vim.notify("snacks.nvim not installed; configure a different picker or install snacks", vim.log.levels.WARN)
		return
	end

	format = format or M.format_hunks

	---@param hunks Hunks
	git.get_hunks(vim.schedule_wrap(function(hunks)
		if next(hunks) == nil then
			vim.notify("No hunks")
			return
		end

		return Snacks.picker({
			---@return snacks.picker.finder.Item[]
			finder = function()
				return M._build_hunk_items(hunks, require("pr.provider").get_provider().git_root)
			end,
			-- layout = {
			-- 	layout = {
			-- 		box = "horizontal",
			-- 		width = 0.5,
			-- 		height = 0.5,
			-- 		{
			-- 			box = "vertical",
			-- 			border = "rounded",
			-- 			title = "Find directory",
			-- 			{ win = "input", height = 1, border = "bottom" },
			-- 			{ win = "list", border = "none" },
			-- 		},
			-- 	},
			-- },
			format = format,
			confirm = function(picker, item)
				picker:close()
				M._confirm_hunk(item)
			end,
		})
	end))
end

function M.format_hunks(item, _)
	local ret = {}
	local a = Snacks.picker.util.align
	local icon, icon_hl = Snacks.util.icon(item.file.ft)
	ret[#ret + 1] = { a(icon, 3), icon_hl }
	ret[#ret + 1] = { " " }
	-- ret[#ret + 1] = { Snacks.picker.util.truncate(item.file, 60), "@text.literal" }
	ret[#ret + 1] = { Snacks.picker.util.truncate(item.file, 60), "PRDiff" .. item.data.type }
	ret[#ret + 1] = { "  " }
	ret[#ret + 1] = { item.data.hunk_start .. ":" .. item.data.hunk_end, "SnacksPickerComment" }

	return ret
end

---@param opts? { filter?: "mine"|"assigned"|"review-requested"|"all" }
---@return nil
function M.pick_prs(opts)
	if not Snacks then
		vim.notify("snacks.nvim not installed; configure a different picker or install snacks", vim.log.levels.WARN)
		return
	end
	if opts and opts.filter then
		filter.set_pr_filter(opts.filter)
	end

	-- Mutable upvalue so the cycle action can swap in a new list and re-trigger
	-- the finder without closing/re-opening the picker.
	local state = { prs = {} }

	---@return snacks.picker.finder.Item[]
	local function build_items()
		return M._build_pr_items(state.prs)
	end

	git.list_prs(
		filter.state.pr_list_filter,
		vim.schedule_wrap(function(prs)
			if not prs or #prs == 0 then
				vim.notify("No PRs to list (filter: " .. filter.state.pr_list_filter .. ")")
				return
			end
			state.prs = prs

			return Snacks.picker({
				title = filter.pr_list_label() .. "PRs",
				actions = {
					pr_cycle_filter = function(picker)
						filter.cycle_pr_filter()
						-- list_prs is cached per filter on the provider — first cycle
						-- to a new filter triggers one network call, subsequent cycles
						-- hit the cache. The picker stays open; the finder re-runs.
						git.list_prs(
							filter.state.pr_list_filter,
							vim.schedule_wrap(function(new_prs)
								state.prs = new_prs or {}
								picker:find()
							end)
						)
					end,
				},
				win = {
					input = {
						keys = {
							["<c-f>"] = { "pr_cycle_filter", mode = { "n", "i" }, desc = "Cycle PR filter" },
						},
					},
					list = {
						keys = {
							["<c-f>"] = { "pr_cycle_filter", mode = { "n", "i" }, desc = "Cycle PR filter" },
						},
					},
				},
				---@return snacks.picker.finder.Item[]
				finder = build_items,
				format = M.format_prs,
				confirm = function(picker, item)
					picker:close()
					M._confirm_pr(item)
				end,
			})
		end)
	)
end

function M.format_prs(item, _)
	local ret = {}
	local a = Snacks.picker.util.align
	local data = item.data
	ret[#ret + 1] = { a("#" .. tostring(data.number), 7), "Number" }
	ret[#ret + 1] = { " " }
	ret[#ret + 1] = { a(data.state, 8), "Identifier" }
	ret[#ret + 1] = { " " }
	ret[#ret + 1] = { Snacks.picker.util.truncate(data.title, 60), "Title" }
	ret[#ret + 1] = { "  " }
	ret[#ret + 1] = { "@" .. data.author, "@variable.builtin" }
	return ret
end

return M
