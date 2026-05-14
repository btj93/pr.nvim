-- Pure helpers for GitHub-flavored ```suggestion blocks.
-- Apply / render integration lives in lua/pr/ui.lua and lua/pr/<future tasks>.

local M = {}

local drift = require("pr.drift")

---@class Suggestion
---@field content_lines string[]
---@field fence_open_idx integer  -- 1-indexed line in the original body
---@field fence_close_idx integer

---Parse a comment body and return all `suggestion` blocks (in order).
---Unclosed fences are skipped; only fully-fenced blocks are returned.
---@param body string?
---@return Suggestion[]
function M.extract_suggestions(body)
	local out = {}
	if not body or body == "" then
		return out
	end
	local lines = vim.split(body, "\n", { plain = true })
	local i = 1
	while i <= #lines do
		if lines[i]:match("^```suggestion%s*$") then
			local content = {}
			local close_idx = nil
			for j = i + 1, #lines do
				if lines[j]:match("^```%s*$") then
					close_idx = j
					break
				end
				table.insert(content, lines[j])
			end
			if close_idx then
				table.insert(out, {
					content_lines = content,
					fence_open_idx = i,
					fence_close_idx = close_idx,
				})
				i = close_idx + 1
			else
				-- Unclosed fence — bail out so the next iteration doesn't re-process.
				break
			end
		else
			i = i + 1
		end
	end
	return out
end

---Wrap a list of lines in a ```suggestion fence.
---@param lines string[]
---@return string
function M.wrap_as_suggestion(lines)
	return "```suggestion\n" .. table.concat(lines or {}, "\n") .. "\n```"
end

---If `text` is a complete ```suggestion ``` block, return its inner lines.
---Otherwise return nil (not a suggestion).
---@param text string
---@return string[]?
function M.unwrap_suggestion(text)
	if type(text) ~= "string" then
		return nil
	end
	local lines = vim.split(text, "\n", { plain = true })
	if #lines < 2 then
		return nil
	end
	if not lines[1]:match("^```suggestion%s*$") then
		return nil
	end
	if not lines[#lines]:match("^```%s*$") then
		return nil
	end
	local inner = {}
	for k = 2, #lines - 1 do
		table.insert(inner, lines[k])
	end
	return inner
end

---Apply a suggestion to a buffer. Drift-aware: translates the suggestion's
---commit-space anchor lines through `drift_map` (when provided) before
---rewriting the buffer.
---@param buf integer
---@param suggestion table  -- needs content_lines, anchor_start_line, anchor_end_line
---@param drift_map DriftMap|nil
---@return boolean ok, string? err
function M.apply(buf, suggestion, drift_map)
	if not vim.api.nvim_buf_is_valid(buf) then
		return false, "invalid buffer"
	end
	if not suggestion or not suggestion.content_lines then
		return false, "no suggestion content"
	end
	local s = suggestion.anchor_start_line
	local e = suggestion.anchor_end_line
	if not s or not e then
		return false, "missing anchor"
	end
	if drift_map then
		s = drift.commit_to_buffer(drift_map, suggestion.anchor_start_line)
		e = drift.commit_to_buffer(drift_map, suggestion.anchor_end_line)
	end
	if not s or not e then
		return false, "anchor drifted off buffer"
	end
	vim.api.nvim_buf_set_lines(buf, s - 1, e, false, suggestion.content_lines)
	return true
end

---Capture the lines between `start_line` and `end_line` (both 1-indexed and
---inclusive) from `buf`. Safe against invalid ranges and invalid buffers.
---@param buf integer
---@param start_line integer  -- 1-indexed
---@param end_line integer    -- 1-indexed inclusive
---@return string[]
function M._capture_visual_lines(buf, start_line, end_line)
	if not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	if start_line < 1 or end_line < start_line then
		return {}
	end
	local ok, lines = pcall(vim.api.nvim_buf_get_text, buf, start_line - 1, 0, end_line - 1, -1, {})
	if not ok or not lines then
		return {}
	end
	-- Defense-in-depth: some Neovim versions returned a trailing "" when col -1
	-- landed on the next line; strip it.
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines, #lines)
	end
	return lines
end

---Open a new-comment popup pre-wrapped as a ```suggestion fence around the
---current visual selection. The user can add prose above/below before submitting.
function M.comment_with_suggestion()
	local git = require("pr.provider").get_provider()
	git.get_git_root(vim.schedule_wrap(function(git_root)
		if not git_root or git_root == "" then
			vim.notify("Not a git repository", vim.log.levels.ERROR)
			return
		end
		local buf = vim.api.nvim_get_current_buf()
		local buffer_path = vim.api.nvim_buf_get_name(buf)
		if buffer_path == "" then
			vim.notify("Buffer has no file path", vim.log.levels.ERROR)
			return
		end
		local relative_path = buffer_path:sub(#git_root + 2)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
		local start_line = vim.fn.line("'<")
		local end_line = vim.fn.line("'>")
		if start_line == 0 or end_line == 0 then
			vim.notify("No visual selection", vim.log.levels.WARN)
			return
		end
		local lines = M._capture_visual_lines(buf, start_line, end_line)
		if #lines == 0 then
			vim.notify("No selection", vim.log.levels.WARN)
			return
		end
		local fenced = M.wrap_as_suggestion(lines)
		local fenced_lines = vim.split(fenced, "\n", { plain = true })
		local ui = require("pr.ui")
		local ft = vim.bo.filetype
		local layout = ui.make_new_comment_layout(fenced_lines, ft, relative_path, start_line, end_line)
		layout:mount()
		vim.cmd("startinsert")
	end))
end

return M
