local provider = require("pr.provider")
local config = require("pr.config")
local git = provider.get_provider()
local ui = require("pr.ui")
local comment = require("pr.comment")
local hunk = require("pr.hunk")
local Job = require("plenary.job")

local M = {}

local last_branch = nil
local last_git_root = nil
local last_head = nil

--- Asynchronously read the current branch name. Invokes callback with the branch string,
--- or nil if not in a git repo or the command fails.
local function get_current_branch(callback)
	Job:new({
		command = "git",
		args = { "rev-parse", "--abbrev-ref", "HEAD" },
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				return callback(nil)
			end
			local result = j:result()
			local branch = result and result[1]
			callback(branch)
		end),
	}):start()
end

--- Asynchronously read the git root (`git rev-parse --show-toplevel`).
--- Invokes callback with the root path string, or nil if not in a git repo or the command fails.
local function get_git_root_async(callback)
	Job:new({
		command = "git",
		args = { "rev-parse", "--show-toplevel" },
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				return callback(nil)
			end
			local result = j:result()
			local t = result and result[1]
			callback(t)
		end),
	}):start()
end

local function check_branch_and_refresh()
	if not (comment.enabled or hunk.enabled) then
		return
	end
	get_git_root_async(function(new_root)
		if new_root and last_git_root and new_root ~= last_git_root then
			vim.notify("Entered different git root, resetting PR state…")
			-- Capture currently-enabled state BEFORE stop() flips the flags.
			-- We want to resume what the user had on, not what config defaults say.
			local was_comment = comment.enabled
			local was_hunk = hunk.enabled
			comment.stop()
			hunk.stop()
			if type(git.clear) == "function" then
				git.clear()
			end
			last_branch = nil -- branch comparison is meaningless across repos
			last_head = nil -- HEAD comparison is also meaningless across repos
			last_git_root = new_root
			if was_comment then
				comment.start()
			end
			if was_hunk then
				hunk.start()
			end
			return
		end
		if new_root and not last_git_root then
			last_git_root = new_root
		end

		get_current_branch(function(branch)
			if not branch then
				return
			end
			if last_branch and last_branch ~= branch then
				vim.notify("Switched to branch '" .. branch .. "', refreshing PR data…")
				-- Diff against the previous branch's PR is nonsense — suppress it.
				-- The provider's own "You have N(M) comment threads" notification still fires.
				M.refresh({ show_diff = false })
			end
			last_branch = branch
		end)
	end)
end

local uv = vim.uv or vim.loop
local refresh_timer = nil

--- Start (or restart) the periodic-refresh timer.
--- Pass 0 / nil / negative to stop it.
---@param interval_seconds number?
function M.set_refresh_interval(interval_seconds)
	if refresh_timer then
		refresh_timer:stop()
		if not refresh_timer:is_closing() then
			refresh_timer:close()
		end
		refresh_timer = nil
	end

	if not interval_seconds or interval_seconds <= 0 then
		return
	end

	refresh_timer = uv.new_timer()
	local ms = math.floor(interval_seconds * 1000)
	refresh_timer:start(
		ms,
		ms,
		vim.schedule_wrap(function()
			if comment.enabled or hunk.enabled then
				M.refresh()
			end
		end)
	)
end

---
---@param relative_path string?
---@param line integer?
function M.popup(relative_path, line)
	-- TODO: check gh.get_comments is done
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

			for _, thread in ipairs(comments) do
				local _, first_comment = next(thread.comments)
				if first_comment and first_comment.start_line <= line and first_comment.end_line >= line then
					local layout = ui.make_comments_layout(thread, relative_path)
					layout:mount()
					break
				end
			end
		end))
	end))
end

-- A single setup function for signs and highlights
function M.setup(opts)
	config.setup(opts)

	-- vim.fn.sign_define(sign_add, { text = "+", texthl = "DiffAdd" })
	-- vim.fn.sign_define(sign_del, { text = "-", texthl = "DiffDelete" })
	vim.fn.sign_define(config.opts.highlights.sign_comment, { text = config.opts.sign, texthl = config.opts.highlights.sign_hl })
	vim.fn.sign_define(
		config.opts.highlights.sign_comment_multi_line_start,
		{ text = config.opts.multi_line_sign.start_line, texthl = config.opts.highlights.sign_hl }
	)
	vim.fn.sign_define(
		config.opts.highlights.sign_comment_multi_line_connector,
		{ text = config.opts.multi_line_sign.connector, texthl = config.opts.highlights.sign_hl }
	)
	vim.fn.sign_define(
		config.opts.highlights.sign_comment_multi_line_end,
		{ text = config.opts.multi_line_sign.end_line, texthl = config.opts.highlights.sign_hl }
	)
	require("pr.highlights").apply()
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = vim.api.nvim_create_augroup("PRColorScheme", { clear = true }),
		callback = function()
			require("pr.highlights").apply()
		end,
	})

	-- Suppress vim.diagnostic's auto-placed severity signs for our namespace.
	-- pr.nvim places its own signcolumn glyphs (`󰅺` + `┌`/`│`/`└` multi-line
	-- connectors) via `vim.fn.sign_place`; without this the diagnostic UI
	-- would draw a second sign on top.
	pcall(vim.diagnostic.config, { signs = false }, require("pr.diagnostics").namespace)

	ui.setup()
	comment.setup()
	hunk.setup()

	vim.api.nvim_create_user_command("PRRefresh", function()
		M.refresh()
	end, { desc = "Refresh PR comments and hunks" })

	vim.api.nvim_create_user_command("PRList", function(arg)
		local pick_opts = nil
		if arg.args and arg.args ~= "" then
			pick_opts = { filter = arg.args }
		end
		require("pr.picker").pick_prs(pick_opts)
	end, {
		nargs = "?",
		complete = function()
			return require("pr.pickers.filter").PR_FILTERS
		end,
		desc = "List PRs [mine|assigned|review-requested|all] and switch into one",
	})

	vim.api.nvim_create_user_command("PRInfo", function(arg)
		require("pr.pr_info").show(arg.args == "edit" and "edit" or "view")
	end, {
		nargs = "?",
		complete = function()
			return { "edit" }
		end,
		desc = "Show or edit PR info",
	})

	vim.api.nvim_create_user_command("PRReview", function()
		require("pr.review").show()
	end, { desc = "Open pending review for submission" })

	vim.api.nvim_create_user_command("PRReviewDiscard", function()
		require("pr.review")._discard()
	end, { desc = "Discard pending review" })

	vim.api.nvim_create_user_command("PRSuggest", function()
		require("pr.suggestion").comment_with_suggestion()
	end, {
		range = true,
		desc = "Open a new-comment popup wrapping the visual selection as a suggestion",
	})

	vim.api.nvim_create_user_command("PRQuickfix", function(arg)
		local kind = arg.args
		if kind == "" then
			kind = "unresolved"
		end
		require("pr.quickfix").dump({ kind = kind })
	end, {
		nargs = "?",
		complete = function()
			return { "unresolved", "outdated", "all", "file" }
		end,
		desc = "Dump PR threads to quickfix",
	})

	vim.api.nvim_create_user_command("PRRefreshUsers", function()
		local g = provider.get_provider()
		if type(g.clear_collaborators) == "function" then
			g.clear_collaborators()
		end
		pcall(function()
			require("pr.completion")._clear_collaborators()
		end)
		vim.notify("PR: collaborator cache cleared")
	end, { desc = "Clear cached collaborators (forces re-fetch on next completion)" })

	vim.api.nvim_create_user_command("PRRefreshIssues", function()
		local g = provider.get_provider()
		if type(g.clear_issues) == "function" then
			g.clear_issues()
		end
		pcall(function()
			require("pr.completion")._clear_issues()
		end)
		vim.notify("PR: issue cache cleared")
	end, { desc = "Clear cached issues + PRs (forces re-fetch on next completion)" })

	-- Flush any debounced draft writes on quit so unsaved keystrokes persist.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("PRDraftsFlush", { clear = true }),
		callback = function()
			pcall(function()
				require("pr.drafts").flush()
			end)
		end,
	})

	if config.opts.winbar and config.opts.winbar.enabled then
		local group = vim.api.nvim_create_augroup("PRWinbar", { clear = true })
		local function apply_winbar()
			local prov = require("pr.provider").get_provider()
			if not prov.git_root or prov.git_root == "" then
				return
			end
			local bufname = vim.api.nvim_buf_get_name(0)
			if bufname == "" or bufname:sub(1, #prov.git_root) ~= prov.git_root then
				return
			end
			local w = require("pr.status").winbar(0)
			if w ~= "" then
				vim.wo.winbar = w
			end
		end
		vim.api.nvim_create_autocmd("BufWinEnter", {
			group = group,
			callback = apply_winbar,
		})
		vim.api.nvim_create_autocmd("User", {
			group = group,
			pattern = "PRCommentsRefreshed",
			callback = function()
				-- Refresh winbar across all visible windows.
				for _, win in ipairs(vim.api.nvim_list_wins()) do
					local b = vim.api.nvim_win_get_buf(win)
					vim.api.nvim_win_call(win, function()
						local bufname = vim.api.nvim_buf_get_name(b)
						local prov = require("pr.provider").get_provider()
						if prov.git_root and prov.git_root ~= "" and bufname:sub(1, #prov.git_root) == prov.git_root then
							local w = require("pr.status").winbar(b)
							if w ~= "" then
								vim.wo[win].winbar = w
							end
						end
					end)
				end
			end,
		})
	end

	if config.opts.auto_refresh and config.opts.auto_refresh.on_branch_change then
		local group = vim.api.nvim_create_augroup("PRAutoRefresh", { clear = true })
		vim.api.nvim_create_autocmd({ "FocusGained", "DirChanged" }, {
			group = group,
			callback = check_branch_and_refresh,
		})
		-- Seed last_branch so the first FocusGained doesn't refresh spuriously.
		get_current_branch(function(branch)
			last_branch = branch
		end)
		-- Seed last_git_root so the first DirChanged doesn't trigger a spurious reset.
		get_git_root_async(function(root)
			last_git_root = root
		end)
		-- Seed last_head so the first BufWritePost doesn't trigger a spurious refresh.
		Job:new({
			command = "git",
			args = { "rev-parse", "HEAD" },
			on_exit = vim.schedule_wrap(function(j, code)
				if code == 0 then
					local r = j:result()
					local t = r and r[1]
					if t then
						last_head = (t or ""):gsub("%s+$", "")
					end
				end
			end),
		}):start()
	end

	if config.opts.auto_refresh and config.opts.auto_refresh.on_head_change then
		vim.api.nvim_create_autocmd("BufWritePost", {
			group = vim.api.nvim_create_augroup("PRHeadChange", { clear = true }),
			callback = function(args)
				if not (comment.enabled or hunk.enabled) then
					return
				end
				-- Only react to writes inside the PR's working tree. Saving a buffer
				-- in an unrelated repo would otherwise run `git rev-parse HEAD` in
				-- that repo's directory and trip a spurious "HEAD changed" notify.
				local root = git.git_root
				if root == "" then
					return
				end
				local saved_path = args.file or vim.api.nvim_buf_get_name(args.buf or 0)
				if saved_path == "" or saved_path:sub(1, #root) ~= root then
					return
				end
				Job:new({
					command = "git",
					args = { "-C", root, "rev-parse", "HEAD" },
					on_exit = vim.schedule_wrap(function(j, code)
						if code ~= 0 then
							return
						end
						local result = j:result()
						local _, t = next(result)
						if not t then
							return
						end
						local new_head = (t or ""):gsub("%s+$", "")
						if last_head and new_head ~= last_head then
							vim.notify("HEAD changed (" .. last_head:sub(1, 7) .. " → " .. new_head:sub(1, 7) .. "), refreshing PR data…")
							-- HEAD rotated, so cached HEAD content is stale.
							require("pr.drift").invalidate_all()
							M.refresh({ show_diff = false })
						end
						last_head = new_head
					end),
				}):start()
			end,
		})
	end

	if config.opts.auto_refresh then
		M.set_refresh_interval(config.opts.auto_refresh.interval)
	end
end

--- Invalidate cached comments + hunks (and PR number, in case the branch changed)
--- and redraw all attached windows for whichever features are currently enabled.
---@param opts? { show_diff?: boolean }
function M.refresh(opts)
	if type(git.clear_pr_number) == "function" then
		git.clear_pr_number()
	end
	if type(git.clear_pr_list) == "function" then
		git.clear_pr_list()
	end
	if type(git.clear_pr_metadata) == "function" then
		git.clear_pr_metadata()
	end
	if type(git.clear_checks) == "function" then
		git.clear_checks()
	end
	if type(git.clear_pending_review) == "function" then
		git.clear_pending_review()
	end
	pcall(function()
		require("pr.drift").invalidate_all()
	end)
	comment.refresh(opts)
	hunk.refresh()
end

-- Run setup when the module is loaded
-- M.setup()

M.cycle_comments_in_buffer = comment.cycle_comments_in_buffer
M.cycle_hunks_in_buffer = hunk.cycle_hunks_in_buffer
M.comment = comment.comment
M.comment_with_suggestion = require("pr.suggestion").comment_with_suggestion
M.attach_comment = comment.attach
M.attach_hunk = hunk.attach
M.toggle_hunks = hunk.toggle
M.toggle_comments = comment.toggle
M._check_branch_and_refresh = check_branch_and_refresh
M.status = function()
	return require("pr.status").compute()
end
M.winbar = function(bufnr)
	return require("pr.status").winbar(bufnr)
end

return M
