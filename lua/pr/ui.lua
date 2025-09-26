local Popup = require("nui.popup")
local Layout = require("nui.layout")
local Menu = require("nui.menu")
local Line = require("nui.line")
local Text = require("nui.text")
local NuiText = require("nui.text")
local event = require("nui.utils.autocmd").event

local gh = require("pr.providers.gh")

local M = {}

local popup_hl = "PRCommentPopup"
local hl_emoji = "PREmojiLine"
local comment_sep = "PRCommentSeparator"

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

M.actions = {
	emoji = {
		key = "e",
		menu_text = "Emoji",
		menu_desc = "Reactions for this comment",
		popup_hint = "[E]moji",
		show_hint = true,
		---
		---@param comment CommentInfo
		---@return boolean
		can_perform = function(_, comment)
			return comment.viewer_can_react
		end,
		---
		---@param comment CommentInfo
		---@param popup_winid number
		perform = function(_, comment, popup_winid)
			local menu = M.make_emoji_menu(comment.database_id, comment.reaction_groups, popup_winid)
			menu:mount()
		end,
	},
	resolve = {
		key = "r",
		menu_text = "Resolve",
		menu_desc = "Resolve this thread",
		popup_hint = "[R]esolve",
		show_hint = true,
		---
		---@param thread ReviewThread
		---@return boolean
		can_perform = function(thread, _)
			return (not thread.is_resolved) and thread.viewer_can_resolve
		end,
		perform = function(thread, comment, popup_winid)
			vim.notify("TODO: implement")
		end,
	},
	unresolve = {
		key = "r",
		menu_text = "Unresolve",
		menu_desc = "Unresolve this thread",
		popup_hint = "Un[R]esolve",
		show_hint = true,
		---
		---@param thread ReviewThread
		---@return boolean
		can_perform = function(thread, _)
			return thread.is_resolved and thread.viewer_can_unresolve
		end,
		perform = function(thread, comment, popup_winid)
			vim.notify("TODO: implement")
		end,
	},
	edit = {
		key = nil,
		menu_text = "Edit",
		menu_desc = "Enter insert mode to edit this comment",
		popup_hint = nil,
		show_hint = false,
		---
		---@param comment CommentInfo
		---@return boolean
		can_perform = function(_, comment)
			return comment.viewer_can_update
		end,
		perform = function(_, _, popup_winid)
			vim.api.nvim_set_current_win(popup_winid)
			vim.cmd("startinsert")
		end,
	},
	save = {
		-- FIXME: keymap
		key = nil,
		menu_text = "Save",
		menu_desc = "Save edited comment",
		popup_hint = nil,
		show_hint = false,
		can_perform = function(_, comment)
			-- TODO: check comment is edited
		end,
		perform = function(thread, comment, popup_winid)
			vim.notify("TODO: implement")
		end,
	},
	help = {
		key = "?",
		menu_text = "Help",
		menu_desc = "Show this help menu",
		popup_hint = "[?]help",
		show_hint = false,
		can_perform = function()
			return true
		end,
		---
		---@param thread ReviewThread
		---@param comment CommentInfo
		---@param popup_winid number
		perform = function(thread, comment, popup_winid)
			local menu = M.make_help_menu(thread, comment, popup_winid)
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
		key = "q",
		menu_text = "Quit",
		menu_desc = "Close comments popup",
		popup_hint = "[Q]uit",
		show_hint = true,
		can_perform = function()
			return true
		end,
		perform = function(_, _, _)
			-- implemented in M.make_layout
		end,
	},
}

M.reply_actions = {
	submit = {},
	suggestion = {},
	saved_reply = {},
}

---
---@param thread ReviewThread
---@param comment CommentInfo
---@param enter boolean
---@return NuiPopup
function M.make_popup(thread, comment, enter)
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
			-- FIXME: user can edit emoji lines
			modifiable = comment.viewer_can_update,
			readonly = true,
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
		popup.border:set_highlight(popup_hl)
		local menus = {}
		for _, action in pairs(M.actions) do
			if action.show_hint and action.can_perform(thread, comment) then
				table.insert(menus, action.popup_hint)
			end
		end

		-- FIXME: menu text should be dynamic
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

	local body = vim.fn.split(comment.body, "\r\n")
	local emojis = M.format_reaction(comment.reaction_groups)
	-- FIXME: fix hardcode
	local body_width = 78
	local emojis_width = vim.fn.strdisplaywidth(emojis)

	table.insert(body, (" "):rep(body_width))
	table.insert(body, emojis .. (" "):rep(body_width - emojis_width))

	vim.api.nvim_buf_set_lines(popup.bufnr, 0, 1, false, body)

	vim.api.nvim_buf_set_extmark(popup.bufnr, popup.ns_id, #body - 2, 0, {
		end_col = 0,
		end_line = #body - 1,
		hl_group = comment_sep,
	})

	vim.api.nvim_buf_set_extmark(popup.bufnr, popup.ns_id, #body - 1, 0, {
		end_col = 0,
		end_line = #body,
		hl_group = "StatusLine",
	})

	for k, action in pairs(M.actions) do
		if action.key then
			popup:map("n", action.key, function()
				M.actions[k].perform(thread, comment, popup.winid)
			end)
		end
	end

	return popup
end

-- TODO: make templates
---
---@return NuiPopup
function M.make_new_reply_popup()
	local reply_popup = Popup({
		border = {
			padding = {
				top = 1,
				bottom = 1,
				left = 1,
				right = 1,
			},
			style = "rounded",
			text = {
				top = "Reply as " .. gh.git_user,
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
		enter = false,
	})

	reply_popup:on(event.BufEnter, function()
		reply_popup.border:set_highlight(popup_hl)
		reply_popup.border:set_text("bottom", " [ 󰌑 Submit ] ", "right")
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
---@param popups NuiPopup[]
---@return NuiLayout
function M.make_layout(popups)
	local comment_boxes = {}
	for _, popup in ipairs(popups) do
		local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, true)
		-- padding
		table.insert(comment_boxes, Layout.Box(popup, { size = #lines }))
	end

	gh.get_git_user()
	local new_comment_popup = M.make_new_reply_popup()
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

		popup:map("n", "j", function()
			if i == #popups then
				return
			end
			vim.api.nvim_set_current_win(popups[i + 1].winid)
		end)

		popup:map("n", "k", function()
			if i == 1 then
				return
			end
			vim.api.nvim_set_current_win(popups[i - 1].winid)
		end)
	end

	return layout
end

---
---@param comment_id integer
---@param reaction_groups CommentReactionGroup[]
---@param winid number
---@return NuiMenu
function M.make_emoji_menu(comment_id, reaction_groups, winid)
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
			text:set(reaction_contents[reaction.content] .. sep .. reaction.reactors.totalCount, hl_emoji)
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
						gh.remove_reaction(item.comment_id, reaction.database_id)
						return
					end
				end
				vim.notify("You have not reacted to this comment yet.")
			else
				gh.add_reaction(item.comment_id, item.id)
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
				"   ( " .. reaction_contents[reaction.content] .. " " .. reaction.reactors.totalCount .. " )"
			)
		end
	end
	return table.concat(reactions, " | ")
end

---
---@param thread ReviewThread
---@param comment CommentInfo
---@param popup_winid number
---@return NuiMenu
function M.make_help_menu(thread, comment, popup_winid)
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

			M.actions[item.action].perform(thread, comment, popup_winid)
		end,
	})

	return menu
end

function M.setup()
	vim.api.nvim_set_hl(0, hl_emoji, { bg = "#4493f8", fg = "white" })
	vim.api.nvim_set_hl(0, popup_hl, { fg = "Yellow" })
	vim.api.nvim_set_hl(0, comment_sep, { underline = true, fg = "Grey" })
end

function M.replace_chars(pos, str, r)
	return vim.fn.slice(str, 0, pos) .. r .. vim.fn.slice(str, pos + 40)
	-- return ("%s%s%s"):format(str:sub(1, pos - #r), r, str:sub(pos + #r))
end

return M
