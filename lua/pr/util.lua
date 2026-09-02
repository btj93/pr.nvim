local Job = require("plenary.job")
local log = require("pr.log")

local M = {}

-- `Job:new` validates `command` against `vim.fn.executable` and raises when the
-- CLI is missing (plenary/job.lua:108), at construction rather than in
-- `:start()`, and before any `on_exit` can run. Left unhandled inside a
-- `fetch_state`-owned chain that raise settles nothing, so the resource stays
-- "loading" and every later caller joins a waiter list that never drains.
-- The `pcall` must therefore wrap the construction, not just the `:start()`.
---@param operation string
---@param spec table `Job:new` options (`command`, `args`, `on_exit`, ...)
---@param on_spawn_error fun() Settles the caller the way a failed command does.
function M.start_job(operation, spec, on_spawn_error)
	local ok, err = pcall(function()
		Job:new(spec):start()
	end)
	if ok then
		return
	end
	-- Strip Lua's "<chunk>:<line>: " prefix so the reported cause is the raise's
	-- own message ("gh: Executable not found"), not a plenary source path.
	local cause = tostring(err):match("^.-:%d+: (.*)$") or tostring(err)
	log.command_failed(operation, spec.command, spec.args, cause, { hint = "Is a " .. spec.command .. " cli installed?" })
	on_spawn_error()
end

---
---@param win integer
---@return boolean?
function M.is_float(win)
	local opts = vim.api.nvim_win_get_config(win)
	return opts and opts.relative and opts.relative ~= ""
end

---
---@param win integer
---@return boolean
function M.is_valid_win(win)
	if not vim.api.nvim_win_is_valid(win) then
		return false
	end
	-- avoid E5108 after pressing q:
	if vim.fn.getcmdwintype() ~= "" then
		return false
	end
	-- dont do anything for floating windows
	if M.is_float(win) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	return M.is_valid_buf(buf)
end

---
---@param buf integer
---@return boolean
function M.is_quickfix(buf)
	return vim.api.nvim_get_option_value("buftype", { buf = buf }) == "quickfix"
end

---
---@param buf integer
---@return boolean
function M.is_valid_buf(buf)
	-- Skip special buffers
	local buftype = vim.api.nvim_get_option_value("buftype", { buf = buf })
	if buftype ~= "" and buftype ~= "quickfix" then
		return false
	end
	return true
end

--- Parse unified-diff output (as produced by `git diff`, `gh pr diff`, `glab mr diff`)
--- into a per-file table of contiguous change blocks.
---@param diff_lines table A table of strings, where each string is a line from the diff output.
---@return Hunks A table where keys are filenames and values are lists of Hunk objects.
function M.parse_diff_hunks(diff_lines)
	---@type Hunks
	local hunks_by_file = {}

	local current_file = nil
	local line_num_in_buffer = -1

	local block_start_line = 0
	local block_end_line = 0
	local has_add = false
	local has_del = false

	local function save_current_block()
		if current_file and block_start_line > 0 then
			local final_end_line = block_end_line
			if has_del and not has_add then
				final_end_line = block_start_line
			end

			table.insert(hunks_by_file[current_file], {
				hunk_start = block_start_line,
				hunk_end = final_end_line,
				type = (has_add and has_del and "Change") or (has_del and "Del") or "Add",
			})
		end

		block_start_line = 0
		block_end_line = 0
		has_add = false
		has_del = false
	end

	for _, line in ipairs(diff_lines) do
		local diff_file = line:match("^diff %-%-git a/.+ b/(.+)$")
		if diff_file then
			save_current_block()

			current_file = diff_file
			hunks_by_file[current_file] = {}
			line_num_in_buffer = -1
			goto continue
		end

		if not current_file then
			goto continue
		end

		local start_line_str = line:match("^@@ %-.+ %+([0-9]+)")
		if start_line_str then
			save_current_block()
			line_num_in_buffer = tonumber(start_line_str) - 1
			goto continue
		end

		if line_num_in_buffer >= 0 then
			if line:sub(1, 1) == " " then
				save_current_block()
				line_num_in_buffer = line_num_in_buffer + 1
			elseif line:sub(1, 1) == "+" then
				if block_start_line == 0 then
					block_start_line = line_num_in_buffer + 1
				end
				line_num_in_buffer = line_num_in_buffer + 1
				block_end_line = line_num_in_buffer
				has_add = true
			elseif line:sub(1, 1) == "-" then
				if block_start_line == 0 then
					block_start_line = line_num_in_buffer + 1
				end
				has_del = true
			end
		end
		::continue::
	end

	save_current_block()

	return hunks_by_file
end

-- In-flight set keyed by the eventual scratch buffer name (`pr://<path>@<sha>`).
-- Prevents racing duplicate fetches when the user opens the same deleted-in-PR
-- file twice before the first `git show` completes.
local _inflight_fetches = {}

--- Open a PR-touched file. If the file exists on disk, behaves like `:edit`.
--- If it doesn't (e.g. a file deleted by the PR), fetches the base-commit
--- content via `git show <base>:<relative_path>` and loads it into a
--- read-only scratch buffer named `pr://<path>@<base_sha>`.
---
---@param absolute_path string  Absolute path under the git root.
---@param relative_path string  Path relative to git_root (used for `git show`).
---@param opts? { line?: integer }
function M.open_pr_file(absolute_path, relative_path, opts)
	opts = opts or {}

	local stat = vim.uv.fs_stat(absolute_path)
	if stat and stat.type == "file" then
		vim.cmd("edit " .. vim.fn.fnameescape(absolute_path))
		if opts.line then
			pcall(vim.api.nvim_win_set_cursor, 0, { opts.line, 0 })
		end
		return
	end

	-- File missing on disk — fetch base content.
	local git = require("pr.provider").get_provider()
	git.get_base_sha(vim.schedule_wrap(function(base_sha)
		if not base_sha or base_sha == "" then
			vim.notify("File not on disk and no PR base sha available: " .. relative_path)
			return
		end

		local name = "pr://" .. relative_path .. "@" .. base_sha:sub(1, 7)
		-- If we've already loaded this exact (path, base) pair this session,
		-- just switch to that buffer instead of erroring on duplicate name.
		local existing = vim.fn.bufnr(name)
		if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
			vim.api.nvim_set_current_buf(existing)
			if opts.line then
				pcall(vim.api.nvim_win_set_cursor, 0, { opts.line, 0 })
			end
			return
		end

		if _inflight_fetches[name] then
			return
		end
		_inflight_fetches[name] = true

		Job:new({
			command = "git",
			args = { "-C", git.git_root, "show", base_sha .. ":" .. relative_path },
			on_exit = vim.schedule_wrap(function(j, code)
				_inflight_fetches[name] = nil
				if code ~= 0 then
					vim.notify("File not in PR base commit: " .. relative_path)
					return
				end
				local content = j:result() or {}
				vim.cmd("enew")
				local buf = vim.api.nvim_get_current_buf()
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
				-- Defensive: race between bufnr check above and now. pcall avoids
				-- crashing if a parallel call already grabbed the name.
				pcall(vim.api.nvim_buf_set_name, buf, name)
				vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
				vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
				vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
				vim.api.nvim_set_option_value("modified", false, { buf = buf })
				local ft = vim.filetype.match({ filename = relative_path })
				if ft then
					vim.api.nvim_set_option_value("filetype", ft, { buf = buf })
				end
				if opts.line then
					pcall(vim.api.nvim_win_set_cursor, 0, { opts.line, 0 })
				end
				vim.notify("Opened base-commit content for deleted-in-PR file: " .. relative_path)
			end),
		}):start()
	end))
end

return M
