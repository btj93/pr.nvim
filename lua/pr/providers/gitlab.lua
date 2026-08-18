local Job = require("plenary.job")
local util = require("pr.util")
local local_review = require("pr.review_local")
local log = require("pr.log")
local M = {}

M.git_root = ""
M.git_user = ""
--- @type RepoInfo
--- (`owner` holds the namespace path — possibly nested for groups/subgroups —
---  and `repo` holds the project slug. `project_path` is owner .. "/" .. repo,
---  used to address the project in `glab api` URLs.)
M.repo_info = {}
M.pr_number = 0
M.base_sha = ""
---@type string?
M.pending_review_id = nil

--- DiffRefs required when posting a new inline comment. Populated as a side-effect
--- of `get_comments` (returned by the same GraphQL query) and used by `M.comment`.
---@class GitLabDiffRefs
---@field base_sha string
---@field head_sha string
---@field start_sha string
---@type GitLabDiffRefs?
M.diff_refs = nil

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

-- Canonical reaction keys are uppercase ASCII names (GitHub GraphQL enum values
-- plus a curated set of GitLab extras). The rest of the plugin only speaks
-- canonical keys; we translate to/from GitLab award-emoji names at the boundary.
M._REACTION_TO_AWARD = {
	THUMBS_UP = "thumbsup",
	THUMBS_DOWN = "thumbsdown",
	-- LAUGH maps to gemoji `smile` (😄) — the glyph GitHub uses for its LAUGH reaction.
	LAUGH = "smile",
	HOORAY = "tada",
	CONFUSED = "confused",
	HEART = "heart",
	ROCKET = "rocket",
	EYES = "eyes",
	FIRE = "fire",
	PARTY = "partying_face",
	WAVE = "wave",
	CLAP = "clap",
}
-- Inverse mapping. Some canonical keys accept multiple inbound names
-- (e.g. LAUGH accepts both `smile` and `laughing`).
M._AWARD_TO_REACTION = {
	thumbsup = "THUMBS_UP",
	thumbsdown = "THUMBS_DOWN",
	smile = "LAUGH",
	laughing = "LAUGH",
	tada = "HOORAY",
	confused = "CONFUSED",
	heart = "HEART",
	rocket = "ROCKET",
	eyes = "EYES",
	fire = "FIRE",
	partying_face = "PARTY",
	wave = "WAVE",
	clap = "CLAP",
}

--- See github.lua for the type. Order is the menu display order.
---@type ReactionPaletteEntry[]
M.reaction_palette = {
	{ content = "THUMBS_UP", glyph = "👍" },
	{ content = "THUMBS_DOWN", glyph = "👎" },
	{ content = "LAUGH", glyph = "😄" },
	{ content = "HOORAY", glyph = "🎉" },
	{ content = "CONFUSED", glyph = "😕" },
	{ content = "HEART", glyph = "❤️" },
	{ content = "ROCKET", glyph = "🚀" },
	{ content = "EYES", glyph = "👀" },
	{ content = "FIRE", glyph = "🔥" },
	{ content = "PARTY", glyph = "🥳" },
	{ content = "WAVE", glyph = "👋" },
	{ content = "CLAP", glyph = "👏" },
}

function M._url_encode(str)
	if not str then
		return ""
	end
	return (str:gsub("([^%w%-._~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- "gid://gitlab/Note/12345" -> 12345
function M._parse_global_id(gid)
	if type(gid) ~= "string" then
		return nil
	end
	local n = gid:match("/(%d+)$")
	return tonumber(n)
end

-- Discussions are addressed by a hex hash, not a numeric id.
-- "gid://gitlab/Discussion/abc123" -> "abc123"
function M._parse_discussion_id(gid)
	if type(gid) ~= "string" then
		return nil
	end
	return gid:match("Discussion/(.+)$") or gid
end

local function nil_if_vim_nil(v)
	if v == nil or v == vim.NIL then
		return nil
	end
	return v
end

--- Parse `git remote get-url origin` output into namespace path + slug.
--- Returns nil on a URL we don't recognise.
---@param url string
---@return string|nil owner Namespace path (may contain slashes for nested groups). Empty string for single-segment paths; nil for unrecognised URLs.
---@return string|nil repo Project slug
---@return string|nil project_path Full namespace/project path
function M._parse_remote_url(url)
	url = trim(url)
	local path = url:match("@[^:]+:(.+)%.git$") or url:match("@[^:]+:(.+)$")
	if not path then
		path = url:match("://[^/]+/(.+)%.git$") or url:match("://[^/]+/(.+)$")
	end
	if not path then
		return nil, nil, nil
	end
	path = trim(path)
	local owner, repo = path:match("^(.+)/([^/]+)$")
	if not owner then
		return "", path, path
	end
	return owner, repo, path
end

--- Pure transformation from a parsed `glab api graphql` response into the
--- canonical Comments shape. Exposed for unit testing.
---@param data table Decoded JSON from glab api graphql
---@param git_user string The authenticated user's nickname (used to derive viewer_did_author).
---@return Comments|nil comments
---@return integer thread_count
---@return integer unsolved_count
---@return GitLabDiffRefs|nil diff_refs
function M._normalize_comments(data, git_user)
	if not data or not data.data or not data.data.project or not data.data.project.mergeRequest then
		return nil, 0, 0, nil
	end
	local mr = data.data.project.mergeRequest

	local diff_refs = nil
	if mr.diffRefs and mr.diffRefs ~= vim.NIL then
		diff_refs = {
			base_sha = mr.diffRefs.baseSha,
			head_sha = mr.diffRefs.headSha,
			start_sha = mr.diffRefs.startSha,
		}
	end

	---@type Comments
	local comments = {}
	local thread_count = 0
	local unsolved_count = 0

	for _, discussion in ipairs(mr.discussions.nodes or {}) do
		---@type CommentInfo[]
		local thread = {}
		local file = nil
		local thread_is_outdated = false

		for _, note in ipairs(discussion.notes.nodes or {}) do
			local pos = nil_if_vim_nil(note.position)
			if not note.system and pos then
				local new_path = nil_if_vim_nil(pos.newPath)
				local old_path = nil_if_vim_nil(pos.oldPath)
				local path = new_path or old_path
				local new_line = nil_if_vim_nil(pos.newLine)
				local old_line = nil_if_vim_nil(pos.oldLine)
				local line = new_line or old_line
				local note_is_outdated = new_line == nil and old_line ~= nil
				if note_is_outdated then
					thread_is_outdated = true
				end

				if path and line then
					file = file or path

					local start_line = line
					local end_line = line
					local line_range = nil_if_vim_nil(pos.lineRange)
					if line_range then
						local rs = nil_if_vim_nil(line_range.start)
						local re = nil_if_vim_nil(line_range["end"])
						if rs then
							local rs_new = nil_if_vim_nil(rs.newLine)
							local rs_old = nil_if_vim_nil(rs.oldLine)
							start_line = rs_new or rs_old or line
						end
						if re then
							local re_new = nil_if_vim_nil(re.newLine)
							local re_old = nil_if_vim_nil(re.oldLine)
							end_line = re_new or re_old or line
						end
					end

					local groups_by_content = {}
					local award_nodes = (note.awardEmoji and note.awardEmoji.nodes) or {}
					for _, ae in ipairs(award_nodes) do
						local content_key = M._AWARD_TO_REACTION[ae.name] or string.upper(ae.name)
						if not groups_by_content[content_key] then
							groups_by_content[content_key] = {
								content = content_key,
								viewerHasReacted = false,
								reactors = { totalCount = 0, nodes = {} },
							}
						end
						local g = groups_by_content[content_key]
						g.reactors.totalCount = g.reactors.totalCount + 1
						local user_login = (ae.user and ae.user.username) or "unknown"
						if git_user ~= "" and user_login == git_user then
							g.viewerHasReacted = true
						end
						table.insert(g.reactors.nodes, {
							database_id = M._parse_global_id(ae.id),
							content = content_key,
							user = user_login,
						})
					end
					local reaction_groups = {}
					for _, g in pairs(groups_by_content) do
						table.insert(reaction_groups, g)
					end

					local author_login = (note.author and note.author.username) or "unknown"
					local perm = note.userPermissions or {}

					table.insert(thread, {
						database_id = M._parse_global_id(note.id),
						author = author_login,
						body = note.body,
						start_line = start_line,
						end_line = end_line,
						viewer_can_update = perm.adminNote or false,
						viewer_can_react = perm.awardEmoji ~= false, -- nil means "not explicitly forbidden"
						viewer_can_delete = perm.adminNote or false,
						reaction_groups = reaction_groups,
						published_at = note.createdAt,
						updated_at = note.updatedAt,
						viewer_did_author = git_user ~= "" and author_login == git_user,
					})
				end
			end
		end

		if file and #thread > 0 then
			local file_threads = comments[file] or {}
			local resolvable = discussion.resolvable or false
			local resolved = discussion.resolved or false
			local resolved_by = nil
			if discussion.resolvedBy and discussion.resolvedBy ~= vim.NIL then
				resolved_by = discussion.resolvedBy.username
			end

			local composed = {
				id = M._parse_discussion_id(discussion.id),
				is_resolved = resolved,
				resolved_by = resolved_by,
				is_outdated = thread_is_outdated,
				is_collapsed = false,
				viewer_can_reply = true,
				viewer_can_resolve = resolvable and not resolved,
				viewer_can_unresolve = resolvable and resolved,
				comments = thread,
			}

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

	return comments, thread_count, unsolved_count, diff_refs
end

local function project_url()
	return "/projects/" .. M._url_encode(M.repo_info.project_path)
end

local function mr_url()
	return project_url() .. "/merge_requests/" .. M.pr_number
end

local function run_glab(args, on_done)
	Job:new({
		command = "glab",
		args = args,
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				log.command_failed("GitLab API command", "glab", args, j:stderr_result(), { hint = "Is a glab cli installed?", code = code })
			end
			on_done(code == 0, j)
		end),
	}):start()
end

-- Run a getter chain (repo_info -> pr_number) so a mutation has a project + iid
-- to address. Short-circuits silently on failure to match github.lua's behavior.
local function ensure_context(fn)
	M.get_repo_info(vim.schedule_wrap(function()
		if not M.repo_info.project_path then
			return
		end
		M.get_pr_number(vim.schedule_wrap(function(pr_number)
			if not pr_number then
				return
			end
			fn()
		end))
	end))
end

---
---@param callback? fun(git_root: string)
function M.get_git_root(callback)
	callback = callback or function(_) end
	if M.git_root ~= "" then
		callback(M.git_root)
		return
	end

	local args = { "rev-parse", "--show-toplevel" }
	Job:new({
		command = "git",
		args = args,
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				log.command_failed("Git root lookup", "git", args, j:stderr_result(), { hint = "Is a git cli installed?", code = code })
				return
			end
			local result = j:result()
			local _, t = next(result)
			if t then
				M.git_root = t
			else
				vim.notify("No result from git rev-parse command. Is a git cli installed?")
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

	local args = { "api", "/user", "--jq", ".username" }
	Job:new({
		command = "glab",
		args = args,
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				log.command_failed("GitLab user lookup", "glab", args, j:stderr_result(), { hint = "Is a glab cli installed?", code = code })
				return
			end
			local result = j:result()
			local _, t = next(result)
			if t then
				M.git_user = t
				vim.notify("Logged in as " .. t)
			else
				vim.notify("No result from glab user command. Is a glab cli installed?")
			end
			callback(M.git_user)
		end),
	}):start()
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
				vim.api.nvim_echo({ { "Could not determine GitLab project from remote 'origin'.", "ErrorMsg" } }, true, {})
				return
			end
			local result = j:result()
			local _, t = next(result)
			if not t then
				vim.api.nvim_echo({ { "Could not determine GitLab project from remote 'origin'.", "ErrorMsg" } }, true, {})
				return
			end
			local url = trim(t)
			local owner, repo, project_path = M._parse_remote_url(url)
			if not project_path then
				vim.api.nvim_echo({ { "Could not determine GitLab project from remote 'origin'.", "ErrorMsg" } }, true, {})
				return
			end
			M.repo_info = { owner = owner, repo = repo, project_path = project_path }
			callback(owner, repo)
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

	Job:new({
		command = "glab",
		args = { "mr", "view", "--json", "iid" },
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				vim.notify("No MR open for this branch")
				return
			end
			local result = j:result()
			local body = table.concat(result, "\n")
			local ok, data = pcall(vim.json.decode, body)
			if not ok or type(data) ~= "table" or not data.iid then
				vim.notify("Could not get MR number. Is a glab cli installed?")
				return
			end
			local iid = tonumber(data.iid) or data.iid
			M.pr_number = iid
			callback(iid)
		end),
	}):start()
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
				vim.api.nvim_echo({ { "Could not determine commit hash.", "ErrorMsg" } }, true, {})
				return
			end
			callback(t)
		end),
	}):start()
end

--- Resolve the MR's base-branch HEAD commit sha. Used by util.open_pr_file
--- to fetch the original content of files deleted in the MR.
---@param callback? fun(sha: string)
function M.get_base_sha(callback)
	callback = callback or function(_) end
	if M.base_sha ~= "" then
		callback(M.base_sha)
		return
	end

	-- diff_refs is populated as a side-effect of get_comments; fall through to
	-- a direct REST call when it's not yet available.
	if M.diff_refs and M.diff_refs.base_sha then
		M.base_sha = M.diff_refs.base_sha
		callback(M.base_sha)
		return
	end

	ensure_context(function()
		local project_id = M._url_encode(M.repo_info.project_path)
		Job:new({
			command = "glab",
			args = { "api", "/projects/" .. project_id .. "/merge_requests/" .. M.pr_number, "--jq", ".diff_refs.base_sha" },
			on_exit = vim.schedule_wrap(function(j, code)
				if code ~= 0 then
					vim.notify("Could not fetch MR base sha. Is glab installed?")
					return
				end
				local result = j:result()
				local _, t = next(result)
				if t then
					M.base_sha = t
				end
				callback(M.base_sha)
			end),
		}):start()
	end)
end

local DISCUSSIONS_QUERY = [[
query($fullPath: ID!, $iid: String!) {
  project(fullPath: $fullPath) {
    mergeRequest(iid: $iid) {
      diffRefs { baseSha headSha startSha }
      discussions(first: 100) {
        nodes {
          id
          resolvable
          resolved
          resolvedBy { username }
          notes(first: 100) {
            nodes {
              id
              author { username }
              body
              createdAt
              updatedAt
              system
              userPermissions {
                adminNote
                awardEmoji
              }
              position {
                newLine
                oldLine
                newPath
                oldPath
                lineRange {
                  start { newLine oldLine }
                  end { newLine oldLine }
                }
              }
              awardEmoji {
                nodes {
                  id
                  name
                  user { username }
                }
              }
            }
          }
        }
      }
    }
  }
}
]]

---
---@param callback? fun(comments: Comments)
function M.get_comments(callback)
	callback = callback or function(_) end

	if next(M.comments) then
		callback(M.comments)
		return
	end

	-- git_user is needed to derive viewer_did_author / viewerHasReacted, which
	-- the GitLab GraphQL schema doesn't expose directly on Note / AwardEmoji.
	M.get_git_user(vim.schedule_wrap(function(_)
		M.get_repo_info(vim.schedule_wrap(function()
			if not M.repo_info.project_path then
				return
			end
			M.get_pr_number(vim.schedule_wrap(function(pr_number)
				if not pr_number then
					return
				end

				local args = {
					"api",
					"graphql",
					"-f",
					"fullPath=" .. M.repo_info.project_path,
					"-f",
					"iid=" .. tostring(pr_number),
					"-f",
					"query=" .. DISCUSSIONS_QUERY,
				}

				Job:new({
					command = "glab",
					args = args,
					on_exit = vim.schedule_wrap(function(j, code)
						if code ~= 0 then
							log.command_failed("GitLab discussion fetch", "glab", args, j:stderr_result(), { hint = "Is a glab cli installed?", code = code })
							return
						end

						local body = table.concat(j:result(), "\n")
						local ok, data = pcall(vim.json.decode, body)
						if not ok then
							vim.notify("Unexpected GraphQL response structure.")
							return
						end

						local comments, thread_count, unsolved_count, diff_refs = M._normalize_comments(data, M.git_user)
						if not comments then
							vim.notify("Unexpected GraphQL response structure.")
							return
						end

						if diff_refs then
							M.diff_refs = diff_refs
						end

						M.comments = comments
						vim.notify("You have " .. thread_count .. "(" .. unsolved_count .. ")" .. " comment threads")
						callback(comments)
					end),
				}):start()
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

	M.get_repo_info(vim.schedule_wrap(function()
		if not M.repo_info.project_path then
			return
		end
		M.get_pr_number(vim.schedule_wrap(function(pr_number)
			if not pr_number then
				return
			end

			Job:new({
				command = "glab",
				args = { "mr", "diff" },
				on_exit = vim.schedule_wrap(function(j, code)
					if code ~= 0 then
						vim.notify("Error running glab mr diff command. Is a glab cli installed?")
						return
					end
					local diff_lines = j:result()
					if not diff_lines or #diff_lines == 0 then
						vim.notify("No result from glab mr diff command. Is a glab cli installed?")
						return
					end

					M.hunks = util.parse_diff_hunks(diff_lines)
					callback(M.hunks)
				end),
			}):start()
		end))
	end))
end

---
---@param comment_id integer
---@param reaction_key string Canonical key (e.g., "THUMBS_UP").
---@param callback? fun(success: boolean)
function M.add_reaction(comment_id, reaction_key, callback)
	callback = callback or function(_) end
	ensure_context(function()
		local award_name = M._REACTION_TO_AWARD[reaction_key] or string.lower(reaction_key)
		run_glab({
			"api",
			"--method",
			"POST",
			mr_url() .. "/notes/" .. comment_id .. "/award_emoji",
			"-f",
			"name=" .. award_name,
		}, function(ok)
			callback(ok)
		end)
	end)
end

---
---@param comment_id integer
---@param reaction_id integer
---@param callback? fun(success: boolean)
function M.remove_reaction(comment_id, reaction_id, callback)
	callback = callback or function(_) end
	ensure_context(function()
		run_glab({
			"api",
			"--method",
			"DELETE",
			mr_url() .. "/notes/" .. comment_id .. "/award_emoji/" .. reaction_id,
		}, function(ok)
			callback(ok)
		end)
	end)
end

-- GitLab REST replies are anchored to a *discussion*, not a note. We resolve the
-- containing discussion by searching the cached comments — fine because the UI
-- only invokes reply after a popup has been opened (which populates the cache).
local function find_discussion_id_for_note(note_id)
	for _, file_threads in pairs(M.comments) do
		for _, thread in ipairs(file_threads) do
			for _, c in ipairs(thread.comments) do
				if c.database_id == note_id then
					return thread.id
				end
			end
		end
	end
	return nil
end

---
---@param comment_id integer
---@param body string
---@param callback? fun(success: boolean)
function M.reply(comment_id, body, callback)
	callback = callback or function(_) end
	local discussion_id = find_discussion_id_for_note(comment_id)
	if not discussion_id then
		vim.notify("Could not find discussion for comment " .. tostring(comment_id) .. ". Try refreshing.")
		callback(false)
		return
	end
	ensure_context(function()
		run_glab({
			"api",
			"--method",
			"POST",
			mr_url() .. "/discussions/" .. discussion_id .. "/notes",
			"-f",
			"body=" .. body,
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
	ensure_context(function()
		if not M.diff_refs then
			vim.notify("GitLab diff refs not loaded. Open the PR comments view (or refresh) first.")
			callback(false)
			return
		end

		local args = {
			"api",
			"--method",
			"POST",
			mr_url() .. "/discussions",
			"-f",
			"body=" .. body,
			"-f",
			"position[position_type]=text",
			"-f",
			"position[base_sha]=" .. M.diff_refs.base_sha,
			"-f",
			"position[head_sha]=" .. M.diff_refs.head_sha,
			"-f",
			"position[start_sha]=" .. M.diff_refs.start_sha,
			"-f",
			"position[new_path]=" .. relative_path,
			"-f",
			"position[old_path]=" .. relative_path,
			"-F",
			"position[new_line]=" .. end_line,
		}
		if start_line and end_line and start_line ~= end_line then
			table.insert(args, "-F")
			table.insert(args, "position[line_range][start][new_line]=" .. start_line)
			table.insert(args, "-F")
			table.insert(args, "position[line_range][end][new_line]=" .. end_line)
		end
		run_glab(args, function(ok)
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
	ensure_context(function()
		run_glab({
			"api",
			"--method",
			"PUT",
			mr_url() .. "/notes/" .. comment_id,
			"-f",
			"body=" .. body,
		}, function(ok)
			callback(ok)
		end)
	end)
end

---Stub: silent no-op. Returns nil so callers (conflict-aware edit) skip the
---remote-change check and proceed with the edit.
---@param _comment_id integer|string
---@param callback fun(comment: any?)
function M.refetch_comment(_comment_id, callback)
	if callback then
		callback(nil)
	end
end

---
---@param thread_id string Discussion hex hash (what we stored as `thread.id`).
---@param callback? fun(success: boolean)
function M.resolve_thread(thread_id, callback)
	callback = callback or function(_) end
	ensure_context(function()
		run_glab({
			"api",
			"--method",
			"PUT",
			mr_url() .. "/discussions/" .. thread_id,
			"-F",
			"resolved=true",
		}, function(ok)
			callback(ok)
		end)
	end)
end

---
---@param thread_id string
---@param callback? fun(success: boolean)
function M.unresolve_thread(thread_id, callback)
	callback = callback or function(_) end
	ensure_context(function()
		run_glab({
			"api",
			"--method",
			"PUT",
			mr_url() .. "/discussions/" .. thread_id,
			"-F",
			"resolved=false",
		}, function(ok)
			callback(ok)
		end)
	end)
end

---
---@param comment_id integer
---@param callback? fun(success: boolean)
function M.delete_comment(comment_id, callback)
	callback = callback or function(_) end
	ensure_context(function()
		run_glab({
			"api",
			"--method",
			"DELETE",
			mr_url() .. "/notes/" .. comment_id,
		}, function(ok)
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
	return string.format("https://gitlab.com/%s/%s/-/merge_requests/%d#note_%s", M.repo_info.owner, M.repo_info.repo, M.pr_number, tostring(comment.database_id))
end

---@param _filter string
---@param callback fun(prs: PRSummary[])
function M.list_prs(_filter, callback)
	vim.notify("list_prs not implemented yet for gitlab")
	if callback then
		callback({})
	end
end

---@param _pr_number integer
---@param callback fun(success: boolean, err: string?)
function M.checkout_pr(_pr_number, callback)
	vim.notify("checkout_pr not implemented yet for gitlab")
	if callback then
		callback(false, "not implemented")
	end
end

function M.clear_pr_list()
	M.pr_list = {}
end

---@param callback fun(metadata: PRMetadata?)
function M.get_pr_metadata(callback)
	vim.notify("get_pr_metadata not implemented yet for gitlab")
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

--- GitLab has no server-side draft-review concept that bundles multiple inline
--- comments + an approval into a single submit step. We fake it with a local
--- on-disk queue (review_local), keyed by (provider, owner, repo, pr). The
--- review_id is the literal string "local" since there's no upstream id to
--- track.
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
	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not owner or not repo then
			return callback(false, "no repo info")
		end
		M.get_pr_number(vim.schedule_wrap(function(pr)
			if not pr or pr == 0 then
				return callback(false, "no PR")
			end
			local_review.save("gitlab", owner, repo, pr, {
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
	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not owner or not repo then
			return callback({})
		end
		M.get_pr_number(vim.schedule_wrap(function(pr)
			if not pr or pr == 0 then
				return callback({})
			end
			callback(local_review.load("gitlab", owner, repo, pr))
		end))
	end))
end

---@param _review_id string
---@param event string
---@param _body string?
---@param callback fun(success: boolean, err: string?)
function M.submit_review(_review_id, event, _body, callback)
	callback = callback or function(_, _) end
	-- v1: emit a notification per pending comment + event; the real glab/api wiring
	-- is deferred to a follow-up plan. For now we drop the pending state so the
	-- user sees the right "no pending" state on the next :PRReview invocation.
	vim.notify("gitlab submit_review (" .. event .. ") not implemented end-to-end; pending comments will be retained until you discard", vim.log.levels.WARN)
	callback(false, "not implemented end-to-end")
end

---@param _review_id string
---@param callback fun(success: boolean, err: string?)
function M.discard_pending_review(_review_id, callback)
	callback = callback or function(_, _) end
	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not owner or not repo then
			return callback(false, "no repo info")
		end
		M.get_pr_number(vim.schedule_wrap(function(pr)
			if not pr or pr == 0 then
				return callback(false, "no PR")
			end
			local_review.clear("gitlab", owner, repo, pr)
			M.pending_review_id = nil
			callback(true)
		end))
	end))
end

---@type { login: string, name: string? }[]|nil
M.collaborators = nil

---@type { number: integer, title: string, state: string }[]|nil
M.issues = nil

---@param callback fun(users: any[])
function M.list_collaborators(callback)
	if callback then
		callback({})
	end
end

---@param callback fun(issues: any[])
function M.list_issues(callback)
	if callback then
		callback({})
	end
end

function M.clear_collaborators()
	M.collaborators = nil
end

function M.clear_issues()
	M.issues = nil
end

function M.clear()
	M.comments = {}
	M.hunks = {}
	M.repo_info = {}
	M.pr_number = 0
	M.git_root = ""
	M.git_user = ""
	M.diff_refs = nil
	M.base_sha = ""
	M.pr_list = {}
	M.pr_metadata = nil
	M.checks = nil
	M.pending_review_id = nil
	M.collaborators = nil
	M.issues = nil
end

function M.clear_comments()
	M.comments = {}
end

function M.clear_hunks()
	M.hunks = {}
end

function M.clear_pr_number()
	M.pr_number = 0
	-- diff_refs are scoped to a specific MR, so drop them with the pr number.
	M.diff_refs = nil
end

function M.clear_pending_review()
	M.pending_review_id = nil
end

return M
