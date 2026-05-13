local M = {}

---
---@param win integer
---@return boolean?
function M.is_float(win)
	local opts = vim.api.nvim_win_get_config(win)
	return opts and opts.relative and opts.relative ~= ""
end

---
---@param win integer
---@return boolean
function M.is_valid_win(win)
	if not vim.api.nvim_win_is_valid(win) then
		return false
	end
	-- avoid E5108 after pressing q:
	if vim.fn.getcmdwintype() ~= "" then
		return false
	end
	-- dont do anything for floating windows
	if M.is_float(win) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	return M.is_valid_buf(buf)
end

---
---@param buf integer
---@return boolean
function M.is_quickfix(buf)
	return vim.api.nvim_get_option_value("buftype", { buf = buf }) == "quickfix"
end

---
---@param buf integer
---@return boolean
function M.is_valid_buf(buf)
	-- Skip special buffers
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
	if buftype ~= "" and buftype ~= "quickfix" then
		return false
	end
	-- local filetype = vim.api.nvim_buf_get_option(buf, "filetype")
	-- TODO: config
	-- if vim.tbl_contains({}, filetype) then
	--   return false
	-- end
	return true
end

--- Parse unified-diff output (as produced by `git diff`, `gh pr diff`, `glab mr diff`)
--- into a per-file table of contiguous change blocks.
---@param diff_lines table A table of strings, where each string is a line from the diff output.
---@return Hunks A table where keys are filenames and values are lists of Hunk objects.
function M.parse_diff_hunks(diff_lines)
	---@type Hunks
	local hunks_by_file = {}

	local current_file = nil
	local line_num_in_buffer = -1

	local block_start_line = 0
	local block_end_line = 0
	local has_add = false
	local has_del = false

	local function save_current_block()
		if current_file and block_start_line > 0 then
			local final_end_line = block_end_line
			if has_del and not has_add then
				final_end_line = block_start_line
			end

			table.insert(hunks_by_file[current_file], {
				hunk_start = block_start_line,
				hunk_end = final_end_line,
				type = (has_add and has_del and "Change") or (has_del and "Del") or "Add",
			})
		end

		block_start_line = 0
		block_end_line = 0
		has_add = false
		has_del = false
	end

	for _, line in ipairs(diff_lines) do
		local diff_file = line:match("^diff %-%-git a/.+ b/(.+)$")
		if diff_file then
			save_current_block()

			current_file = diff_file
			hunks_by_file[current_file] = {}
			line_num_in_buffer = -1
			goto continue
		end

		if not current_file then
			goto continue
		end

		local start_line_str = line:match("^@@ %-.+ %+([0-9]+)")
		if start_line_str then
			save_current_block()
			line_num_in_buffer = tonumber(start_line_str) - 1
			goto continue
		end

		if line_num_in_buffer >= 0 then
			if line:sub(1, 1) == " " then
				save_current_block()
				line_num_in_buffer = line_num_in_buffer + 1
			elseif line:sub(1, 1) == "+" then
				if block_start_line == 0 then
					block_start_line = line_num_in_buffer + 1
				end
				line_num_in_buffer = line_num_in_buffer + 1
				block_end_line = line_num_in_buffer
				has_add = true
			elseif line:sub(1, 1) == "-" then
				if block_start_line == 0 then
					block_start_line = line_num_in_buffer + 1
				end
				has_del = true
			end
		end
		::continue::
	end

	save_current_block()

	return hunks_by_file
end

return M
