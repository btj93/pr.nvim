local M = {}

function M.get_picker(opts)
	opts = opts or {}
	local picker = opts.picker or "snacks"
	return require("pr.pickers." .. picker)
end

function M.pick_hunks(...)
	local picker = M.get_picker()
	picker.pick_hunks(...)
end

function M.pick_comments(...)
	local picker = M.get_picker()
	picker.pick_comments(...)
end

return M
