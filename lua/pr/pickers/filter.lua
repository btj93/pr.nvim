-- Shared filter state across pickers. Each picker reads `state` at list-build
-- time and rebuilds when toggle(kind) is called.

local M = {}

local PR_FILTERS = { "mine", "assigned", "review-requested", "all" }
M.PR_FILTERS = PR_FILTERS -- exposed for command-completion / external consumers

-- Defaults match the inline rendering knobs (`show_resolved_inline` /
-- `show_outdated_inline` in config.lua, both `false`) so the picker
-- surfaces actionable threads first. Toggle via `R`/`O` (snacks, telescope)
-- or `<C-r>`/`<C-o>` (fzf).
M.state = {
	show_resolved = false,
	show_outdated = false,
	pr_list_filter = "all",
}

--- Reset filter state to defaults. Called by M.refresh paths.
function M.reset()
	M.state.show_resolved = false
	M.state.show_outdated = false
	M.state.pr_list_filter = "all"
end

--- Set the PR-list filter to a specific kind. Ignores unknown values.
---@param kind string
function M.set_pr_filter(kind)
	for _, v in ipairs(PR_FILTERS) do
		if v == kind then
			M.state.pr_list_filter = kind
			return
		end
	end
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

--- Cycle to the next PR-list filter (mine → assigned → review-requested → all → mine).
function M.cycle_pr_filter()
	local current = M.state.pr_list_filter
	for i, v in ipairs(PR_FILTERS) do
		if v == current then
			M.state.pr_list_filter = PR_FILTERS[(i % #PR_FILTERS) + 1]
			return
		end
	end
	-- Unknown value: reset to the default.
	M.state.pr_list_filter = PR_FILTERS[1]
end

--- Human label describing the current PR-list filter. Used by pickers to prefix
--- the prompt (e.g. "[mine] PRs").
---@return string
function M.pr_list_label()
	return "[" .. M.state.pr_list_filter .. "] "
end

--- Single-cell state indicator for a thread, used by all three pickers'
--- `format_comments` so resolved / outdated / active rows are visually
--- distinguishable when the filters allow them through.
--- Returns `{ glyph, hl }` — the glyph is a single display cell so column
--- alignment downstream stays predictable.
---@param thread { is_resolved?: boolean, is_outdated?: boolean }
---@return string glyph
---@return string highlight_group
function M.state_glyph(thread)
	if thread and thread.is_resolved then
		return "✓", "Comment"
	end
	if thread and thread.is_outdated then
		return "~", "DiagnosticHint"
	end
	return "·", "NonText"
end

return M
