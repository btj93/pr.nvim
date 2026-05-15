-- Surface PR threads as vim.diagnostic entries with drift-aware line placement.
-- This module owns the inline comment text rendering — the buffer overlay below
-- a commented line is whatever the user's `vim.diagnostic.config` produces from
-- the entries we publish here. The signcolumn glyphs (`󰅺` + `┌`/`│`/`└` multi-
-- line connectors) are placed separately by `lua/pr/comment.lua` since
-- vim.diagnostic cannot express multi-line range markers.

local M = {}

local config = require("pr.config")
local drift = require("pr.drift")

M.namespace = vim.api.nvim_create_namespace("pr_threads")

---Resolve the effective "include resolved/outdated threads" flags.
---Precedence: explicit `diagnostics.include_*` wins; nil falls back to the
---unified `show_*_inline` config. This unifies the single-knob behavior
---requested when comment.lua's virt_lines render was removed.
---@param opts table  -- config.opts.diagnostics
---@return boolean include_resolved
---@return boolean include_outdated
local function resolve_gates(opts)
	local include_resolved = opts.include_resolved
	if include_resolved == nil then
		include_resolved = config.opts.show_resolved_inline
	end
	local include_outdated = opts.include_outdated
	if include_outdated == nil then
		include_outdated = config.opts.show_outdated_inline
	end
	return include_resolved and true or false, include_outdated and true or false
end

---Build vim.diagnostic entries for the given threads.
---Pure; suitable for unit testing.
---@param threads ReviewThread[]?
---@param drift_map DriftMap?
---@return table[]  -- vim.diagnostic.set format
function M._build(threads, drift_map)
	local opts = config.opts.diagnostics or {}
	local include_resolved, include_outdated = resolve_gates(opts)
	local severity_unresolved = opts.severity or vim.diagnostic.severity.HINT
	local severity_resolved = opts.severity_resolved or vim.diagnostic.severity.INFO
	local out = {}
	for _, thread in ipairs(threads or {}) do
		local include = true
		if thread.is_resolved and not include_resolved then
			include = false
		end
		if thread.is_outdated and not include_outdated then
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
					-- Flatten newlines so the diagnostic message stays on a single line.
					-- Match the chain comment.lua's old virt_lines code used so behavior
					-- is identical for CRLF bodies.
					local body = (first.body or ""):gsub("\r\n", " "):gsub("\n", " ")
					local message = (first.author or "?") .. ": " .. body
					table.insert(out, {
						lnum = s - 1,
						end_lnum = e - 1,
						col = 0,
						severity = thread.is_resolved and severity_resolved or severity_unresolved,
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
