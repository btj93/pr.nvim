local M = {}
local git = require("pr.provider").get_provider()

--- @class pr.pickers.PickCommentsConfig
--- @field filters function[] (comments: Comments): Comments

---
---@param opts? pr.pickers.PickCommentsConfig
---@return nil
function M.pick_comments(opts)
	local fzf = require("fzf-lua")
	local filter = require("pr.pickers.filter")

	opts = opts or {}

	git.get_comments(vim.schedule_wrap(function(comments)
		for _, f in ipairs(opts.filters or {}) do
			comments = f(comments)
		end
		comments = filter.apply(comments)

		if next(comments) == nil then
			vim.notify("No comments to pick")
			return
		end

		local entries = {}
		for file, threads in pairs(comments) do
			for _, thread in ipairs(threads) do
				local _, first = next(thread.comments)
				if first then
					local body = first.body:gsub("\r?\n", " ")
					if #body > 60 then
						body = body:sub(1, 60) .. "…"
					end
					-- "file:line:col:text" — recognized by fzf-lua's builtin previewer
					local entry = string.format("%s:%d:1:%s: %s", file, first.start_line, first.author, body)
					table.insert(entries, entry)
				end
			end
		end

		local default_actions = fzf.defaults and fzf.defaults.actions and fzf.defaults.actions.files
			or {
				["default"] = function(selected)
					if not selected or not selected[1] then
						return
					end
					local file, line = selected[1]:match("^([^:]+):(%d+):")
					if file then
						local abs = require("pr.provider").get_provider().git_root .. "/" .. file
						require("pr.util").open_pr_file(abs, file, { line = tonumber(line) })
					end
				end,
			}

		local actions = vim.tbl_extend("force", default_actions, {
			["ctrl-r"] = function()
				filter.toggle("resolved")
				require("pr.picker").pick_comments()
			end,
			["ctrl-o"] = function()
				filter.toggle("outdated")
				require("pr.picker").pick_comments()
			end,
		})

		fzf.fzf_exec(entries, {
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

function M.pick_hunks()
	local fzf = require("fzf-lua")

	git.get_hunks(vim.schedule_wrap(function(hunks)
		if next(hunks) == nil then
			vim.notify("No hunks")
			return
		end

		local entries = {}
		for file, hs in pairs(hunks) do
			for _, h in ipairs(hs) do
				local entry = string.format("%s:%d:1:[%s] %d-%d", file, h.hunk_start, h.type, h.hunk_start, h.hunk_end)
				table.insert(entries, entry)
			end
		end

		fzf.fzf_exec(entries, {
			prompt = "PR Hunks> ",
			previewer = "builtin",
			actions = fzf.defaults and fzf.defaults.actions and fzf.defaults.actions.files or {
				["default"] = function(selected)
					if not selected or not selected[1] then
						return
					end
					local file, line = selected[1]:match("^([^:]+):(%d+):")
					if file then
						local abs = require("pr.provider").get_provider().git_root .. "/" .. file
						require("pr.util").open_pr_file(abs, file, { line = tonumber(line) })
					end
				end,
			},
		})
	end))
end

return M
