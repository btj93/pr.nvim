-- nui.nvim is a hard runtime dependency, but we wrap requires in pcall so that
-- the pure helpers in this file (e.g. M._render_thread) can be unit-tested in
-- environments that don't have nui installed.
local function safe_require(mod)
	local ok, m = pcall(require, mod)
	return ok and m or nil
end

local Popup = safe_require("nui.popup")
local Layout = safe_require("nui.layout")
local Menu = safe_require("nui.menu")
local Line = safe_require("nui.line")
local Text = safe_require("nui.text")
local NuiText = safe_require("nui.text")
local _autocmd = safe_require("nui.utils.autocmd")
local event = _autocmd and _autocmd.event or nil

local git = require("pr.provider").get_provider()
local config = require("pr.config")

local M = {}

function M._glyph_for(content)
	if git and git.reaction_palette then
		for _, entry in ipairs(git.reaction_palette) do
			if entry.content == content then
				return entry.glyph
			end
		end
	end
	-- Reactions outside the active provider's palette (e.g. an award placed via
	-- the GitLab web UI with an emoji we don't list) show their raw shortcode.
	return ":" .. tostring(content):lower() .. ":"
end

M.reply_actions = {
	submit = {},
	suggestion = {},
	saved_reply = {},
}

-- FIXME: lift this into config; the outer layout width (80) and the per-popup
-- content width (78 = 80 - left/right border) must stay in sync.
local BODY_WIDTH = 78

--- Map a CheckRun's status/conclusion to a single-glyph indicator. Used by
--- _render_pr_info and the (future) checks menu to keep glyphs consistent.
---@param c CheckRun
---@return string
local function check_glyph(c)
	if c.status ~= "completed" then
		return "…"
	end
	if c.conclusion == "success" then
		return "✔"
	end
	if c.conclusion == "failure" then
		return "✖"
	end
	if c.conclusion == "cancelled" then
		return "○"
	end
	if c.conclusion == "skipped" then
		return "⤼"
	end
	return "?"
end

-- Exposed for unit testing only.
M._check_glyph = check_glyph

--- Pure renderer for a comment thread.
--- Produces the buffer contents for the unified scrollable comments view, plus
--- a lookup from each buffer line to the comment index it belongs to, and
--- per-comment line ranges used by edit-in-place and hint placement.
---@param thread ReviewThread
---@return { lines: string[], line_to_comment: table<integer, integer>, comment_meta: table<integer, { header_line: integer, body_start: integer, body_end: integer, footer_line: integer }> }
local function render_thread(thread)
	local lines = {}
	local line_to_comment = {}
	local comment_meta = {}

	local function emit(line, idx)
		table.insert(lines, line)
		line_to_comment[#lines] = idx
	end

	-- Width used for the horizontal rule fill; subtract for the leading "─ author ─ " prefix.
	local function header_line(author_display)
		local prefix = "── " .. author_display .. " "
		local fill = math.max(3, BODY_WIDTH - vim.fn.strdisplaywidth(prefix))
		return prefix .. string.rep("─", fill)
	end

	for i, c in ipairs(thread.comments or {}) do
		local author = (c.author or "unknown") .. (c.viewer_did_author and " (you)" or "")
		local meta = {}

		emit(header_line(author), i)
		meta.header_line = #lines

		local body_raw = (c.body or ""):gsub("\r", "")
		local body = vim.fn.split(body_raw, "\n")
		if #body == 0 then
			body = { "" }
		end
		meta.body_start = #lines + 1
		-- Walk body lines, swapping in a visual box wherever a ```suggestion fence opens.
		-- `extract_suggestions` operates on the original body so its fence_open_idx /
		-- fence_close_idx line up with the indices of `body` here.
		local suggestion = require("pr.suggestion")
		local sugs = suggestion.extract_suggestions(body_raw)
		if #sugs == 0 then
			for _, bl in ipairs(body) do
				emit(bl, i)
			end
		else
			local sug_by_open = {}
			for _, s in ipairs(sugs) do
				sug_by_open[s.fence_open_idx] = s
			end
			local bi = 1
			while bi <= #body do
				local s = sug_by_open[bi]
				if s then
					-- Header rule. BODY_WIDTH = 78; "╔═ suggestion " is 14 cells.
					local header_prefix = "╔═ suggestion "
					local header_fill = math.max(3, BODY_WIDTH - vim.fn.strdisplaywidth(header_prefix))
					emit(header_prefix .. string.rep("═", header_fill), i)
					for _, sl in ipairs(s.content_lines) do
						emit("║ + " .. sl, i)
					end
					emit("╚" .. string.rep("═", BODY_WIDTH - 1), i)
					bi = s.fence_close_idx + 1
				else
					emit(body[bi], i)
					bi = bi + 1
				end
			end
		end
		meta.body_end = #lines

		-- Reaction row, only if there's at least one reaction with count > 0.
		local has_reactions = false
		for _, rg in ipairs(c.reaction_groups or {}) do
			if rg.reactors and rg.reactors.totalCount and rg.reactors.totalCount > 0 then
				has_reactions = true
				break
			end
		end
		if has_reactions then
			emit("", i)
			emit(M.format_reaction(c.reaction_groups), i)
		end

		-- Footer line acts as the anchor for the hint virt_lines extmark.
		meta.footer_line = #lines

		comment_meta[i] = meta

		-- Gap between comments, mapped to the preceding comment so cursor-on-gap still resolves.
		if i < #thread.comments then
			emit("", i)
		end
	end

	return { lines = lines, line_to_comment = line_to_comment, comment_meta = comment_meta }
end

-- Exposed for unit testing only.
M._render_thread = render_thread

---Pure: produce the array of lines for the PR info popup buffer.
---Header, body, label/reviewer/assignee rows, optional checks line, action hint.
---@param metadata PRMetadata
---@param checks CheckRun[]|nil
---@return string[]
function M._render_pr_info(metadata, checks)
	local lines = {}
	table.insert(lines, string.format("PR #%d · %s", metadata.number, metadata.title or ""))
	table.insert(
		lines,
		string.format("@%s wants to merge %s ← %s · %s", metadata.author or "", metadata.base_ref or "", metadata.head_ref or "", metadata.state or "")
	)
	table.insert(lines, "")
	for _, l in ipairs(vim.split(metadata.body or "", "\n", { plain = true })) do
		table.insert(lines, l)
	end
	table.insert(lines, "")

	local labels_str = (#metadata.labels > 0) and table.concat(metadata.labels, ", ") or "—"
	table.insert(lines, "── labels:    " .. labels_str)

	local reviewer_strs = {}
	for _, r in ipairs(metadata.reviewers or {}) do
		table.insert(reviewer_strs, string.format("@%s (%s)", r.user, r.state))
	end
	table.insert(lines, "── reviewers: " .. ((#reviewer_strs > 0) and table.concat(reviewer_strs, ", ") or "—"))

	local assignees_str = (#metadata.assignees > 0) and table.concat(metadata.assignees, ", ") or "—"
	table.insert(lines, "── assignees: " .. assignees_str)

	if checks and #checks > 0 then
		local check_strs = {}
		for _, c in ipairs(checks) do
			table.insert(check_strs, string.format("%s %s", check_glyph(c), c.name))
		end
		table.insert(lines, "── checks:    " .. table.concat(check_strs, " · "))
	end

	table.insert(lines, "")
	table.insert(lines, "[e] edit  [c] open check log  [u] refresh  [q] close")
	return lines
end

---Pure: produce one line per pending comment for the review-layout pending list.
---@param pending PendingComment[]|nil
---@return string[]
function M._render_pending_list(pending)
	if not pending or #pending == 0 then
		return { "  (no pending comments)" }
	end
	local lines = {}
	for _, c in ipairs(pending) do
		local snippet = (c.body or ""):gsub("\r\n", " "):gsub("\n", " ")
		if #snippet > 60 then
			snippet = snippet:sub(1, 60) .. "…"
		end
		table.insert(lines, string.format('  · %s:%d "%s"', c.path or "?", c.end_line or 0, snippet))
	end
	return lines
end

--- Compute the bottom-border-style hint string for one comment, mirroring
--- `get_popup_hints` but as a single pre-formatted string suitable for virt_text.
--- Exported (`M._compute_hint_text`) so it can be unit-tested directly.
---@param thread ReviewThread
---@param comment CommentInfo
---@param mode string
---@return string
function M._compute_hint_text(thread, comment, mode)
	local parts = {}
	for _, action in pairs(M.actions or {}) do
		if action.mode == mode and action.show_hint and action.can_perform and action.can_perform(thread, comment) then
			table.insert(parts, action.popup_hint)
		end
	end
	if #parts == 0 then
		return ""
	end
	return " " .. table.concat(parts, " | ") .. " "
end

---
---@param mode string
---@param thread ReviewThread
---@param comment CommentInfo
---@return string[]
local function get_popup_hints(mode, thread, comment)
	local menus = {}
	for _, action in pairs(M.actions) do
		if action.mode == mode and action.show_hint and action.can_perform(thread, comment) then
			table.insert(menus, action.popup_hint)
		end
	end

	return menus
end

---
---@param thread ReviewThread
---@param comment CommentInfo
---@param new_reply_popup NuiPopup
---@param enter boolean
---@return NuiPopup
function M.make_comment_popup(thread, comment, new_reply_popup, enter)
	local author_display = comment.author
	if comment.viewer_did_author then
		author_display = author_display .. " (you)"
	end

	local popup = Popup({
		border = {
			padding = {
				top = 0,
				bottom = 0,
				left = 1,
				right = 1,
			},
			style = "rounded",
			text = {
				top = author_display .. ":",
				top_align = "left",
			},
		},
		buf_options = {
			modifiable = comment.viewer_can_update,
			readonly = not comment.viewer_can_update,
			filetype = "markdown",
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
			wrap = true,
			linebreak = true,
			breakindent = true,
			spell = false,
			foldenable = false,
		},
		enter = enter or false,
	})

	local buf_enter_event = { event.BufEnter }
	if enter then
		table.insert(buf_enter_event, event.BufWinEnter)
	end

	popup:on(buf_enter_event, function()
		popup.border:set_highlight(config.opts.highlights.popup_hl)
	end)

	popup:on({ event.ModeChanged, unpack(buf_enter_event) }, function()
		if vim.api.nvim_get_current_buf() ~= popup.bufnr then
			return
		end

		-- TODO: update menu on comment edit
		local mode = vim.api.nvim_get_mode().mode
		local menus = get_popup_hints(mode, thread, comment)
		local menu = " " .. table.concat(menus, " | ") .. " "
		popup.border:set_text("bottom", menu, "right")
	end)

	popup:on(event.BufLeave, function()
		popup.border:set_highlight("FloatBorder")
		-- don't set text if popup is closing
		if popup.border.bufnr then
			popup.border:set_text("bottom", nil, "right")
		end
	end)

	-- If a persisted draft exists and matches this comment's updated_at, restore it.
	-- Otherwise drop any stale draft (the upstream comment has moved on).
	local drafts = require("pr.drafts")
	local persisted = drafts.get_edit(comment.database_id)
	if persisted and persisted.updated_at ~= comment.updated_at then
		drafts.delete_edit(comment.database_id)
		persisted = nil
	end

	local body
	if persisted and persisted.body then
		body = type(persisted.body) == "table" and persisted.body or vim.fn.split(persisted.body, "\n")
	else
		local b = comment.body:gsub("\r", "")
		body = vim.fn.split(b, "\n")
	end

	local emojis = M.format_reaction(comment.reaction_groups)
	local emojis_width = vim.fn.strdisplaywidth(emojis)

	vim.api.nvim_buf_set_lines(popup.bufnr, 0, 1, false, body)

	vim.api.nvim_buf_set_extmark(popup.bufnr, config.opts.highlights.comments_ns_id, #body - 1, -1, {
		virt_lines = {
			{ { (" "):rep(BODY_WIDTH), config.opts.highlights.comment_sep } },
			{ { emojis .. (" "):rep(BODY_WIDTH - emojis_width), "StatusLine" } },
		},
	})

	if comment.viewer_can_update then
		popup:on({ event.TextChanged, event.TextChangedI }, function()
			local new_body = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, true)
			if vim.deep_equal(new_body, body) then
				return
			end

			drafts.save_edit(comment.database_id, {
				body = new_body,
				updated_at = comment.updated_at,
			})
		end)
	end

	for k, action in pairs(M.actions) do
		if action.key and action.can_perform(thread, comment) then
			popup:map(action.mode, action.key, function()
				M.actions[k].perform(thread, comment, new_reply_popup, popup.winid)
			end)
		end
	end

	return popup
end

-- TODO: make templates
---
---@param enter? boolean
---@param bottom_text? string
---@return NuiPopup
local function make_new_reply_popup(enter, bottom_text)
	bottom_text = bottom_text or "[ 󰌑 Submit ]"

	enter = enter or false
	-- FIXME: use gh.get_git_user
	local reply_popup = Popup({
		border = {
			padding = {
				top = 0,
				bottom = 0,
				left = 1,
				right = 1,
			},
			style = "rounded",
			text = {
				top = "Reply as " .. git.git_user,
				top_align = "left",
			},
		},
		buf_options = {
			modifiable = true,
			readonly = false,
			filetype = "markdown",
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
			wrap = true,
			linebreak = true,
			breakindent = true,
			spell = false,
			foldenable = false,
		},
		enter = enter,
	})

	-- Wire omnifunc for @user / #issue completion (S3b). Users trigger with
	-- <C-x><C-o> in insert mode after typing @ or #.
	if config.opts.completion and config.opts.completion.enabled ~= false then
		vim.bo[reply_popup.bufnr].omnifunc = "v:lua.require'pr.completion'.omnifunc"
	end

	local buf_enter_event = { event.BufEnter }
	if enter then
		table.insert(buf_enter_event, event.BufWinEnter)
	end

	reply_popup:on(buf_enter_event, function()
		reply_popup.border:set_highlight(config.opts.highlights.popup_hl)
		reply_popup.border:set_text("bottom", bottom_text, "right")
	end)

	reply_popup:on(event.BufLeave, function()
		reply_popup.border:set_highlight("FloatBorder")
		-- don't set text if popup is closing
		if reply_popup.border.bufnr then
			reply_popup.border:set_text("bottom", nil, "right")
		end
	end)

	return reply_popup
end

---
---@param lines string[]
---@param ft string
---@return NuiPopup
local function make_code_reference_popup(lines, ft)
	local popup = Popup({
		border = {
			padding = {
				top = 0,
				bottom = 0,
				left = 0,
				right = 0,
			},
			style = "rounded",
			text = {
				top = "Highlighted lines",
				top_align = "left",
			},
		},
		buf_options = {
			modifiable = false,
			readonly = true,
			filetype = ft,
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
		enter = false,
	})

	popup:on(event.BufEnter, function()
		popup.border:set_highlight(config.opts.highlights.popup_hl)
	end)

	popup:on(event.BufLeave, function()
		popup.border:set_highlight("FloatBorder")
	end)

	vim.api.nvim_buf_set_lines(popup.bufnr, 0, #lines, false, lines)

	return popup
end

---
---@param thread ReviewThread
---@param relative_path string?  -- path of the file the thread anchors to (when known)
---@return NuiLayout layout, NuiPopup comments_popup, NuiPopup new_reply_popup
function M.make_comments_layout(thread, relative_path)
	git.get_git_user()
	-- Capture the source buffer BEFORE any popup mounts steal focus. The <C-r>
	-- queue-as-review-comment handler needs to derive the relative path from the
	-- buffer the user was viewing, since ReviewThread doesn't carry a path field.
	local source_bufnr = vim.api.nvim_get_current_buf()
	-- Forward declarations so closures created before these are assigned can still
	-- capture them. `refresh_thread` is built after the layout exists (since it
	-- needs to unmount on a deleted thread); `layout` itself is assigned further
	-- below. Lua resolves these as upvalues by the time the closures actually run.
	---@type NuiLayout?
	local layout
	---@type function?
	local refresh_thread

	local new_reply_popup = make_new_reply_popup()

	-- Reply drafts: keyed by thread.id. Persisted on every buffer change, deleted
	-- on successful submit (<CR> reply or <C-r> queue-as-review path).
	local drafts = require("pr.drafts")
	local reply_key = tostring(thread.id)

	local existing_reply = drafts.get_reply(reply_key)
	if existing_reply and existing_reply.body and existing_reply.body ~= "" then
		vim.api.nvim_buf_set_lines(new_reply_popup.bufnr, 0, -1, false, vim.split(existing_reply.body, "\n", { plain = true }))
	end

	vim.api.nvim_buf_attach(new_reply_popup.bufnr, false, {
		on_lines = function()
			if not vim.api.nvim_buf_is_valid(new_reply_popup.bufnr) then
				return true
			end
			local body = table.concat(vim.api.nvim_buf_get_lines(new_reply_popup.bufnr, 0, -1, false), "\n")
			drafts.save_reply(reply_key, { body = body, updated_at = tostring(os.time()) })
		end,
	})

	new_reply_popup:map("n", "<CR>", function()
		local body = vim.api.nvim_buf_get_lines(new_reply_popup.bufnr, 0, -1, true)
		local _, first_comment = next(thread.comments)
		if first_comment == nil then
			return
		end

		git.reply(
			first_comment.database_id,
			table.concat(body, "\n"),
			vim.schedule_wrap(function(success)
				if not success then
					vim.notify("Reply failed", vim.log.levels.ERROR)
					return
				end
				vim.notify("Reply submitted")
				drafts.delete_reply(reply_key)
				-- Clear the composer buffer and refresh so the new reply appears.
				if vim.api.nvim_buf_is_valid(new_reply_popup.bufnr) then
					vim.api.nvim_buf_set_lines(new_reply_popup.bufnr, 0, -1, false, {})
				end
				if refresh_thread then
					refresh_thread()
				end
			end)
		)
	end)

	-- <C-r>: queue the reply body as a review comment anchored to the first
	-- comment's commit-space line range. Parity with make_new_comment_layout's
	-- <C-r>; replies need no drift translation because the anchor is the
	-- existing thread location, which is already in commit-space.
	local function queue_reply_as_review()
		local body_lines = vim.api.nvim_buf_get_lines(new_reply_popup.bufnr, 0, -1, false)
		local body = table.concat(body_lines, "\n")
		if body == "" then
			vim.notify("Empty body; nothing to queue", vim.log.levels.WARN)
			return
		end
		if type(git.start_pending_review) ~= "function" or type(git.add_review_comment) ~= "function" then
			vim.notify("submit-review not available for this provider")
			return
		end
		local first = thread.comments and thread.comments[1]
		if not first then
			vim.notify("Cannot queue: thread has no comments to anchor to", vim.log.levels.ERROR)
			return
		end
		-- Derive the file path from the source buffer; ReviewThread doesn't
		-- carry a path field. Mirror the pattern in comment.M.comment.
		git.get_git_root(vim.schedule_wrap(function(git_root)
			if not git_root or git_root == "" then
				vim.notify("Not a git repository.", vim.log.levels.ERROR)
				return
			end
			-- Prefer the caller-provided relative_path (init.lua's M.popup
			-- already resolved it). Fall back to deriving from the source
			-- buffer for completeness in case make_comments_layout is called
			-- without the optional 2nd argument.
			local path = relative_path
			if not path or path == "" then
				local buffer_path = vim.api.nvim_buf_is_valid(source_bufnr) and vim.api.nvim_buf_get_name(source_bufnr) or ""
				if buffer_path == "" then
					vim.notify("Cannot queue: source buffer has no name", vim.log.levels.ERROR)
					return
				end
				path = buffer_path:sub(#git_root + 2)
			end
			git.start_pending_review(vim.schedule_wrap(function(review_id, err)
				if not review_id then
					vim.notify(err or "Could not start review", vim.log.levels.ERROR)
					return
				end
				git.add_review_comment(
					review_id,
					path,
					first.start_line or first.end_line,
					first.end_line,
					body,
					vim.schedule_wrap(function(ok)
						if ok then
							vim.notify("Queued as review comment")
							drafts.delete_reply(reply_key)
							if layout then
								layout:unmount()
							end
						else
							vim.notify("Failed to queue review comment", vim.log.levels.ERROR)
						end
					end)
				)
			end))
		end))
	end

	for _, mode in ipairs({ "n", "i" }) do
		new_reply_popup:map(mode, "<C-r>", queue_reply_as_review, { noremap = true })
	end

	-- Single scrollable popup holding the entire conversation.
	local count_label = #thread.comments .. " comment" .. (#thread.comments == 1 and "" or "s")
	local title_suffix = ""
	if thread.is_outdated then
		title_suffix = " — outdated"
	end
	if thread.is_resolved and thread.resolved_by and thread.resolved_by ~= "" then
		title_suffix = title_suffix .. " — resolved by " .. thread.resolved_by
	elseif thread.is_resolved then
		title_suffix = title_suffix .. " — resolved"
	end
	local title = " " .. count_label .. title_suffix .. " "
	-- When the thread is outdated, link Normal to the dim group so the whole
	-- conversation reads as faded. cursorline / hint hl still paint on top.
	local normal_link = thread.is_outdated and "PRCommentOutdated" or "Normal"
	local comments_popup = Popup({
		border = {
			padding = { top = 0, bottom = 0, left = 1, right = 1 },
			style = "rounded",
			text = {
				top = title,
				top_align = "left",
			},
		},
		buf_options = {
			-- Only modifiable=false — writers toggle it around each render. Setting
			-- readonly=true too made every render log "W10: Changing a readonly file".
			modifiable = false,
			filetype = "markdown",
		},
		win_options = {
			winhighlight = "Normal:" .. normal_link .. ",FloatBorder:FloatBorder",
			wrap = true,
			linebreak = true,
			breakindent = true,
			cursorline = true,
			spell = false,
			foldenable = false,
		},
		enter = true,
	})

	-- Border focus highlight, mirroring make_comment_popup.
	comments_popup:on({ event.BufEnter }, function()
		comments_popup.border:set_highlight(config.opts.highlights.popup_hl)
	end)
	comments_popup:on(event.BufLeave, function()
		comments_popup.border:set_highlight("FloatBorder")
	end)

	-- Render state (mutable across re-renders triggered by edit-commit).
	local rendered = render_thread(thread)
	local hint_ns = vim.api.nvim_create_namespace("PRThreadHints")

	local function write_buf()
		vim.bo[comments_popup.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(comments_popup.bufnr, 0, -1, false, rendered.lines)
		vim.bo[comments_popup.bufnr].modifiable = false
	end
	write_buf()

	---@return CommentInfo?, integer?
	local function under_cursor()
		if not comments_popup.winid or not vim.api.nvim_win_is_valid(comments_popup.winid) then
			return nil, nil
		end
		local row = vim.api.nvim_win_get_cursor(comments_popup.winid)[1]
		local idx = rendered.line_to_comment[row]
		if not idx then
			return nil, nil
		end
		return thread.comments[idx], idx
	end

	local function refresh_hints()
		vim.api.nvim_buf_clear_namespace(comments_popup.bufnr, hint_ns, 0, -1)
		local comment, idx = under_cursor()
		if not comment or not idx then
			return
		end
		local mode = vim.api.nvim_get_mode().mode
		local text = M._compute_hint_text(thread, comment, mode)
		if text == "" then
			return
		end
		local footer = rendered.comment_meta[idx].footer_line
		-- Footer is 1-indexed; extmark row is 0-indexed.
		vim.api.nvim_buf_set_extmark(comments_popup.bufnr, hint_ns, footer - 1, 0, {
			virt_lines = { { { text, config.opts.highlights.popup_hl } } },
			virt_lines_above = false,
		})
	end

	comments_popup:on({ event.CursorMoved, event.CursorMovedI, event.ModeChanged, event.BufEnter }, refresh_hints)

	--- Is the given 1-indexed buffer line part of any comment's body region?
	--- Header rules, blank/emoji rows, and gap lines all return false — j/k
	--- skip past them so the cursor only lands on actual comment content.
	local function is_body_line(lnum)
		for _, meta in pairs(rendered.comment_meta) do
			if lnum >= meta.body_start and lnum <= meta.body_end then
				return true
			end
		end
		return false
	end

	--- Walk from `from` in `dir` (±1) until we find a body line or fall off the buffer.
	---@return integer? lnum
	local function next_body_line(from, dir)
		local total = vim.api.nvim_buf_line_count(comments_popup.bufnr)
		local l = from + dir
		while l >= 1 and l <= total do
			if is_body_line(l) then
				return l
			end
			l = l + dir
		end
		return nil
	end

	local function re_render()
		rendered = render_thread(thread)
		write_buf()
		refresh_hints()
	end

	-- Position the cursor on the first body line as soon as the popup window
	-- exists (mount() runs after we return). Without this, the popup opens with
	-- the cursor on a header rule.
	vim.schedule(function()
		if comments_popup.winid and vim.api.nvim_win_is_valid(comments_popup.winid) and rendered.comment_meta[1] then
			pcall(vim.api.nvim_win_set_cursor, comments_popup.winid, { rendered.comment_meta[1].body_start, 0 })
		end
	end)

	-- Layout: comments pane on top, reply composer below (always visible).
	local boxes = { Layout.Box(comments_popup, { size = thread.viewer_can_reply and "60%" or "100%" }) }
	if thread.viewer_can_reply then
		table.insert(boxes, Layout.Box(new_reply_popup, { size = "40%" }))
	end

	layout = Layout({
		position = "50%",
		size = { width = BODY_WIDTH + 2, height = "60%" },
	}, Layout.Box(boxes, { dir = "col" }))

	--- Re-fetch the thread from the provider and re-render. Used after any
	--- mutation (reply, react, edit, resolve, delete) so the popup reflects the
	--- server state without forcing the user to close + reopen.
	---
	--- Replaces the captured `thread` upvalue so cursor-dispatched actions and
	--- the navigation keymaps see the fresh data automatically.
	refresh_thread = function()
		if type(git.clear_comments) == "function" then
			git.clear_comments()
		end
		git.get_comments(vim.schedule_wrap(function(new_comments_by_file)
			for _, file_threads in pairs(new_comments_by_file or {}) do
				for _, t in ipairs(file_threads) do
					if t.id == thread.id then
						thread = t
						-- nui's unmount() sets comments_popup.bufnr = nil, and
						-- nvim_buf_is_valid(nil) is a type error — bail if the popup is
						-- gone (the user closed it before this re-fetch landed).
						if not comments_popup.bufnr or not vim.api.nvim_buf_is_valid(comments_popup.bufnr) then
							return
						end
						re_render()
						return
					end
				end
			end
			-- Thread is gone (e.g. last comment deleted, which removes the thread).
			vim.notify("Thread no longer exists; closing.")
			pcall(function()
				layout:unmount()
			end)
		end))
	end

	-- Cross-popup focus toggling.
	local function focus_comments()
		if comments_popup.winid and vim.api.nvim_win_is_valid(comments_popup.winid) then
			vim.api.nvim_set_current_win(comments_popup.winid)
		end
	end
	local function focus_reply()
		if new_reply_popup.winid and vim.api.nvim_win_is_valid(new_reply_popup.winid) then
			vim.api.nvim_set_current_win(new_reply_popup.winid)
		end
	end

	-- `q` on the comments popup is handled by the M.actions.quit entry below
	-- (via the per-action keymap loop), which calls `ctx.unmount()`.
	if thread.viewer_can_reply then
		comments_popup:map("n", "<Tab>", focus_reply)
		comments_popup:map("n", "<S-Tab>", focus_reply)
		new_reply_popup:map("n", "<S-Tab>", focus_comments)
		new_reply_popup:map("n", "<Tab>", focus_comments)
		new_reply_popup:map("n", "q", function()
			layout:unmount()
		end)
	end

	-- Motion-key handling: after any motion (j/k/gj/gk/<C-d>/<C-u>/<C-f>/<C-b>/etc.)
	-- runs natively, snap the cursor to the nearest body line in the direction the
	-- user was moving — so the header rule / emoji row / gap line are never focus
	-- targets, no matter how the cursor got there.
	local function snap_to_body(prefer_dir)
		if not comments_popup.winid or not vim.api.nvim_win_is_valid(comments_popup.winid) then
			return
		end
		local cur = vim.api.nvim_win_get_cursor(comments_popup.winid)[1]
		if is_body_line(cur) then
			return
		end
		local target = next_body_line(cur - prefer_dir, prefer_dir) or next_body_line(cur - prefer_dir, -prefer_dir)
		if target then
			vim.api.nvim_win_set_cursor(comments_popup.winid, { target, 0 })
		end
	end

	---@param lhs string Map LHS as a keymap string (e.g. "j", "<C-d>", "<Down>").
	---@param dir 1|-1 Direction the motion moves (used to bias the snap fallback).
	local function map_motion(lhs, dir)
		comments_popup:map("n", lhs, function()
			local count = vim.v.count1
			local prefix = count > 1 and tostring(count) or ""
			local keys = vim.api.nvim_replace_termcodes(prefix .. lhs, true, false, true)
			vim.cmd("normal! " .. keys)
			snap_to_body(dir)
		end)
	end

	map_motion("j", 1)
	map_motion("<Down>", 1)
	map_motion("k", -1)
	map_motion("<Up>", -1)
	map_motion("gj", 1)
	map_motion("gk", -1)
	map_motion("<C-d>", 1)
	map_motion("<C-u>", -1)
	map_motion("<C-f>", 1)
	map_motion("<C-b>", -1)

	-- Insert-mode entry on a comment body: auto-trigger the edit flow.
	-- Pressing `i` / `a` / `o` etc. on a body line whose comment is editable
	-- behaves exactly like selecting Edit from the `?` menu — except the
	-- original key still does its native action (insert before, append after,
	-- new line, ...) once edit mode is set up.
	local function try_start_inline_edit(orig_key)
		return function()
			local comment, idx = under_cursor()
			if not comment or not idx or not comment.viewer_can_update then
				return
			end
			if vim.b[comments_popup.bufnr].pr_edit_comment_id ~= comment.database_id then
				M._start_inline_edit(thread, comment, {
					bufnr = comments_popup.bufnr,
					winid = comments_popup.winid,
					body_range = rendered.comment_meta[idx],
					re_render = re_render,
				})
			end
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(orig_key, true, false, true), "n", false)
		end
	end
	for _, k in ipairs({ "i", "I", "a", "A", "o", "O" }) do
		comments_popup:map("n", k, try_start_inline_edit(k))
	end

	-- gg / G: explicit top / bottom — jump straight to the first / last body line.
	comments_popup:map("n", "gg", function()
		if rendered.comment_meta[1] then
			vim.api.nvim_win_set_cursor(comments_popup.winid, { rendered.comment_meta[1].body_start, 0 })
		end
	end)
	comments_popup:map("n", "G", function()
		local last = rendered.comment_meta[#thread.comments]
		if last then
			vim.api.nvim_win_set_cursor(comments_popup.winid, { last.body_end, 0 })
		end
	end)

	-- J / K: jump between comments. J on the last comment crosses into the reply.
	comments_popup:map("n", "J", function()
		local _, idx = under_cursor()
		if not idx then
			return
		end
		if idx >= #thread.comments then
			if thread.viewer_can_reply then
				focus_reply()
			end
			return
		end
		local next_start = rendered.comment_meta[idx + 1].body_start
		vim.api.nvim_win_set_cursor(comments_popup.winid, { next_start, 0 })
	end)

	comments_popup:map("n", "K", function()
		local _, idx = under_cursor()
		if not idx or idx <= 1 then
			return
		end
		local prev_start = rendered.comment_meta[idx - 1].body_start
		vim.api.nvim_win_set_cursor(comments_popup.winid, { prev_start, 0 })
	end)

	-- Keys that, when no action can_perform, should fall through to the
	-- inline-edit on-keypress flow (insert/append/open-line). Without this
	-- fallback, defining an action on one of these keys (e.g. `a` for
	-- apply_suggestion) would consume the keypress unconditionally and break
	-- the default editing affordances on comments the user can edit.
	local inline_edit_fallback_keys = { a = true, A = true, i = true, I = true, o = true, O = true }

	-- Per-action keymaps, dispatching to the comment under cursor.
	for _, action in pairs(M.actions) do
		if action.key then
			comments_popup:map(action.mode, action.key, function()
				local comment, idx = under_cursor()
				if not comment or not idx then
					return
				end
				local ctx = {
					bufnr = comments_popup.bufnr,
					winid = comments_popup.winid,
					body_range = rendered.comment_meta[idx],
					re_render = re_render,
					refresh_thread = refresh_thread,
					source_bufnr = source_bufnr,
					relative_path = relative_path,
					unmount = function()
						layout:unmount()
					end,
				}
				-- Dispatch to whichever action on this key+mode can_perform for the
				-- focused thread/comment. can_perform is still the gate; we just
				-- evaluate it across every action sharing the binding. This is what
				-- makes the resolve/unresolve `r` collision work: both bind `r` and
				-- only one is applicable per thread, but nui's :map is last-write-
				-- wins, so the surviving closure isn't necessarily the applicable
				-- action — resolve it here rather than trusting binding order.
				if action.can_perform(thread, comment) then
					action.perform(thread, comment, new_reply_popup, comments_popup.winid, ctx)
					return
				end
				for _, sibling in pairs(M.actions) do
					if sibling ~= action and sibling.key == action.key and sibling.mode == action.mode and sibling.can_perform(thread, comment) then
						sibling.perform(thread, comment, new_reply_popup, comments_popup.winid, ctx)
						return
					end
				end
				-- No applicable action — for the editing keys, fall back to the
				-- inline-edit-on-keypress behavior so users can still edit their own
				-- comments with `a`/`i`/`o` etc.
				if inline_edit_fallback_keys[action.key] then
					try_start_inline_edit(action.key)()
				end
			end)
		end
	end

	return layout, comments_popup, new_reply_popup
end

---
---@param lines string[]
---@param ft string
---@param relative_path string
---@param start_line integer
---@param end_line integer
---@return NuiLayout
function M.make_new_comment_layout(lines, ft, relative_path, start_line, end_line)
	-- Capture the source buffer BEFORE any popup mounts steal focus. The drift
	-- preflight (see the <CR> handler below) needs the buffer the user actually
	-- selected lines in, not the popup that's about to take focus.
	local source_bufnr = vim.api.nvim_get_current_buf()
	local comment_reference_popup = make_code_reference_popup(lines, ft)
	local comment_boxes = {}

	local popups = {}
	local l = vim.api.nvim_buf_get_lines(comment_reference_popup.bufnr, 0, -1, true)
	table.insert(comment_boxes, Layout.Box(comment_reference_popup, { size = #l }))
	table.insert(popups, comment_reference_popup)

	git.get_git_user()
	local new_comment_popup = make_new_reply_popup(true, "[<M-s> Toggle suggestion ] | [ <C-r> Queue review ] | [ 󰌑 Submit ]")

	-- New-comment drafts: keyed by the path + anchor range, persisted on every
	-- buffer change, deleted on successful submit (<CR> or <C-r> queue path).
	local drafts = require("pr.drafts")
	local new_draft_key = string.format("%s:%d:%d", relative_path or "", start_line, end_line)

	-- Pre-fill from a persisted draft if it exists. Only overwrite if the popup
	-- doesn't already have content the caller wants to preserve.
	local existing_new = drafts.get_new(new_draft_key)
	if existing_new and existing_new.body and existing_new.body ~= "" then
		local cur = vim.api.nvim_buf_get_lines(new_comment_popup.bufnr, 0, -1, false)
		local cur_text = table.concat(cur, "\n")
		if cur_text == "" then
			vim.api.nvim_buf_set_lines(new_comment_popup.bufnr, 0, -1, false, vim.split(existing_new.body, "\n", { plain = true }))
		end
	end

	-- Persist on every buffer change. Detach when the buffer becomes invalid.
	vim.api.nvim_buf_attach(new_comment_popup.bufnr, false, {
		on_lines = function()
			if not vim.api.nvim_buf_is_valid(new_comment_popup.bufnr) then
				return true
			end
			local body = table.concat(vim.api.nvim_buf_get_lines(new_comment_popup.bufnr, 0, -1, false), "\n")
			drafts.save_new(new_draft_key, { body = body, updated_at = tostring(os.time()) })
		end,
	})

	-- nui's Popup:map forwards `mode` straight to nvim_buf_set_keymap, which
	-- requires a string; a table like { "n", "i" } raises "Invalid 'mode'" and
	-- crashes the whole layout on mount. Bind each mode separately (mirrors the
	-- <C-r> queue map below).
	local function toggle_suggestion()
		local current_lines = vim.api.nvim_buf_get_lines(new_comment_popup.bufnr, 0, -1, false)
		local current_text = table.concat(current_lines, "\n")
		local unwrapped = require("pr.suggestion").unwrap_suggestion(current_text)
		if unwrapped then
			-- Currently wrapped — unwrap.
			vim.api.nvim_buf_set_lines(new_comment_popup.bufnr, 0, -1, false, unwrapped)
		else
			-- Not wrapped — wrap.
			local wrapped = require("pr.suggestion").wrap_as_suggestion(current_lines)
			vim.api.nvim_buf_set_lines(new_comment_popup.bufnr, 0, -1, false, vim.split(wrapped, "\n", { plain = true }))
		end
	end
	for _, mode in ipairs({ "n", "i" }) do
		new_comment_popup:map(mode, "<M-s>", toggle_suggestion, { noremap = true })
	end

	local new_comment_box = Layout.Box(new_comment_popup, { size = "40%" })

	table.insert(popups, new_comment_popup)
	table.insert(comment_boxes, new_comment_box)

	local layout = Layout({
		position = "50%",
		size = {
			width = 80,
			height = "60%",
		},
	}, Layout.Box(comment_boxes, { dir = "col" }))

	-- set keymaps for comment popups
	for i, popup in ipairs(popups) do
		popup:map("n", "q", function()
			layout:unmount()
		end)

		popup:map("n", { "j", "<Down>", "<C-n>" }, function()
			if i == #popups then
				return
			end
			vim.api.nvim_set_current_win(popups[i + 1].winid)
		end)

		popup:map("n", { "k", "<Up>", "<C-p>" }, function()
			if i == 1 then
				return
			end
			vim.api.nvim_set_current_win(popups[i - 1].winid)
		end)
	end

	new_comment_popup:map("n", "<CR>", function()
		local body = vim.api.nvim_buf_get_lines(new_comment_popup.bufnr, 0, -1, true)
		local drift = require("pr.drift")
		local git_root = git.git_root

		drift.get_for_buffer(source_bufnr, git_root, relative_path, function(drift_map)
			local commit_start = start_line
			local commit_end = end_line
			if drift_map then
				commit_start = drift.buffer_to_commit(drift_map, start_line)
				commit_end = drift.buffer_to_commit(drift_map, end_line)
			end
			if commit_start == nil or commit_end == nil then
				vim.notify(
					"Cannot post: selected lines are not in the PR's committed diff (uncommitted local changes). Commit your changes or select a line that exists in the PR.",
					vim.log.levels.WARN
				)
				return
			end
			git.comment(
				relative_path,
				commit_start,
				commit_end,
				table.concat(body, "\n"),
				vim.schedule_wrap(function(success)
					if success then
						vim.notify("Comment submitted")
						drafts.delete_new(new_draft_key)
						layout:unmount()
					end
				end)
			)
		end)
	end)

	local function queue_review()
		if type(git.start_pending_review) ~= "function" then
			vim.notify("submit-review not available for this provider")
			return
		end
		local body_lines = vim.api.nvim_buf_get_lines(new_comment_popup.bufnr, 0, -1, false)
		local body = table.concat(body_lines, "\n")
		if body == "" then
			vim.notify("Empty body; nothing to queue", vim.log.levels.WARN)
			return
		end
		local drift = require("pr.drift")
		local git_root = git.git_root
		drift.get_for_buffer(source_bufnr, git_root, relative_path, function(drift_map)
			local commit_start = start_line
			local commit_end = end_line
			if drift_map then
				commit_start = drift.buffer_to_commit(drift_map, start_line)
				commit_end = drift.buffer_to_commit(drift_map, end_line)
			end
			if commit_start == nil or commit_end == nil then
				vim.notify(
					"Cannot queue: selected lines are not in the PR's committed diff (uncommitted local changes). Commit your changes or select a line that exists in the PR.",
					vim.log.levels.WARN
				)
				return
			end
			git.start_pending_review(vim.schedule_wrap(function(review_id, err)
				if not review_id then
					vim.notify(err or "Could not start review", vim.log.levels.ERROR)
					return
				end
				if type(git.add_review_comment) ~= "function" then
					vim.notify("submit-review not available for this provider")
					return
				end
				git.add_review_comment(
					review_id,
					relative_path,
					commit_start,
					commit_end,
					body,
					vim.schedule_wrap(function(ok)
						if ok then
							vim.notify("Queued as review comment")
							drafts.delete_new(new_draft_key)
							layout:unmount()
						else
							vim.notify("Failed to queue review comment", vim.log.levels.ERROR)
						end
					end)
				)
			end))
		end)
	end

	for _, mode in ipairs({ "n", "i" }) do
		new_comment_popup:map(mode, "<C-r>", queue_review, { noremap = true })
	end

	return layout
end

---Build a read-mode PR info popup layout.
---Single read-only popup whose body is rendered by `M._render_pr_info`. Action
---keymaps (`e`, `c`, `u`, `q`) dispatch through `callbacks`; the orchestration
---module (Task 7) supplies their concrete implementations.
---@param metadata PRMetadata
---@param checks CheckRun[]|nil
---@param callbacks { on_edit: fun(), on_refresh: fun(), on_check_menu: fun() }
---@return NuiLayout
function M.make_pr_info_layout(metadata, checks, callbacks)
	local popup = Popup({
		border = {
			style = "rounded",
			text = { top = string.format(" PR #%d ", metadata.number) },
		},
		buf_options = {
			-- readonly omitted on purpose: the BufWinEnter writer toggles modifiable
			-- to repaint, and readonly=true would make that log a spurious W10.
			modifiable = false,
			filetype = "markdown",
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
			wrap = true,
			spell = false,
			foldenable = false,
		},
		enter = true,
	})

	local layout =
		Layout({ position = "50%", size = { width = 90, height = 30 }, relative = "editor" }, Layout.Box({ Layout.Box(popup, { size = "100%" }) }, { dir = "col" }))

	popup:on(event.BufWinEnter, function()
		vim.bo[popup.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, M._render_pr_info(metadata, checks))
		vim.bo[popup.bufnr].modifiable = false
	end)

	popup:map("n", "q", function()
		layout:unmount()
	end, { noremap = true })
	popup:map("n", "e", function()
		callbacks.on_edit()
	end, { noremap = true })
	popup:map("n", "u", function()
		callbacks.on_refresh()
	end, { noremap = true })
	popup:map("n", "c", function()
		callbacks.on_check_menu()
	end, { noremap = true })

	return layout
end

---Build the title+body edit popups for a PR.
---@param metadata PRMetadata
---@param callbacks { on_submit: fun(fields: { title: string, body: string }) }
---@return NuiLayout
function M.make_pr_edit_layout(metadata, callbacks)
	local title_popup = Popup({
		border = { style = "rounded", text = { top = " Title " } },
		buf_options = { modifiable = true },
		enter = true,
	})
	local body_popup = Popup({
		border = { style = "rounded", text = { top = " Body " } },
		buf_options = { modifiable = true, filetype = "markdown" },
		win_options = { wrap = true, spell = false, foldenable = false },
	})

	local layout = Layout(
		{ position = "50%", size = { width = 90, height = 30 }, relative = "editor" },
		Layout.Box({
			Layout.Box(title_popup, { size = 3 }),
			Layout.Box(body_popup, { grow = 1 }),
		}, { dir = "col" })
	)

	-- Seed initial content before mount so the buffers carry the existing
	-- title/body when the user enters edit mode.
	vim.api.nvim_buf_set_lines(title_popup.bufnr, 0, -1, false, { metadata.title or "" })
	vim.api.nvim_buf_set_lines(body_popup.bufnr, 0, -1, false, vim.split(metadata.body or "", "\n", { plain = true }))

	local function submit()
		local title = vim.trim(table.concat(vim.api.nvim_buf_get_lines(title_popup.bufnr, 0, -1, false), " "))
		if title == "" then
			vim.notify("Title is empty; submit aborted. Use [Esc][Esc] or q to cancel.", vim.log.levels.ERROR)
			return
		end
		local body = table.concat(vim.api.nvim_buf_get_lines(body_popup.bufnr, 0, -1, false), "\n")
		if vim.trim(body) == "" then
			vim.notify("Body is empty; submit aborted. Use [Esc][Esc] or q to cancel.", vim.log.levels.ERROR)
			return
		end
		callbacks.on_submit({ title = title, body = body })
		layout:unmount()
	end

	local function cancel()
		layout:unmount()
	end

	-- Prevent newlines in the title popup; `gh pr edit --title` expects a single
	-- line, and silently flattening multi-line input is a footgun.
	title_popup:map("i", "<CR>", "<Nop>", { noremap = true })

	for _, p in ipairs({ title_popup, body_popup }) do
		-- nui's Popup:map forwards `mode` straight to nvim_buf_set_keymap, which
		-- requires a string; a table like { "n", "i" } raises "Invalid 'mode'" and
		-- crashes the layout on mount. Bind each mode separately (mirrors the
		-- new-comment composer's <M-s> fix).
		for _, mode in ipairs({ "n", "i" }) do
			p:map(mode, "<C-s>", submit, { noremap = true })
		end
		p:map("n", "<Esc><Esc>", cancel, { noremap = true })
		p:map("n", "q", cancel, { noremap = true })
	end

	return layout
end

---Build the review submission layout (pending list above, body editor below).
---@param pending PendingComment[]
---@param callbacks { on_submit: fun(event: string, body: string, unmount: fun()), on_discard: fun() }
---@return NuiLayout
function M.make_review_layout(pending, callbacks)
	local list_lines = M._render_pending_list(pending)
	local list_height = math.max(#list_lines + 2, 6)

	local list_popup = Popup({
		border = { style = "rounded", text = { top = " Pending review (" .. tostring(pending and #pending or 0) .. ") " } },
		-- readonly omitted: the post-mount writer toggles modifiable to fill the
		-- list, and readonly=true would make that log a spurious W10.
		buf_options = { modifiable = false },
		win_options = { wrap = false, foldenable = false },
	})
	local body_popup = Popup({
		border = { style = "rounded", text = { top = " Review body " } },
		buf_options = { modifiable = true, filetype = "markdown" },
		win_options = { wrap = true, spell = false, foldenable = false },
		enter = true,
	})

	local layout = Layout(
		{ position = "50%", size = { width = 90, height = 30 }, relative = "editor" },
		Layout.Box({
			Layout.Box(list_popup, { size = list_height }),
			Layout.Box(body_popup, { grow = 1 }),
		}, { dir = "col" })
	)

	local function submit(ev)
		local body = table.concat(vim.api.nvim_buf_get_lines(body_popup.bufnr, 0, -1, false), "\n")
		callbacks.on_submit(ev, body, function()
			layout:unmount()
		end)
	end

	local function close()
		layout:unmount()
	end

	local function discard()
		local choice = vim.fn.confirm("Discard pending review?", "&Discard\n&Cancel", 2)
		if choice == 1 then
			callbacks.on_discard()
			layout:unmount()
		end
	end

	layout:mount()

	-- Populate the list popup after mount so the buffer is associated with a window.
	vim.bo[list_popup.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(list_popup.bufnr, 0, -1, false, list_lines)
	vim.bo[list_popup.bufnr].modifiable = false

	for _, p in ipairs({ list_popup, body_popup }) do
		p:map("n", "a", function()
			submit("APPROVE")
		end, { noremap = true })
		p:map("n", "r", function()
			submit("REQUEST_CHANGES")
		end, { noremap = true })
		p:map("n", "c", function()
			submit("COMMENT")
		end, { noremap = true })
		p:map("n", "d", discard, { noremap = true })
		p:map("n", "q", close, { noremap = true })
		p:map("n", "<Esc><Esc>", close, { noremap = true })
	end

	return layout
end

---Build a menu listing CI checks. `on_select` receives the URL of the chosen check.
---@param checks CheckRun[]
---@param on_select fun(url: string)
---@return NuiMenu
function M.make_checks_menu(checks, on_select)
	local items = {}
	for _, c in ipairs(checks or {}) do
		table.insert(items, Menu.item(check_glyph(c) .. " " .. (c.name or ""), { url = c.url or "" }))
	end
	if #items == 0 then
		table.insert(items, Menu.item("(no checks)"))
	end

	return Menu({
		position = "50%",
		size = { width = 60, height = math.min(#items + 2, 15) },
		border = { style = "rounded", text = { top = " Checks " } },
	}, {
		lines = items,
		on_submit = function(item)
			if item and item.url and item.url ~= "" then
				on_select(item.url)
			end
		end,
		keymap = {
			close = { "q", "<Esc>" },
			submit = { "<CR>" },
		},
	})
end

--- Build the ordered list of emoji-menu entries for a comment. Pure function
--- exposed for unit testing — does not construct nui Menu objects.
---@param reaction_groups CommentReactionGroup[] reactions already on the comment
---@param palette ReactionPaletteEntry[]|nil active provider's palette (nil/empty palette returns empty list)
---@return table[] items List of `{ content, glyph, count, viewer_has_reacted, reactors }` entries in display order.
function M._build_menu_items(reaction_groups, palette)
	local existing = {}
	for _, rg in pairs(reaction_groups or {}) do
		existing[rg.content] = rg
	end

	local ordered = {}
	local seen = {}
	if palette then
		for _, entry in ipairs(palette) do
			table.insert(ordered, entry.content)
			seen[entry.content] = true
		end
	end
	for _, rg in pairs(reaction_groups or {}) do
		if not seen[rg.content] then
			table.insert(ordered, rg.content)
			seen[rg.content] = true
		end
	end

	local items = {}
	for _, content in ipairs(ordered) do
		local rg = existing[content]
		local count = (rg and rg.reactors and rg.reactors.totalCount) or 0
		local viewer_has_reacted = (rg and rg.viewerHasReacted) or false
		local reactors = (rg and rg.reactors and rg.reactors.nodes) or {}
		table.insert(items, {
			content = content,
			glyph = M._glyph_for(content),
			count = count,
			viewer_has_reacted = viewer_has_reacted,
			reactors = reactors,
		})
	end
	return items
end

---
---@param comment_id integer
---@param reaction_groups CommentReactionGroup[]
---@param winid integer Window the menu is anchored to (its right edge).
---@param row? integer 0-indexed row within `winid` where the menu's NE corner sits. Defaults to 0 (top of the window). The unified comments view passes the cursor's `winline() - 1` so the menu anchors next to the focused comment instead of the top of the conversation.
---@param refresh? fun() Called after a successful add/remove reaction so the popup re-fetches the thread and re-renders updated counts.
---@return NuiMenu
local function make_emoji_menu(comment_id, reaction_groups, winid, row, refresh)
	local entries = M._build_menu_items(reaction_groups, git.reaction_palette)

	local space_count = 6
	for _, e in ipairs(entries) do
		local d = #tostring(e.count)
		if d > space_count then
			space_count = d + 2
		end
	end

	local items = {}
	for _, e in ipairs(entries) do
		local sep = string.rep(" ", space_count - #tostring(e.count))
		local text = NuiText(e.glyph .. sep .. e.count)
		if e.viewer_has_reacted then
			text:set(e.glyph .. sep .. e.count, config.opts.highlights.hl_emoji)
		end
		table.insert(
			items,
			Menu.item(text, {
				id = e.content,
				viewer_has_reacted = e.viewer_has_reacted,
				comment_id = comment_id,
				reactions = e.reactors,
			})
		)
	end

	-- TODO: adjust col based on longest item
	---@type nui_popup_options
	local popup_options = {
		relative = "win",
		anchor = "NE",
		winid = winid,
		position = {
			row = row or 0,
			col = -1,
		},
		border = {
			style = "rounded",
			text = {
				top = "",
				top_align = "center",
			},
		},
		win_options = {
			winhighlight = "Normal:Normal",
		},
	}

	local menu = Menu(popup_options, {
		lines = items,
		max_width = 20,
		keymap = {
			focus_next = { "j", "<Down>", "<Tab>" },
			focus_prev = { "k", "<Up>", "<S-Tab>" },
			close = { "<Esc>", "<C-c>", "q", "e" },
			submit = { "<CR>", "<Space>" },
		},
		on_close = function() end,
		on_submit = function(item)
			local function after(success)
				if not success then
					vim.notify("Reaction failed", vim.log.levels.ERROR)
					return
				end
				if refresh then
					refresh()
				end
			end

			if item.viewer_has_reacted then
				for _, reaction in ipairs(item.reactions) do
					if reaction.user == git.git_user then
						git.remove_reaction(item.comment_id, reaction.database_id, vim.schedule_wrap(after))
						return
					end
				end
				vim.notify("You have not reacted to this comment yet.")
			else
				git.add_reaction(item.comment_id, item.id, vim.schedule_wrap(after))
			end
		end,
	})

	return menu
end

---
---@param reaction_group CommentReactionGroup
---@return string
function M.format_reaction(reaction_group)
	local reactions = {}
	for _, reaction in ipairs(reaction_group) do
		if reaction.reactors.totalCount > 0 then
			table.insert(reactions, "( " .. M._glyph_for(reaction.content) .. " " .. reaction.reactors.totalCount .. " )")
		end
	end
	return "   " .. table.concat(reactions, " | ")
end

---
---@param thread ReviewThread
---@param comment CommentInfo
---@param new_reply_popup NuiPopup
---@param popup_winid number
---@return NuiMenu
function M.make_help_menu(thread, comment, new_reply_popup, popup_winid, ctx)
	---@type nui_popup_options
	local popup_options = {
		position = "50%",
		border = {
			style = "rounded",
			text = {
				top = "Help",
				top_align = "center",
			},
		},
		win_options = {
			winhighlight = "Normal:Normal",
		},
	}

	-- Compute the width needed so menu_text (left) and menu_desc (right, drawn
	-- as a right_align virt_text in the perform handler) don't overlap. We use
	-- strdisplaywidth so multibyte glyphs are sized correctly.
	local MIN_GAP = 2
	local TITLE = "Help"
	local content_width = vim.fn.strdisplaywidth(TITLE) + 2 -- title + breathing room
	local lines = {}
	for k, action in pairs(M.actions) do
		local t = Text(action.menu_text, "NonText")
		local can_perform_bool = action.can_perform(thread, comment)
		if can_perform_bool then
			t = Text(action.menu_text)
		end

		local row_width = vim.fn.strdisplaywidth(action.menu_text or "") + MIN_GAP + vim.fn.strdisplaywidth(action.menu_desc or "")
		if row_width > content_width then
			content_width = row_width
		end

		local menu = Menu.item(Line({ t }), {
			action = k,
			can_perform_bool = can_perform_bool,
		})
		table.insert(lines, menu)
	end
	-- Cap to a sensible maximum so a future pathologically-long description
	-- can't make the menu take over the screen.
	if content_width > 120 then
		content_width = 120
	end

	local menu = Menu(popup_options, {
		lines = lines,
		max_width = content_width,
		min_width = content_width,
		keymap = {
			focus_next = { "j", "<Down>", "<Tab>" },
			focus_prev = { "k", "<Up>", "<S-Tab>" },
			close = { "<Esc>", "<C-c>", "?", "q" },
			submit = { "<CR>", "<Space>" },
		},
		should_skip_item = function(item)
			return not M.actions[item.action].can_perform(thread, comment)
		end,
		on_close = function() end,
		on_submit = function(item)
			if item.action == "help" then
				vim.notify("You are already here!")
				return
			end

			M.actions[item.action].perform(thread, comment, new_reply_popup, popup_winid, ctx)
		end,
	})

	return menu
end

function M.setup()
	-- Drafts are now persisted lazily by the `pr.drafts` module; no upfront load needed.
end

---@class Action
---@field mode? string
---@field key? string
---@field menu_text string
---@field menu_desc string
---@field popup_hint string
---@field show_hint boolean
---@field can_perform? fun(thread: ReviewThread, comment: CommentInfo): boolean
---@field perform? fun(thread: ReviewThread, comment: CommentInfo, new_reply_popup: NuiPopup, popup_winid: number)

---Pure: decide what to do when a pre-commit refetch returns `fresh`.
---Returns one of "proceed" | "overwrite" | "refresh" | "abort".
---
---- `proceed` — no refetch data, or no remote drift; send the user's body as-is.
---- `overwrite` — remote changed, but the user picked Overwrite at the prompt.
---- `refresh`  — remote changed and the user picked Refresh; caller should
---  rewrite the edit buffer with the fresh body and keep the user in edit mode.
---- `abort`    — remote changed and the user picked Abort (or no choice); no-op.
---@param fresh { updated_at: string }?
---@param snapshot_updated_at string?
---@param confirm_choice integer  -- as returned by vim.fn.confirm
---@return "proceed"|"overwrite"|"refresh"|"abort"
function M._conflict_decision(fresh, snapshot_updated_at, confirm_choice)
	if not fresh then
		return "proceed"
	end
	if fresh.updated_at == snapshot_updated_at then
		return "proceed"
	end
	if confirm_choice == 1 then
		return "overwrite"
	end
	if confirm_choice == 2 then
		return "refresh"
	end
	return "abort"
end

--- Set up inline-edit mode on the comments buffer for the given comment, WITHOUT
--- moving the cursor or entering insert mode. The caller is responsible for
--- whatever brings the user into insert mode (`startinsert` from the menu path,
--- or letting the original `i`/`a`/`o`-style keystroke through via `feedkeys`).
---
--- Exit happens automatically on `InsertLeave`:
---   - if the body changed, the new text is sent to `git.edit_comment` (commit);
---   - otherwise the edit is just torn down with no API call.
---
--- `<C-c>` in insert mode is bound as an explicit cancel — it exits insert mode
--- with a `skip_commit_on_leave` flag set so the InsertLeave handler tears down
--- without committing.
---@param thread ReviewThread
---@param comment CommentInfo
---@param ctx { bufnr: integer, winid: integer?, body_range: { body_start: integer, body_end: integer }, re_render: function? }
function M._start_inline_edit(thread, comment, ctx)
	local bufnr = ctx.bufnr
	local body_start = ctx.body_range.body_start
	local body_end = ctx.body_range.body_end

	-- Mutable mirrors of body_start / body_end that track shifts caused by ANY
	-- buffer edit (in-range or out-of-range). Without this, an out-of-range
	-- edit that changes line count (e.g. pressing <CR> on a header line)
	-- would leave us reading body from the wrong rows on restore — and the
	-- user would lose their in-flight body edits.
	local current_body_start = body_start
	local current_body_end = body_end

	local dim_ns = vim.api.nvim_create_namespace("PRCommentEditDim")
	local function place_dim()
		vim.api.nvim_buf_clear_namespace(bufnr, dim_ns, 0, -1)
		local total = vim.api.nvim_buf_line_count(bufnr)
		for i = 0, current_body_start - 2 do
			vim.api.nvim_buf_set_extmark(bufnr, dim_ns, i, 0, { line_hl_group = "PRCommentEditDim" })
		end
		for i = current_body_end, total - 1 do
			vim.api.nvim_buf_set_extmark(bufnr, dim_ns, i, 0, { line_hl_group = "PRCommentEditDim" })
		end
	end

	local detached = false
	local skip_commit_on_leave = false
	local autocmd_id
	local cursor_clamp_id

	-- Snapshot the body to compare against on InsertLeave.
	local original_body = vim.api.nvim_buf_get_lines(bufnr, body_start - 1, body_end, false)

	-- Snapshot the comment's updated_at so we can detect remote edits between
	-- the moment the user entered edit mode and the moment they commit.
	local snapshot_updated_at = comment.updated_at

	-- Snapshot the lines outside the editable body so we can splice them back
	-- on an out-of-range edit. Using `:undo` was unsafe here — in insert mode
	-- vim batches keystrokes into one undo block, and `nvim_buf_set_lines`
	-- from the popup's initial render is its own undo step, so a single
	-- mid-insert `:undo` could step all the way back to an empty buffer.
	-- Declared up-front so the closures below (commit/do_edit) can refresh
	-- `after_snapshot` after a conflict-driven "Refresh" rewrite.
	local before_snapshot = vim.api.nvim_buf_get_lines(bufnr, 0, body_start - 1, false)
	local after_snapshot = vim.api.nvim_buf_get_lines(bufnr, body_end, -1, false)
	local restoring = false

	local function teardown()
		detached = true
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, dim_ns, 0, -1)
			pcall(vim.keymap.del, "i", "<C-c>", { buffer = bufnr })
			vim.b[bufnr].pr_edit_comment_id = nil
			vim.bo[bufnr].modifiable = false
		end
		if autocmd_id then
			pcall(vim.api.nvim_del_autocmd, autocmd_id)
			autocmd_id = nil
		end
		if cursor_clamp_id then
			pcall(vim.api.nvim_del_autocmd, cursor_clamp_id)
			cursor_clamp_id = nil
		end
	end

	local function do_edit(body_text)
		git.edit_comment(
			comment.database_id,
			body_text,
			vim.schedule_wrap(function(success)
				if success then
					vim.notify("Comment saved")
					require("pr.drafts").delete_edit(comment.database_id)
				end
				teardown()
				if ctx.re_render then
					ctx.re_render()
				end
			end)
		)
	end

	local function commit()
		local body_lines = vim.api.nvim_buf_get_lines(bufnr, current_body_start - 1, current_body_end, false)
		local body_text = table.concat(body_lines, "\n")

		local conflict_check_enabled = config.opts.conflict_detection and config.opts.conflict_detection.enabled
		if not conflict_check_enabled or type(git.refetch_comment) ~= "function" then
			do_edit(body_text)
			return
		end

		git.refetch_comment(
			comment.database_id,
			vim.schedule_wrap(function(fresh)
				-- Prompt the user only when there's an actual mismatch — otherwise
				-- the choice is unused. We still call `_conflict_decision` after
				-- the prompt so the pure helper remains the single source of truth.
				local choice = 0
				if fresh and fresh.updated_at ~= snapshot_updated_at then
					choice = vim.fn.confirm(
						"Comment changed remotely since edit started.",
						"&Overwrite\n&Refresh and re-edit\n&Abort",
						3 -- default to Abort
					)
				end
				local decision = M._conflict_decision(fresh, snapshot_updated_at, choice)
				if decision == "proceed" or decision == "overwrite" then
					do_edit(body_text)
				elseif decision == "refresh" then
					-- Replace the buffer's edit range with the fresh body, update
					-- the snapshots, and keep the user in edit mode. Re-entering
					-- insert mode is the caller's job; we don't yank focus around.
					if not vim.api.nvim_buf_is_valid(bufnr) then
						return
					end
					local fresh_lines = vim.split(fresh.body or "", "\n", { plain = true })
					vim.bo[bufnr].modifiable = true
					vim.api.nvim_buf_set_lines(bufnr, current_body_start - 1, current_body_end, false, fresh_lines)
					current_body_end = current_body_start + #fresh_lines - 1
					-- Refresh `after_snapshot` so future out-of-range splices use the
					-- new body's length. `before_snapshot` is unchanged because the
					-- splice happens strictly inside the body range.
					after_snapshot = vim.api.nvim_buf_get_lines(bufnr, current_body_end, -1, false)
					-- Update both the on-disk comment mirror and the snapshot so a
					-- subsequent commit attempt compares against the fresh state.
					comment.body = fresh.body or ""
					comment.updated_at = fresh.updated_at
					snapshot_updated_at = fresh.updated_at
					original_body = fresh_lines
					place_dim()
					vim.notify("Comment refreshed from remote. Continue editing, then leave insert mode to save.")
				end
				-- "abort": no-op. User stays in normal mode with the editable body
				-- still in place; pressing `i` re-enters their changes.
			end)
		)
	end

	local function exit_no_commit()
		teardown()
		if ctx.re_render then
			ctx.re_render()
		end
	end

	vim.bo[bufnr].modifiable = true
	vim.b[bufnr].pr_edit_comment_id = comment.database_id
	place_dim()

	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function(_, _, _, firstline, lastline, new_lastline)
			if detached then
				return true
			end
			if restoring then
				return
			end

			local delta = new_lastline - lastline
			-- Body range in 0-indexed exclusive form: [current_body_start - 1, current_body_end).
			local body_first = current_body_start - 1
			local body_last_excl = current_body_end

			-- In-range: change is fully inside body. Just track the size delta.
			if firstline >= body_first and lastline <= body_last_excl then
				current_body_end = current_body_end + delta
				return
			end

			-- Out-of-range: account for any line-count shift caused by the bad change
			-- BEFORE we read body — otherwise we'd read the wrong rows and corrupt
			-- the user's in-flight body edits on restore.
			if lastline <= body_first then
				-- Bad change happened entirely BEFORE body. Body shifts by delta.
				current_body_start = current_body_start + delta
				current_body_end = current_body_end + delta
			end
			-- If the bad change happens entirely AFTER body, body's position is unchanged.
			-- If it overlaps body, we can't cleanly separate the user's body edits from
			-- the corruption — the splice will use whatever's at the (now-ambiguous) body
			-- rows. Documented v1 trade-off.

			vim.schedule(function()
				if detached then
					return
				end
				restoring = true
				-- Read body from its CURRENT (post-shift) position so legitimate body
				-- edits are preserved across the restore.
				local body_lines = vim.api.nvim_buf_get_lines(bufnr, current_body_start - 1, current_body_end, false)
				vim.bo[bufnr].modifiable = true
				local restored = {}
				for _, l in ipairs(before_snapshot) do
					table.insert(restored, l)
				end
				for _, l in ipairs(body_lines) do
					table.insert(restored, l)
				end
				for _, l in ipairs(after_snapshot) do
					table.insert(restored, l)
				end
				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, restored)
				-- After the splice, body sits back at its original absolute position
				-- (defined by before_snapshot's length). Reset the trackers.
				current_body_start = #before_snapshot + 1
				current_body_end = current_body_start + #body_lines - 1
				place_dim()
				if ctx.winid and vim.api.nvim_win_is_valid(ctx.winid) then
					pcall(vim.api.nvim_win_set_cursor, ctx.winid, { current_body_start, 0 })
				end
				vim.notify("Edit reverted: changes must be inside the focused comment.")
				-- Clear the flag AFTER the on_lines for our restore has fired.
				vim.schedule(function()
					restoring = false
				end)
			end)
		end,
	})

	-- Cancel: <C-c> in insert mode flags skip-commit, then drops to normal mode.
	vim.keymap.set("i", "<C-c>", function()
		skip_commit_on_leave = true
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
	end, { buffer = bufnr, nowait = true, desc = "PR: cancel comment edit" })

	-- Auto-commit when returning to normal mode (or silent exit if nothing changed).
	autocmd_id = vim.api.nvim_create_autocmd("InsertLeave", {
		buffer = bufnr,
		callback = function()
			if detached then
				return
			end
			if skip_commit_on_leave then
				exit_no_commit()
				return
			end
			local current_body = vim.api.nvim_buf_get_lines(bufnr, current_body_start - 1, current_body_end, false)
			if vim.deep_equal(current_body, original_body) then
				exit_no_commit()
			else
				commit()
			end
		end,
	})

	-- Clamp the cursor to the body range while edit mode is active. Fires on
	-- every cursor move in both normal and insert mode; if the cursor strays
	-- above current_body_start or below current_body_end (e.g. user arrow-keyed
	-- onto a header), it gets snapped back. This is the primary mechanism
	-- preventing out-of-range edits; the on_lines snapshot-restore is now a
	-- defensive backstop for rare paths the autocmd can't intercept.
	cursor_clamp_id = vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		buffer = bufnr,
		callback = function()
			if detached or not ctx.winid or not vim.api.nvim_win_is_valid(ctx.winid) then
				return
			end
			local pos = vim.api.nvim_win_get_cursor(ctx.winid)
			local row, col = pos[1], pos[2]
			local target = row
			if row < current_body_start then
				target = current_body_start
			elseif row > current_body_end then
				target = current_body_end
			end
			if target ~= row then
				-- Clamp column to the target line's length (set_cursor errors otherwise).
				local line_len = #(vim.api.nvim_buf_get_lines(bufnr, target - 1, target, false)[1] or "")
				pcall(vim.api.nvim_win_set_cursor, ctx.winid, { target, math.min(col, line_len) })
			end
		end,
	})
end

---@type table<string, Action>
M.actions = {
	emoji = {
		mode = "n",
		key = "e",
		menu_text = "Emoji",
		menu_desc = "Reactions for this comment",
		popup_hint = "[E]moji",
		show_hint = true,
		can_perform = function(_, comment)
			if not comment.viewer_can_react then
				return false
			end
			-- Hide the emoji action when the active provider has no palette
			-- (e.g. bitbucket — no reaction support on PR comments).
			local palette = git.reaction_palette
			return palette ~= nil and #palette > 0
		end,
		perform = function(_, comment, _, popup_winid, ctx)
			-- In the unified comments view, anchor the menu to the row of the
			-- focused comment (otherwise it would always open at the top of the
			-- conversation popup, regardless of scroll position).
			local row = 0
			if popup_winid and vim.api.nvim_win_is_valid(popup_winid) and vim.api.nvim_get_current_win() == popup_winid then
				row = vim.fn.winline() - 1
			end
			local refresh = ctx and ctx.refresh_thread
			local menu = make_emoji_menu(comment.database_id, comment.reaction_groups, popup_winid, row, refresh)
			menu:mount()
		end,
	},
	resolve = {
		mode = "n",
		key = "r",
		menu_text = "Resolve",
		menu_desc = "Resolve this thread",
		popup_hint = "[R]esolve",
		show_hint = true,
		can_perform = function(thread, _)
			return (not thread.is_resolved) and thread.viewer_can_resolve
		end,
		perform = function(thread, _, _, _, ctx)
			git.resolve_thread(
				thread.id,
				vim.schedule_wrap(function(success)
					if not success then
						vim.notify("Resolve failed", vim.log.levels.ERROR)
						return
					end
					vim.notify("Thread resolved")
					if ctx and ctx.refresh_thread then
						ctx.refresh_thread()
					end
				end)
			)
		end,
	},
	unresolve = {
		mode = "n",
		key = "r",
		menu_text = "Unresolve",
		menu_desc = "Unresolve this thread",
		popup_hint = "Un[R]esolve",
		show_hint = true,
		can_perform = function(thread, _)
			return thread.is_resolved and thread.viewer_can_unresolve
		end,
		perform = function(thread, _, _, _, ctx)
			git.unresolve_thread(
				thread.id,
				vim.schedule_wrap(function(success)
					if not success then
						vim.notify("Unresolve failed", vim.log.levels.ERROR)
						return
					end
					vim.notify("Thread unresolved")
					if ctx and ctx.refresh_thread then
						ctx.refresh_thread()
					end
				end)
			)
		end,
	},
	reply = {
		mode = "n",
		key = "c",
		menu_text = "Comment",
		menu_desc = "Reply to this thread",
		popup_hint = "[C]omment",
		show_hint = true,
		can_perform = function(thread, _)
			return thread.viewer_can_reply
		end,
		perform = function(_, _, new_reply_popup, _)
			vim.api.nvim_set_current_buf(new_reply_popup.bufnr)
		end,
	},
	quote_reply = {
		mode = "v",
		key = "c",
		menu_text = "Quote Comment",
		menu_desc = "Quote reply this comment",
		popup_hint = "[C]omment",
		show_hint = false,
		can_perform = function(thread, _)
			return thread.viewer_can_reply
		end,
		perform = function(_, _, new_reply_popup, _)
			local mode = vim.api.nvim_get_mode().mode

			-- for menu
			if mode ~= "v" and mode ~= "V" and mode ~= "\22" then
				vim.notify("Please select a text to quote")
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("v", true, false, true), "x!", true)
				return
			end

			local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
			for i, line in ipairs(lines) do
				lines[i] = "> " .. line
			end

			table.insert(lines, "")

			vim.api.nvim_buf_set_lines(new_reply_popup.bufnr, 0, -1, false, lines)
			-- TODO: clear if already exists
			-- TODO: keep existing comment
			vim.api.nvim_set_current_win(new_reply_popup.winid)
			vim.api.nvim_win_set_cursor(new_reply_popup.winid, { #lines, 0 })
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
		end,
	},
	edit = {
		mode = nil,
		key = nil,
		menu_text = "Edit",
		menu_desc = "Enter insert mode to edit this comment",
		popup_hint = "",
		show_hint = false,
		can_perform = function(_, comment)
			return comment.viewer_can_update
		end,
		perform = function(thread, comment, _, popup_winid, ctx)
			-- Legacy fallback: the caller is the single-comment popup, whose buffer
			-- is already modifiable. Just enter insert mode like before.
			if not ctx or not ctx.bufnr or not ctx.body_range then
				vim.api.nvim_set_current_win(popup_winid)
				vim.cmd("startinsert")
				return
			end

			-- Already in edit mode for the same comment? Just re-enter insert.
			if vim.b[ctx.bufnr].pr_edit_comment_id == comment.database_id then
				if ctx.winid and vim.api.nvim_win_is_valid(ctx.winid) then
					vim.api.nvim_set_current_win(ctx.winid)
					vim.api.nvim_win_set_cursor(ctx.winid, { ctx.body_range.body_start, 0 })
				end
				vim.cmd("startinsert")
				return
			end

			M._start_inline_edit(thread, comment, ctx)

			-- Position cursor at the start of the editable body and enter insert mode.
			if ctx.winid and vim.api.nvim_win_is_valid(ctx.winid) then
				vim.api.nvim_set_current_win(ctx.winid)
				vim.api.nvim_win_set_cursor(ctx.winid, { ctx.body_range.body_start, 0 })
			end
			vim.cmd("startinsert")
		end,
	},
	save = {
		mode = "n",
		key = "s",
		menu_text = "Save",
		menu_desc = "Save edited comment",
		popup_hint = "([S]ave edited)",
		show_hint = false,
		can_perform = function(_, comment)
			local draft = require("pr.drafts").get_edit(comment.database_id) or {}
			return draft.body and draft.updated_at
		end,
		perform = function(_, comment, _, _)
			local drafts = require("pr.drafts")
			local draft = drafts.get_edit(comment.database_id)
			if not draft or not draft.body then
				return
			end
			local body = type(draft.body) == "table" and table.concat(draft.body, "\n") or draft.body
			git.edit_comment(
				comment.database_id,
				body,
				vim.schedule_wrap(function(success)
					if success then
						vim.notify("Comment saved")
						drafts.delete_edit(comment.database_id)
					end
				end)
			)
		end,
	},
	delete = {
		mode = "n",
		key = "<M-d>",
		menu_text = "Delete",
		menu_desc = "Delete this comment",
		popup_hint = "<M-d>elete",
		show_hint = true,
		can_perform = function(_, comment)
			return comment.viewer_can_delete
		end,
		perform = function(_, comment, _, _, ctx)
			vim.ui.select({ "Yes", "No" }, {
				prompt = "Are you sure you want to delete this comment? This action cannot be undone.",
			}, function(choice)
				if choice == "Yes" then
					git.delete_comment(
						comment.database_id,
						vim.schedule_wrap(function(success)
							if not success then
								vim.notify("Delete failed", vim.log.levels.ERROR)
								return
							end
							vim.notify("Comment deleted")
							if ctx and ctx.refresh_thread then
								ctx.refresh_thread()
							end
						end)
					)
				end
			end)
		end,
	},
	yank_url = {
		mode = "n",
		key = "yl",
		menu_text = "Yank thread URL",
		menu_desc = "Copy a permalink to this comment to the clipboard",
		popup_hint = "[yl] yank URL",
		show_hint = false,
		can_perform = function(_, comment)
			return comment ~= nil and type(git.thread_url) == "function"
		end,
		perform = function(thread, comment, _, _)
			local url = git.thread_url(thread, comment)
			if not url or url == "" then
				vim.notify("Permalink unavailable for this thread")
				return
			end
			vim.fn.setreg("+", url)
			vim.fn.setreg('"', url)
			vim.notify("Yanked: " .. url)
		end,
	},
	open_url = {
		mode = "n",
		key = "gx",
		menu_text = "Open thread in browser",
		menu_desc = "Open this comment's permalink in the system browser",
		popup_hint = "[gx] open in browser",
		show_hint = false,
		can_perform = function(_, comment)
			return comment ~= nil and type(git.thread_url) == "function"
		end,
		perform = function(thread, comment, _, _)
			local url = git.thread_url(thread, comment)
			if not url or url == "" then
				vim.notify("Permalink unavailable for this thread")
				return
			end
			-- vim.ui.open exists on Neovim >= 0.10. On older versions the pcall
			-- catches the nil-call and we report a useful error instead of
			-- crashing the popup.
			if type(vim.ui.open) ~= "function" then
				vim.notify("vim.ui.open unavailable (requires Neovim 0.10+)", vim.log.levels.ERROR)
				return
			end
			local ok, err = pcall(vim.ui.open, url)
			if not ok then
				vim.notify("Failed to open: " .. tostring(err), vim.log.levels.ERROR)
			end
		end,
	},
	apply_suggestion = {
		mode = "n",
		key = "a",
		menu_text = "Apply suggestion",
		menu_desc = "Replace anchored lines with the suggestion content",
		popup_hint = "[a] apply suggestion",
		show_hint = true,
		can_perform = function(_, comment)
			if not comment or not comment.body then
				return false
			end
			return #require("pr.suggestion").extract_suggestions(comment.body) > 0
		end,
		perform = function(_thread, comment, _, _, ctx)
			local suggestion = require("pr.suggestion")
			local list = suggestion.extract_suggestions(comment.body)
			if #list == 0 then
				return
			end
			-- v1: only the first suggestion in the comment. Multi-suggestion
			-- handling would require picker UI; punt for now.
			local sug = list[1]
			sug.anchor_start_line = comment.start_line
			sug.anchor_end_line = comment.end_line

			-- Resolve the file path. The popup's owning caller (init.lua's
			-- M.popup) threads `relative_path` through `make_comments_layout`
			-- into `ctx`. The visual-mode `:PRComment` flow doesn't open the
			-- comments popup, so a missing relative_path here is a programmer
			-- error rather than a user-facing condition.
			local relative_path = ctx and ctx.relative_path
			if not relative_path or relative_path == "" then
				vim.notify("Cannot apply: file path unknown for this thread", vim.log.levels.ERROR)
				return
			end

			git.get_git_root(vim.schedule_wrap(function(git_root)
				if not git_root or git_root == "" then
					vim.notify("Not a git repository", vim.log.levels.ERROR)
					return
				end
				local abs = git_root .. "/" .. relative_path

				-- Prefer the source buffer the popup was opened from; fall
				-- back to scanning loaded buffers by absolute path; finally
				-- open the file ourselves.
				local target_buf = nil
				if ctx and ctx.source_bufnr and vim.api.nvim_buf_is_valid(ctx.source_bufnr) then
					if vim.api.nvim_buf_get_name(ctx.source_bufnr) == abs then
						target_buf = ctx.source_bufnr
					end
				end
				if not target_buf then
					for _, b in ipairs(vim.api.nvim_list_bufs()) do
						if vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == abs then
							target_buf = b
							break
						end
					end
				end
				if not target_buf then
					local util = require("pr.util")
					util.open_pr_file(abs, relative_path, { line = comment.start_line })
					target_buf = vim.api.nvim_get_current_buf()
				end

				local drift = require("pr.drift")
				drift.get_for_buffer(target_buf, git_root, relative_path, function(dm)
					local ok, err = suggestion.apply(target_buf, sug, dm)
					if ok then
						vim.notify("Applied suggestion (" .. #sug.content_lines .. " lines)")
					else
						vim.notify("Apply failed: " .. (err or "?"), vim.log.levels.ERROR)
					end
				end)
			end))
		end,
	},
	yank_suggestion = {
		mode = "n",
		key = "ya",
		menu_text = "Yank suggestion",
		menu_desc = "Copy the suggestion content to the clipboard",
		popup_hint = "[ya] yank suggestion",
		show_hint = true,
		can_perform = function(_, comment)
			if not comment or not comment.body then
				return false
			end
			return #require("pr.suggestion").extract_suggestions(comment.body) > 0
		end,
		perform = function(_thread, comment, _, _)
			local list = require("pr.suggestion").extract_suggestions(comment.body)
			if #list == 0 then
				return
			end
			local content = table.concat(list[1].content_lines, "\n")
			vim.fn.setreg("+", content)
			vim.fn.setreg('"', content)
			vim.notify("Yanked suggestion (" .. #list[1].content_lines .. " lines)")
		end,
	},
	help = {
		mode = "n",
		key = "?",
		menu_text = "Help",
		menu_desc = "Show this help menu",
		popup_hint = "[?]help",
		show_hint = false,
		can_perform = function()
			return true
		end,
		perform = function(thread, comment, new_reply_popup, popup_winid, ctx)
			local menu = M.make_help_menu(thread, comment, new_reply_popup, popup_winid, ctx)
			menu:mount()

			for i, node in ipairs(menu.tree:get_nodes()) do
				local action = M.actions[node.action]
				vim.api.nvim_buf_set_extmark(menu.bufnr, menu.ns_id, i - 1, 0, {
					virt_text = { { action.menu_desc, "Comment" } },
					virt_text_pos = "right_align",
				})
			end
		end,
	},
	quit = {
		mode = "n",
		key = "q",
		menu_text = "Quit",
		menu_desc = "Close comments popup",
		popup_hint = "[Q]uit",
		show_hint = true,
		can_perform = function()
			return true
		end,
		perform = function(_, _, _, _, ctx)
			if ctx and ctx.unmount then
				ctx.unmount()
			end
		end,
	},
}

return M
