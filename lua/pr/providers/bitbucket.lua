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
local M = {}

M.git_root = ""
M.git_user = ""
---@type RepoInfo
M.repo_info = {}
M.pr_number = 0
---@type Comments
M.comments = {}
---@type Hunks
M.hunks = {}

---@type ReactionPaletteEntry[]
M.reaction_palette = {}

local API_BASE = "https://api.bitbucket.org/2.0"

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function url_encode(str)
	if not str then
		return ""
	end
	return (str:gsub("([^%w%-._~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
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
				vim.notify("Bitbucket curl failed: " .. table.concat(args, " "))
				vim.notify(vim.inspect(j:stderr_result()))
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
			local path = url:match("@[^:]+:(.+)%.git$") or url:match("@[^:]+:(.+)$")
			if not path then
				path = url:match("://[^/]+/(.+)%.git$") or url:match("://[^/]+/(.+)$")
			end
			if not path then
				vim.api.nvim_echo({ { "Could not determine Bitbucket project from remote 'origin'.", "ErrorMsg" } }, true, {})
				return
			end
			path = trim(path)
			local workspace, repo_slug = path:match("^([^/]+)/(.+)$")
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
			local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests?state=OPEN&pagelen=5&q=" .. url_encode(q)
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
local function build_threads(flat)
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
				local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. pr_number .. "/comments?pagelen=100"
				run_curl("GET", path, nil, function(ok, data)
					if not ok or not data or not data.values then
						return
					end

					local by_root = build_threads(data.values)

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
							local line = inline and (nil_if_vim_nil(inline.to) or nil_if_vim_nil(inline.from))

							if file and line then
								---@type CommentInfo[]
								local thread_comments = {}
								for _, c in ipairs(group) do
									if not c.deleted then
										local nick = (c.user and c.user.nickname) or (c.user and c.user.display_name) or "unknown"
										local mine = M.git_user ~= "" and nick == M.git_user
										table.insert(thread_comments, {
											database_id = c.id,
											author = nick,
											body = (c.content and c.content.raw) or "",
											start_line = line,
											end_line = line,
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

									local composed = {
										id = tostring(root_id),
										is_resolved = resolved,
										resolved_by = resolved_by,
										is_outdated = false,
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

					M.comments = comments
					vim.notify("You have " .. thread_count .. "(" .. unsolved_count .. ")" .. " comment threads")
					callback(comments)
				end)
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
	-- Bitbucket Cloud's inline comments are single-line on the destination side;
	-- start_line is collapsed onto end_line. (Range comments via line ranges
	-- aren't part of the public REST shape today.)
	local _ = start_line
	ensure_context(function(workspace, repo, pr)
		local path = "/repositories/" .. workspace .. "/" .. repo .. "/pullrequests/" .. pr .. "/comments"
		run_curl("POST", path, {
			content = { raw = body },
			inline = { path = relative_path, to = end_line },
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

function M.clear()
	M.comments = {}
	M.hunks = {}
	M.repo_info = {}
	M.pr_number = 0
	M.git_root = ""
	M.git_user = ""
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

return M
