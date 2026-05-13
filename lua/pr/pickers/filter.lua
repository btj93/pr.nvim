-- Shared filter state across pickers. Each picker reads `state` at list-build
-- time and rebuilds when toggle(kind) is called.

local M = {}

M.state = {
	show_resolved = true,
	show_outdated = true,
}

--- Reset filter state to defaults. Called by M.refresh paths.
function M.reset()
	M.state.show_resolved = true
	M.state.show_outdated = true
end

--- Toggle the visibility of a thread category.
---@param kind "resolved"|"outdated"
function M.toggle(kind)
	if kind == "resolved" then
		M.state.show_resolved = not M.state.show_resolved
	elseif kind == "outdated" then
		M.state.show_outdated = not M.state.show_outdated
	end
end

--- Filter a Comments map according to current state.
--- Threads whose flags don't match the current filters are dropped from
--- their file's list; files with no surviving threads are dropped entirely.
---@param comments Comments
---@return Comments
function M.apply(comments)
	local out = {}
	for file, threads in pairs(comments or {}) do
		local kept = {}
		for _, thread in ipairs(threads) do
			local include = true
			if not M.state.show_resolved and thread.is_resolved then
				include = false
			end
			if not M.state.show_outdated and thread.is_outdated then
				include = false
			end
			if include then
				table.insert(kept, thread)
			end
		end
		if #kept > 0 then
			out[file] = kept
		end
	end
	return out
end

--- Human label describing the current filter state. Used by pickers to
--- prefix the prompt (e.g. "[unresolved] >").
---@return string
function M.label()
	local parts = {}
	if not M.state.show_resolved then
		table.insert(parts, "unresolved")
	end
	if not M.state.show_outdated then
		table.insert(parts, "current")
	end
	if #parts == 0 then
		return ""
	end
	return "[" .. table.concat(parts, "+") .. "] "
end

return M
