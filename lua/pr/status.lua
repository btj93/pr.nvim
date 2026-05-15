-- Status counters and winbar token for pr.nvim.
-- Cheap to call from statusline plugins; reads only in-memory provider state.

local M = {}

---@class PRStatus
---@field pr_number integer?
---@field total integer
---@field unresolved integer
---@field resolved integer
---@field outdated integer
---@field on_buffer integer
---@field pending_review integer

local function provider()
	return require("pr.provider").get_provider()
end

---Compute aggregate counters across all cached comments on the current provider.
---@return PRStatus
function M.compute()
	local p = provider()
	local s = {
		pr_number = (p.pr_number and p.pr_number > 0) and p.pr_number or nil,
		total = 0,
		unresolved = 0,
		resolved = 0,
		outdated = 0,
		on_buffer = 0,
		pending_review = 0,
	}
	for _, threads in pairs(p.comments or {}) do
		for _, t in ipairs(threads) do
			s.total = s.total + 1
			if t.is_resolved then
				s.resolved = s.resolved + 1
			else
				s.unresolved = s.unresolved + 1
			end
			if t.is_outdated then
				s.outdated = s.outdated + 1
			end
		end
	end
	-- Pending review (from S1c). Treat missing as 0.
	if p.pending_review_comments then
		s.pending_review = #p.pending_review_comments
	end
	return s
end

---Count unresolved threads on a specific buffer's file (relative to git_root).
---Returns 0 for buffers outside the git tree or without comments.
---@param bufnr integer?
---@return integer
function M.compute_for_buffer(bufnr)
	bufnr = bufnr or 0
	local p = provider()
	if not p.git_root or p.git_root == "" then
		return 0
	end
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" or name:sub(1, #p.git_root) ~= p.git_root then
		return 0
	end
	local rel = name:sub(#p.git_root + 2)
	local threads = (p.comments or {})[rel] or {}
	local n = 0
	for _, t in ipairs(threads) do
		if not t.is_resolved then
			n = n + 1
		end
	end
	return n
end

---Return the formatted winbar token for `bufnr` (or current buffer when nil).
---Empty string when winbar is disabled or no PR is associated with the branch.
---@param bufnr integer?
---@return string
function M.winbar(bufnr)
	local config = require("pr.config")
	if not config.opts.winbar or not config.opts.winbar.enabled then
		return ""
	end
	local s = M.compute()
	if not s.pr_number then
		return ""
	end
	local on = M.compute_for_buffer(bufnr)
	local fmt = config.opts.winbar.format or "[PR #%d · %d unresolved]"
	return string.format(fmt, s.pr_number, on)
end

return M
