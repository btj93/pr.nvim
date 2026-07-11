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
			-- The fixture MUST be single-line: get_comments decodes only the
			-- first stdout line of the graphql response.
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

		-- Thread-level fields normalized straight off the fixture nodes.
		assert.equals("T1", threads[1].id)
		assert.is_false(threads[1].is_resolved)

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
		-- clear_comments leaves pr_number cached, so no second `gh pr view`.
		assert.equals(1, #calls_with("gh", "view"))
	end)

	-- Join argv with the field separator so header/endpoint substrings can be
	-- probed with plain `find`; no argv token carries a \31 byte.
	local function join(argv)
		return table.concat(argv, "\31")
	end

	-- Every notification message emitted so far, one per capture.
	local function notify_msgs()
		local out = {}
		for _, n in ipairs(notifications) do
			out[#out + 1] = n.msg
		end
		return out
	end

	it("reply sends a clean Accept header and correct endpoint", function()
		-- Seed caches directly so the reply chain skips the git/gh routing jobs.
		gh.repo_info = { owner = "acme", repo = "widget" }
		gh.pr_number = 42
		shim.stub("gh", { { match = { "api", "--method", "POST" }, stdout = "{}" } })

		local done = false
		gh.reply(1001, "hello", function()
			done = true
		end)
		wait_for(function()
			return done
		end, "reply cb")

		local argv = shim.calls("gh")[1]
		local joined = join(argv)
		assert.truthy(joined:find("Accept: application/vnd.github+json", 1, true))
		assert.is_nil(joined:find("'Accept", 1, true), "header must not carry literal quotes")
		assert.truthy(joined:find("/repos/acme/widget/pulls/42/comments/1001/replies", 1, true))
		assert_flag_pair(argv, "-f", "body=hello")
	end)

	it("comment posts a clean Accept header, endpoint, and field pairs", function()
		gh.repo_info = { owner = "acme", repo = "widget" }
		gh.pr_number = 42
		-- get_commit_hash runs a real `git rev-parse HEAD` in the temp repo;
		-- git is never shimmed, so the commit_id resolves to a live sha.
		shim.stub("gh", { { match = { "api", "--method", "POST" }, stdout = "{}" } })

		local done = false
		gh.comment("lua/a.lua", 1, 3, "note body", function()
			done = true
		end)
		wait_for(function()
			return done
		end, "comment cb")

		local argv = shim.calls("gh")[1]
		local joined = join(argv)
		assert.truthy(joined:find("Accept: application/vnd.github+json", 1, true))
		assert.is_nil(joined:find("'Accept", 1, true), "header must not carry literal quotes")
		assert.truthy(joined:find("/repos/acme/widget/pulls/42/comments", 1, true))
		assert_flag_pair(argv, "-f", "body=note body")
		assert_flag_pair(argv, "-f", "path=lua/a.lua")
		assert_flag_pair(argv, "-F", "start_line=1")
		assert_flag_pair(argv, "-f", "start_side=RIGHT")
		assert_flag_pair(argv, "-F", "line=3")
		assert_flag_pair(argv, "-f", "side=RIGHT")
		-- commit_id carries the live sha; assert only the flag pairing exists.
		assert.truthy(joined:find("\31-f\31commit_id=", 1, true), "commit_id must follow a -f flag")
	end)

	it("edit_comment PATCHes with a clean Accept header and endpoint", function()
		gh.repo_info = { owner = "acme", repo = "widget" }
		shim.stub("gh", { { match = { "api", "--method", "PATCH" }, stdout = "{}" } })

		local done = false
		gh.edit_comment(1001, "updated body", function()
			done = true
		end)
		wait_for(function()
			return done
		end, "edit_comment cb")

		local argv = shim.calls("gh")[1]
		local joined = join(argv)
		assert.truthy(joined:find("Accept: application/vnd.github+json", 1, true))
		assert.is_nil(joined:find("'Accept", 1, true), "header must not carry literal quotes")
		assert.truthy(joined:find("/repos/acme/widget/pulls/comments/1001", 1, true))
		assert_flag_pair(argv, "--method", "PATCH")
		assert_flag_pair(argv, "-f", "body=updated body")
	end)

	it("delete_comment DELETEs with a clean Accept header and endpoint", function()
		gh.repo_info = { owner = "acme", repo = "widget" }
		shim.stub("gh", { { match = { "api", "--method", "DELETE" }, stdout = "{}" } })

		local done = false
		gh.delete_comment(1001, function()
			done = true
		end)
		wait_for(function()
			return done
		end, "delete_comment cb")

		local argv = shim.calls("gh")[1]
		local joined = join(argv)
		assert.truthy(joined:find("Accept: application/vnd.github+json", 1, true))
		assert.is_nil(joined:find("'Accept", 1, true), "header must not carry literal quotes")
		assert.truthy(joined:find("/repos/acme/widget/pulls/comments/1001", 1, true))
		assert_flag_pair(argv, "--method", "DELETE")
	end)

	it("remove_reaction DELETEs the reaction and logs no inspect dump", function()
		gh.repo_info = { owner = "acme", repo = "widget" }
		shim.stub("gh", { { match = { "api", "--method", "DELETE" }, stdout = "{}" } })

		local done = false
		gh.remove_reaction(1001, 555, function()
			done = true
		end)
		wait_for(function()
			return done
		end, "remove_reaction cb")

		local argv = shim.calls("gh")[1]
		local joined = join(argv)
		assert.truthy(joined:find("/repos/acme/widget/pulls/comments/1001/reactions/555", 1, true))
		assert_flag_pair(argv, "--method", "DELETE")
		-- No leftover debug notify: a vim.inspect(args) dump renders as a table
		-- literal, so no notification may start with `{`.
		for _, msg in ipairs(notify_msgs()) do
			assert.is_nil(tostring(msg):find("^%s*{"), "unexpected inspect-dump notification: " .. tostring(msg))
		end
	end)

	it("resolve_thread runs the graphql mutation with a threadId pair", function()
		shim.stub("gh", { { match = { "api", "graphql" }, stdout = "{}" } })

		local done = false
		gh.resolve_thread("T1", function()
			done = true
		end)
		wait_for(function()
			return done
		end, "resolve_thread cb")

		local argv = shim.calls("gh")[1]
		local joined = join(argv)
		assert_flag_pair(argv, "-f", "threadId=T1")
		assert.truthy(joined:find("resolveReviewThread", 1, true), "mutation name must be in the query arg")
	end)

	it("unresolve_thread runs the graphql mutation with a threadId pair", function()
		shim.stub("gh", { { match = { "api", "graphql" }, stdout = "{}" } })

		local done = false
		gh.unresolve_thread("T1", function()
			done = true
		end)
		wait_for(function()
			return done
		end, "unresolve_thread cb")

		local argv = shim.calls("gh")[1]
		local joined = join(argv)
		assert_flag_pair(argv, "-f", "threadId=T1")
		assert.truthy(joined:find("unresolveReviewThread", 1, true), "mutation name must be in the query arg")
	end)

	it("get_git_user calls exactly `api user -q .login`", function()
		shim.stub("gh", { { match = { "api", "user" }, stdout = "octocat\n" } })

		local user
		gh.get_git_user(function(u)
			user = u
		end)
		wait_for(function()
			return user ~= nil
		end, "get_git_user cb")

		assert.equals("octocat", user)
		-- Full argv equality: no stray flags, no dead options bleeding into argv.
		assert.same({ "api", "user", "-q", ".login" }, shim.calls("gh")[1])
	end)
end)
