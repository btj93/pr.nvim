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

return M
