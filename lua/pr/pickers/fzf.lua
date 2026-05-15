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

---@param opts? { filter?: "mine"|"assigned"|"review-requested"|"all" }
---@return nil
function M.pick_prs(opts)
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		vim.notify("fzf-lua not installed", vim.log.levels.WARN)
		return
	end
	local filter = require("pr.pickers.filter")
	if opts and opts.filter then
		filter.set_pr_filter(opts.filter)
	end

	git.list_prs(
		filter.state.pr_list_filter,
		vim.schedule_wrap(function(prs)
			if not prs or #prs == 0 then
				vim.notify("No PRs to list (filter: " .. filter.state.pr_list_filter .. ")")
				return
			end

			-- Encode each PR as a line keyed back to the PR record so we can
			-- recover the number from fzf's selection.
			local entries = {}
			local by_line = {}
			for _, pr in ipairs(prs) do
				local line = string.format("#%-5d %-8s %s  @%s", pr.number, pr.state or "", pr.title or "", pr.author or "")
				table.insert(entries, line)
				by_line[line] = pr
			end

			fzf.fzf_exec(entries, {
				prompt = filter.pr_list_label() .. "PRs> ",
				actions = {
					["default"] = function(selected)
						if not selected or not selected[1] then
							return
						end
						local pr = by_line[selected[1]]
						if not pr then
							return
						end
						local ok_pr, pr_list = pcall(require, "pr.pr_list")
						if not ok_pr or type(pr_list.checkout) ~= "function" then
							vim.notify("pr_list.checkout not available yet")
							return
						end
						pr_list.checkout(pr.number)
					end,
					["ctrl-f"] = function()
						filter.cycle_pr_filter()
						M.pick_prs()
					end,
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
