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
		menu_text = "Emoji",
		menu_desc = "Reactions for this comment",
		popup_text = "[E]moji",
		---
		---@param comment CommentInfo
		---@param popup_winid number
		perform = function(comment, popup_winid)
			local menu = M.make_emoji_menu(comment.database_id, comment.reaction_groups, popup_winid)
			menu:mount()
		end,
	},
	comment = {
		menu_text = "Comment",
		menu_desc = "Reply this thread",
		popup_text = "[C]omment",
		perform = function(comment, popup_winid) end,
	},
	resolve = {
		menu_text = "Resolve",
		menu_desc = "Resolve this thread",
		popup_text = "[R]esolve",
		perform = function(comment, popup_winid) end,
	},
	help = {
		menu_text = "Help",
		menu_desc = "Show this help menu",
		popup_text = "[?]help",
		perform = function(comment, popup_winid) end,
	},
}

---
---@param comment CommentInfo
---@param enter boolean
---@return NuiPopup
function M.make_popup(comment, enter)
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
			modifiable = false,
			readonly = true,
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
		local menu = " [E]moji | [C]omment | [R]esolve | [Q]uit  "
		popup.border:set_text("bottom", menu, "right")
	end)
	popup:on(event.BufLeave, function()
		popup.border:set_highlight("FloatBorder")
		-- don't set text if popup is closing
		if popup.border.bufnr then
			popup.border:set_text("bottom", nil, "right")
		end
	end)

	local body = M.split_crlf(comment.body)
	local emojis = M.format_reaction(comment.reaction_groups)
	-- TODO: fix hardcode
	local body_width = 78
	local emojis_width = vim.fn.strdisplaywidth(emojis)

	local lines = { unpack(body), (" "):rep(body_width), emojis .. (" "):rep(body_width - emojis_width) }

	vim.api.nvim_buf_set_lines(popup.bufnr, 0, 1, false, lines)

	vim.api.nvim_buf_set_extmark(popup.bufnr, popup.ns_id, #body, 0, {
		end_col = 0,
		end_line = #body + 1,
		hl_group = "Underlined",
	})

	vim.api.nvim_buf_set_extmark(popup.bufnr, popup.ns_id, #body + 1, 0, {
		end_col = 0,
		end_line = #body + 2,
		hl_group = "StatusLine",
	})

	popup:map("n", "e", function()
		local menu = M.make_emoji_menu(comment.database_id, comment.reaction_groups, popup.winid)
		menu:mount()
	end)

	popup:map("n", "?", function()
		local menu = M.make_help_menu(comment, popup.winid)
		menu:mount()

		local i = 0
		for _, action in pairs(M.actions) do
			vim.api.nvim_buf_set_extmark(menu.bufnr, menu.ns_id, i, 0, {
				virt_text = { { action.menu_desc, "Comment" } },
				virt_text_pos = "right_align",
			})
			i = i + 1
		end
	end)

	return popup
end

-- TODO: make templates
---
---@return NuiPopup
function M.make_new_reply_popup()
	local new_comment_popup = Popup({
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

	new_comment_popup:on(event.BufEnter, function()
		new_comment_popup.border:set_highlight(popup_hl)
		new_comment_popup.border:set_text("bottom", " [ 󰌑 Submit ] ", "right")
	end)

	new_comment_popup:on(event.BufLeave, function()
		new_comment_popup.border:set_highlight("FloatBorder")
		-- don't set text if popup is closing
		if new_comment_popup.border.bufnr then
			new_comment_popup.border:set_text("bottom", nil, "right")
		end
	end)

	return new_comment_popup
end

---
---@param popups NuiPopup[]
---@return NuiLayout
function M.make_layout(popups)
	local comment_boxes = {}
	for _, popup in ipairs(popups) do
		local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, true)
		-- padding
		table.insert(comment_boxes, Layout.Box(popup, { size = #lines + 3 }))
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
---@param comment CommentInfo
---@param popup_winid number
---@return NuiMenu
function M.make_help_menu(comment, popup_winid)
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
		local menu = Menu.item(Line({ Text(action.menu_text) }), {
			action = k,
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
			close = { "<Esc>", "<C-c>", "?" },
			submit = { "<CR>", "<Space>" },
		},
		on_close = function() end,
		on_submit = function(item)
			M.actions[item.action].perform(comment, popup_winid)
		end,
	})

	return menu
end

---
---@param s string
---@return string[]
function M.split_crlf(s)
	local res = {}
	local delim = "\r\n"
	local i = 1

	-- special-case empty string -> one empty field
	if s == "" then
		return { "" }
	end

	while true do
		local start_pos, end_pos = string.find(s, delim, i, true) -- plain find
		if not start_pos then
			table.insert(res, string.sub(s, i)) -- remainder (may be "")
			break
		end
		table.insert(res, string.sub(s, i, start_pos - 1)) -- segment before delim (may be "")
		i = end_pos + 1 -- move past the delimiter
	end

	return res
end

function M.setup()
	vim.api.nvim_set_hl(0, hl_emoji, { bg = "#4493f8", fg = "white" })

	vim.api.nvim_set_hl(0, popup_hl, { fg = "Yellow" })
end

function M.replace_chars(pos, str, r)
	return vim.fn.slice(str, 0, pos) .. r .. vim.fn.slice(str, pos + 40)
	-- return ("%s%s%s"):format(str:sub(1, pos - #r), r, str:sub(pos + #r))
end

return M
