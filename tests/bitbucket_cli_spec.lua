-- Exercises the real bitbucket provider (pr.providers.bitbucket) end-to-end
-- against the cli_shim fake `curl` + a real temp git repo. The provider's async
-- getter chains (plenary.job) are driven by predicate waits over vim.wait.
--
-- git is NEVER shimmed: `git remote get-url origin` parses acme/widget from the
-- fabricated remote (git@bitbucket.org:acme/widget.git) via
-- bitbucket._parse_remote_url, and checkout_pr runs a REAL `git fetch origin`.
--
-- Local-bare-origin mechanism (see tests/helpers/git_repo.lua bare_origin):
--   bitbucket.checkout_pr runs a REAL `git -C root fetch origin <branch>` +
--   checkout, so origin must be a fetchable path — but repo_info parsing earlier
--   in every other chain needs a bitbucket-SHAPED URL that _parse_remote_url can
--   split into workspace/repo_slug (a bare filesystem path returns nil,nil).
--   Resolution: create the repo with the host-shaped origin so the parse-driven
--   cases (and the checkout test's own get_repo_info) resolve acme/widget, THEN
--   in the checkout test flip origin's URL to the local bare path
--   (repo.set_origin_url) AFTER repo_info is cached, so the real fetch/checkout
--   targets a branch that genuinely lives only in the bare origin.
--
-- stdout decoding: run_curl joins ALL result() lines with "\n" before
-- vim.json.decode, so multi-line JSON fixtures also parse; get_hunks passes the
-- raw result() line list straight to util.parse_diff_hunks. Fixtures are kept
-- compact for parity with the github/gitlab fixtures.
local cli_shim = require("helpers.cli_shim")
local git_repo = require("helpers.git_repo")

-- Resolve the fixture dir from this file's own path so it survives the cwd
-- changing into the temp repo mid-test. `:p` is resolved at module-load time
-- (cwd is still the project root here), so FIXTURES is absolute.
local this_file = debug.getinfo(1, "S").source:sub(2)
local FIXTURES = vim.fn.fnamemodify(this_file, ":p:h") .. "/fixtures/bitbucket"

describe("bitbucket provider through real CLI plumbing", function()
	local shim, repo, bb, saved_cwd, saved_notify, notifications
	local saved_user, saved_pass, saved_debug

	-- get_pr_number filters open PRs by source branch; the fixture resolves to
	-- PR id 5. The URL carries the url-encoded `q=source.branch.name="<branch>"`.
	local PR_NUMBER_QUERY = { match = { "pullrequests?state=OPEN&pagelen=5" }, stdout = '{"values":[{"id":5}]}' }
	-- get_git_user resolves the authed nickname off GET /user.
	local API_USER = { match = { "/user" }, stdout = '{"nickname":"tester"}' }
	-- list_prs("mine") needs the uuid too (author.uuid DSL filter + is_mine).
	local API_USER_UUID = { match = { "/user" }, stdout = '{"nickname":"tester","uuid":"abc-123"}' }
	-- A 2-PR page for list_prs, both authored by `tester` (uuid abc-123). Kept on
	-- a single line so run_curl's vim.json.decode consumes it as one body.
	local LIST_BODY = table.concat({
		'{"values":[',
		'{"id":11,"title":"first pr","state":"OPEN",',
		'"author":{"nickname":"tester","uuid":"abc-123"},',
		'"source":{"branch":{"name":"feat/one"}},',
		'"reviewers":[{"nickname":"bob","uuid":"bob-9"}],',
		'"links":{"html":{"href":"https://bitbucket.org/acme/widget/pull-requests/11"}},',
		'"updated_on":"2024-01-02T00:00:00Z"},',
		'{"id":12,"title":"second pr","state":"OPEN",',
		'"author":{"nickname":"tester","uuid":"abc-123"},',
		'"source":{"branch":{"name":"feat/two"}},',
		'"reviewers":[],',
		'"links":{"html":{"href":"https://bitbucket.org/acme/widget/pull-requests/12"}},',
		'"updated_on":"2024-01-03T00:00:00Z"}',
		"]}",
	})

	before_each(function()
		saved_cwd = vim.fn.getcwd()
		notifications = {}
		saved_notify = vim.notify
		vim.notify = function(msg, level)
			table.insert(notifications, { msg = msg, level = level })
		end

		-- Normalise auth env to "unset" so tests are deterministic regardless of
		-- the host machine; each test opts into setting them. Restored after_each.
		saved_user = vim.env.BITBUCKET_USERNAME
		saved_pass = vim.env.BITBUCKET_APP_PASSWORD
		vim.env.BITBUCKET_USERNAME = nil
		vim.env.BITBUCKET_APP_PASSWORD = nil

		saved_debug = require("pr.config").opts.debug
		require("pr.config").opts.debug = false

		package.loaded["pr.providers.bitbucket"] = nil
		bb = require("pr.providers.bitbucket")
		repo = git_repo.create({
			origin = "git@bitbucket.org:acme/widget.git",
			bare_origin = true,
			files = { ["src/foo.lua"] = { "line 1", "line 2", "line 3" } },
		})
		vim.cmd.cd(repo.root)
		shim = cli_shim.new()
		shim.install()
	end)

	after_each(function()
		pcall(vim.cmd.cd, saved_cwd)
		vim.notify = saved_notify
		vim.env.BITBUCKET_USERNAME = saved_user
		vim.env.BITBUCKET_APP_PASSWORD = saved_pass
		require("pr.config").opts.debug = saved_debug
		pcall(function()
			shim.uninstall()
		end)
		pcall(function()
			repo.cleanup()
		end)
		package.loaded["pr.providers.bitbucket"] = nil
	end)

	local function wait_for(pred, label)
		assert(vim.wait(4000, pred, 10), "timeout: " .. label)
	end

	-- Join argv with the field separator so URL / header substrings can be probed
	-- with plain `find`; no argv token carries a \31 byte.
	local function join(argv)
		return table.concat(argv, "\31")
	end

	-- Assert that `value` appears in argv immediately preceded by `flag`
	-- (i.e. `-u user:pass` is logged as two adjacent argv entries).
	local function assert_flag_pair(argv, flag, value)
		for i, v in ipairs(argv) do
			if v == value then
				assert.equals(flag, argv[i - 1], value .. " should be preceded by " .. flag)
				return
			end
		end
		assert(false, "value not found in argv: " .. value)
	end

	-- Index of the first `curl` invocation whose joined argv contains `needle`.
	local function curl_index(needle)
		for i, argv in ipairs(shim.calls("curl")) do
			if join(argv):find(needle, 1, true) then
				return i
			end
		end
		return nil
	end

	-- Count of `curl` invocations whose joined argv contains `needle`.
	local function curl_count(needle)
		local n = 0
		for _, argv in ipairs(shim.calls("curl")) do
			if join(argv):find(needle, 1, true) then
				n = n + 1
			end
		end
		return n
	end

	-- Every notification message emitted so far.
	local function notify_msgs()
		local out = {}
		for _, n in ipairs(notifications) do
			out[#out + 1] = n.msg
		end
		return out
	end

	it("get_pr_number filters open PRs by the url-encoded source branch and caches", function()
		shim.stub("curl", { PR_NUMBER_QUERY })

		local n1
		bb.get_pr_number(function(n)
			n1 = n
		end)
		wait_for(function()
			return n1 ~= nil
		end, "first get_pr_number")

		local n2
		bb.get_pr_number(function(n)
			n2 = n
		end)
		wait_for(function()
			return n2 ~= nil
		end, "second get_pr_number")

		assert.equals(5, n1)
		assert.equals(5, n2)

		-- The repo is on `main`, so the DSL query is source.branch.name="main",
		-- url-encoded (= -> %3D, " -> %22) into the single URL argv token.
		local argv = shim.calls("curl")[1]
		assert.truthy(join(argv):find("q=source.branch.name%3D%22main%22", 1, true))
		assert.truthy(join(argv):find("state=OPEN", 1, true))

		-- fetch-once: the second call short-circuits on the cached pr_number, so
		-- only a single `curl` invocation ever happened.
		assert.equals(1, #shim.calls("curl"))
	end)

	it("get_comments runs get_hunks before the comments GET and normalizes with the outdated heuristic", function()
		shim.stub("curl", {
			API_USER,
			PR_NUMBER_QUERY,
			{ match = { "/diff" }, stdout_file = FIXTURES .. "/diff.txt" },
			{ match = { "comments?pagelen=100" }, stdout_file = FIXTURES .. "/comments.json" },
		})

		local comments
		bb.get_comments(function(c)
			comments = c
		end)
		wait_for(function()
			return comments ~= nil
		end, "get_comments")

		-- Thread on src/foo.lua: path IS in the diff-derived path set -> live.
		local foo = comments["src/foo.lua"]
		assert.is_not_nil(foo)
		assert.equals(1, #foo)
		assert.equals("100", foo[1].id)
		assert.is_false(foo[1].is_outdated)
		assert.equals("alice", foo[1].comments[1].author)
		assert.equals(2, foo[1].comments[1].start_line)
		assert.equals(2, foo[1].comments[1].end_line)

		-- Thread on src/old.lua: path is NOT in the diff -> flagged outdated by the
		-- path-based heuristic (get_hunks must have run first for this to hold).
		local old = comments["src/old.lua"]
		assert.is_not_nil(old)
		assert.equals(1, #old)
		assert.equals("200", old[1].id)
		assert.is_true(old[1].is_outdated)
		assert.equals("bob", old[1].comments[1].author)

		-- Call order: the /diff route was hit strictly before the /comments route.
		local diff_i = curl_index("/diff")
		local comments_i = curl_index("comments?pagelen=100")
		assert.is_not_nil(diff_i, "diff route was not hit")
		assert.is_not_nil(comments_i, "comments route was not hit")
		assert.is_true(diff_i < comments_i, "diff route must precede the comments route")
	end)

	it("auth argv: -u user:pass when BITBUCKET_USERNAME/APP_PASSWORD are set", function()
		vim.env.BITBUCKET_USERNAME = "u"
		vim.env.BITBUCKET_APP_PASSWORD = "p"
		shim.stub("curl", { API_USER })

		local user
		bb.get_git_user(function(u)
			user = u
		end)
		wait_for(function()
			return user ~= nil and user ~= ""
		end, "get_git_user")

		local argv = shim.calls("curl")[1]
		assert_flag_pair(argv, "-u", "u:p")
		assert.is_nil(join(argv):find("--netrc", 1, true), "must not fall back to --netrc when creds are set")
	end)

	it("auth argv: --netrc when the env credentials are unset", function()
		-- before_each already cleared the env vars.
		shim.stub("curl", { API_USER })

		local user
		bb.get_git_user(function(u)
			user = u
		end)
		wait_for(function()
			return user ~= nil and user ~= ""
		end, "get_git_user")

		local argv = shim.calls("curl")[1]
		assert.truthy(vim.tbl_contains(argv, "--netrc"))
		assert.is_nil(join(argv):find("\31-u\31", 1, true), "no -u flag without creds")
	end)

	it("reply POSTs the body with a parent.id in the -d JSON payload", function()
		-- Seed caches so ensure_context skips the git/curl routing jobs.
		bb.repo_info = { owner = "acme", repo = "widget" }
		bb.pr_number = 5
		shim.stub("curl", { { match = { "-X", "POST" }, stdout = "{}" } })

		local done = false
		bb.reply(100, "hello", function()
			done = true
		end)
		wait_for(function()
			return done
		end, "reply cb")

		local argv = shim.calls("curl")[1]
		local joined = join(argv)
		assert.truthy(joined:find("/repositories/acme/widget/pullrequests/5/comments", 1, true))
		assert_flag_pair(argv, "-X", "POST")

		-- The request body is a single argv token following `-d`; decode it and
		-- assert the parent link + content survived JSON encoding.
		local payload
		for i, v in ipairs(argv) do
			if v == "-d" then
				payload = argv[i + 1]
				break
			end
		end
		assert.is_not_nil(payload, "no -d payload token")
		local body = vim.json.decode(payload)
		assert.equals(100, body.parent.id)
		assert.equals("hello", body.content.raw)
	end)

	it("run_curl surfaces the auth-failed hint on exit 22 + a 401 stderr", function()
		bb.repo_info = { owner = "acme", repo = "widget" }
		bb.pr_number = 5
		shim.stub("curl", {
			{ match = { "-X", "POST" }, exit = 22, stderr = "curl: (22) The requested URL returned error: 401 Unauthorized" },
		})

		local done = false
		bb.reply(100, "hello", function()
			done = true
		end)
		wait_for(function()
			return done
		end, "reply cb")

		-- run_curl's non-zero branch: a 401/403 in stderr routes to the auth hint
		-- rather than the generic reachability message.
		local found = false
		local reachability_msg
		for _, m in ipairs(notify_msgs()) do
			if tostring(m):find("Bitbucket auth failed", 1, true) then
				found = true
			end
			-- The else-branch reachability message (run_curl) must NOT fire on a 401.
			if tostring(m):find("Is curl installed and api.bitbucket.org reachable?", 1, true) then
				reachability_msg = m
			end
		end
		assert.is_true(found, "expected the Bitbucket auth-failed notification")
		assert.is_nil(reachability_msg, "generic reachability message must not fire on a 401")
	end)

	it("run_curl redacts credentials and review text in debug mode while keeping the auth hint", function()
		require("pr.config").opts.debug = true
		vim.env.BITBUCKET_USERNAME = "SECURITY_USER"
		vim.env.BITBUCKET_APP_PASSWORD = "APP_PASSWORD_SECRET"
		bb.repo_info = { owner = "acme", repo = "widget" }
		bb.pr_number = 5
		local private_body = "BITBUCKET UNPUBLISHED REVIEW"
		shim.stub("curl", {
			{
				match = { "-X", "POST" },
				exit = 22,
				stderr = "curl: (22) 401 Unauthorized SECURITY_USER:APP_PASSWORD_SECRET " .. private_body,
			},
		})

		local done = false
		bb.reply(100, private_body, function()
			done = true
		end)
		wait_for(function()
			return done
		end, "reply cb")

		local rendered = table.concat(notify_msgs(), "\n")
		assert.truthy(rendered:find("Bitbucket auth failed", 1, true))
		assert.truthy(rendered:find("<redacted>", 1, true))
		-- Positive argv coverage: the debug dump must still be *present and
		-- useful* (the endpoint survives), with only the credential replaced.
		-- Without these two, deleting the argv dump entirely would still satisfy
		-- the `<redacted>` assertion above (the normal-mode cause line carries
		-- one), so the redaction of `-u user:app-password` would go unpinned --
		-- and bitbucket is the only provider that puts a credential on argv.
		assert.truthy(rendered:find("pullrequests/5/comments", 1, true))
		assert.truthy(rendered:find("-u <redacted>", 1, true))
		assert.is_nil(rendered:find("SECURITY_USER", 1, true))
		assert.is_nil(rendered:find("APP_PASSWORD_SECRET", 1, true))
		assert.is_nil(rendered:find(private_body, 1, true))
		assert.is_nil(rendered:find('"content"', 1, true))
		assert.is_nil(rendered:find("Is curl installed and api.bitbucket.org reachable?", 1, true))
	end)

	it("checkout_pr fetches + checks out a branch that lives only in the bare origin", function()
		-- Publish a feature branch to the bare origin, then drop it locally so the
		-- provider's `git fetch origin <branch>` is genuinely required.
		local BRANCH = "feature/checkout-me"
		repo.checkout(BRANCH, true)
		repo.write("marker.txt", { "from the PR branch" })
		repo.commit("branch work")
		repo.push_bare(BRANCH)
		repo.checkout("main")
		repo.git("branch", "-D", BRANCH)

		-- Resolve repo_info the real way (git remote get-url origin parses the
		-- host-shaped bitbucket URL -> acme/widget), THEN flip origin to the local
		-- bare path so the subsequent real fetch/checkout can succeed offline.
		local ri_done = false
		bb.get_repo_info(function(ws, r)
			assert.equals("acme", ws)
			assert.equals("widget", r)
			ri_done = true
		end)
		wait_for(function()
			return ri_done
		end, "get_repo_info")
		bb.git_root = repo.root
		repo.set_origin_url(repo.bare)

		-- The PR metadata GET names the branch to check out.
		shim.stub("curl", {
			{ match = { "/pullrequests/7" }, stdout = '{"source":{"branch":{"name":"' .. BRANCH .. '"}}}' },
		})

		-- Spy vim.cmd to prove the success path ran `checktime`.
		local saved_cmd = vim.cmd
		local checktime_called = false
		vim.cmd = function(c)
			if c == "checktime" then
				checktime_called = true
			end
			return saved_cmd(c)
		end

		local success, err_val, done
		bb.checkout_pr(7, function(ok, err)
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
			-- The real checkout moved HEAD onto the fetched branch.
			assert.equals(BRANCH, repo.git("rev-parse", "--abbrev-ref", "HEAD"))
			assert.equals(1, vim.fn.filereadable(repo.root .. "/marker.txt"))
		end)
		vim.cmd = saved_cmd
		if not pok then
			error(perr, 0)
		end
	end)

	it("resolve_thread POSTs to the comment's /resolve endpoint", function()
		-- Seed caches so ensure_context skips the git/curl routing jobs; only the
		-- resolve POST fires.
		bb.repo_info = { owner = "acme", repo = "widget" }
		bb.pr_number = 5
		shim.stub("curl", { { match = { "-X", "POST" }, stdout = "{}" } })

		local ok
		bb.resolve_thread("100", function(success)
			ok = success
		end)
		wait_for(function()
			return ok ~= nil
		end, "resolve_thread cb")

		assert.is_true(ok)
		local argv = shim.calls("curl")[1]
		assert.truthy(join(argv):find("/repositories/acme/widget/pullrequests/5/comments/100/resolve", 1, true))
		assert_flag_pair(argv, "-X", "POST")
	end)

	it("clear_comments forces the next get_comments to re-run the comments GET", function()
		shim.stub("curl", {
			API_USER,
			PR_NUMBER_QUERY,
			{ match = { "/diff" }, stdout_file = FIXTURES .. "/diff.txt" },
			{ match = { "comments?pagelen=100" }, stdout_file = FIXTURES .. "/comments.json" },
		})

		local c1
		bb.get_comments(function(c)
			c1 = c
		end)
		wait_for(function()
			return c1 ~= nil
		end, "first get_comments")
		assert.equals(1, curl_count("comments?pagelen=100"))

		bb.clear_comments()

		local c2
		bb.get_comments(function(c)
			c2 = c
		end)
		wait_for(function()
			return c2 ~= nil
		end, "second get_comments after clear")
		-- git_user, repo_info, pr_number, and hunks stay cached, so only the
		-- comments GET re-fires: 1 -> 2.
		assert.equals(2, curl_count("comments?pagelen=100"))
	end)

	it("list_prs('mine') filters by author.uuid, normalizes, and caches per filter", function()
		shim.stub("curl", {
			API_USER_UUID,
			{ match = { "pullrequests?state=OPEN&pagelen=50" }, stdout = LIST_BODY },
		})

		local prs
		bb.list_prs("mine", function(p)
			prs = p
		end)
		wait_for(function()
			return prs ~= nil
		end, "list_prs mine")

		-- The list URL carries the url-encoded author.uuid DSL filter + OPEN state.
		local idx = curl_index("pagelen=50")
		assert.is_not_nil(idx, "list route was not hit")
		local argv = shim.calls("curl")[idx]
		assert.truthy(join(argv):find("q=author.uuid%3D%22abc-123%22", 1, true))
		assert.truthy(join(argv):find("state=OPEN", 1, true))

		-- Normalized from the 2-PR fixture; both PRs are authored by the viewer.
		assert.equals(2, #prs)
		assert.equals(11, prs[1].number)
		assert.equals("first pr", prs[1].title)
		assert.equals("tester", prs[1].author)
		assert.equals("open", prs[1].state)
		assert.equals("feat/one", prs[1].branch)
		assert.is_true(prs[1].is_mine)
		assert.same({ "bob" }, prs[1].reviewers)
		assert.equals(12, prs[2].number)

		-- Per-filter cache: a second "mine" call short-circuits, no new curl call.
		local after_first = #shim.calls("curl")
		local prs2
		bb.list_prs("mine", function(p)
			prs2 = p
		end)
		wait_for(function()
			return prs2 ~= nil
		end, "cached list_prs mine")
		assert.equals(after_first, #shim.calls("curl"))
	end)

	it("list_prs('assigned') falls through to 'all' with a one-time notification", function()
		shim.stub("curl", {
			API_USER_UUID,
			{ match = { "pullrequests?state=OPEN&pagelen=50" }, stdout = LIST_BODY },
		})

		local prs
		bb.list_prs("assigned", function(p)
			prs = p
		end)
		wait_for(function()
			return prs ~= nil
		end, "list_prs assigned")

		-- Bitbucket Cloud has no assignee concept: the list URL emits no q= filter.
		local idx = curl_index("pagelen=50")
		assert.is_not_nil(idx, "list route was not hit")
		local argv = shim.calls("curl")[idx]
		assert.is_nil(join(argv):find("q=", 1, true), "assigned must not emit a q= filter")

		-- A one-time notification announces the fallback to 'all'.
		local found = false
		for _, m in ipairs(notify_msgs()) do
			if tostring(m):find("falling back to 'all'", 1, true) then
				found = true
			end
		end
		assert.is_true(found, "expected the assignee-fallback notification")

		assert.equals(2, #prs)
	end)

	-- Lifecycle: bitbucket's read getters short-circuited on `next(M.comments)` /
	-- `next(M.hunks)`, so a PR with no comments and a PR with an empty diff both
	-- refetched on every call, concurrent callers each started their own curl
	-- chain, and a failed fetch never settled its caller at all.
	local DIFF_ROUTE = { match = { "/diff" }, stdout_file = FIXTURES .. "/diff.txt" }
	local COMMENTS_ROUTE = { match = { "comments?pagelen=100" }, stdout_file = FIXTURES .. "/comments.json" }
	local EMPTY_COMMENTS = { match = { "comments?pagelen=100" }, stdout = '{"values":[]}' }
	local PR_QUERY_FAILS = { match = { "pullrequests?state=OPEN&pagelen=5" }, exit = 1, stderr = "curl: (22) 404" }

	it("caches an empty comments result instead of refetching", function()
		shim.stub("curl", { API_USER, PR_NUMBER_QUERY, DIFF_ROUTE, EMPTY_COMMENTS })

		local first, second
		bb.get_comments(function(c)
			first = c
		end)
		wait_for(function()
			return first ~= nil
		end, "first get_comments")
		bb.get_comments(function(c)
			second = c
		end)
		wait_for(function()
			return second ~= nil
		end, "second get_comments")

		assert.same({}, first)
		assert.same({}, second)
		-- Cached: a PR with no comments used to fail `next(M.comments)` and
		-- re-issue the whole chain on every call.
		assert.equals(1, curl_count("comments?pagelen=100"))

		-- ...and invalidation makes the NEXT call fetch again.
		bb.clear_comments()
		local third
		bb.get_comments(function(c)
			third = c
		end)
		wait_for(function()
			return third ~= nil
		end, "get_comments after clear_comments")
		assert.same({}, third)
		assert.equals(2, curl_count("comments?pagelen=100"))
	end)

	it("caches an empty hunks result and refetches after invalidation", function()
		-- An exit-0 /diff with no body is a PR whose diff is empty, not a failure.
		shim.stub("curl", { PR_NUMBER_QUERY, { match = { "/diff" }, stdout = "" } })

		local first, second
		bb.get_hunks(function(h)
			first = h
		end)
		wait_for(function()
			return first ~= nil
		end, "first get_hunks")
		bb.get_hunks(function(h)
			second = h
		end)
		wait_for(function()
			return second ~= nil
		end, "second get_hunks")

		assert.same({}, first)
		assert.same({}, second)
		assert.equals(1, curl_count("/diff"))

		bb.clear_hunks()
		local third
		bb.get_hunks(function(h)
			third = h
		end)
		wait_for(function()
			return third ~= nil
		end, "get_hunks after clear_hunks")
		assert.same({}, third)
		assert.equals(2, curl_count("/diff"))
	end)

	it("coalesces two callers arriving before the fetch completes", function()
		shim.stub("curl", { API_USER, PR_NUMBER_QUERY, DIFF_ROUTE, COMMENTS_ROUTE })

		local a, b
		bb.get_comments(function(c)
			a = c
		end)
		bb.get_comments(function(c)
			b = c
		end)
		wait_for(function()
			return a ~= nil and b ~= nil
		end, "both callers settled")

		assert.is_not_nil(a["src/foo.lua"])
		assert.is_not_nil(b["src/foo.lua"])
		-- One chain, not two: the second caller joined the first fetch.
		assert.equals(1, curl_count("comments?pagelen=100"))
	end)

	it("settles the caller with an error instead of hanging when the fetch fails", function()
		shim.stub("curl", {
			API_USER,
			PR_NUMBER_QUERY,
			DIFF_ROUTE,
			{ match = { "comments?pagelen=100" }, exit = 22, stderr = "curl: (22) The requested URL returned error: 429" },
		})

		local value, err, called = nil, nil, false
		bb.get_comments(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "failed get_comments settles its caller")

		assert.same({}, value)
		assert.is_not_nil(err)
		-- The failure must NOT be cached as a successful empty result.
		assert.same({}, bb.comments)
		assert.equals("error", bb._fetch:status("comments"))
	end)

	it("clear() returns the fetch coordinator to cold so the next get_comments refetches", function()
		shim.stub("curl", { API_USER, PR_NUMBER_QUERY, DIFF_ROUTE, EMPTY_COMMENTS })

		local first
		bb.get_comments(function(c)
			first = c
		end)
		wait_for(function()
			return first ~= nil
		end, "first get_comments")

		-- clear() resets the cache fields inline rather than delegating to
		-- clear_comments/clear_hunks, so it has to invalidate the coordinator
		-- itself or the emptied cache stays "loaded" forever.
		bb.clear()

		local second
		bb.get_comments(function(c)
			second = c
		end)
		wait_for(function()
			return second ~= nil
		end, "get_comments after clear()")
		assert.equals(2, curl_count("comments?pagelen=100"))
	end)

	-- Each reject and owns site gets its own pin. A failing PR lookup and a
	-- missing origin remote are the two ways the prelude getters fail; before
	-- they settled their own callbacks the resource stayed "loading" forever and
	-- every later caller joined a waiter list nothing would drain.
	it("get_comments settles and stays retryable when the PR lookup fails", function()
		shim.stub("curl", { API_USER, PR_QUERY_FAILS, DIFF_ROUTE, COMMENTS_ROUTE })

		local value, err, called
		bb.get_comments(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_comments settles on a failed PR lookup")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.equals("error", bb._fetch:status("comments"))
		assert.equals(0, curl_count("comments?pagelen=100"))

		-- Retryable, not wedged: once the PR resolves, the next caller fetches.
		shim.stub("curl", { API_USER, PR_NUMBER_QUERY, DIFF_ROUTE, EMPTY_COMMENTS })
		local second
		bb.get_comments(function(c)
			second = c
		end)
		wait_for(function()
			return second ~= nil
		end, "get_comments after the failure")
		assert.same({}, second)
		assert.equals(1, curl_count("comments?pagelen=100"))
	end)

	it("get_comments settles when the origin remote is gone", function()
		repo.git("remote", "remove", "origin")
		shim.stub("curl", { API_USER, PR_NUMBER_QUERY, DIFF_ROUTE, COMMENTS_ROUTE })

		local value, err, called
		bb.get_comments(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_comments settles without repo info")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.equals(0, curl_count("comments?pagelen=100"))
	end)

	it("get_comments settles on an unexpected comments response", function()
		shim.stub("curl", {
			API_USER,
			PR_NUMBER_QUERY,
			DIFF_ROUTE,
			{ match = { "comments?pagelen=100" }, stdout = '{"type":"error"}' },
		})

		local value, err, called
		bb.get_comments(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_comments settles on an unexpected response")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.equals("error", bb._fetch:status("comments"))
	end)

	it("get_hunks settles with an error when the diff request fails", function()
		shim.stub("curl", { PR_NUMBER_QUERY, { match = { "/diff" }, exit = 22, stderr = "curl: (22) 500" } })

		local value, err, called
		bb.get_hunks(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "failed get_hunks settles its caller")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.same({}, bb.hunks)
		assert.equals("error", bb._fetch:status("hunks"))

		-- A failure is not cached as success: the next caller re-runs the diff GET
		-- instead of replaying an empty result.
		shim.stub("curl", { PR_NUMBER_QUERY, DIFF_ROUTE })
		local second
		bb.get_hunks(function(h)
			second = h
		end)
		wait_for(function()
			return second ~= nil and next(second) ~= nil
		end, "get_hunks after the failure")
		assert.equals(2, curl_count("/diff"))
	end)

	it("get_hunks settles when the PR lookup fails", function()
		shim.stub("curl", { PR_QUERY_FAILS, DIFF_ROUTE })

		local value, err, called
		bb.get_hunks(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_hunks settles on a failed PR lookup")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.equals(0, curl_count("/diff"))
	end)

	it("get_hunks settles when the origin remote is gone", function()
		repo.git("remote", "remove", "origin")
		shim.stub("curl", { PR_NUMBER_QUERY, DIFF_ROUTE })

		local value, err, called
		bb.get_hunks(function(v, e)
			value, err, called = v, e, true
		end)
		wait_for(function()
			return called
		end, "get_hunks settles without repo info")

		assert.same({}, value)
		assert.is_not_nil(err)
		assert.equals(0, curl_count("/diff"))
	end)

	it("a comments fetch invalidated mid-flight never publishes into the cache", function()
		shim.stub("curl", { API_USER, PR_NUMBER_QUERY, DIFF_ROUTE, COMMENTS_ROUTE })

		local err, called
		bb.get_comments(function(_, e)
			err, called = e, true
		end)
		-- The chain is still on its first curl here, so this retires the token the
		-- in-flight completion is holding.
		bb.clear_comments()
		assert.is_true(called, "invalidate settles the waiting caller")
		assert.is_not_nil(err)

		wait_for(function()
			return curl_count("comments?pagelen=100") == 1
		end, "the retired fetch still ran to completion")
		vim.wait(500, function()
			return false
		end)

		-- The completion lost its token, so the fixture's threads must not have
		-- landed in a just-emptied cache.
		assert.same({}, bb.comments)
		assert.equals("cold", bb._fetch:status("comments"))
	end)

	it("a hunks fetch invalidated mid-flight never publishes into the cache", function()
		shim.stub("curl", { PR_NUMBER_QUERY, DIFF_ROUTE })

		local err, called
		bb.get_hunks(function(_, e)
			err, called = e, true
		end)
		bb.clear_hunks()
		assert.is_true(called, "invalidate settles the waiting caller")
		assert.is_not_nil(err)

		wait_for(function()
			return curl_count("/diff") == 1
		end, "the retired fetch still ran to completion")
		vim.wait(500, function()
			return false
		end)

		assert.same({}, bb.hunks)
		assert.equals("cold", bb._fetch:status("hunks"))
	end)

	-- Point PATH at a directory holding nothing but `git`, so `curl` is genuinely
	-- absent and plenary's `Job:new` executable check fires. git is still never
	-- shimmed: the entry is a symlink to the real binary.
	local function hide_curl()
		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		local git_exe = vim.fn.exepath("git")
		assert(git_exe ~= "", "git must be on PATH for this spec")
		local uv = vim.uv or vim.loop
		uv.fs_symlink(git_exe, dir .. "/git")
		local saved = vim.env.PATH
		vim.env.PATH = dir
		return function()
			vim.env.PATH = saved
			vim.fn.delete(dir, "rf")
		end
	end

	-- A raising `Job:new` inside a fetch_state-owned chain used to settle
	-- nothing, so the resource stayed "loading" forever and every later caller
	-- joined a waiter list that never drained. Drive one such chain with curl
	-- absent: the caller must be settled, the raise must not escape the entry
	-- call, and the resource must be retryable rather than joined.
	local function assert_missing_cli_settles(resource, start_fetch)
		local restore = hide_curl()
		local settled, err_seen = 0, nil
		local function run()
			start_fetch(function(_, err)
				settled = settled + 1
				err_seen = err
			end)
			wait_for(function()
				return settled > 0
			end, resource .. " settles with curl missing")
		end
		local pcall_ok, pcall_err = pcall(run)
		restore()
		assert(pcall_ok, pcall_err)

		assert.equals(1, settled)
		assert.is_not_nil(err_seen)
		assert.equals("error", bb._fetch:status(resource))
		assert.equals("start", (bb._fetch:begin(resource, nil)))

		local named = vim.tbl_filter(function(msg)
			return tostring(msg):find("curl: Executable not found", 1, true) ~= nil
		end, notify_msgs())
		assert(#named > 0, "expected a notification naming the missing CLI, got: " .. vim.inspect(notify_msgs()))
	end

	it("get_comments settles and stays retryable when curl is not installed", function()
		assert_missing_cli_settles("comments", bb.get_comments)
	end)

	it("get_hunks settles and stays retryable when curl is not installed", function()
		assert_missing_cli_settles("hunks", bb.get_hunks)
	end)
end)
