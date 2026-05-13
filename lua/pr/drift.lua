-- Working-tree drift: translate line numbers between a file's HEAD-committed
-- state and its current buffer state using vim.diff's index-mode output.
--
-- vim.diff index conventions (verified 2026-05-13 against Neovim):
--   pure insertion at top -> { 0, 0, 1, count_b }
--   pure deletion at top  -> { 1, count_a, 0, 0 }
-- start_a/start_b for zero-count sides represent the "position before which"
-- the missing content would have lived in the other input.
--
-- Public API:
--   M.compute_drift(committed_lines: string[], buffer_lines: string[]) -> DriftMap
--   M.commit_to_buffer(drift, commit_line) -> integer|nil
--   M.buffer_to_commit(drift, buffer_line) -> integer|nil
--
-- A nil return means "this line was removed in the other version" — caller
-- should typically skip drawing/anchoring on it.

local M = {}

--- @class DriftHunk
--- @field [1] integer start_a (1-indexed; 0 when count_a == 0 means "before line 1 of A")
--- @field [2] integer count_a
--- @field [3] integer start_b
--- @field [4] integer count_b

--- @class DriftMap
--- @field hunks DriftHunk[]

---@param committed_lines string[]
---@param buffer_lines string[]
---@return DriftMap
function M.compute_drift(committed_lines, buffer_lines)
	local a = table.concat(committed_lines, "\n")
	local b = table.concat(buffer_lines, "\n")
	local hunks = vim.diff(a, b, { result_type = "indices" }) or {}
	return { hunks = hunks }
end

---@param drift DriftMap
---@param commit_line integer
---@return integer|nil
function M.commit_to_buffer(drift, commit_line)
	if type(commit_line) ~= "number" or commit_line < 1 then
		return nil
	end
	local shift = 0
	for _, h in ipairs(drift.hunks) do
		local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
		if count_a == 0 then
			-- Pure insertion: only affects shift for commit lines past start_a.
			if commit_line > start_a then
				shift = shift + count_b
			else
				return commit_line + shift
			end
		else
			if commit_line < start_a then
				return commit_line + shift
			elseif commit_line < start_a + count_a then
				if count_b == 0 then
					return nil
				end
				local off = commit_line - start_a
				if off < count_b then
					return start_b + off
				else
					return nil
				end
			else
				shift = shift + (count_b - count_a)
			end
		end
	end
	return commit_line + shift
end

---@param drift DriftMap
---@param buffer_line integer
---@return integer|nil
function M.buffer_to_commit(drift, buffer_line)
	if type(buffer_line) ~= "number" or buffer_line < 1 then
		return nil
	end
	local shift = 0
	for _, h in ipairs(drift.hunks) do
		local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
		if count_b == 0 then
			if buffer_line > start_b then
				shift = shift + (count_b - count_a)
			else
				return buffer_line - shift
			end
		else
			if buffer_line < start_b then
				return buffer_line - shift
			elseif buffer_line < start_b + count_b then
				if count_a == 0 then
					return nil
				end
				local off = buffer_line - start_b
				if off < count_a then
					return start_a + off
				else
					return nil
				end
			else
				shift = shift + (count_b - count_a)
			end
		end
	end
	return buffer_line - shift
end

local Job = require("plenary.job")

--- Fetch the HEAD-committed lines of a file via `git show HEAD:<relative_path>`.
--- Invokes callback with a string[] (split on \n) on success, or {} on failure
--- (file doesn't exist at HEAD, or git error).
---@param git_root string Absolute path to the git root.
---@param relative_path string Path relative to git_root.
---@param callback fun(lines: string[])
function M.fetch_committed_lines(git_root, relative_path, callback)
	Job:new({
		command = "git",
		args = { "-C", git_root, "show", "HEAD:" .. relative_path },
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				callback({})
				return
			end
			callback(j:result() or {})
		end),
	}):start()
end

-- Per-buffer cache of HEAD-committed content. The DriftMap is recomputed
-- against the buffer's CURRENT lines on every call (cheap — it's a string
-- diff). HEAD content is only refetched when invalidated (BufWritePost,
-- HEAD rotation, M.refresh) or when the path changes for this bufnr.
---@class DriftCacheEntry
---@field committed_lines string[]
---@field path string

local cache = {} -- bufnr -> DriftCacheEntry

-- Memoize the computed DriftMap by (bufnr, changedtick, path) so repeated
-- get_for_buffer calls between buffer edits skip the diff recomputation.
local diff_cache = {} -- bufnr -> { changedtick, path, drift_map }

--- Async getter that returns a fresh DriftMap for the given buffer.
---@param bufnr integer
---@param git_root string
---@param relative_path string
---@param callback fun(drift: DriftMap|nil)
function M.get_for_buffer(bufnr, git_root, relative_path, callback)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		callback(nil)
		return
	end

	local entry = cache[bufnr]

	-- Reuse committed_lines when the entry matches the same path.
	-- Invalidation (drift.invalidate / drift.invalidate_all) drops the entry,
	-- forcing a refetch on the next call.
	if entry and entry.path == relative_path then
		local current_tick = vim.api.nvim_buf_get_changedtick(bufnr)
		local memo = diff_cache[bufnr]
		if memo and memo.changedtick == current_tick and memo.path == relative_path then
			callback(memo.drift_map)
			return
		end
		local buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local drift_map = M.compute_drift(entry.committed_lines, buffer_lines)
		diff_cache[bufnr] = { changedtick = current_tick, path = relative_path, drift_map = drift_map }
		callback(drift_map)
		return
	end

	M.fetch_committed_lines(git_root, relative_path, function(committed_lines)
		cache[bufnr] = {
			committed_lines = committed_lines,
			path = relative_path,
		}
		if not vim.api.nvim_buf_is_valid(bufnr) then
			callback(nil)
			return
		end
		local refreshed_buffer_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local drift_map = M.compute_drift(committed_lines, refreshed_buffer_lines)
		diff_cache[bufnr] = {
			changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
			path = relative_path,
			drift_map = drift_map,
		}
		callback(drift_map)
	end)
end

--- Force a refetch of HEAD content for the given buffer on next get_for_buffer.
--- Call this from BufWritePost / refresh paths.
---@param bufnr integer
function M.invalidate(bufnr)
	cache[bufnr] = nil
	diff_cache[bufnr] = nil
end

--- Drop all cache entries (e.g. on provider clear).
function M.invalidate_all()
	cache = {}
	diff_cache = {}
end

return M
