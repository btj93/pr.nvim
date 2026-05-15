local M = {}
local git = require("pr.provider").get_provider()

local function safe_require(mod)
	local ok, m = pcall(require, mod)
	return ok and m or nil
end
local Snacks = safe_require("snacks")

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
	local filter = require("pr.pickers.filter")

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
		---@return snacks.picker.finder.Item[]
		local function build_items()
			local comments = filter.apply(pre)
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
					},
				},
				list = {
					keys = {
						["R"] = { "toggle_resolved", mode = "n", desc = "Toggle resolved threads" },
						["O"] = { "toggle_outdated", mode = "n", desc = "Toggle outdated threads" },
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
				if not item then
					return
				end
				local abs = require("pr.provider").get_provider().git_root .. "/" .. item.file
				local line = item.pos and item.pos[1] or nil
				require("pr.util").open_pr_file(abs, item.file, { line = line })
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
				if not item then
					return
				end
				local abs = require("pr.provider").get_provider().git_root .. "/" .. item.file
				local line = item.pos and item.pos[1] or nil
				require("pr.util").open_pr_file(abs, item.file, { line = line })
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
	local filter = require("pr.pickers.filter")
	if opts and opts.filter then
		filter.set_pr_filter(opts.filter)
	end

	-- Mutable upvalue so the cycle action can swap in a new list and re-trigger
	-- the finder without closing/re-opening the picker.
	local state = { prs = {} }

	---@return snacks.picker.finder.Item[]
	local function build_items()
		local items = {}
		for _, pr in ipairs(state.prs) do
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
					if not item then
						return
					end
					local ok, pr_list = pcall(require, "pr.pr_list")
					if not ok or type(pr_list.checkout) ~= "function" then
						vim.notify("pr_list.checkout not available yet")
						return
					end
					pr_list.checkout(item.data.number)
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
