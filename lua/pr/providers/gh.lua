local Job = require("plenary.job")
local M = {}

M.git_root = ""
M.git_user = ""
--- @class RepoInfo
--- @field owner string?
--- @field repo string?
M.repo_info = {}
M.pr_number = 0

--- @class ReviewThread
--- @field id string
--- @field is_resolved boolean
--- @field resolved_by string
--- @field is_outdated boolean
--- @field is_collapsed boolean
--- @field viewer_can_reply boolean
--- @field viewer_can_resolve boolean
--- @field viewer_can_unresolve boolean
--- @field comments CommentInfo[]

--- @class CommentInfo
--- @field database_id integer
--- @field author string
--- @field body string
--- @field published_at string
--- @field updated_at string
--- @field viewer_did_author boolean
--- @field start_line integer
--- @field end_line integer
--- @field viewer_can_update boolean
--- @field viewer_can_react boolean
--- @field viewer_can_delete boolean
--- @field reaction_groups table<CommentReactionGroup>
---
--- @class CommentReactionGroup
--- @field content string
--- @field viewerHasReacted boolean
--- @field reactors CommentReactionReactors
---
--- @class CommentReactionReactors
--- @field totalCount integer
--- @field nodes CommentReactionReactorsNode[]
---
--- @class CommentReactionReactorsNode
--- @field database_id integer
--- @field content string
--- @field user string
---
---@alias Comments table<string, ReviewThread[]>
---@type Comments
M.comments = {}

-- Helper to get owner/repo from git remote
---
---@param callback function?(owner: string, repo: string)
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
				vim.api.nvim_echo(
					{ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } },
					true,
					{}
				)
				return
			end
			local result_json = j:result()
			local _, t = next(result_json)
			if not t then
				vim.api.nvim_echo(
					{ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } },
					true,
					{}
				)
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
				vim.api.nvim_echo(
					{ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } },
					true,
					{}
				)
			end
			callback(owner, repo)
		end),
	}):start()
end

-- Helper to get the current PR number
---
---@param callback function?(pr_number: number)
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

-- Helper to get current commit hash
---
---@param callback function?(hash: string)
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

	-- 1. Get dynamic repository and PR info
	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo(
				{ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } },
				true,
				{}
			)
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
					if
						not data
						or not data.data
						or not data.data.repository
						or not data.data.repository.pullRequest
					then
						vim.notify("Unexpected GraphQL response structure.")
						return
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
							-- vim.notify(vim.inspect(comment))
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
								table[i] = composed
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

	Job:new({
		command = "git",
		args = { "rev-parse", "--show-toplevel" },
		on_exit = function(j, return_val)
			-- vim.notify(vim.inspect(j:result()))
			if return_val ~= 0 then
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

	Job:new({
		command = "gh",
		args = { "api", "user", "-q", ".login" },
		cmd = "./",
		on_exit = vim.schedule_wrap(function(j, return_val)
			-- vim.notify(vim.inspect(j:result()))
			if return_val ~= 0 then
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
			vim.api.nvim_echo(
				{ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } },
				true,
				{}
			)
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
				callback(return_val ~= 0)
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
			vim.api.nvim_echo(
				{ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } },
				true,
				{}
			)
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

				callback(return_val ~= 0)
			end,
		}):start()
	end))
end

---
---@param comment_id integer
---@param body string
---@param callback function(success: boolean)
function M.reply(comment_id, body, callback)
	callback = callback or function(_) end

	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo(
				{ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } },
				true,
				{}
			)
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
						vim.notify(vim.inspect(j:result()))
						vim.notify("Error running gh reply command. Is a gh cli installed?")
					end

					callback(return_val ~= 0)
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
---@param callback function(success: boolean)
function M.comment(relative_path, start_line, end_line, body, callback)
	callback = callback or function(_) end

	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo(
				{ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } },
				true,
				{}
			)
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
					"'body=" .. body .. "'",
					"-f",
					"'commit_id=" .. commit_hash .. "'",
					"-f",
					"'path=" .. relative_path .. "'",
					"-F",
					"start_line=" .. start_line,
					"-f",
					"'start_side=RIGHT'",
					"-F",
					"line=" .. end_line,
					"-f",
					"'side=RIGHT'",
				}
				Job:new({
					command = "gh",
					args = args,
					on_exit = function(j, return_val)
						if return_val ~= 0 then
							vim.notify(vim.inspect(j:result()))
							vim.notify("Error running gh reply command. Is a gh cli installed?")
						end

						callback(return_val ~= 0)
					end,
				}):start()
			end))
		end))
	end))
end

---
---@param comment_id integer
---@param body string
---@param callback function(success: boolean)
function M.edit_comment(comment_id, body, callback)
	callback = callback or function(_) end

	M.get_repo_info(vim.schedule_wrap(function(owner, repo)
		if not repo and not owner then
			vim.api.nvim_echo(
				{ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } },
				true,
				{}
			)
			return
		end

		M.get_pr_number(vim.schedule_wrap(function(pr_number)
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
				"/repos/" .. owner .. "/" .. repo .. "/pulls/" .. pr_number .. "/comments/" .. comment_id,
				"-f",
				"body=" .. body,
			}
			Job:new({
				command = "gh",
				args = args,
				on_exit = function(j, return_val)
					if return_val ~= 0 then
						vim.notify(vim.inspect(j:result()))
						vim.notify("Error running gh edit comment command. Is a gh cli installed?")
					end

					callback(return_val ~= 0)
				end,
			}):start()
		end))
	end))
end

function M.clear()
	M.comments = {}
	M.repo_info = {}
	M.pr_number = 0
	M.git_root = ""
	M.git_user = ""
end

return M
