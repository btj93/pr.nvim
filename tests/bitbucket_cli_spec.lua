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
	local saved_user, saved_pass

	-- get_pr_number filters open PRs by source branch; the fixture resolves to
	-- PR id 5. The URL carries the url-encoded `q=source.branch.name="<branch>"`.
	local PR_NUMBER_QUERY = { match = { "pullrequests?state=OPEN&pagelen=5" }, stdout = '{"values":[{"id":5}]}' }
	-- get_git_user resolves the authed nickname off GET /user.
	local API_USER = { match = { "/user" }, stdout = '{"nickname":"tester"}' }

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
		for _, m in ipairs(notify_msgs()) do
			if tostring(m):find("Bitbucket auth failed", 1, true) then
				found = true
			end
		end
		assert.is_true(found, "expected the Bitbucket auth-failed notification")
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

		-- Spy vim.cmd to prove the success path ran `checktime`. Restored before
		-- any assert so a failure can't leave the global wrapped for after_each.
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
		wait_for(function()
			return done
		end, "checkout_pr cb")

		vim.cmd = saved_cmd

		assert.is_true(success)
		assert.is_nil(err_val)
		assert.is_true(checktime_called)
		-- The real checkout moved HEAD onto the fetched branch.
		assert.equals(BRANCH, repo.git("rev-parse", "--abbrev-ref", "HEAD"))
		assert.equals(1, vim.fn.filereadable(repo.root .. "/marker.txt"))
	end)
end)
