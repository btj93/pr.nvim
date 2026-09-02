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
	local shim, repo, gh, saved_cwd, saved_notify, notifications, saved_debug

	-- Shared route: `gh pr view --json number --jq .number` resolves the PR
	-- number for every chain that needs it.
	local PR_VIEW_NUMBER = { match = { "pr", "view", "--json", "number" }, stdout = "42\n" }

	before_each(function()
		saved_cwd = vim.fn.getcwd()
		saved_debug = require("pr.config").opts.debug
		require("pr.config").opts.debug = false
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
		require("pr.config").opts.debug = saved_debug
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

	it("failed reply diagnostics do not expose the review body or raw argv", function()
		local private_body = "GITHUB PRIVATE REVIEW BODY"

		local function run_failed_reply()
			gh.repo_info = { owner = "acme", repo = "widget" }
			gh.pr_number = 42
			shim.stub("gh", {
				{ match = { "api", "--method", "POST" }, exit = 1, stderr = "request rejected: " .. private_body },
			})
			local done
			gh.reply(1001, private_body, function(ok)
				done = ok
			end)
			wait_for(function()
				return done ~= nil
			end, "failed reply cb")
			assert.is_false(done)
			return table.concat(notify_msgs(), "\n")
		end

		local normal = run_failed_reply()
		assert.truthy(normal:find("Is a gh cli installed?", 1, true))
		assert.is_nil(normal:find(private_body, 1, true))
		assert.is_nil(normal:find("body=", 1, true))

		notifications = {}
		require("pr.config").opts.debug = true
		local debugged = run_failed_reply()
		assert.truthy(debugged:find("Is a gh cli installed?", 1, true))
		assert.truthy(debugged:find("body=<redacted>", 1, true))
		assert.is_nil(debugged:find(private_body, 1, true))
	end)

	it("a failed review-thread fetch exposes neither the GraphQL document nor the response body", function()
		require("pr.config").opts.debug = true
		shim.stub("gh", {
			PR_VIEW_NUMBER,
			{
				match = { "api", "graphql" },
				exit = 1,
				stdout = '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"comments":{"nodes":[{"body":"LEAKED THREAD BODY"}]}}]}}}}}',
				stderr = "GraphQL: rate limit exceeded",
			},
		})

		-- get_comments' failure branch returns WITHOUT invoking the callback
		-- (github.lua:557) -- a fetch-lifecycle bug owned by the next slice of
		-- the spec, not this one. So wait on the notification, not a callback
		-- that never fires.
		gh.get_comments(function() end)
		wait_for(function()
			for _, m in ipairs(notify_msgs()) do
				if tostring(m):find("Is a gh cli installed?", 1, true) then
					return true
				end
			end
			return false
		end, "review-thread fetch failure notification")

		local out = table.concat(notify_msgs(), "\n")
		assert.truthy(out:find("query=<redacted>", 1, true))
		assert.is_nil(out:find("LEAKED THREAD BODY", 1, true))
		assert.is_nil(out:find("reviewThreads", 1, true))
	end)

	it("a failed review submission redacts the error string handed to its caller", function()
		gh.repo_info = { owner = "acme", repo = "widget" }
		gh.pr_number = 42
		local private_body = "UNPUBLISHED REVIEW SUMMARY"
		-- submit_review uses `-X POST`, NOT `--method POST` (github.lua:1558-1559),
		-- and formats review_id with %d, so the id must be a number.
		shim.stub("gh", {
			{ match = { "api", "/reviews/", "-X", "POST" }, exit = 1, stderr = "422 Unprocessable: " .. private_body },
		})

		local ok, err
		gh.submit_review(7, "APPROVE", private_body, function(o, e)
			ok, err = o, e
		end)
		wait_for(function()
			return ok ~= nil
		end, "submit_review cb")

		assert.is_false(ok)
		-- review.lua:47 renders this straight into "Submit failed: <err>".
		assert.is_nil(err:find(private_body, 1, true))
		assert.truthy(err:find("<redacted>", 1, true))
	end)

	it("a failed PR metadata update redacts both title and body out of the caller's error", function()
		gh.pr_number = 42
		local private_title = "SECRET RELEASE CODENAME"
		local private_body = "UNPUBLISHED PR DESCRIPTION"

		-- `gh pr edit` echoes the rejected fields back on stderr; pr_info.lua:69
		-- renders whatever reaches the callback into "Update failed: <err>".
		-- The echo is deliberately prose, NOT `title=x body=y`: redact_text's
		-- standing `body=` end-of-line pattern would scrub a `body=` form on its
		-- own and the assertions below would hold no matter what secrets argument
		-- the provider passed, making this test vacuous.
		local function run_failed_edit(fields)
			shim.stub("gh", {
				{
					match = { "pr", "edit" },
					exit = 1,
					stderr = "422 Validation Failed: " .. private_title .. " / " .. private_body,
				},
			})
			local ok, err
			gh.update_pr_metadata(fields, function(o, e)
				ok, err = o, e
			end)
			wait_for(function()
				return ok ~= nil
			end, "update_pr_metadata cb")
			assert.is_false(ok)
			return err
		end

		-- Body-only is the discriminating case: a `{ fields.title, fields.body }`
		-- literal truncates at index 1 under ipairs when title is nil, so the body
		-- would survive. log.payload_secrets(fields) is key-based and does not.
		local body_only = run_failed_edit({ body = private_body })
		assert.is_nil(body_only:find(private_body, 1, true))
		assert.truthy(body_only:find("<redacted>", 1, true))

		local both = run_failed_edit({ title = private_title, body = private_body })
		assert.is_nil(both:find(private_title, 1, true))
		assert.is_nil(both:find(private_body, 1, true))
		assert.truthy(both:find("<redacted>", 1, true))
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

	it("list_prs('mine') passes --author @me, normalizes, and caches per filter", function()
		local prs_json = vim.json.encode({
			{
				number = 101,
				title = "feat: alpha",
				author = { login = "alice" },
				state = "OPEN",
				headRefName = "alpha",
				url = "https://github.com/acme/widget/pull/101",
				updatedAt = "2026-01-01T00:00:00Z",
				isDraft = false,
			},
			{
				number = 202,
				title = "fix: beta",
				author = { login = "bob" },
				state = "OPEN",
				headRefName = "beta",
				url = "https://github.com/acme/widget/pull/202",
				updatedAt = "2026-01-02T00:00:00Z",
				isDraft = false,
			},
		})
		shim.stub("gh", { { match = { "pr", "list" }, stdout = prs_json } })

		local prs1
		gh.list_prs("mine", function(p)
			prs1 = p
		end)
		wait_for(function()
			return prs1 ~= nil
		end, "list_prs mine first")

		-- `--author @me` is logged as two adjacent argv tokens.
		local argv = shim.calls("gh")[1]
		assert_flag_pair(argv, "--author", "@me")

		-- The 2-PR fixture is normalized straight through to the callback.
		assert.equals(2, #prs1)
		assert.equals(101, prs1[1].number)
		assert.equals("feat: alpha", prs1[1].title)
		assert.equals(202, prs1[2].number)
		assert.equals("fix: beta", prs1[2].title)

		-- A second "mine" call short-circuits on the per-filter cache: no new gh run.
		local prs2
		gh.list_prs("mine", function(p)
			prs2 = p
		end)
		wait_for(function()
			return prs2 ~= nil
		end, "list_prs mine second")
		assert.equals(1, #shim.calls("gh"))
	end)

	it("list_prs('review-requested') passes the --search query token", function()
		shim.stub("gh", { { match = { "pr", "list" }, stdout = "[]" } })

		local prs
		gh.list_prs("review-requested", function(p)
			prs = p
		end)
		wait_for(function()
			return prs ~= nil
		end, "list_prs review-requested")

		-- The whole search expression is a single argv token following --search.
		local argv = shim.calls("gh")[1]
		assert_flag_pair(argv, "--search", "review-requested:@me state:open")
		assert.equals(0, #prs)
	end)

	it("checkout_pr runs `gh pr checkout N`, invokes checktime, and reports success", function()
		shim.stub("gh", { { match = { "pr", "checkout", "7" } } })

		-- Spy vim.cmd so we can prove the success path ran `checktime` (its buffer
		-- reload) without staging an on-disk change.
		local saved_cmd = vim.cmd
		local checktime_called = false
		vim.cmd = function(c)
			if c == "checktime" then
				checktime_called = true
			end
			return saved_cmd(c)
		end

		local success, err_val, done
		gh.checkout_pr(7, function(ok, err)
			success, err_val, done = ok, err, true
		end)

		-- Run the wait + asserts under pcall: wait_for raises on timeout, so an
		-- unguarded failure here would leave vim.cmd wrapped and break after_each's
		-- cd. Restore unconditionally, then re-raise the captured error.
		local pok, perr = pcall(function()
			wait_for(function()
				return done
			end, "checkout_pr cb")

			assert.is_true(success)
			assert.is_nil(err_val)
			assert.is_true(checktime_called)
			-- Exact argv: no stray tokens leak into `gh pr checkout`.
			assert.same({ "pr", "checkout", "7" }, shim.calls("gh")[1])
			-- The success path emits no error notification.
			assert.equals(0, #notifications)
		end)
		vim.cmd = saved_cmd
		if not pok then
			error(perr, 0)
		end
	end)

	it("get_pr_number surfaces the install hint on unexpected gh output", function()
		-- gh exits 0 but yields a non-numeric line: this is the get_pr_number
		-- failure branch that carries the literal "Is a gh cli installed?" hint
		-- (github.lua's exit != 0 branch reports "No PR open" instead -- see the
		-- companion test below).
		shim.stub("gh", { { match = { "pr", "view" }, stdout = "garbage\n" } })

		gh.get_pr_number(function() end)
		wait_for(function()
			return #notifications > 0
		end, "install-hint notification")

		local found = false
		for _, m in ipairs(notify_msgs()) do
			if tostring(m):find("Is a gh cli installed?", 1, true) then
				found = true
			end
		end
		assert.is_true(found, "expected the install hint in a notification")
	end)

	it("get_pr_number reports 'No PR open' when gh exits non-zero", function()
		-- A non-zero `gh pr view` is the ordinary no-PR-for-branch case, reported
		-- with the branch message rather than the install hint.
		shim.stub("gh", { { match = { "pr", "view" }, exit = 1 } })

		gh.get_pr_number(function() end)
		wait_for(function()
			return #notifications > 0
		end, "no-PR notification")

		local found = false
		for _, m in ipairs(notify_msgs()) do
			if tostring(m):find("No PR open for this branch", 1, true) then
				found = true
			end
		end
		assert.is_true(found, "expected the no-PR notification")
	end)

	it("caches an empty comments result instead of refetching", function()
		shim.stub("gh", {
			PR_VIEW_NUMBER,
			{ match = { "api", "graphql" }, stdout = '{"data":{"repository":{"pullRequest":{"reviewThreads":{"edges":[]}}}}}' },
		})

		local first, second
		gh.get_comments(function(c)
			first = c
		end)
		wait_for(function()
			return first ~= nil
		end, "first get_comments")
		gh.get_comments(function(c)
			second = c
		end)
		wait_for(function()
			return second ~= nil
		end, "second get_comments")

		assert.same({}, first)
		assert.same({}, second)

		local function graphql_calls()
			local n = 0
			for _, argv in ipairs(shim.calls("gh")) do
				if table.concat(argv, " "):find("graphql", 1, true) then
					n = n + 1
				end
			end
			return n
		end

		-- Cached: an empty result that refetched would issue a second graphql call.
		assert.equals(1, graphql_calls())

		-- ...and invalidation makes the NEXT call fetch again (spec line 209).
		gh.clear_comments()
		local third
		gh.get_comments(function(c)
			third = c
		end)
		wait_for(function()
			return third ~= nil
		end, "get_comments after clear")
		assert.same({}, third)
		assert.equals(2, graphql_calls())
	end)

	it("caches an empty hunks result and refetches after invalidation", function()
		shim.stub("gh", {
			PR_VIEW_NUMBER,
			{ match = { "pr", "diff" }, stdout = "" },
		})

		local function diff_calls()
			local n = 0
			for _, argv in ipairs(shim.calls("gh")) do
				if table.concat(argv, " "):find("diff", 1, true) then
					n = n + 1
				end
			end
			return n
		end

		local first, second
		gh.get_hunks(function(h)
			first = h
		end)
		wait_for(function()
			return first ~= nil
		end, "first get_hunks")
		gh.get_hunks(function(h)
			second = h
		end)
		wait_for(function()
			return second ~= nil
		end, "second get_hunks")

		assert.same({}, first)
		assert.same({}, second)
		assert.equals(1, diff_calls())

		gh.clear_hunks()
		local third
		gh.get_hunks(function(h)
			third = h
		end)
		wait_for(function()
			return third ~= nil
		end, "get_hunks after clear")
		assert.equals(2, diff_calls())
	end)

	it("coalesces two callers arriving before the fetch completes", function()
		shim.stub("gh", {
			PR_VIEW_NUMBER,
			{ match = { "api", "graphql" }, stdout_file = FIXTURES .. "/review_threads.json" },
		})

		local a, b
		gh.get_comments(function(c)
			a = c
		end)
		gh.get_comments(function(c)
			b = c
		end)
		wait_for(function()
			return a ~= nil and b ~= nil
		end, "both callers settled")

		assert.is_not_nil(a["lua/a.lua"])
		assert.is_not_nil(b["lua/a.lua"])
		local graphql = 0
		for _, argv in ipairs(shim.calls("gh")) do
			if table.concat(argv, " "):find("graphql", 1, true) then
				graphql = graphql + 1
			end
		end
		assert.equals(1, graphql)
	end)

	it("settles the caller with an error instead of hanging when the fetch fails", function()
		shim.stub("gh", {
			PR_VIEW_NUMBER,
			{ match = { "api", "graphql" }, exit = 1, stderr = "rate limit exceeded" },
		})

		local value, err, called = nil, nil, false
		gh.get_comments(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "failed get_comments settles its caller")

		assert.same({}, value)
		assert.is_not_nil(err)
		-- The failure must NOT be cached as a successful empty result.
		assert.same({}, gh.comments)
	end)

	it("clear() returns the fetch coordinator to cold so the next get_comments refetches", function()
		shim.stub("gh", {
			PR_VIEW_NUMBER,
			{ match = { "api", "graphql" }, stdout = '{"data":{"repository":{"pullRequest":{"reviewThreads":{"edges":[]}}}}}' },
		})

		local first
		gh.get_comments(function(c)
			first = c
		end)
		wait_for(function()
			return first ~= nil
		end, "first get_comments")

		-- clear() resets the cache fields directly rather than delegating to
		-- clear_comments/clear_hunks, so it has to invalidate the coordinator
		-- itself or the emptied cache stays "loaded" forever.
		gh.clear()

		local second
		gh.get_comments(function(c)
			second = c
		end)
		wait_for(function()
			return second ~= nil
		end, "get_comments after clear()")

		local graphql = 0
		for _, argv in ipairs(shim.calls("gh")) do
			if table.concat(argv, " "):find("graphql", 1, true) then
				graphql = graphql + 1
			end
		end
		assert.equals(2, graphql)
	end)
end)
