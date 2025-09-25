local M = {}
local gh = require("pr.providers.gh")

--- @class pr.picker.Config
--- @field filters function[] (comments: Comments): Comments
--- @field format function (item: snacks.picker.Item, _: snacks.Picker): table

---
---@param opts? pr.picker.Config
---@return nil
function M.picker(opts)
	local Snacks = require("snacks")

	opts = opts or {}

	local format = opts.format or M.format

	gh.get_comments(function(comments)
		for _, filter in ipairs(opts.filters or {}) do
			comments = filter(comments)
		end
		return Snacks.picker({
			---@return snacks.picker.finder.Item[]
			finder = function()
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
								pos = { first.start_line, 0 },
								end_pos = { first.end_line, 0 },
							})
						end
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
		})
	end)
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

function M.format(item, _)
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

return M
