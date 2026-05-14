-- Bitbucket Cloud provider. Authenticates against api.bitbucket.org via curl.
--
-- Auth: set BITBUCKET_USERNAME + BITBUCKET_APP_PASSWORD env vars, or put
-- credentials in ~/.netrc under `machine api.bitbucket.org`. App passwords are
-- generated at https://bitbucket.org/account/settings/app-passwords/ — the
-- account password itself won't work against the API.
--
-- Bitbucket Cloud has no PR-comment reactions, so M.reaction_palette is empty
-- and ui.lua hides the emoji action. Bitbucket Server / Data Center has a
-- different API and is NOT supported here.

local Job = require("plenary.job")
local util = require("pr.util")
local local_review = require("pr.review_local")
local M = {}

M.git_root = ""
M.git_user = ""
M.git_user_uuid = ""
---@type RepoInfo
M.repo_info = {}
M.pr_number = 0
M.base_sha = ""
---@type string?
M.pending_review_id = nil
---@type Comments
M.comments = {}
---@type Hunks
M.hunks = {}
---@type table<string, PRSummary[]>
M.pr_list = {}
---@type PRMetadata?
M.pr_metadata = nil
---@type CheckRun[]|nil
M.checks = nil

---@type ReactionPaletteEntry[]
M.reaction_palette = {}

local API_BASE = "https://api.bitbucket.org/2.0"

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M._url_encode(str)
	if not str then
		return ""
	end
	return (str:gsub("([^%w%-._~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

--- Parse `git remote get-url origin` output into workspace + repo slug.
---@param url string
---@return string|nil workspace
---@return string|nil repo_slug
function M._parse_remote_url(url)
	url = trim(url)
	local path = url:match("@[^:]+:(.+)%.git$") or url:match("@[^:]+:(.+)$")
	if not path then
		path = url:match("://[^/]+/(.+)%.git$") or url:match("://[^/]+/(.+)$")
	end
	if not path then
		return nil, nil
	end
	path = trim(path)
	local workspace, repo_slug = path:match("^([^/]+)/(.+)$")
	if not workspace or not repo_slug then
		return nil, nil
	end
	return workspace, repo_slug
end

local function nil_if_vim_nil(v)
	if v == nil or v == vim.NIL then
		return nil
	end
	return v
end

local function auth_args()
	local user = os.getenv("BITBUCKET_USERNAME")
	local pass = os.getenv("BITBUCKET_APP_PASSWORD")
	if user and pass and user ~= "" and pass ~= "" then
		return { "-u", user .. ":" .. pass }
	end
	return { "--netrc" }
end

-- Build a curl invocation and dispatch its parsed JSON response (or nil for
-- empty bodies / errors) to on_done. `body` is a Lua table to be JSON-encoded
-- as the request payload; pass nil for GET/DELETE.
local function run_curl(method, path, body, on_done)
	local args = { "-sS", "-X", method, "-H", "Accept: application/json" }
	vim.list_extend(args, auth_args())
	if body then
		table.insert(args, "-H")
		table.insert(args, "Content-Type: application/json")
		table.insert(args, "-d")
		table.insert(args, vim.json.encode(body))
	end
	table.insert(args, API_BASE .. path)

	Job:new({
		command = "curl",
		args = args,
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				local stderr = vim.inspect(j:stderr_result() or {})
				vim.notify("Bitbucket curl failed: " .. table.concat(args, " "))
				vim.notify(stderr)
				-- Curl is universal but auth misconfiguration is the most common cause.
				if stderr:find("401") or stderr:find("403") then
					vim.notify("Bitbucket auth failed. Check BITBUCKET_USERNAME / BITBUCKET_APP_PASSWORD env vars or ~/.netrc entry for api.bitbucket.org.")
				else
					vim.notify("Is curl installed and api.bitbucket.org reachable?")
				end
				on_done(false, nil)
				return
			end
			local body_str = table.concat(j:result(), "\n")
			if body_str == "" then
				on_done(true, nil)
				return
			end
			local ok, data = pcall(vim.json.decode, body_str)
			if not ok then
				vim.notify("Bitbucket: failed to parse response: " .. body_str)
				on_done(false, nil)
				return
			end
			if type(data) == "table" and data.error then
				local msg = (type(data.error) == "table" and data.error.message) or vim.inspect(data.error)
				vim.notify("Bitbucket API error: " .. msg)
				on_done(false, data)
				return
			end
			on_done(true, data)
		end),
	}):start()
end

local function get_current_branch(callback)
	Job:new({
		command = "git",
		args = { "rev-parse", "--abbrev-ref", "HEAD" },
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				callback(nil)
				return
			end
			local result = j:result()
			local _, t = next(result)
			callback(t)
		end),
	}):start()
end

---
---@param callback? fun(git_root: string)
function M.get_git_root(callback)
	callback = callback or function(_) end
	if M.git_root ~= "" then
		callback(M.git_root)
		return
	end

	Job:new({
		command = "git",
		args = { "rev-parse", "--show-toplevel" },
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				vim.notify(vim.inspect(j:result()))
				vim.notify("Error running git rev-parse command. Is a git cli installed?")
				return
			end
			local result = j:result()
			local _, t = next(result)
			if t then
				M.git_root = t
			end
			callback(M.git_root)
		end),
	}):start()
end

---
---@param callback? fun(git_user: string)
function M.get_git_user(callback)
	callback = callback or function(_) end
	if M.git_user ~= "" then
		callback(M.git_user)
		return
	end

	run_curl("GET", "/user", nil, function(ok, data)
		if not ok or not data or not data.nickname then
			vim.notify("Could not fetch Bitbucket user. Check BITBUCKET_USERNAME/APP_PASSWORD or ~/.netrc.")
			callback(M.git_user)
			return
		end
		M.git_user = data.nickname
		if data.uuid then
			M.git_user_uuid = data.uuid
		end
		vim.notify("Logged in as " .. M.git_user)
		callback(M.git_user)
	end)
end

---
---@param callback? fun(owner: string, repo: string)
function M.get_repo_info(callback)
	callback = callback or function(_, _) end
	if M.repo_info.owner and M.repo_info.repo then
		callback(M.repo_info.owner, M.repo_info.repo)
		return
	end

	Job:new({
		command = "git",
		args = { "remote", "get-url", "origin" },
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				vim.api.nvim_echo({ { "Could not determine Bitbucket project from remote 'origin'.", "ErrorMsg" } }, true, {})
				return
			end
			local result = j:result()
			local _, t = next(result)
			if not t then
				vim.api.nvim_echo({ { "Could not determine Bitbucket project from remote 'origin'.", "ErrorMsg" } }, true, {})
				return
			end
			local url = trim(t)
			local workspace, repo_slug = M._parse_remote_url(url)
			if not workspace or not repo_slug then
				vim.api.nvim_echo({ { "Could not parse workspace/repo from remote URL.", "ErrorMsg" } }, true, {})
				return
			end
			M.repo_info = { owner = workspace, repo = repo_slug }
			callback(workspace, repo_slug)
		end),
	}):start()
end

---
---@param callback? fun(pr_number: number)
function M.get_pr_number(callback)
	callback = callback or function(_) end
	if M.pr_number > 0 then
		callback(M.pr_number)
		return
	end

	M.get_repo_info(vim.schedule_wrap(function(workspace, repo)
		if not workspace or not repo then
			return
		end
		get_current_branch(function(branch)
			if not branch then
				vim.notify("Could not determine current branch.")
				return
			end
			-- Bitbucket's query DSL: filter by source branch + open state.
			local q = 'source.branch.name="' .. branch .. '"'
			local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests?state=OPEN&pagelen=5&q=" .. M._url_encode(q)
			run_curl("GET", path, nil, function(ok, data)
				if not ok or not data or not data.values or #data.values == 0 then
					vim.notify("No PR open for this branch")
					return
				end
				local pr = data.values[1]
				M.pr_number = pr.id
				callback(pr.id)
			end)
		end)
	end))
end

---
---@param callback? fun(hash: string)
function M.get_commit_hash(callback)
	callback = callback or function(_) end

	Job:new({
		command = "git",
		args = { "rev-parse", "HEAD" },
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				vim.api.nvim_echo({ { "Could not determine commit hash.", "ErrorMsg" } }, true, {})
				return
			end
			local result = j:result()
			local _, t = next(result)
			if not t then
				return
			end
			callback(t)
		end),
	}):start()
end

-- Re-assemble flat Bitbucket comments into root-keyed thread groups by walking
-- parent links. Orphans (parent ID not in the page) become their own roots.
function M._build_threads(flat)
	local by_id = {}
	for _, c in ipairs(flat) do
		by_id[c.id] = c
	end

	local root_of = {}
	local function find_root(c)
		if root_of[c.id] then
			return root_of[c.id]
		end
		local parent = nil_if_vim_nil(c.parent)
		if not parent then
			root_of[c.id] = c.id
			return c.id
		end
		local p = by_id[parent.id]
		if not p then
			root_of[c.id] = c.id
			return c.id
		end
		local r = find_root(p)
		root_of[c.id] = r
		return r
	end

	local by_root = {}
	for _, c in ipairs(flat) do
		local r = find_root(c)
		by_root[r] = by_root[r] or {}
		table.insert(by_root[r], c)
	end

	for _, group in pairs(by_root) do
		table.sort(group, function(a, b)
			return (a.created_on or "") < (b.created_on or "")
		end)
	end

	return by_root
end

--- Pure transformation from a parsed Bitbucket Cloud comments page into the
--- canonical Comments shape. Exposed for unit testing.
---@param data table Decoded JSON from /pullrequests/:id/comments
---@param git_user string Authenticated user's nickname (for viewer_did_author).
---@param current_paths table<string, true>|nil Set of paths in the current diff; when provided, threads anchored on paths not in this set are flagged is_outdated. Pass nil to skip the check (back-compat).
---@return Comments|nil comments
---@return integer thread_count
---@return integer unsolved_count
--- Returns 3 values: (comments, thread_count, unsolved_count).
--- Note: gitlab's `_normalize_comments` adds a 4th value (diff_refs).
function M._normalize_comments(data, git_user, current_paths)
	if not data or not data.values then
		return nil, 0, 0
	end

	local by_root = M._build_threads(data.values)

	---@type Comments
	local comments = {}
	local thread_count = 0
	local unsolved_count = 0

	for root_id, group in pairs(by_root) do
		local root_comment = nil
		for _, c in ipairs(group) do
			if c.id == root_id then
				root_comment = c
				break
			end
		end
		if root_comment then
			local inline = nil_if_vim_nil(root_comment.inline)
			local file = inline and nil_if_vim_nil(inline.path)
			local to = inline and nil_if_vim_nil(inline.to)
			local from = inline and nil_if_vim_nil(inline.from)
			local end_line = to or from
			-- When only `to` exists, treat as single-line (start collapses onto end).
			local start_line = from or to

			if file and end_line then
				---@type CommentInfo[]
				local thread_comments = {}
				for _, c in ipairs(group) do
					if not c.deleted then
						local nick = (c.user and c.user.nickname) or (c.user and c.user.display_name) or "unknown"
						local user_uuid = c.user and c.user.uuid
						local mine = false
						if M.git_user_uuid ~= "" and user_uuid and user_uuid == M.git_user_uuid then
							mine = true
						elseif git_user ~= "" and nick == git_user then
							mine = true
						end
						table.insert(thread_comments, {
							database_id = c.id,
							author = nick,
							body = (c.content and c.content.raw) or "",
							start_line = start_line,
							end_line = end_line,
							viewer_can_update = mine,
							viewer_can_react = false,
							viewer_can_delete = mine,
							reaction_groups = {},
							published_at = c.created_on,
							updated_at = c.updated_on or c.created_on,
							viewer_did_author = mine,
						})
					end
				end

				if #thread_comments > 0 then
					local resolution = nil_if_vim_nil(root_comment.resolution)
					local resolved = resolution ~= nil
					local resolved_by = nil
					if resolution and resolution.user then
						resolved_by = resolution.user.nickname or resolution.user.display_name
					end

					local outdated = false
					if current_paths and not current_paths[file] then
						outdated = true
					end
					local composed = {
						id = tostring(root_id),
						is_resolved = resolved,
						resolved_by = resolved_by,
						is_outdated = outdated,
						is_collapsed = false,
						viewer_can_reply = true,
						viewer_can_resolve = not resolved,
						viewer_can_unresolve = resolved,
						comments = thread_comments,
					}

					local file_threads = comments[file] or {}
					local found = false
					for i, th in ipairs(file_threads) do
						if th.id == composed.id then
							file_threads[i] = composed
							found = true
							break
						end
					end
					if not found then
						table.insert(file_threads, composed)
					end
					comments[file] = file_threads
					thread_count = thread_count + 1
					if not resolved then
						unsolved_count = unsolved_count + 1
					end
				end
			end
		end
	end

	return comments, thread_count, unsolved_count
end

---
---@param callback? fun(comments: Comments)
function M.get_comments(callback)
	callback = callback or function(_) end
	if next(M.comments) then
		callback(M.comments)
		return
	end

	M.get_git_user(vim.schedule_wrap(function(_)
		M.get_repo_info(vim.schedule_wrap(function(workspace, repo)
			if not workspace or not repo then
				return
			end
			M.get_pr_number(vim.schedule_wrap(function(pr_number)
				if not pr_number then
					return
				end
				-- Fetch hunks first so we can populate the path-set used by the
				-- outdated heuristic. M.get_hunks may legitimately return early
				-- (network error, auth failure, etc.) — in that case the callback
				-- fires with no hunks captured, and we fall through with
				-- current_paths_arg = nil so normalization defaults is_outdated
				-- = false rather than refusing to show comments at all.
				M.get_hunks(vim.schedule_wrap(function(hunks)
					local current_paths = {}
					for p, _ in pairs(hunks or {}) do
						current_paths[p] = true
					end
					local current_paths_arg = next(current_paths) and current_paths or nil
					local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. pr_number .. "/comments?pagelen=100"
					run_curl("GET", path, nil, function(ok, data)
						if not ok then
							return
						end
						local comments, thread_count, unsolved_count = M._normalize_comments(data, M.git_user, current_paths_arg)
						if not comments then
							return
						end
						M.comments = comments
						vim.notify("You have " .. thread_count .. "(" .. unsolved_count .. ")" .. " comment threads")
						callback(comments)
					end)
				end))
			end))
		end))
	end))
end

---
---@param callback? fun(hunks: Hunks)
function M.get_hunks(callback)
	callback = callback or function(_) end
	if next(M.hunks) then
		callback(M.hunks)
		return
	end

	M.get_repo_info(vim.schedule_wrap(function(workspace, repo)
		if not workspace or not repo then
			return
		end
		M.get_pr_number(vim.schedule_wrap(function(pr_number)
			if not pr_number then
				return
			end
			-- The /diff endpoint returns plain unified diff text rather than JSON.
			local args = { "-sS", "-X", "GET", "-H", "Accept: text/plain" }
			vim.list_extend(args, auth_args())
			table.insert(args, API_BASE .. "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. pr_number .. "/diff")

			Job:new({
				command = "curl",
				args = args,
				on_exit = vim.schedule_wrap(function(j, code)
					if code ~= 0 then
						vim.notify("Error running curl for pull request diff.")
						return
					end
					local diff_lines = j:result()
					if not diff_lines or #diff_lines == 0 then
						return
					end
					M.hunks = util.parse_diff_hunks(diff_lines)
					callback(M.hunks)
				end),
			}):start()
		end))
	end))
end

local function ensure_context(fn)
	M.get_repo_info(vim.schedule_wrap(function(workspace, repo)
		if not workspace or not repo then
			return
		end
		M.get_pr_number(vim.schedule_wrap(function(pr_number)
			if not pr_number then
				return
			end
			fn(workspace, repo, pr_number)
		end))
	end))
end

--- Resolve the PR's base-branch HEAD commit sha. Used by util.open_pr_file
--- to fetch the original content of files deleted in the PR.
---@param callback? fun(sha: string)
function M.get_base_sha(callback)
	callback = callback or function(_) end
	if M.base_sha ~= "" then
		callback(M.base_sha)
		return
	end
	ensure_context(function(workspace, repo, pr)
		local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. pr
		run_curl("GET", path, nil, function(ok, data)
			if not ok or not data or not data.destination or not data.destination.commit then
				vim.notify("Could not fetch PR base sha from Bitbucket.")
				return
			end
			M.base_sha = data.destination.commit.hash or ""
			callback(M.base_sha)
		end)
	end)
end

local function reactions_unsupported(callback)
	vim.notify("Bitbucket Cloud doesn't support reactions on PR comments.")
	if callback then
		callback(false)
	end
end

---@param callback? fun(success: boolean)
function M.add_reaction(_, _, callback)
	reactions_unsupported(callback)
end

---@param callback? fun(success: boolean)
function M.remove_reaction(_, _, callback)
	reactions_unsupported(callback)
end

---
---@param comment_id integer
---@param body string
---@param callback? fun(success: boolean)
function M.reply(comment_id, body, callback)
	callback = callback or function(_) end
	ensure_context(function(workspace, repo, pr)
		local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. pr .. "/comments"
		run_curl("POST", path, {
			content = { raw = body },
			parent = { id = comment_id },
		}, function(ok)
			callback(ok)
		end)
	end)
end

---
---@param relative_path string
---@param start_line integer
---@param end_line integer
---@param body string
---@param callback? fun(success: boolean)
function M.comment(relative_path, start_line, end_line, body, callback)
	callback = callback or function(_) end
	ensure_context(function(workspace, repo, pr)
		local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. pr .. "/comments"
		local inline = { path = relative_path, to = end_line }
		if start_line and end_line and start_line ~= end_line then
			inline.from = start_line
		end
		run_curl("POST", path, {
			content = { raw = body },
			inline = inline,
		}, function(ok)
			callback(ok)
		end)
	end)
end

---
---@param comment_id integer
---@param body string
---@param callback? fun(success: boolean)
function M.edit_comment(comment_id, body, callback)
	callback = callback or function(_) end
	ensure_context(function(workspace, repo, pr)
		local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. pr .. "/comments/" .. comment_id
		run_curl("PUT", path, {
			content = { raw = body },
		}, function(ok)
			callback(ok)
		end)
	end)
end

---
---@param thread_id string Root comment id (stringified) — what we stored as `thread.id`.
---@param callback? fun(success: boolean)
function M.resolve_thread(thread_id, callback)
	callback = callback or function(_) end
	ensure_context(function(workspace, repo, pr)
		local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. pr .. "/comments/" .. thread_id .. "/resolve"
		run_curl("POST", path, nil, function(ok)
			callback(ok)
		end)
	end)
end

---
---@param thread_id string
---@param callback? fun(success: boolean)
function M.unresolve_thread(thread_id, callback)
	callback = callback or function(_) end
	ensure_context(function(workspace, repo, pr)
		local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. pr .. "/comments/" .. thread_id .. "/reopen"
		run_curl("POST", path, nil, function(ok)
			callback(ok)
		end)
	end)
end

---
---@param comment_id integer
---@param callback? fun(success: boolean)
function M.delete_comment(comment_id, callback)
	callback = callback or function(_) end
	ensure_context(function(workspace, repo, pr)
		local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. pr .. "/comments/" .. comment_id
		run_curl("DELETE", path, nil, function(ok)
			callback(ok)
		end)
	end)
end

---@param _thread ReviewThread
---@param comment CommentInfo
---@return string?
function M.thread_url(_thread, comment)
	if not M.repo_info or not M.repo_info.owner or not M.repo_info.repo then
		return nil
	end
	if not M.pr_number or M.pr_number == 0 then
		return nil
	end
	if not comment or not comment.database_id then
		return nil
	end
	return string.format(
		"https://bitbucket.org/%s/%s/pull-requests/%d#comment-%s",
		M.repo_info.owner,
		M.repo_info.repo,
		M.pr_number,
		tostring(comment.database_id)
	)
end

--- Pure transformation from a parsed `/pullrequests?state=OPEN` body into the
--- canonical PRSummary[] shape. Exposed for unit testing.
---@param raw table  -- decoded body of /pullrequests?state=OPEN
---@param git_user string
---@param git_user_uuid string
---@return PRSummary[]
function M._normalize_prs(raw, git_user, git_user_uuid)
	local out = {}
	for _, p in ipairs((raw or {}).values or {}) do
		local author = (p.author and p.author.nickname) or (p.author and p.author.display_name) or ""
		local author_uuid = p.author and p.author.uuid or ""
		local state_lower = string.lower(p.state or "OPEN")
		local state
		if state_lower == "open" then
			state = "open"
		elseif state_lower == "merged" then
			state = "merged"
		elseif state_lower == "declined" or state_lower == "superseded" then
			state = "closed"
		else
			state = state_lower
		end

		local branch = (p.source and p.source.branch and p.source.branch.name) or ""

		local reviewers = {}
		local is_rr = false
		for _, r in ipairs(p.reviewers or {}) do
			local nick = r.nickname or r.display_name or ""
			table.insert(reviewers, nick)
			if (r.uuid and r.uuid == git_user_uuid) or (git_user ~= "" and nick == git_user) then
				is_rr = true
			end
		end

		table.insert(out, {
			number = p.id,
			title = p.title or "",
			author = author,
			state = state,
			branch = branch,
			url = (p.links and p.links.html and p.links.html.href) or "",
			updated_at = p.updated_on or p.created_on or "",
			unread_count = nil,
			reviewers = reviewers,
			is_mine = (git_user_uuid ~= "" and author_uuid == git_user_uuid) or (git_user ~= "" and author == git_user),
			is_assignee = false, -- Bitbucket Cloud has no assignee concept; always false.
			is_review_requested = is_rr,
		})
	end
	return out
end

---@param filter string
---@param callback fun(prs: PRSummary[])
function M.list_prs(filter, callback)
	callback = callback or function(_) end
	if M.pr_list[filter] then
		callback(M.pr_list[filter])
		return
	end

	M.get_git_user(vim.schedule_wrap(function(git_user)
		M.get_repo_info(vim.schedule_wrap(function(workspace, repo)
			if not workspace or not repo then
				callback({})
				return
			end
			local user_uuid = M.git_user_uuid or ""
			local q_parts = {}
			if filter == "mine" and user_uuid ~= "" then
				table.insert(q_parts, 'author.uuid="' .. user_uuid .. '"')
			elseif filter == "review-requested" and user_uuid ~= "" then
				table.insert(q_parts, 'reviewers.uuid="' .. user_uuid .. '"')
			elseif filter == "assigned" then
				vim.notify("Bitbucket Cloud has no assignee filter; falling back to 'all'")
			end
			-- Always restrict to OPEN PRs; for "all" we only constrain by state.
			local query
			if #q_parts > 0 then
				query = "?state=OPEN&pagelen=50&q=" .. M._url_encode(table.concat(q_parts, " AND "))
			else
				query = "?state=OPEN&pagelen=50"
			end

			local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests" .. query
			run_curl(
				"GET",
				path,
				nil,
				vim.schedule_wrap(function(ok, data)
					if not ok or not data then
						callback({})
						return
					end
					local prs = M._normalize_prs(data, git_user or "", user_uuid)
					M.pr_list[filter] = prs
					callback(prs)
				end)
			)
		end))
	end))
end

---@param pr_number integer
---@param callback fun(success: boolean, err: string?)
function M.checkout_pr(pr_number, callback)
	callback = callback or function(_, _) end

	M.get_repo_info(vim.schedule_wrap(function(workspace, repo)
		if not workspace or not repo then
			callback(false, "no repo info")
			return
		end
		local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. tostring(pr_number)
		run_curl(
			"GET",
			path,
			nil,
			vim.schedule_wrap(function(ok, data)
				if not ok or not data or not data.source or not data.source.branch or not data.source.branch.name then
					callback(false, "could not fetch PR metadata")
					return
				end
				local branch = data.source.branch.name
				local git_root = (M.git_root ~= nil and M.git_root ~= "") and M.git_root or "."

				-- git fetch origin <branch>
				Job:new({
					command = "git",
					args = { "-C", git_root, "fetch", "origin", branch },
					on_exit = vim.schedule_wrap(function(_, fetch_code)
						if fetch_code ~= 0 then
							local err = "git fetch origin " .. branch .. " failed"
							vim.notify(err, vim.log.levels.ERROR)
							callback(false, err)
							return
						end
						-- git checkout <branch>
						Job:new({
							command = "git",
							args = { "-C", git_root, "checkout", branch },
							on_exit = vim.schedule_wrap(function(_, ck_code)
								if ck_code ~= 0 then
									local err = "git checkout " .. branch .. " failed"
									vim.notify(err, vim.log.levels.ERROR)
									callback(false, err)
									return
								end
								vim.cmd("checktime")
								callback(true)
							end),
						}):start()
					end),
				}):start()
			end)
		)
	end))
end

function M.clear_pr_list()
	M.pr_list = {}
end

---@param callback fun(metadata: PRMetadata?)
function M.get_pr_metadata(callback)
	vim.notify("get_pr_metadata not implemented yet for bitbucket")
	if callback then
		callback(nil)
	end
end

---@param _fields { title?: string, body?: string }
---@param callback fun(success: boolean, err: string?)
function M.update_pr_metadata(_fields, callback)
	if callback then
		callback(false, "not implemented")
	end
end

---@param callback fun(checks: CheckRun[])
function M.get_checks(callback)
	if callback then
		callback({})
	end
end

function M.clear_pr_metadata()
	M.pr_metadata = nil
end

function M.clear_checks()
	M.checks = nil
end

--- Bitbucket Cloud has free-text PR comments but no first-class "draft review"
--- bundling multiple inline comments with an approval into a single submit
--- step. We fake it with a local on-disk queue (review_local), keyed by
--- (provider, owner, repo, pr). The review_id is the literal string "local"
--- since there's no upstream id to track.
---@param callback fun(review_id: string?, err: string?)
function M.start_pending_review(callback)
	callback = callback or function(_, _) end
	M.pending_review_id = "local"
	callback("local")
end

---@param _review_id string
---@param relative_path string
---@param start_line integer
---@param end_line integer
---@param body string
---@param callback fun(success: boolean, err: string?)
function M.add_review_comment(_review_id, relative_path, start_line, end_line, body, callback)
	callback = callback or function(_, _) end
	M.get_repo_info(vim.schedule_wrap(function(workspace, repo)
		if not workspace or not repo then
			return callback(false, "no repo info")
		end
		M.get_pr_number(vim.schedule_wrap(function(pr)
			if not pr or pr == 0 then
				return callback(false, "no PR")
			end
			local_review.save("bitbucket", workspace, repo, pr, {
				id = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)),
				path = relative_path,
				start_line = start_line,
				end_line = end_line,
				body = body,
			})
			callback(true)
		end))
	end))
end

---@param _review_id string
---@param callback fun(comments: PendingComment[])
function M.list_review_comments(_review_id, callback)
	callback = callback or function(_) end
	M.get_repo_info(vim.schedule_wrap(function(workspace, repo)
		if not workspace or not repo then
			return callback({})
		end
		M.get_pr_number(vim.schedule_wrap(function(pr)
			if not pr or pr == 0 then
				return callback({})
			end
			callback(local_review.load("bitbucket", workspace, repo, pr))
		end))
	end))
end

---@param _review_id string
---@param event string
---@param _body string?
---@param callback fun(success: boolean, err: string?)
function M.submit_review(_review_id, event, _body, callback)
	callback = callback or function(_, _) end
	-- v1: emit a notification per pending comment + event; the real bitbucket
	-- API wiring is deferred to a follow-up plan. For now we drop the pending
	-- state so the user sees the right "no pending" state on the next
	-- :PRReview invocation.
	vim.notify("bitbucket submit_review (" .. event .. ") not implemented end-to-end; pending comments will be retained until you discard", vim.log.levels.WARN)
	callback(false, "not implemented end-to-end")
end

---@param _review_id string
---@param callback fun(success: boolean, err: string?)
function M.discard_pending_review(_review_id, callback)
	callback = callback or function(_, _) end
	M.get_repo_info(vim.schedule_wrap(function(workspace, repo)
		if not workspace or not repo then
			return callback(false, "no repo info")
		end
		M.get_pr_number(vim.schedule_wrap(function(pr)
			if not pr or pr == 0 then
				return callback(false, "no PR")
			end
			local_review.clear("bitbucket", workspace, repo, pr)
			M.pending_review_id = nil
			callback(true)
		end))
	end))
end

function M.clear()
	M.comments = {}
	M.hunks = {}
	M.repo_info = {}
	M.pr_number = 0
	M.git_root = ""
	M.git_user = ""
	M.git_user_uuid = ""
	M.base_sha = ""
	M.pr_list = {}
	M.pr_metadata = nil
	M.checks = nil
	M.pending_review_id = nil
end

function M.clear_comments()
	M.comments = {}
end

function M.clear_hunks()
	M.hunks = {}
end

function M.clear_pr_number()
	M.pr_number = 0
end

function M.clear_pending_review()
	M.pending_review_id = nil
end

return M
