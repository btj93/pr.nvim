local Job = require("plenary.job")
local M = {}

M.git_root = ""
M.git_user = ""
--- @class RepoInfo
--- @field owner string?
--- @field repo string?
M.repo_info = {}
M.pr_number = 0

--- @class CommentInfo
--- @field database_id integer
--- @field author string
--- @field body string
--- @field start_line integer
--- @field end_line integer
--- @field reaction_groups table<CommentReactionGroup>
---
--- @class CommentReactionGroup
--- @field content string
--- @field viewer_has_reacted boolean
--- @field reactors CommentReactionReactors
---
--- @class CommentReactionReactors
--- @field total_count integer
---
---@alias Comments table<string, CommentInfo[]>
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
				callback(owner, repo)
				return
			else
				vim.api.nvim_echo(
					{ { "Could not determine GitHub repository from remote 'origin'.", "ErrorMsg" } },
					true,
					{}
				)
				return
			end
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
				vim.api.nvim_echo(
					{ { "Could not get PR number. Is a PR open for this branch?", "ErrorMsg" } },
					true,
					{}
				)
				return
			end
			local result_json = j:result()
			local _, t = next(result_json)
			if not t then
				vim.api.nvim_echo(
					{ { "Could not get PR number. Is a PR open for this branch?", "ErrorMsg" } },
					true,
					{}
				)
				return
			end

			local pr_number_str = t
			local pr_number = tonumber(pr_number_str)
			if pr_number then
				M.pr_number = pr_number
				callback(pr_number)
				return
			else
				vim.notify("Could not get PR number. Is a gh cli installed?")
				return
			end
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
	-- vim.notify(vim.inspect(M.comments))

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
				vim.api.nvim_echo(
					{ { "Could not get PR number. Is a PR open for this branch?", "ErrorMsg" } },
					true,
					{}
				)
				return
			end
			-- 2. Construct the GraphQL query with dynamic data
			-- https://docs.github.com/en/graphql/reference/objects#pullrequestreviewcomment
			local query_template = [[
    query($owner: String!, $name: String!, $prNumber: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $prNumber) {
          reviewThreads(first: 100) {
            edges {
              node {
                comments(first: 100) {
                  edges {
                    node {
                      databaseId
                      author { login }
                      body
                      path
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

			-- 3. Execute the gh api graphql command safely
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
					-- vim.notify(vim.inspect(j:result()))
					if return_val ~= 0 then
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

					local comments = {}
					local thread_count = 0

					for _, thread_edge in ipairs(threads) do
						local thread = {}
						local file = ""
						for _, comment_edge in ipairs(thread_edge.node.comments.edges) do
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
								table.insert(thread, {
									database_id = comment.databaseId,
									author = author,
									body = comment.body,
									start_line = start_line,
									end_line = line,
									reaction_groups = comment.reactionGroups,
								})
							end
						end
						local c = comments[file] or {}
						table.insert(c, thread)
						comments[file] = c
						thread_count = thread_count + 1
					end

					M.comments = comments

					-- Add unresolved
					vim.notify("You have " .. thread_count .. " comment threads")
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
	if M.git_root then
		callback(M.git_root)
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
				return
			end

			M.git_root = t
			callback(M.git_root)
		end,
	}):start()
end

---
---@param callback function?(git_user: string)
function M.get_git_user(callback)
	callback = callback or function(_) end
	if M.git_user then
		callback(M.git_user)
	end
	Job:new({
		command = "gh",
		args = { "api", "api", "user", "-q", ".login" },
		cmd = "./",
		on_exit = function(j, return_val)
			-- vim.notify(vim.inspect(j:result()))
			if return_val ~= 0 then
				vim.notify("Error running git user command. Is a git cli installed?")
				return
			end
			local result_json = j:result()
			local _, t = next(result_json)
			if not t then
				vim.notify("No result from git user command. Is a git cli installed?")
				return
			end

			M.git_user = t
			vim.notify(M.git_user)
			callback(M.git_user)
		end,
	}):start()
end

function M.clear()
	M.comments = {}
	M.repo_info = {}
	M.pr_number = 0
	M.git_root = ""
	M.git_user = ""
end

return M
