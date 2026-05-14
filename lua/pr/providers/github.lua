-- Shared types (RepoInfo, ReviewThread, CommentInfo, Comments, Hunk, Hunks,
-- ReactionPaletteEntry, ...) are declared in pr.providers.interface; see that
-- file for the full provider contract.

local Job = require("plenary.job")
local util = require("pr.util")
local M = {}

M.git_root = ""
M.git_user = ""
---@type RepoInfo
M.repo_info = {}
M.pr_number = 0
M.base_sha = ""

---@type Comments
M.comments = {}

---@type Hunks
M.hunks = {}

---@type table<string, PRSummary[]>
M.pr_list = {}

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
}

--- Pure transformation from a parsed `gh api graphql` reviewThreads response
--- into the canonical Comments shape. Exposed for unit testing.
---@param data table Decoded JSON from gh api graphql
---@return Comments|nil comments
---@return integer thread_count
---@return integer unsolved_count
--- Returns 3 values: (comments, thread_count, unsolved_count).
--- Note: gitlab's `_normalize_comments` adds a 4th value (diff_refs).
function M._normalize_comments(data)
	if not data or not data.data or not data.data.repository or not data.data.repository.pullRequest or not data.data.repository.pullRequest.reviewThreads then
		return nil, 0, 0
	end
	local threads = data.data.repository.pullRequest.reviewThreads.edges

	---@type Comments
	local comments = {}
	local thread_count = 0
	local unsolved_count = 0

	for _, thread_edge in ipairs(threads) do
		---@type CommentInfo[]
		local thread = {}
		local file = ""
		local thread_info = thread_edge.node
		for _, comment_edge in ipairs(thread_info.comments.edges) do
			local comment = comment_edge.node
			if comment.line ~= vim.NIL or comment.originalLine ~= vim.NIL then
				local line = comment.line
				if comment.line == vim.NIL then
					line = comment.originalLine
				end

				local start_line = comment.startLine
				if comment.startLine == vim.NIL then
					if comment.originalStartLine == vim.NIL then
						start_line = line
					else
						start_line = comment.originalStartLine
					end
				end
				file = comment.path
				local author = comment.author and comment.author.login or "unknown"
				local reactionGroups = comment.reactionGroups

				local reactions_by_content = {}
				for _, reaction in ipairs(comment.reactions.nodes) do
					if not reactions_by_content[reaction.content] then
						reactions_by_content[reaction.content] = {}
					end
					table.insert(reactions_by_content[reaction.content], {
						database_id = reaction.databaseId,
						content = reaction.content,
						user = reaction.user.login,
					})
				end

				for _, reactionGroup in ipairs(reactionGroups) do
					reactionGroup.reactors.nodes = reactions_by_content[reactionGroup.content]
				end

				table.insert(thread, {
					database_id = comment.databaseId,
					author = author,
					body = comment.body,
					start_line = start_line,
					end_line = line,
					viewer_can_update = comment.viewerCanUpdate,
					viewer_can_react = comment.viewerCanReact,
					viewer_can_delete = comment.viewerCanDelete,
					reaction_groups = comment.reactionGroups,
					published_at = comment.publishedAt,
					updated_at = comment.updatedAt,
					viewer_did_author = comment.viewerDidAuthor,
				})
			end
		end
		local c = comments[file] or {}
		local composed = {
			id = thread_info.id,
			is_resolved = thread_info.isResolved,
			resolved_by = thread_info.resolvedBy ~= vim.NIL and thread_info.resolvedBy.login or nil,
			is_outdated = thread_info.isOutdated,
			is_collapsed = thread_info.isCollapsed,
			viewer_can_reply = thread_info.viewerCanReply,
			viewer_can_resolve = thread_info.viewerCanResolve,
			viewer_can_unresolve = thread_info.viewerCanUnresolve,
			comments = thread,
		}

		local found = false
		for i, th in ipairs(c) do
			if th.id == thread_info.id then
				c[i] = composed
				found = true
				break
			end
		end
		if not found then
			table.insert(c, composed)
		end
		comments[file] = c
		thread_count = thread_count + 1
		if not thread_info.isResolved then
			unsolved_count = unsolved_count + 1
		end
	end

	return comments, thread_count, unsolved_count
end

--- Pure transformation from a decoded `gh pr list --json ...` array into the
--- canonical PRSummary[] shape. Exposed for unit testing.
---@param raw table[]   -- decoded JSON array from `gh pr list --json ...`
---@return PRSummary[]
function M._normalize_prs(raw)
	local out = {}
	for _, p in ipairs(raw or {}) do
		local author = p.author and p.author.login or ""
		local state = p.isDraft and "draft" or string.lower(p.state or "open")
		local reviewers = {}
		for _, rr in ipairs(p.reviewRequests or {}) do
			if rr.login then
				table.insert(reviewers, rr.login)
			end
		end
		local is_assignee = false
		for _, a in ipairs(p.assignees or {}) do
			if a.login == M.git_user then
				is_assignee = true
			end
		end
		local is_rr = false
		for _, r in ipairs(reviewers) do
			if r == M.git_user then
				is_rr = true
			end
		end
		table.insert(out, {
			number = p.number,
			title = p.title,
			author = author,
			state = state,
			branch = p.headRefName,
			url = p.url,
			updated_at = p.updatedAt,
			unread_count = nil,
			reviewers = reviewers,
			is_mine = author == M.git_user,
			is_assignee = is_assignee,
			is_review_requested = is_rr,
		})
	end
	return out
end

---
---@param callback? fun(owner: string, repo: string)
---@return nil
function M.get_repo_info(callback)
	callback = callback or function(_, _) end
	if M.repo_info.owner and M.repo_info.repo then
		callback(M.repo_info.owner, M.repo_info.repo)
		return
	end

	Job:new({
		command = "git",
		args = { "remote", "get-url", "origin" },
		on_exit = vim.schedule_wrap(function(j, return_val)
			if return_val ~= 0 then
				vim.api.nvim_echo({ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } }, true, {})
				return
			end
			local result_json = j:result()
			local _, t = next(result_json)
			if not t then
				vim.api.nvim_echo({ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } }, true, {})
				return
			end

			local remote_url = t
			-- Match git@github.com:owner/repo.git OR https://github.com/owner/repo.git
			local owner, repo = remote_url:match("[:/]([^/]+)/([^/]+)%.git$")
			if not owner then
				-- Match https://github.com/owner/repo (no .git suffix)
				owner, repo = remote_url:match("github%.com/([^/]+)/([^/]+)$")
			end
			if owner and repo then
				M.repo_info = { owner = owner, repo = repo }
			else
				vim.api.nvim_echo({ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } }, true, {})
			end
			callback(owner, repo)
		end),
	}):start()
end

-- Helper to get the current PR number
---
---@param callback? fun(pr_number: number)
function M.get_pr_number(callback)
	callback = callback or function(_) end
	if M.pr_number > 0 then
		callback(M.pr_number)
		return
	end

	Job:new({
		command = "gh",
		args = { "pr", "view", "--json", "number", "--jq", ".number" },
		on_exit = vim.schedule_wrap(function(j, return_val)
			if return_val ~= 0 then
				vim.notify("No PR open for this branch")
				return
			end
			local result_json = j:result()
			local _, t = next(result_json)
			if not t then
				vim.notify("No PR open for this branch")
				return
			end

			local pr_number_str = t
			local pr_number = tonumber(pr_number_str)
			if not pr_number then
				vim.notify("Could not get PR number. Is a gh cli installed?")
			else
				M.pr_number = pr_number
			end
			callback(pr_number)
		end),
	}):start()
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

	Job:new({
		command = "gh",
		args = { "pr", "view", "--json", "baseRefOid", "--jq", ".baseRefOid" },
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				vim.notify("Could not fetch PR base sha. Is a gh cli installed?")
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
end

-- Helper to get current commit hash
---
---@param callback? fun(hash: string)
---@return nil
function M.get_commit_hash(callback)
	callback = callback or function(_, _) end

	Job:new({
		command = "git",
		args = { "rev-parse", "HEAD" },
		on_exit = vim.schedule_wrap(function(j, return_val)
			if return_val ~= 0 then
				vim.api.nvim_echo({ { "Could not determine commit hash.", "ErrorMsg" } }, true, {})
				return
			end
			local result_json = j:result()
			local _, t = next(result_json)
			if not t then
				vim.api.nvim_echo({ { "Could not determine commit hash.", "ErrorMsg" } }, true, {})
				return
			end

			local hash = t

			if not hash then
				vim.api.nvim_echo({ { "Could not determine commit hash.", "ErrorMsg" } }, true, {})
			end
			callback(hash)
		end),
	}):start()
end

---
---@param callback function?(comments: Comments)
function M.get_comments(callback)
	callback = callback or function(_) end

	if next(M.comments) then
		callback(M.comments)
		return
	end

	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo({ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } }, true, {})
			return
		end
		M.get_pr_number(vim.schedule_wrap(function(pr_number)
			if not pr_number then
				return
			end

			-- ref: https://docs.github.com/en/graphql/reference/objects#pullrequestreviewcomment
			local query_template = [[
    query($owner: String!, $name: String!, $prNumber: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $prNumber) {
          reviewThreads(first: 100) {
            edges {
              node {
                id
                isResolved
                resolvedBy {
                  login
                }
                isOutdated
                isCollapsed
                viewerCanReply
                viewerCanResolve
                viewerCanUnresolve
                comments(first: 100) {
                  edges {
                    node {
                      databaseId
                      author { login }
                      body
                      path
                      publishedAt
                      updatedAt
                      viewerDidAuthor
                      viewerCanUpdate
                      viewerCanDelete
                      viewerCanReact
                      line
                      startLine
                      originalLine
                      originalStartLine
                      reactionGroups {
                        content
                        viewerHasReacted
                        reactors {
                          totalCount
                        }
                      }
                      reactions(first: 10) {
                        nodes {
                          databaseId
                          content
                          user {
                            login
                          }
                        }
                      }
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

			local args = {
				"api",
				"graphql",
				"-F",
				"owner=" .. owner,
				"-F",
				"name=" .. repo,
				"-F",
				"prNumber=" .. pr_number,
				"-f",
				"query=" .. query_template,
			}
			Job:new({
				command = "gh",
				args = args,
				on_exit = function(j, return_val)
					if return_val ~= 0 then
						vim.notify(table.concat(args, " "))
						vim.notify(vim.inspect(j:result()))
						vim.notify("Error running gh api graphql command. Is a gh cli installed?")
						return
					end

					local result_json = j:result()
					local _, t = next(result_json)
					if not t then
						vim.notify("No result from gh api graphql command. Is a gh cli installed?")
						return
					end

					local data = vim.json.decode(t)
					local comments, thread_count, unsolved_count = M._normalize_comments(data)
					if not comments then
						vim.notify("Unexpected GraphQL response structure.")
						return
					end

					M.comments = comments
					vim.notify("You have " .. thread_count .. "(" .. unsolved_count .. ")" .. " comment threads")
					callback(comments)
				end,
			}):start()
		end))
	end))
end

---
---@param callback function?(git_root: string)
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
		on_exit = function(j, return_val)
			if return_val ~= 0 then
				vim.notify(table.concat(args, " "))
				vim.notify(vim.inspect(j:result()))
				vim.notify("Error running git rev-parse command. Is a git cli installed?")
				return
			end
			local result_json = j:result()
			local _, t = next(result_json)
			if not t then
				vim.notify("No result from git rev-parse command. Is a git cli installed?")
			else
				M.git_root = t
			end
			callback(M.git_root)
		end,
	}):start()
end

---
---@param callback function?(git_user: string)
function M.get_git_user(callback)
	callback = callback or function(_) end
	if M.git_user ~= "" then
		callback(M.git_user)
		return
	end

	local args = { "api", "user", "-q", ".login" }
	Job:new({
		command = "gh",
		args = args,
		cmd = "./",
		on_exit = vim.schedule_wrap(function(j, return_val)
			if return_val ~= 0 then
				vim.notify(table.concat(args, " "))
				vim.notify(vim.inspect(j:result()))
				vim.notify("Error running git user command. Is a git cli installed?")
				return
			end
			local result_json = j:result()
			local _, t = next(result_json)
			if not t then
				vim.notify("No result from git user command. Is a git cli installed?")
			else
				M.git_user = t
				vim.notify("Logged in as " .. M.git_user)
			end

			callback(M.git_user)
		end),
	}):start()
end

---
---@param callback function?(hunks: Hunks)
function M.get_hunks(callback)
	callback = callback or function(_) end

	if next(M.hunks) then
		callback(M.hunks)
		return
	end

	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo({ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } }, true, {})
			return
		end

		M.get_pr_number(vim.schedule_wrap(function(pr_number)
			if not pr_number then
				return
			end

			Job:new({
				command = "gh",
				args = {
					"pr",
					"diff",
				},
				on_exit = function(j, return_val)
					if return_val ~= 0 then
						vim.notify("Error running gh pr diff command. Is a gh cli installed?")
						return
					end

					local diff_lines = j:result()
					local _, t = next(diff_lines)
					if not t then
						vim.notify("No result from gh pr diff command. Is a gh cli installed?")
						return
					end

					M.hunks = util.parse_diff_hunks(diff_lines)

					callback(M.hunks)
				end,
			}):start()
		end))
	end))
end

--
---@param comment_id integer
---@param reaction_key string
---@param callback function?(success: boolean)
function M.add_reaction(comment_id, reaction_key, callback)
	callback = callback or function(_) end

	local reaction_key_map = {
		CONFUSED = "confused",
		EYES = "eyes",
		HEART = "heart",
		HOORAY = "hooray",
		LAUGH = "laugh",
		ROCKET = "rocket",
		THUMBS_DOWN = "-1",
		THUMBS_UP = "+1",
	}

	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo({ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } }, true, {})
			return
		end

		local args = {
			"api",
			"--method",
			"POST",
			"-H",
			"Accept: application/vnd.github+json",
			"/repos/" .. owner .. "/" .. repo .. "/pulls/comments/" .. comment_id .. "/reactions",
			"-f",
			"content=" .. reaction_key_map[reaction_key],
		}
		Job:new({
			command = "gh",
			args = args,
			on_exit = function(j, return_val)
				if return_val ~= 0 then
					vim.notify("Error running gh add reaction command. Is a gh cli installed?")
					return
				end

				local result_json = j:result()
				local _, t = next(result_json)
				if not t then
					vim.notify("No result from gh add reaction command. Is a gh cli installed?")
				end
				callback(return_val == 0)
			end,
		}):start()
	end))
end

---
---@param comment_id integer
---@param reaction_id integer
---@param callback function?(success: boolean)
function M.remove_reaction(comment_id, reaction_id, callback)
	callback = callback or function(_) end

	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo({ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } }, true, {})
			return
		end

		local args = {
			"api",
			"--method",
			"DELETE",
			"-H",
			"Accept: application/vnd.github+json",
			"/repos/" .. owner .. "/" .. repo .. "/pulls/comments/" .. comment_id .. "/reactions/" .. reaction_id,
		}
		vim.notify(vim.inspect(args))
		Job:new({
			command = "gh",
			args = args,
			on_exit = function(_, return_val)
				if return_val ~= 0 then
					vim.notify("Error running gh remove reaction command. Is a gh cli installed?")
				end

				callback(return_val == 0)
			end,
		}):start()
	end))
end

---
---@param comment_id integer
---@param body string
---@param callback? fun(success: boolean)
function M.reply(comment_id, body, callback)
	callback = callback or function(_) end

	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo({ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } }, true, {})
			return
		end

		M.get_pr_number(vim.schedule_wrap(function(pr_number)
			-- gh api \
			--   --method POST \
			--   -H "Accept: application/vnd.github+json" \
			--   -H "X-GitHub-Api-Version: 2022-11-28" \
			--   /repos/OWNER/REPO/pulls/PULL_NUMBER/comments/COMMENT_ID/replies \
			--    -f 'body=Great stuff!'

			local args = {
				"api",
				"--method",
				"POST",
				"-H",
				"'Accept: application/vnd.github+json'",
				"/repos/" .. owner .. "/" .. repo .. "/pulls/" .. pr_number .. "/comments/" .. comment_id .. "/replies",
				"-f",
				"body=" .. body,
			}
			Job:new({
				command = "gh",
				args = args,
				on_exit = function(j, return_val)
					if return_val ~= 0 then
						vim.notify(table.concat(args, " "))
						vim.notify(vim.inspect(j:result()))
						vim.notify("Error running gh reply command. Is a gh cli installed?")
					end

					callback(return_val == 0)
				end,
			}):start()
		end))
	end))
end

---
---@param relative_path string
---@param start_line integer
---@param end_line integer
---@param body string
---@param callback? fun(success: boolean)
function M.comment(relative_path, start_line, end_line, body, callback)
	callback = callback or function(_) end

	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo({ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } }, true, {})
			return
		end

		M.get_pr_number(vim.schedule_wrap(function(pr_number)
			if not pr_number then
				return
			end

			M.get_commit_hash(vim.schedule_wrap(function(commit_hash)
				if not commit_hash then
					return
				end

				-- gh api \
				--   --method POST \
				--   -H "Accept: application/vnd.github+json" \
				--   -H "X-GitHub-Api-Version: 2022-11-28" \
				--   /repos/OWNER/REPO/pulls/PULL_NUMBER/comments \
				--    -f 'body=Great stuff!' -f 'commit_id=6dcb09b5b57875f334f61aebed695e2e4193db5e' -f 'path=file1.txt' -F "start_line=1" -f 'start_side=RIGHT' -F "line=2" -f 'side=RIGHT'

				local args = {
					"api",
					"--method",
					"POST",
					"-H",
					"'Accept: application/vnd.github+json'",
					"/repos/" .. owner .. "/" .. repo .. "/pulls/" .. pr_number .. "/comments",
					"-f",
					"body=" .. body,
					"-f",
					"commit_id=" .. commit_hash,
					"-f",
					"path=" .. relative_path,
					"-F",
					"start_line=" .. start_line,
					"-f",
					"start_side=RIGHT",
					"-F",
					"line=" .. end_line,
					"-f",
					"side=RIGHT",
				}
				Job:new({
					command = "gh",
					args = args,
					on_exit = function(j, return_val)
						if return_val ~= 0 then
							vim.notify(table.concat(args, " "))
							vim.notify(vim.inspect(j:result()))
							vim.notify("Error running gh reply command. Is a gh cli installed?")
						end

						callback(return_val == 0)
					end,
				}):start()
			end))
		end))
	end))
end

---
---@param comment_id integer
---@param body string
---@param callback? fun(success: boolean)
function M.edit_comment(comment_id, body, callback)
	callback = callback or function(_) end

	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo({ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } }, true, {})
			return
		end

		-- gh api \
		--   --method PATCH \
		--   -H "Accept: application/vnd.github+json" \
		--   -H "X-GitHub-Api-Version: 2022-11-28" \
		--   /repos/OWNER/REPO/pulls/comments/COMMENT_ID \
		--    -f 'body=I like this too!'

		local args = {
			"api",
			"--method",
			"PATCH",
			"-H",
			"'Accept: application/vnd.github+json'",
			"/repos/" .. owner .. "/" .. repo .. "/pulls/comments/" .. comment_id,
			"-f",
			"body=" .. body,
		}
		Job:new({
			command = "gh",
			args = args,
			on_exit = function(j, return_val)
				if return_val ~= 0 then
					vim.notify(table.concat(args, " "))
					vim.notify(vim.inspect(j:result()))
					vim.notify("Error running gh edit comment command. Is a gh cli installed?")
				end

				callback(return_val == 0)
			end,
		}):start()
	end))
end

--
---@param thread_id string
---@param callback function?(success: boolean)
function M.resolve_thread(thread_id, callback)
	callback = callback or function(_) end

	--   gh api graphql -f threadId='<THREAD_ID>' -f query='
	--   mutation($threadId: ID!) {
	--     resolveReviewThread(input: {threadId: $threadId}) {
	--       thread {
	--         isResolved
	--       }
	--     }
	--   }
	-- '
	local query_template = [[
    mutation($threadId: ID!) {
      resolveReviewThread(input: {threadId: $threadId}) {
        thread {
          isResolved
        }
      }
    }
  ]]

	local args = {
		"api",
		"graphql",
		"-f",
		"threadId=" .. thread_id,
		"-f",
		"query=" .. query_template,
	}
	Job:new({
		command = "gh",
		args = args,
		on_exit = function(j, return_val)
			if return_val ~= 0 then
				vim.notify("Error running gh resolve command. Is a gh cli installed?")
				return
			end

			local result_json = j:result()
			local _, t = next(result_json)
			if not t then
				vim.notify("No result from gh resolve command. Is a gh cli installed?")
			end
			callback(return_val == 0)
		end,
	}):start()
end

--
---@param thread_id string
---@param callback function?(success: boolean)
function M.unresolve_thread(thread_id, callback)
	callback = callback or function(_) end

	--   gh api graphql -f threadId='<THREAD_ID>' -f query='
	--   mutation($threadId: ID!) {
	--     unresolveReviewThread(input: {threadId: $threadId}) {
	--       thread {
	--         isResolved
	--       }
	--     }
	--   }
	-- '
	local query_template = [[
    mutation($threadId: ID!) {
      unresolveReviewThread(input: {threadId: $threadId}) {
        thread {
          isResolved
        }
      }
    }
  ]]

	local args = {
		"api",
		"graphql",
		"-f",
		"threadId=" .. thread_id,
		"-f",
		"query=" .. query_template,
	}
	Job:new({
		command = "gh",
		args = args,
		on_exit = function(j, return_val)
			if return_val ~= 0 then
				vim.notify("Error running gh unresolve command. Is a gh cli installed?")
				return
			end

			local result_json = j:result()
			local _, t = next(result_json)
			if not t then
				vim.notify("No result from gh unresolve command. Is a gh cli installed?")
			end
			callback(return_val == 0)
		end,
	}):start()
end

---
---@param comment_id integer
---@param callback function? (success: boolean)
function M.delete_comment(comment_id, callback)
	callback = callback or function(_) end

	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo({ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } }, true, {})
			return
		end

		--   gh api \
		-- --method DELETE \
		-- -H "Accept: application/vnd.github+json" \
		-- -H "X-GitHub-Api-Version: 2022-11-28" \
		-- /repos/OWNER/REPO/pulls/comments/COMMENT_ID
		local args = {
			"api",
			"--method",
			"DELETE",
			"-H",
			"'Accept: application/vnd.github+json'",
			"/repos/" .. owner .. "/" .. repo .. "/pulls/comments/" .. comment_id,
		}
		Job:new({
			command = "gh",
			args = args,
			on_exit = function(j, return_val)
				if return_val ~= 0 then
					vim.notify(table.concat(args, " "))
					vim.notify(vim.inspect(j:result()))
					vim.notify("Error running gh delete comment command. Is a gh cli installed?")
				end

				callback(return_val == 0)
			end,
		}):start()
	end))
end

-- Exposed for unit testing only; do not rely on this from plugin consumers.
M._parse_diff_hunks = util.parse_diff_hunks

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
	return string.format("https://github.com/%s/%s/pull/%d#discussion_r%s", M.repo_info.owner, M.repo_info.repo, M.pr_number, tostring(comment.database_id))
end

--- List PRs filtered by relationship to the viewer. Caches by filter so repeat
--- picker invocations within the same session don't re-spawn `gh`.
---@param filter string  "mine"|"assigned"|"review-requested"|"all"
---@param callback fun(prs: PRSummary[])
function M.list_prs(filter, callback)
	callback = callback or function(_) end
	if M.pr_list[filter] then
		callback(M.pr_list[filter])
		return
	end

	local args = {
		"pr",
		"list",
		"--json",
		"number,title,author,state,headRefName,url,updatedAt,isDraft,reviewRequests,assignees",
		"--limit",
		"100",
	}
	if filter == "mine" then
		table.insert(args, "--author")
		table.insert(args, "@me")
	elseif filter == "assigned" then
		table.insert(args, "--assignee")
		table.insert(args, "@me")
	elseif filter == "review-requested" then
		table.insert(args, "--search")
		table.insert(args, "review-requested:@me state:open")
	end
	-- For "all" or unknown filter, no extra args -- gh pr list defaults to open PRs.

	Job:new({
		command = "gh",
		args = args,
		on_exit = vim.schedule_wrap(function(j, code)
			if code ~= 0 then
				vim.notify("Error running gh pr list. Is a gh cli installed?")
				callback({})
				return
			end
			local out = j:result() or {}
			local body = table.concat(out, "\n")
			if body == "" then
				M.pr_list[filter] = {}
				callback({})
				return
			end
			local ok, raw = pcall(vim.fn.json_decode, body)
			if not ok or type(raw) ~= "table" then
				vim.notify("Error parsing gh pr list output")
				callback({})
				return
			end
			local prs = M._normalize_prs(raw)
			M.pr_list[filter] = prs
			callback(prs)
		end),
	}):start()
end

---@param pr_number integer
---@param callback fun(success: boolean, err: string?)
function M.checkout_pr(pr_number, callback)
	callback = callback or function(_, _) end
	local stderr_lines = {}
	Job:new({
		command = "gh",
		args = { "pr", "checkout", tostring(pr_number) },
		on_stderr = function(_, line)
			if line and line ~= "" then
				table.insert(stderr_lines, line)
			end
		end,
		on_exit = vim.schedule_wrap(function(_, code)
			if code ~= 0 then
				local err = table.concat(stderr_lines, "\n")
				if err == "" then
					err = "gh pr checkout exited " .. tostring(code)
				end
				vim.notify(err, vim.log.levels.ERROR)
				callback(false, err)
				return
			end
			vim.cmd("checktime")
			callback(true)
		end),
	}):start()
end

function M.clear()
	M.comments = {}
	M.hunks = {}
	M.repo_info = {}
	M.pr_number = 0
	M.git_root = ""
	M.git_user = ""
	M.base_sha = ""
	M.pr_list = {}
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

function M.clear_pr_list()
	M.pr_list = {}
end

return M
