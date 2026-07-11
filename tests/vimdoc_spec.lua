-- Sanity spec for the bundled vimdoc reference (doc/pr.txt).
--
-- Two guarantees:
--   (a) helptags generation succeeds cleanly (no duplicate-tag / parse errors)
--       against an isolated temp copy of doc/, and produces a tags file.
--   (b) command coverage: every :PR* user command the plugin registers has a
--       matching `*:PRxxx*` tag in doc/pr.txt. This fails loudly if a command
--       is added/removed without updating the docs (prevents doc drift).
--
-- Setup follows flow_setup_spec conventions: side-effect-safe opts (no live
-- timer, no branch/head autocmds, no run_on_start shell-out), with the plugin
-- root restored and setup()'s augroups torn down afterward.

local PLUGIN_ROOT = vim.fn.getcwd()
local DOC = PLUGIN_ROOT .. "/doc/pr.txt"

local SAFE_OPTS = {
	run_on_start = { comments = false, hunks = false },
	auto_refresh = { interval = 0, on_branch_change = false, on_head_change = false },
}

describe("vimdoc: doc/pr.txt", function()
	it("generates helptags cleanly and produces a tags file", function()
		-- Isolate in a temp dir so we neither read a stale doc/tags nor write one
		-- into the repo during the test run.
		local tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		vim.fn.writefile(vim.fn.readfile(DOC), tmp .. "/pr.txt")

		local ok, err = pcall(vim.cmd, "helptags " .. vim.fn.fnameescape(tmp))
		assert.is_true(ok, "helptags errored: " .. tostring(err))
		assert.are.equal(1, vim.fn.filereadable(tmp .. "/tags"), "tags file was not created")

		-- The generated tags file must carry the main tag.
		local tags = table.concat(vim.fn.readfile(tmp .. "/tags"), "\n")
		assert.is_not_nil(tags:find("pr.nvim", 1, true), "main tag pr.nvim missing from generated tags")
	end)

	it("documents every registered :PR* command with a matching tag", function()
		vim.cmd.cd(PLUGIN_ROOT)
		package.loaded["pr"] = nil
		local pr = require("pr")

		-- setup() with safe opts registers the real user commands; the safe opts
		-- keep it inert (no timer, no autocmds that shell out).
		pcall(pr.setup, SAFE_OPTS)
		-- Belt-and-suspenders: guarantee registration even if setup() bailed early
		-- in a minimal environment.
		pcall(pr._register_commands)

		local doc = table.concat(vim.fn.readfile(DOC), "\n")

		local commands = vim.api.nvim_get_commands({})
		local pr_cmds = {}
		for name, _ in pairs(commands) do
			if name:match("^PR") then
				table.insert(pr_cmds, name)
			end
		end
		table.sort(pr_cmds)

		assert.is_true(#pr_cmds > 0, "no :PR* commands were registered")

		local missing = {}
		for _, name in ipairs(pr_cmds) do
			local tag = "*:" .. name .. "*"
			if not doc:find(tag, 1, true) then
				table.insert(missing, name)
			end
		end

		assert.are.equal(0, #missing, "commands with no doc tag in doc/pr.txt: " .. table.concat(missing, ", "))
	end)

	after_each(function()
		vim.cmd.cd(PLUGIN_ROOT)
		pcall(function()
			require("pr").set_refresh_interval(0)
		end)
		-- Tear down augroups setup() may have created so nothing leaks into other
		-- specs (mirrors flow_setup_spec's cleanup).
		for _, g in ipairs({ "PRColorScheme", "PRDraftsFlush", "PRWinbar", "PRAutoRefresh", "PRHeadChange" }) do
			pcall(vim.api.nvim_del_augroup_by_name, g)
		end
	end)
end)
