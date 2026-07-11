-- Headless UI environment for mount-based flow specs: big editor, captured
-- notifications, non-blocking stand-ins for every interactive prompt, and
-- temp-file redirection for anything that would touch stdpath('data').
--
-- vim.fn.confirm is stubbed by plain assignment: verified working (and cleanly
-- restorable) on this Neovim build, so the vim.fn metatable fallback the brief
-- names is unnecessary. If a future build regresses, intercept via a __index
-- shim on getmetatable(vim.fn) here.
local M = {}

-- opts is reserved for future per-spec overrides (unused today; the ignore-212
-- luacheck rule covers the unused argument).
function M.setup(opts) -- luacheck: no unused args
	local env = { notifications = {}, opened_urls = {}, confirm_choice = 0, select_choice = 1 }
	local saved = {
		notify = vim.notify,
		select = vim.ui.select,
		open = vim.ui.open,
		confirm = vim.fn.confirm,
		columns = vim.o.columns,
		lines = vim.o.lines,
	}

	vim.o.columns = 220
	vim.o.lines = 60

	vim.notify = function(msg, level)
		table.insert(env.notifications, { msg = msg, level = level })
	end
	vim.ui.select = function(items, _, on_choice)
		local idx = env.select_choice
		if type(idx) == "function" then
			for i, item in ipairs(items) do
				if idx(item) then
					on_choice(item, i)
					return
				end
			end
			on_choice(nil, nil)
			return
		end
		on_choice(items[idx], idx)
	end
	vim.ui.open = function(url)
		table.insert(env.opened_urls, url)
		return nil
	end
	vim.fn.confirm = function()
		return env.confirm_choice
	end

	pcall(function()
		require("pr.drafts")._set_path(vim.fn.tempname())
	end)
	pcall(function()
		require("pr.review_local")._set_path(vim.fn.tempname())
	end)

	function env.feed(keys)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "mx", false)
	end

	function env.wait_for(pred, ms, label)
		local ok = vim.wait(ms or 2000, pred, 10)
		assert(ok, "wait_for timed out" .. (label and (": " .. label) or ""))
	end

	function env.floats()
		local out = {}
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(win).relative ~= "" then
				table.insert(out, win)
			end
		end
		return out
	end

	function env.teardown()
		vim.notify = saved.notify
		vim.ui.select = saved.select
		vim.ui.open = saved.open
		vim.fn.confirm = saved.confirm
		vim.o.columns = saved.columns
		vim.o.lines = saved.lines
		for _, win in ipairs(env.floats()) do
			pcall(vim.api.nvim_win_close, win, true)
		end
		vim.cmd("silent! %bwipeout!")
	end

	return env
end

return M
