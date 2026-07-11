-- Tier 2 flow spec: the popup-open + thread/hunk navigation surface driven over
-- the fake provider inside a real temp git repo. Covers:
--   * M.popup — opening the review thread whose anchored range contains the
--     cursor line (reads git.comments + resolves relative_path from the buffer
--     name under git_root).
--   * comment.cycle_comments_in_buffer — forward/backward cursor motion between
--     thread start lines, in ascending order, wrapping at the ends.
--   * hunk.cycle_hunks_in_buffer — same motion between hunk starts.
--   * the `?` help menu — mounted from the comments layout, listing every action
--     including the keyless `edit`.
--
-- Multi-thread fixture: one real file with threads at lines 2, 5, 9 and hunks at
-- two ranges (starts 3 and 8). git_root is derived from the actually-opened
-- buffer name so symlinked temp dirs (/var vs /private/var on macOS) can't skew
-- the relative_path arithmetic in the modules under test.
if not pcall(require, "nui.popup") then
	return
end

local ui_env = require("helpers.ui_env")
local fake_provider = require("helpers.fake_provider")
local git_repo = require("helpers.git_repo")

--- Concatenated text of a buffer.
local function buf_text(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- First open float whose buffer text contains `needle`, or nil.
local function find_float_with(env, needle)
	for _, win in ipairs(env.floats()) do
		local b = vim.api.nvim_win_get_buf(win)
		if buf_text(b):find(needle, 1, true) then
			return win, b
		end
	end
	return nil, nil
end

--- 1-indexed line in `buf` whose text contains `needle`, or nil.
local function line_with(buf, needle)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i, line in ipairs(lines) do
		if line:find(needle, 1, true) then
			return i
		end
	end
	return nil
end

describe("flow: popup + navigation", function()
	local env, fake, uninstall, repo, file_buf, rel

	before_each(function()
		env = ui_env.setup()
		repo = git_repo.create({
			files = { ["foo.lua"] = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12" } },
		})
		vim.cmd("edit " .. vim.fn.fnameescape(repo.root .. "/foo.lua"))
		file_buf = vim.api.nvim_get_current_buf()
		-- Derive git_root/relative_path from the buffer name the module will read,
		-- not from repo.root, so symlink resolution can't desync the two.
		local bufname = vim.api.nvim_buf_get_name(file_buf)
		local git_root = vim.fn.fnamemodify(bufname, ":h")
		rel = vim.fn.fnamemodify(bufname, ":t")

		local function mk(id, line, body, opts)
			opts = opts or {}
			return {
				id = id,
				is_resolved = opts.is_resolved or false,
				is_outdated = opts.is_outdated or false,
				viewer_can_reply = true,
				viewer_can_resolve = true,
				viewer_can_unresolve = true,
				comments = {
					{
						database_id = opts.database_id or 0,
						author = opts.author or "alice",
						body = body,
						updated_at = "2026-01-01T00:00:00Z",
						viewer_can_update = false,
						viewer_can_delete = false,
						viewer_can_react = true,
						start_line = line,
						end_line = opts.end_line or line,
					},
				},
			}
		end

		fake, uninstall = fake_provider.install("flow_popup_nav_fake", {
			git_root = git_root,
			comments = {
				[rel] = {
					mk("T2", 2, "thread alpha at line two", { database_id = 201 }),
					mk("T5", 5, "thread beta at line five", { database_id = 205 }),
					mk("T9", 9, "thread gamma at line nine", { database_id = 209 }),
				},
			},
			hunks = {
				[rel] = {
					{ hunk_start = 3, hunk_end = 4, type = "Add" },
					{ hunk_start = 8, hunk_end = 10, type = "Change" },
				},
			},
		})
	end)

	after_each(function()
		-- Drain any scheduled re-renders before wiping the popup buffers.
		env.drain(50)
		if uninstall then
			uninstall()
		end
		if env then
			env.teardown()
		end
		if repo then
			repo.cleanup()
			repo = nil
		end
		-- Drop any user commands the :PRComment case registered.
		for _, name in ipairs({
			"PRRefresh",
			"PRComment",
			"PRList",
			"PRInfo",
			"PRReview",
			"PRReviewDiscard",
			"PRSuggest",
			"PRQuickfix",
			"PRRefreshUsers",
			"PRRefreshIssues",
		}) do
			pcall(vim.api.nvim_del_user_command, name)
		end
	end)

	--- Focus the file window and place the cursor on `row`.
	local function focus_file(row)
		vim.api.nvim_set_current_win(vim.fn.bufwinid(file_buf))
		vim.api.nvim_win_set_cursor(0, { row, 0 })
	end

	it("M.popup opens the thread under the cursor", function()
		local pr = require("pr")
		focus_file(5)
		pr.popup()

		local body_buf
		env.wait_for(function()
			local _, b = find_float_with(env, "thread beta at line five")
			body_buf = b
			return b ~= nil
		end, 2000, "popup for the line-5 thread")

		local text = buf_text(body_buf)
		-- Picked the thread whose range covers line 5, not its neighbours.
		assert.truthy(text:find("thread beta at line five", 1, true))
		assert.is_nil(text:find("thread alpha at line two", 1, true))
		assert.is_nil(text:find("thread gamma at line nine", 1, true))
	end)

	it(":PRComment opens the thread under the cursor", function()
		-- Register the user commands (single source of truth in init.lua) and drive
		-- the popup through :PRComment rather than the M.popup() call above.
		require("pr")._register_commands()
		focus_file(5)
		vim.cmd.PRComment()

		local body_buf
		env.wait_for(function()
			local _, b = find_float_with(env, "thread beta at line five")
			body_buf = b
			return b ~= nil
		end, 2000, ":PRComment popup for the line-5 thread")

		local text = buf_text(body_buf)
		assert.truthy(text:find("thread beta at line five", 1, true))
		assert.is_nil(text:find("thread alpha at line two", 1, true))
		assert.is_nil(text:find("thread gamma at line nine", 1, true))
	end)

	it("cycle_comments_in_buffer forward/backward moves the cursor between thread lines in order, wrapping", function()
		focus_file(2)

		--- Run one cycle step and return the row the cursor lands on plus the text
		--- of the notification the step fired. Waits on the module's own
		--- "Comment N of M" notification (fired right after the cursor is set) so
		--- the read reflects the completed async fetch.
		local function step(direction)
			local before = #env.notifications
			require("pr.comment").cycle_comments_in_buffer(direction)
			env.wait_for(function()
				return #env.notifications > before
			end, 2000, "cycle_comments notify")
			return vim.api.nvim_win_get_cursor(0)[1], env.notifications[#env.notifications].msg
		end

		-- Forward: 2 -> 5 -> 9, then wrap to the first thread. The notification
		-- indexes the DESTINATION thread (2nd of 3) so the "N of M" reads right.
		local row, msg = step("forward")
		assert.equals(5, row)
		assert.equals("Comment 2 of 3", msg)
		assert.equals(9, (step("forward")))
		assert.equals(2, (step("forward")))

		-- Backward: from the first thread wrap to the last, then 9 -> 5 -> 2.
		assert.equals(9, step("backward"))
		assert.equals(5, step("backward"))
		assert.equals(2, step("backward"))
	end)

	it("cycle_comments_in_buffer with a single thread wraps to itself both directions", function()
		-- Replace the 3-thread fixture with exactly one thread (at line 6) so both
		-- directions fall through to the wrap branch and land back on the same
		-- thread; the "Comment 1 of 1" notification still fires each step.
		local git_root = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(file_buf), ":h")
		uninstall()
		fake, uninstall = fake_provider.install("flow_popup_nav_fake", {
			git_root = git_root,
			comments = {
				[rel] = {
					{
						id = "SOLO",
						is_resolved = false,
						is_outdated = false,
						viewer_can_reply = true,
						viewer_can_resolve = true,
						viewer_can_unresolve = true,
						comments = {
							{
								database_id = 601,
								author = "alice",
								body = "lonely thread at line six",
								updated_at = "2026-01-01T00:00:00Z",
								viewer_can_update = false,
								viewer_can_delete = false,
								viewer_can_react = true,
								start_line = 6,
								end_line = 6,
							},
						},
					},
				},
			},
		})

		focus_file(2)

		local function step(direction)
			local before = #env.notifications
			require("pr.comment").cycle_comments_in_buffer(direction)
			env.wait_for(function()
				return #env.notifications > before
			end, 2000, "cycle_comments notify")
			return vim.api.nvim_win_get_cursor(0)[1], env.notifications[#env.notifications].msg
		end

		-- Forward from above the sole thread lands on it; wrapping keeps it there.
		local row, msg = step("forward")
		assert.equals(6, row)
		assert.equals("Comment 1 of 1", msg)
		assert.equals(6, (step("forward")))

		-- Backward wraps onto the same single thread as well.
		assert.equals(6, (step("backward")))
		assert.equals(6, (step("backward")))
	end)

	it("cycle_hunks_in_buffer moves between hunk starts", function()
		focus_file(1)

		local function step(direction)
			local before = #env.notifications
			require("pr.hunk").cycle_hunks_in_buffer(direction)
			env.wait_for(function()
				return #env.notifications > before
			end, 2000, "cycle_hunks notify")
			return vim.api.nvim_win_get_cursor(0)[1]
		end

		-- Hunk starts are 3 and 8. Forward walks them in order and wraps.
		assert.equals(3, step("forward"))
		assert.equals(8, step("forward"))
		assert.equals(3, step("forward"))

		-- Backward from the first hunk wraps to the last, then walks back.
		assert.equals(8, step("backward"))
		assert.equals(3, step("backward"))
	end)

	it("? opens the help menu listing every action incl. keyless edit", function()
		local ui = require("pr.ui")
		local thread = fake.scenario.comments[rel][1]
		local layout, comments_popup = ui.make_comments_layout(thread, rel)
		layout:mount()

		env.wait_for(function()
			return line_with(comments_popup.bufnr, "thread alpha at line two") ~= nil
		end, 2000, "thread body rendered")

		-- Focus the conversation popup, land on the first comment body (gg), then
		-- open the help menu.
		vim.api.nvim_set_current_win(comments_popup.winid)
		env.feed("gg")
		env.feed("?")

		local help_buf
		env.wait_for(function()
			-- "Quit" is unique to the help menu buffer (the thread render doesn't
			-- contain it), so it identifies the newest float unambiguously.
			local _, b = find_float_with(env, "Quit")
			help_buf = b
			return b ~= nil
		end, 2000, "help menu float")

		local text = buf_text(help_buf)
		-- Every action's menu_text must be listed — including keyless ones.
		for name, action in pairs(ui.actions) do
			assert.truthy(text:find(action.menu_text, 1, true), "help menu missing action: " .. name .. " (" .. action.menu_text .. ")")
		end

		-- `edit` is the keyless action: it has no key binding but still appears in
		-- the menu so users can reach it.
		assert.is_nil(ui.actions.edit.key)
		assert.truthy(text:find(ui.actions.edit.menu_text, 1, true))
	end)
end)
