-- Exercises the real github provider (pr.providers.github) end-to-end against
-- the cli_shim fake `gh` + a real temp git repo. The provider's async getter
-- chains (plenary.job) are driven by predicate waits over vim.wait; git is
-- never shimmed, so `git remote get-url origin` parses acme/widget from the
-- fabricated remote.
local cli_shim = require("helpers.cli_shim")
local git_repo = require("helpers.git_repo")

-- Resolve the fixture dir from this file's own path so it survives the cwd
-- changing into the temp repo mid-test.
-- `:p` is resolved at module-load time (cwd is still the project root here),
-- so FIXTURES is absolute and survives the per-test cd into the temp repo.
local this_file = debug.getinfo(1, "S").source:sub(2)
local FIXTURES = vim.fn.fnamemodify(this_file, ":p:h") .. "/fixtures/github"

describe("github provider through real CLI plumbing", function()
	local shim, repo, gh, saved_cwd, saved_notify, notifications

	-- Shared route: `gh pr view --json number --jq .number` resolves the PR
	-- number for every chain that needs it.
	local PR_VIEW_NUMBER = { match = { "pr", "view", "--json", "number" }, stdout = "42\n" }

	before_each(function()
		saved_cwd = vim.fn.getcwd()
		notifications = {}
		saved_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end
		package.loaded["pr.providers.github"] = nil
		gh = require("pr.providers.github")
		repo = git_repo.create({
			origin = "git@github.com:acme/widget.git",
			files = { ["lua/a.lua"] = { "line 1", "line 2", "line 3" } },
		})
		vim.cmd.cd(repo.root)
		shim = cli_shim.new()
		shim.install()
	end)

	after_each(function()
		pcall(vim.cmd.cd, saved_cwd)
		vim.notify = saved_notify
		pcall(function()
			shim.uninstall()
		end)
		pcall(function()
			repo.cleanup()
		end)
		package.loaded["pr.providers.github"] = nil
	end)

	local function wait_for(pred, label)
		assert(vim.wait(4000, pred, 10), "timeout: " .. label)
	end

	-- Every argv logged for `name` whose entries contain `needle`.
	local function calls_with(name, needle)
		local out = {}
		for _, argv in ipairs(shim.calls(name)) do
			if vim.tbl_contains(argv, needle) then
				table.insert(out, argv)
			end
		end
		return out
	end

	-- Assert that `value` appears in argv immediately preceded by `flag`
	-- (i.e. `-F owner=acme` is logged as two adjacent argv entries).
	local function assert_flag_pair(argv, flag, value)
		for i, v in ipairs(argv) do
			if v == value then
				assert.equals(flag, argv[i - 1], value .. " should be preceded by " .. flag)
				return
			end
		end
		assert(false, "value not found in argv: " .. value)
	end

	it("get_pr_number resolves via gh pr view --jq and caches", function()
		shim.stub("gh", { PR_VIEW_NUMBER })

		local n1
		gh.get_pr_number(function(n)
			n1 = n
		end)
		wait_for(function()
			return n1 ~= nil
		end, "first get_pr_number")

		local n2
		gh.get_pr_number(function(n)
			n2 = n
		end)
		wait_for(function()
			return n2 ~= nil
		end, "second get_pr_number")

		assert.equals(42, n1)
		assert.equals(42, n2)
		-- fetch-once: the second call short-circuits on the cached number, so
		-- only a single `gh` invocation ever happened.
		assert.equals(1, #shim.calls("gh"))
	end)

	it("get_comments runs the full chain and normalizes", function()
		shim.stub("gh", {
			PR_VIEW_NUMBER,
			{ match = { "api", "graphql" }, stdout_file = FIXTURES .. "/review_threads.json" },
		})

		local comments
		gh.get_comments(function(c)
			comments = c
		end)
		wait_for(function()
			return comments ~= nil
		end, "get_comments")

		-- Comments keyed by relative path with two normalized threads.
		assert.is_not_nil(comments["lua/a.lua"])
		local threads = comments["lua/a.lua"]
		assert.equals(2, #threads)

		assert.equals("alice", threads[1].comments[1].author)
		assert.equals(1, threads[1].comments[1].start_line)
		assert.equals(1, threads[1].comments[1].end_line)

		assert.equals("bob", threads[2].comments[1].author)
		assert.equals(3, threads[2].comments[1].start_line)
		assert.equals(3, threads[2].comments[1].end_line)

		-- The graphql argv carries -F owner/name/prNumber parsed from the
		-- fabricated remote (git@github.com:acme/widget.git) + PR 42.
		local gql = calls_with("gh", "graphql")
		assert.equals(1, #gql)
		local argv = gql[1]
		assert_flag_pair(argv, "-F", "owner=acme")
		assert_flag_pair(argv, "-F", "name=widget")
		assert_flag_pair(argv, "-F", "prNumber=42")
	end)

	it("get_hunks parses gh pr diff", function()
		shim.stub("gh", {
			PR_VIEW_NUMBER,
			{ match = { "pr", "diff" }, stdout_file = FIXTURES .. "/pr_diff.txt" },
		})

		local hunks
		gh.get_hunks(function(h)
			hunks = h
		end)
		wait_for(function()
			return hunks ~= nil
		end, "get_hunks")

		-- Fixture inserts one line after "line 2"; parse yields a single Add
		-- hunk on the new-file line 3.
		assert.same({
			["lua/a.lua"] = { { hunk_start = 3, hunk_end = 3, type = "Add" } },
		}, hunks)
	end)

	it("get_base_sha via --jq .baseRefOid surfaces the sha", function()
		local sha = "1234567890abcdef1234567890abcdef12345678"
		shim.stub("gh", {
			{ match = { "pr", "view", "--json", "baseRefOid" }, stdout = sha .. "\n" },
		})

		local got
		gh.get_base_sha(function(s)
			got = s
		end)
		wait_for(function()
			return got ~= nil and got ~= ""
		end, "get_base_sha")

		assert.equals(sha, got)
		assert.equals(40, #got)
	end)

	it("clear_comments invalidates: refetch spawns a new graphql job", function()
		shim.stub("gh", {
			PR_VIEW_NUMBER,
			{ match = { "api", "graphql" }, stdout_file = FIXTURES .. "/review_threads.json" },
		})

		local first
		gh.get_comments(function(c)
			first = c
		end)
		wait_for(function()
			return first ~= nil
		end, "first get_comments")
		assert.equals(1, #calls_with("gh", "graphql"))

		gh.clear_comments()

		local second
		gh.get_comments(function(c)
			second = c
		end)
		wait_for(function()
			return second ~= nil
		end, "second get_comments")

		-- The cleared cache forces a fresh graphql job; repo_info + pr_number
		-- stay cached, so only the graphql call count grows 1 -> 2.
		assert.equals(2, #calls_with("gh", "graphql"))
	end)
end)
