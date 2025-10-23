local config = require("pr.config")

local M = {}

---
---@param picker? string
---@return table
function M.get_picker(picker)
	picker = picker or config.opts.picker
	return require("pr.pickers." .. picker)
end

function M.pick_hunks(picker, ...)
	picker = M.get_picker(picker)
	picker.pick_hunks(...)
end

function M.pick_comments(picker, ...)
	picker = M.get_picker(picker)
	picker.pick_comments(...)
end

return M
