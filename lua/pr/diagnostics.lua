-- Surface unresolved PR threads as vim.diagnostic entries with drift-aware line placement.

local M = {}

local config = require("pr.config")
local drift = require("pr.drift")

M.namespace = vim.api.nvim_create_namespace("pr_threads")

---Build vim.diagnostic entries for the given threads.
---Pure; suitable for unit testing.
---@param threads ReviewThread[]?
---@param drift_map DriftMap?
---@return table[]  -- vim.diagnostic.set format
function M._build(threads, drift_map)
	local opts = config.opts.diagnostics or {}
	local out = {}
	for _, thread in ipairs(threads or {}) do
		local include = true
		if thread.is_resolved and not opts.include_resolved then
			include = false
		end
		if thread.is_outdated and not opts.include_outdated then
			include = false
		end
		if include then
			local first = thread.comments and thread.comments[1]
			if first then
				local s, e = first.start_line, first.end_line
				if drift_map then
					s = drift.commit_to_buffer(drift_map, first.start_line)
					e = drift.commit_to_buffer(drift_map, first.end_line)
				end
				if s and e then
					local message = (first.author or "?") .. ": " .. ((first.body or ""):gsub("\n", " ")):sub(1, 120)
					table.insert(out, {
						lnum = s - 1,
						end_lnum = e - 1,
						col = 0,
						severity = opts.severity or vim.diagnostic.severity.HINT,
						source = opts.source or "PR",
						message = message,
					})
				end
			end
		end
	end
	return out
end

---Publish diagnostics for a buffer using the threads + drift_map provided.
---No-op when diagnostics are disabled, when the buffer is invalid, or when buftype is non-empty.
---@param buf integer
---@param threads ReviewThread[]?
---@param drift_map DriftMap?
function M.publish(buf, threads, drift_map)
	if not (config.opts.diagnostics and config.opts.diagnostics.enabled) then
		return
	end
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	-- Skip scratch / special buffers (e.g., deleted-file viewer's nofile buffer).
	if vim.bo[buf].buftype ~= "" then
		return
	end
	local entries = M._build(threads, drift_map)
	vim.diagnostic.set(M.namespace, buf, entries)
end

---Clear diagnostics for a single buffer.
---@param buf integer
function M.clear(buf)
	if vim.api.nvim_buf_is_valid(buf) then
		vim.diagnostic.reset(M.namespace, buf)
	end
end

---Clear diagnostics across all buffers.
function M.clear_all()
	vim.diagnostic.reset(M.namespace)
end

return M
