-- Dump PR review threads to the quickfix list for navigation via :cnext / :cprev.

local M = {}

---@param thread ReviewThread
---@param filter { kind: string, file: string? }
---@return boolean
local function should_include(thread, filter)
	if filter.kind == "all" then
		return true
	end
	if filter.kind == "outdated" then
		return thread.is_outdated == true
	end
	-- Default ("unresolved" or "file") drops resolved threads.
	if thread.is_resolved then
		return false
	end
	return true
end

---Pure: build vim.fn.setqflist entries for the given Comments map.
---@param comments Comments?
---@param filter { kind: string, file: string? }
---@param git_root string
---@return table[]
function M._build_entries(comments, filter, git_root)
	local out = {}
	for file, threads in pairs(comments or {}) do
		if filter.kind ~= "file" or file == filter.file then
			for _, thread in ipairs(threads) do
				if should_include(thread, filter) then
					local first = thread.comments and thread.comments[1]
					if first then
						local snippet = ((first.body or ""):gsub("\n", " ")):sub(1, 80)
						table.insert(out, {
							filename = (git_root or "") .. "/" .. file,
							lnum = first.start_line or 0,
							col = 1,
							text = "[" .. (first.author or "?") .. "] " .. snippet,
						})
					end
				end
			end
		end
	end
	return out
end

---Fetch comments and populate the quickfix list.
---@param filter { kind: string, file: string? }
function M.dump(filter)
	local git = require("pr.provider").get_provider()
	git.get_comments(vim.schedule_wrap(function(comments)
		if filter.kind == "file" then
			local bufname = vim.api.nvim_buf_get_name(0)
			local git_root = git.git_root or ""
			if git_root ~= "" and bufname:sub(1, #git_root) == git_root then
				filter.file = bufname:sub(#git_root + 2)
			end
		end
		local entries = M._build_entries(comments, filter, git.git_root or "")
		vim.fn.setqflist(entries, "r")
		vim.notify(("PR: %d entries in quickfix"):format(#entries))
	end))
end

return M
