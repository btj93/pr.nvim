local M = {}

local git = require("pr.provider").get_provider()
local config = require("pr.config")
local util = require("pr.util")
local drift = require("pr.drift")
-- `pr.ui` is required lazily inside M.comment so that importing this module
-- in unit tests doesn't drag in nui.nvim (which isn't available in the test env).

M.bufs = {}
M.wins = {}
M.generations = {}
M.enabled = false

-- File-local helper. Places the gutter signs for a thread. Inline comment
-- text (below the line / at EOL) is published by `lua/pr/diagnostics.lua`
-- via `vim.diagnostic`, so the user's diagnostic config controls how it
-- renders. Multi-line range connectors (┌/│/└) stay here because
-- vim.diagnostic can't express them.
local function place_decorations(buf, thread, first_comment, start_line, end_line)
	if start_line == end_line then
		vim.fn.sign_place(0, config.opts.highlights.sign_group, config.opts.highlights.sign_comment, buf, { lnum = end_line })
	else
		vim.fn.sign_place(0, config.opts.highlights.sign_group, config.opts.highlights.sign_comment_multi_line_start, buf, { lnum = start_line })
		for i = start_line + 1, end_line - 1 do
			vim.fn.sign_place(0, config.opts.highlights.sign_group, config.opts.highlights.sign_comment_multi_line_connector, buf, { lnum = i })
		end
		vim.fn.sign_place(0, config.opts.highlights.sign_group, config.opts.highlights.sign_comment_multi_line_end, buf, { lnum = end_line })
	end
end

---
---@param buf integer?
function M.draw(buf)
	-- vim.notify("draw")
	buf = buf or vim.api.nvim_get_current_buf()
	if M.bufs[buf] then
		return
	end

	M.bufs[buf] = true
	local my_gen = M.generations[buf] or 0

	local buffer_path = vim.api.nvim_buf_get_name(buf)
	if buffer_path == "" then
		return
	end

	local comments_placed = 0
	git.get_git_root(vim.schedule_wrap(function(git_root)
		if git_root == nil or git_root == "" then
			vim.api.nvim_echo({ { "Not a git repository.", "WarningMsg" } }, true, {})
			return
		end

		local relative_path = buffer_path:sub(#git_root + 2)
		local comments = git.comments[relative_path] or {}
		if next(comments) == nil then
			if config.opts.debug then
				vim.api.nvim_echo({ { "No inline PR comments found for this file.", "WarningMsg" } }, true, {})
			end
			return
		end
		drift.get_for_buffer(buf, git_root, relative_path, function(drift_map)
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			if (M.generations[buf] or 0) ~= my_gen then
				return
			end
			for _, thread in ipairs(comments) do
				local _, first_comment = next(thread.comments)
				-- Skip outdated threads inline: their line numbers refer to a previous
				-- commit's file state and would decorate the wrong lines in the buffer.
				-- Opt-in via `config.opts.show_outdated_inline = true`.
				if thread.is_outdated and not config.opts.show_outdated_inline then
					first_comment = nil
				end
				if thread.is_resolved and not config.opts.show_resolved_inline then
					first_comment = nil
				end
				if first_comment then
					local start_line = first_comment.start_line
					local end_line = first_comment.end_line
					if drift_map then
						start_line = drift.commit_to_buffer(drift_map, first_comment.start_line)
						end_line = drift.commit_to_buffer(drift_map, first_comment.end_line)
					end
					if start_line and end_line then
						place_decorations(buf, thread, first_comment, start_line, end_line)

						comments_placed = comments_placed + 1
					end
				end
			end

			local ok_diag, diagnostics = pcall(require, "pr.diagnostics")
			if ok_diag then
				diagnostics.publish(buf, comments, drift_map)
			end

			if config.opts.debug then
				if comments_placed > 0 then
					vim.api.nvim_echo({ { comments_placed .. " PR comment threads shown.", "InfoMsg" } }, true, {})
				else
					vim.api.nvim_echo({ { "No inline PR comments found for this file.", "WarningMsg" } }, true, {})
				end
			end
		end)
	end))
end

---
---@param direction "forward"|"backward"
---@param relative_path string?
---@param line integer?
function M.cycle_comments_in_buffer(direction, relative_path, line)
	git.get_git_root(vim.schedule_wrap(function(git_root)
		if git_root == nil or git_root == "" then
			vim.api.nvim_echo({ { "Not a git repository.", "WarningMsg" } }, true, {})
			return
		end

		local buf = vim.api.nvim_get_current_buf()
		local buffer_path = vim.api.nvim_buf_get_name(buf)
		if buffer_path == "" then
			return
		end
		relative_path = relative_path or buffer_path:sub(#git_root + 2)
		local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
		line = line or row

		git.get_comments(vim.schedule_wrap(function(comments)
			comments = comments[relative_path] or {}

			if #comments == 0 then
				vim.notify("No comments found in this file.")
				return
			end

			local before_line = nil
			local after_line = nil
			local before_index = nil
			local after_index = nil
			for i, thread in ipairs(comments) do
				local _, first_comment = next(thread.comments)
				if first_comment then
					if first_comment.start_line < line then
						before_line = first_comment.start_line
						before_index = i
					else
						after_line = first_comment.start_line
						after_index = i
					end
				end
			end

			if direction == "forward" then
				vim.api.nvim_win_set_cursor(0, { after_line or before_line, 0 })
				vim.notify("Comment " .. (after_index or before_index) .. " of " .. #comments)
			elseif direction == "backward" then
				vim.api.nvim_win_set_cursor(0, { before_line or after_line, 0 })
				vim.notify("Comment " .. (before_index or after_index) .. " of " .. #comments)
			end
		end))
	end))
end

---
---@param relative_path? string
---@param start_line? integer
---@param end_line? integer
function M.comment(relative_path, start_line, end_line)
	-- TODO: permission check
	git.get_git_root(vim.schedule_wrap(function(git_root)
		if git_root == nil or git_root == "" then
			vim.api.nvim_echo({ { "Not a git repository.", "WarningMsg" } }, true, {})
			return
		end

		local buf = vim.api.nvim_get_current_buf()
		local buffer_path = vim.api.nvim_buf_get_name(buf)
		local ft = vim.bo.filetype
		if buffer_path == "" then
			return
		end
		relative_path = relative_path or buffer_path:sub(#git_root + 2)

		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
		start_line = vim.fn.line("'<")
		end_line = vim.fn.line("'>")

		local lines = vim.api.nvim_buf_get_text(buf, start_line - 1, 0, end_line + 1, -1, {})
		local ui = require("pr.ui")
		local layout = ui.make_new_comment_layout(lines, ft, relative_path, start_line, end_line)
		layout:mount()

		vim.cmd("startinsert")
	end))
end

--- Clear comment decorations for a single buffer, including the "already drawn"
--- flag in M.bufs so the next M.draw call actually re-runs (rather than
--- short-circuiting on the flag).
local function clear_buf_decorations(buf)
	M.generations[buf] = (M.generations[buf] or 0) + 1
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, config.opts.highlights.comments_ns_id, 0, -1)
		vim.fn.sign_unplace(config.opts.highlights.sign_group, { buffer = buf })
	end
	M.bufs[buf] = nil
end

--- Clear all comment decorations from currently-tracked buffers.
local function clear_decorations()
	for buf, _ in pairs(M.bufs) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, config.opts.highlights.comments_ns_id, 0, -1)
		end
	end
	vim.fn.sign_unplace(config.opts.highlights.sign_group)
	M.bufs = {}
end

function M.stop()
	M.enabled = false
	M.wins = {}
	clear_decorations()
	pcall(function()
		require("pr.diagnostics").clear_all()
	end)
	drift.invalidate_all()
	pcall(vim.api.nvim_del_augroup_by_name, "PRComment")
	pcall(vim.api.nvim_del_augroup_by_name, "PRCommentBufWrite")
	if type(git.clear_comments) == "function" then
		git.clear_comments()
	else
		git.clear()
	end
end

--- Build flat lookup tables keyed by thread id and comment database_id.
local function flatten(comments_by_file)
	local threads = {}
	local comments = {}
	for _, file_threads in pairs(comments_by_file or {}) do
		for _, thread in ipairs(file_threads) do
			threads[thread.id] = thread
			for _, c in ipairs(thread.comments or {}) do
				comments[c.database_id] = { comment = c, thread_id = thread.id }
			end
		end
	end
	return threads, comments
end

--- Compare two comment snapshots (as returned by the provider's `get_comments`).
--- Returns a single-line human-readable summary, or nil when nothing changed
--- or when there's no meaningful "old" state to diff against.
---@param old Comments?
---@param new Comments?
---@return string?
function M._diff_comments(old, new)
	if not old or not next(old) then
		return nil
	end

	local old_threads, old_comments = flatten(old)
	local new_threads, new_comments = flatten(new)

	local stats = {
		new_threads = 0,
		deleted_threads = 0,
		resolved = 0,
		unresolved = 0,
		new_replies = 0,
		deleted_comments = 0,
		edited_comments = 0,
	}

	for id, thread in pairs(new_threads) do
		if not old_threads[id] then
			stats.new_threads = stats.new_threads + 1
		else
			local was_resolved = old_threads[id].is_resolved
			if not was_resolved and thread.is_resolved then
				stats.resolved = stats.resolved + 1
			elseif was_resolved and not thread.is_resolved then
				stats.unresolved = stats.unresolved + 1
			end
		end
	end

	for id, _ in pairs(old_threads) do
		if not new_threads[id] then
			stats.deleted_threads = stats.deleted_threads + 1
		end
	end

	for id, entry in pairs(new_comments) do
		local old_entry = old_comments[id]
		if not old_entry then
			-- If the thread already existed, this is a reply. If the thread is new,
			-- the first comment is implicit in `new_threads` and we don't double-count.
			if old_threads[entry.thread_id] then
				stats.new_replies = stats.new_replies + 1
			end
		elseif old_entry.comment.updated_at ~= entry.comment.updated_at or old_entry.comment.body ~= entry.comment.body then
			stats.edited_comments = stats.edited_comments + 1
		end
	end

	for id, entry in pairs(old_comments) do
		if not new_comments[id] and new_threads[entry.thread_id] then
			-- Thread still exists but this comment is gone — a deleted reply.
			-- Comments whose thread is also gone are accounted for by deleted_threads.
			stats.deleted_comments = stats.deleted_comments + 1
		end
	end

	local parts = {}
	local function add(count, singular, plural)
		if count > 0 then
			table.insert(parts, count .. " " .. (count == 1 and singular or plural))
		end
	end
	add(stats.new_threads, "new thread", "new threads")
	add(stats.new_replies, "new reply", "new replies")
	add(stats.resolved, "resolved", "resolved")
	add(stats.unresolved, "reopened", "reopened")
	add(stats.edited_comments, "edited", "edited")
	add(stats.deleted_threads, "deleted thread", "deleted threads")
	add(stats.deleted_comments, "deleted comment", "deleted comments")

	if #parts == 0 then
		return nil
	end
	return "PR: " .. table.concat(parts, ", ")
end

local refresh_in_progress = false

--- Invalidate the comments cache, re-fetch, then redraw all attached windows.
---@param opts? { show_diff?: boolean }
function M.refresh(opts)
	if not M.enabled or refresh_in_progress then
		return
	end
	opts = opts or {}
	local show_diff = opts.show_diff ~= false

	local old_snapshot = show_diff and vim.deepcopy(git.comments or {}) or nil

	clear_decorations()
	drift.invalidate_all()
	if type(git.clear_comments) == "function" then
		git.clear_comments()
	end
	refresh_in_progress = true
	git.get_comments(vim.schedule_wrap(function(new_comments)
		refresh_in_progress = false

		if show_diff then
			local msg = M._diff_comments(old_snapshot, new_comments)
			if msg then
				vim.notify(msg)
			end
		end

		for win, _ in pairs(M.wins) do
			if vim.api.nvim_win_is_valid(win) then
				local buf = vim.api.nvim_win_get_buf(win)
				if vim.api.nvim_buf_is_valid(buf) then
					M.draw(buf)
				end
			end
		end

		-- Drop drafts whose target (file / thread / comment) no longer exists
		-- in the refreshed cache. Keeps the drafts file from accumulating
		-- orphans across rebases and upstream deletions.
		pcall(function()
			local known = { paths = {}, thread_ids = {}, comment_ids = {} }
			for path, threads in pairs(new_comments or {}) do
				known.paths[path] = true
				for _, t in ipairs(threads) do
					known.thread_ids[tostring(t.id)] = true
					for _, c in ipairs(t.comments or {}) do
						known.comment_ids[tostring(c.database_id)] = true
					end
				end
			end
			require("pr.drafts").invalidate_orphans(known)
		end)

		pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "PRCommentsRefreshed" })
	end))
end

function M.toggle()
	if M.enabled then
		M.stop()
	else
		M.start()
	end
end

---
---@param win integer?
function M.attach(win)
	win = win or vim.api.nvim_get_current_win()
	if not util.is_valid_win(win) then
		return
	end

	local buf = vim.api.nvim_win_get_buf(win)

	if not M.bufs[buf] then
		-- vim.notify("attach")
		vim.api.nvim_buf_attach(buf, false, {
			on_lines = function()
				if not M.enabled then
					return true
				end
				-- detach from this buffer in case we no longer want it
				if not util.is_valid_buf(buf) then
					return true
				end

				M.draw(buf)
			end,
			on_detach = function()
				M.bufs[buf] = nil
				M.generations[buf] = nil
				drift.invalidate(buf)
			end,
		})

		vim.api.nvim_create_autocmd("BufWritePost", {
			group = vim.api.nvim_create_augroup("PRCommentBufWrite", { clear = false }),
			buffer = buf,
			callback = function()
				drift.invalidate(buf)
				if M.enabled then
					clear_buf_decorations(buf)
					M.draw(buf)
				end
			end,
		})

		M.draw(buf)

		M.wins[win] = true
	end
end

function M.start()
	M.enabled = true
	git.get_git_user(vim.schedule_wrap(function(_)
		git.get_hunks(vim.schedule_wrap(function(_)
			git.get_comments(vim.schedule_wrap(function(_)
				vim.api.nvim_exec2(
					[[augroup PRComment
        autocmd!
        autocmd BufWinEnter,WinNew * lua require("pr").attach_comment()
      augroup end]],
					{ output = false }
				)

				-- attach to all bufs in visible windows
				for _, win in pairs(vim.api.nvim_list_wins()) do
					if not M.wins[win] then
						M.attach(win)
					end
				end
			end))
		end))
	end))
end

function M.setup()
	if config.opts.run_on_start.comments then
		M.start()
	end
end

return M
