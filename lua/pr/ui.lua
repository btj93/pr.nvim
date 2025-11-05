local Popup = require("nui.popup")
local Layout = require("nui.layout")
local Menu = require("nui.menu")
local Line = require("nui.line")
local Text = require("nui.text")
local NuiText = require("nui.text")
local event = require("nui.utils.autocmd").event

local git = require("pr.provider").get_provider()
local config = require("pr.config")

local M = {}

---@type table<integer, Draft>
---@class Draft
---@field body string
---@field updated_at string
-- TODO: validate with version number
M.drafts = {}

local reaction_contents = {
	CONFUSED = "😕",
	EYES = "👀",
	HEART = "❤️",
	HOORAY = "🎉",
	LAUGH = "😄",
	ROCKET = "🚀",
	THUMBS_DOWN = "👎",
	THUMBS_UP = "👍",
}

M.reply_actions = {
	submit = {},
	suggestion = {},
	saved_reply = {},
}

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

	local b = comment.body:gsub("\r", "")
	local body = vim.fn.split(b, "\n")
	local emojis = M.format_reaction(comment.reaction_groups)
	-- FIXME: fix hardcode
	local body_width = 78
	local emojis_width = vim.fn.strdisplaywidth(emojis)

	vim.api.nvim_buf_set_lines(popup.bufnr, 0, 1, false, body)

	vim.api.nvim_buf_set_extmark(popup.bufnr, config.opts.highlights.comments_ns_id, #body - 1, -1, {
		virt_lines = {
			{ { (" "):rep(body_width), config.opts.highlights.comment_sep } },
			{ { emojis .. (" "):rep(body_width - emojis_width), "StatusLine" } },
		},
	})

	if comment.viewer_can_update then
		popup:on({ event.TextChanged, event.TextChangedI }, function()
			local new_body = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, true)
			if new_body == body then
				return
			end

			local draft = M.drafts[comment.database_id] or {}
			if draft.updated_at and draft.updated_at ~= comment.updated_at then
				vim.notify("TODO: implement")
				return
			end

			M.drafts[comment.database_id] = {
				body = new_body,
				updated_at = comment.updated_at,
			}
		end)
	end

	for k, action in pairs(M.actions) do
		if action.key then
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
		},
		enter = enter,
	})

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
---@return NuiLayout
function M.make_comments_layout(thread)
	local popups = {}
	local comment_boxes = {}

	git.get_git_user()
	local new_reply_popup = make_new_reply_popup()

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
				if success then
					vim.notify("Reply submitted")
				end
			end)
		)

		-- TODO: spinner
	end)

	for i, comment in ipairs(thread.comments) do
		local popup = M.make_comment_popup(thread, comment, new_reply_popup, i == 1)
		table.insert(popups, popup)

		local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, true)
		-- padding
		local box = Layout.Box(popup, { size = #lines })
		table.insert(comment_boxes, box)
	end

	comment_boxes = { Layout.Box(comment_boxes, { dir = "col", size = "60%" }) }

	local new_comment_box = Layout.Box(new_reply_popup, { size = "40%" })

	if thread.viewer_can_reply then
		table.insert(popups, new_reply_popup)
		table.insert(comment_boxes, new_comment_box)
	end

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

		-- re-render all comments if either one is updated
		popup:on({ event.TextChanged, event.TextChangedI }, function()
			for sib, sibling in ipairs(popups) do
				local new_body = vim.api.nvim_buf_get_lines(sibling.bufnr, 0, -1, true)
				if sib == 1 then
					sibling:update_layout({
						size = {
							-- FIXME: fix hardcode
							width = 78,
							height = #new_body + 2,
						},
					})
				else
					local prev_buf = popups[sib - 1]
					local prev_buf_lines = vim.api.nvim_buf_get_lines(prev_buf.bufnr, 0, -1, true)
					sibling:update_layout({
						relative = {
							type = "win",
							winid = prev_buf.winid,
						},
						position = {
							row = #prev_buf_lines + 4,
							col = 0,
						},
						size = {
							-- FIXME: fix hardcode
							width = 78,
							height = (sib == #popups and 5) or #new_body + 2,
						},
					})
				end
			end
		end)
	end

	return layout
end

---
---@param lines string[]
---@param ft string
---@param relative_path string
---@param start_line integer
---@param end_line integer
---@return NuiLayout
function M.make_new_comment_layout(lines, ft, relative_path, start_line, end_line)
	local comment_reference_popup = make_code_reference_popup(lines, ft)
	local comment_boxes = {}

	local popups = {}
	local l = vim.api.nvim_buf_get_lines(comment_reference_popup.bufnr, 0, -1, true)
	table.insert(comment_boxes, Layout.Box(comment_reference_popup, { size = #l }))
	table.insert(popups, comment_reference_popup)

	git.get_git_user()
	local new_comment_popup = M.make_new_reply_popup(true, "[<M-s> Toggle suggestion ] | [ 󰌑 Submit ]")

	for _, mode in ipairs({ "n", "i" }) do
		new_comment_popup:map(mode, "<M-s>", function()
			local suggestion = { "```suggestion", unpack(lines) }
			table.insert(suggestion, "```")
			vim.notify(vim.inspect(suggestion))
			vim.api.nvim_buf_set_lines(new_comment_popup.bufnr, 0, -1, false, suggestion)
			-- TODO: clear if already exists
			-- TODO: keep existing comment
		end)
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
		git.comment(
			relative_path,
			start_line,
			end_line,
			table.concat(body, "\n"),
			vim.schedule_wrap(function(success)
				if success then
					vim.notify("Comment submitted")
					layout:unmount()
				end
			end)
		)
	end)

	return layout
end

---
---@param comment_id integer
---@param reaction_groups CommentReactionGroup[]
---@param winid number
---@return NuiMenu
local function make_emoji_menu(comment_id, reaction_groups, winid)
	local items = {}

	local space_count = 6

	for _, reaction in pairs(reaction_groups) do
		local count_digits = #tostring(reaction.reactors.totalCount)
		-- TODO: adjust col based on longest item
		if count_digits > space_count then
			space_count = count_digits + 2
		end

		local sep = string.rep(" ", space_count - count_digits)

		local text = NuiText(reaction_contents[reaction.content] .. sep .. reaction.reactors.totalCount)
		if reaction.viewerHasReacted then
			text:set(
				reaction_contents[reaction.content] .. sep .. reaction.reactors.totalCount,
				config.opts.highlights.hl_emoji
			)
		end
		table.insert(
			items,
			Menu.item(text, {
				id = reaction.content,
				viewer_has_reacted = reaction.viewerHasReacted,
				comment_id = comment_id,
				reactions = reaction.reactors.nodes,
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
			row = 0,
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
			print("SUBMITTED", vim.inspect(item.viewer_has_reacted))
			if item.viewer_has_reacted then
				for _, reaction in ipairs(item.reactions) do
					if reaction.user.login == M.git_user then
						git.remove_reaction(item.comment_id, reaction.database_id)
						return
					end
				end
				vim.notify("You have not reacted to this comment yet.")
			else
				git.add_reaction(item.comment_id, item.id)
			end

			-- TODO: get comment and render again
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
			table.insert(
				reactions,
				"( " .. reaction_contents[reaction.content] .. " " .. reaction.reactors.totalCount .. " )"
			)
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
function M.make_help_menu(thread, comment, new_reply_popup, popup_winid)
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

	local lines = {}
	for k, action in pairs(M.actions) do
		local t = Text(action.menu_text, "NonText")
		local can_perform_bool = action.can_perform(thread, comment)
		if can_perform_bool then
			t = Text(action.menu_text)
		end

		local menu = Menu.item(Line({ t }), {
			action = k,
			can_perform_bool = can_perform_bool,
		})
		table.insert(lines, menu)
	end

	local menu = Menu(popup_options, {
		lines = lines,
		max_width = 50,
		min_width = 50,
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

			M.actions[item.action].perform(thread, comment, new_reply_popup, popup_winid)
		end,
	})

	return menu
end

function M.setup()
	vim.api.nvim_set_hl(0, config.opts.highlights.hl_emoji, { bg = "#4493f8", fg = "white" })
	vim.api.nvim_set_hl(0, config.opts.highlights.popup_hl, { fg = "Yellow" })
	vim.api.nvim_set_hl(0, config.opts.highlights.comment_sep, { underline = true, fg = "Grey" })
end

local function replace_chars(pos, str, r)
	return vim.fn.slice(str, 0, pos) .. r .. vim.fn.slice(str, pos + 40)
	-- return ("%s%s%s"):format(str:sub(1, pos - #r), r, str:sub(pos + #r))
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
			return comment.viewer_can_react
		end,
		perform = function(_, comment, _, popup_winid)
			local menu = make_emoji_menu(comment.database_id, comment.reaction_groups, popup_winid)
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
		perform = function(thread, _, _)
			git.resolve_thread(
				thread.id,
				vim.schedule_wrap(function(success)
					if success then
						vim.notify("Thread resolved")
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
		perform = function(thread, _, _, _)
			git.unresolve_thread(
				thread.id,
				vim.schedule_wrap(function(success)
					if success then
						vim.notify("Thread unresolved")
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
			local buf = vim.api.nvim_get_current_buf()
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<esc>", true, false, true), "x", true)
			local start_line = vim.fn.line("'<")
			local end_line = vim.fn.line("'>")

			local lines = vim.api.nvim_buf_get_text(buf, start_line - 1, 0, end_line + 1, -1, {})
			for i, line in ipairs(lines) do
				lines[i] = "> " .. line
			end

			vim.api.nvim_buf_set_lines(new_reply_popup.bufnr, 0, -1, false, lines)
			-- TODO: clear if already exists
			-- TODO: keep existing comment
			vim.api.nvim_set_current_buf(new_reply_popup.bufnr)
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
		perform = function(_, _, _, popup_winid)
			vim.api.nvim_set_current_win(popup_winid)
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
			local draft = M.drafts[comment.database_id] or {}
			return draft.body and draft.updated_at
		end,
		perform = function(_, comment, _, _)
			git.edit_comment(
				comment.database_id,
				comment.body,
				vim.schedule_wrap(function(success)
					if success then
						vim.notify("Comment saved")
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
		perform = function(_, comment, _, _)
			vim.ui.select({ "Yes", "No" }, {
				prompt = "Are you sure you want to delete this comment? This action cannot be undone.",
			}, function(choice)
				if choice == "Yes" then
					git.delete_comment(
						comment.database_id,
						vim.schedule_wrap(function(success)
							if success then
								-- FIXME: fix notify not working
								vim.notify("Comment deleted")
							end
						end)
					)
				end
			end)
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
		perform = function(thread, comment, new_reply_popup, popup_winid)
			local menu = M.make_help_menu(thread, comment, new_reply_popup, popup_winid)
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
		perform = function(_, _, _, _)
			-- implemented in M.make_layout
		end,
	},
}

return M
