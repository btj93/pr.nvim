local Popup = require("nui.popup")
local Layout = require("nui.layout")
local Menu = require("nui.menu")
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
				bottom = 1,
				left = 1,
				right = 1,
			},
			style = "rounded",
			text = {
				top = author_display .. ":",
				top_align = "left",
				bottom = M.format_reaction(comment.reaction_groups),
				bottom_align = "left",
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
		local width = vim.api.nvim_win_get_width(popup.winid)
		vim.notify(popup.border:get())
	end)
	popup:on(event.BufLeave, function()
		popup.border:set_highlight("FloatBorder")
	end)
	local lines = { unpack(M.split_crlf(comment.body)) }

	vim.api.nvim_buf_set_lines(popup.bufnr, 0, 1, false, lines)

	popup:map("n", "e", function()
		local menu = M.make_emoji_menu(comment.database_id, comment.reaction_groups)
		menu:mount()
	end)

	-- vim.keymap.set("n", "q", function()
	--   popup:unmount()
	-- end, { buffer = popup.bufnr })

	-- vim.api.nvim_set_current_win(popup.winid)
	return popup
end

---
---@param popups NuiPopup[]
---@return NuiLayout
function M.make_layout(popups)
	local comment_boxes = {}
	for _, popup in ipairs(popups) do
		local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, true)
		-- padding
		table.insert(comment_boxes, Layout.Box(popup, { size = #lines + 4 }))
		-- if i == 1 then
		--   popup.border:set_text("top", "Inline Comment", "center")
		-- end
		--
		-- if i == #popups then
		-- 	popup.border:set_text("bottom", " [E]moji | [C]omment | [R]esolve | [Q]uit ", "right")
		-- end
	end

	gh.get_git_user()
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
				top = "New Comment as " .. gh.git_user,
				top_align = "left",
				bottom = " [ 󰌑 Submit ] ",
				bottom_align = "right",
			},
		},
		buf_options = {
			modifiable = true,
			readonly = false,
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
		enter = false,
	})

	table.insert(popups, new_comment_popup)

	new_comment_popup:on(event.BufEnter, function()
		new_comment_popup.border:set_highlight(popup_hl)
	end)
	new_comment_popup:on(event.BufLeave, function()
		new_comment_popup.border:set_highlight("FloatBorder")
	end)

	local new_comment_box = Layout.Box(new_comment_popup, { size = "40%" })

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
---@return NuiMenu
function M.make_emoji_menu(comment_id, reaction_groups)
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
	local popup_options = {
		relative = "cursor",
		position = {
			row = 1,
			col = -7,
		},
		border = {
			style = "rounded",
			text = {
				top = "[Choose Item]",
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
		on_close = function()
			print("CLOSED")
		end,
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
				"( " .. reaction_contents[reaction.content] .. " " .. reaction.reactors.totalCount .. " )"
			)
		end
	end
	return table.concat(reactions, " | ")
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

return M
