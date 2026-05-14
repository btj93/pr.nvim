-- Shared provider interface definitions. Every concrete provider
-- (github / gitlab / bitbucket) exposes the same surface to the rest of the
-- plugin (comment.lua, hunk.lua, ui.lua, init.lua); this file documents the
-- types and the method contract once so each provider doesn't redeclare them.
--
-- This module is type-documentation only — it returns an empty table at
-- runtime. lua-language-server picks the @class / @alias declarations up
-- project-wide, so consumers reference them by name (`---@type Comments`)
-- without requiring this file.
--
-- A provider module must export the following.
--
-- Module fields:
--   M.comments         Comments                cached threads (populated by get_comments)
--   M.hunks            Hunks                   cached diff hunks (populated by get_hunks)
--   M.repo_info        RepoInfo                cached repository identity
--   M.pr_number        integer                 cached PR/MR number (0 when unset)
--   M.git_root         string                  working tree root (empty when unset)
--   M.git_user         string                  authenticated user login (empty when unset)
--   M.base_sha         string                  cached PR base-branch HEAD commit sha (empty when unset)
--   M.pr_list          table<string, PRSummary[]>  cached PR summaries keyed by filter
--   M.pr_metadata      PRMetadata?                  cached PR metadata
--   M.checks           CheckRun[]                   cached CI check runs
--   M.reaction_palette ReactionPaletteEntry[]  addable reactions; empty array hides the emoji action
--
-- Functions (each callback fires on the main thread):
--   get_repo_info(callback?)                                       -> callback(owner, repo)
--   get_pr_number(callback?)                                       -> callback(pr_number)
--   get_commit_hash(callback?)                                     -> callback(hash)
--   get_base_sha(callback?)                                        -> callback(sha)
--   get_git_root(callback?)                                        -> callback(git_root)
--   get_git_user(callback?)                                        -> callback(git_user)
--   get_comments(callback?)                                        -> callback(comments)
--   get_hunks(callback?)                                           -> callback(hunks)
--   add_reaction(comment_id, reaction_key, callback?)              -> callback(success)
--   remove_reaction(comment_id, reaction_id, callback?)            -> callback(success)
--   reply(comment_id, body, callback?)                             -> callback(success)
--   comment(relative_path, start_line, end_line, body, callback?)  -> callback(success)
--   edit_comment(comment_id, body, callback?)                      -> callback(success)
--   resolve_thread(thread_id, callback?)                           -> callback(success)
--   unresolve_thread(thread_id, callback?)                         -> callback(success)
--   delete_comment(comment_id, callback?)                          -> callback(success)
--   thread_url(thread, comment)                                    -> string?  (synchronous URL formatter)
--   list_prs(filter, callback)                                     -> callback(prs: PRSummary[])
--   checkout_pr(pr_number, callback)                               -> callback(success: boolean, err: string?)
--   get_pr_metadata(callback)                                    -> callback(metadata: PRMetadata)
--   update_pr_metadata(fields, callback)                         -> callback(success: boolean, err: string?)
--   get_checks(callback)                                         -> callback(checks: CheckRun[])
--   clear_pr_metadata() / clear_checks()
--   clear() / clear_comments() / clear_hunks() / clear_pr_number() / clear_pr_list()
--
-- thread.id, comment.database_id, and reactor.database_id are opaque to
-- consumers — the provider receives back exactly what it emitted, so each
-- provider chooses whatever form lets its mutations round-trip cleanly
-- (integers, hex strings, GraphQL global IDs — all fine).
--
-- reaction_key (passed to add_reaction) and content (in CommentReactionGroup)
-- are canonical uppercase ASCII keys, e.g. "THUMBS_UP". Providers translate to
-- and from platform-specific names (gemoji shortcodes on GitLab, the GitHub
-- ReactionContent enum, etc.) at their own boundary.

---@class RepoInfo
---@field owner string?
---@field repo string?

---@class ReviewThread
---@field id string|integer
---@field is_resolved boolean
---@field resolved_by string?
---@field is_outdated boolean
---@field is_collapsed boolean
---@field viewer_can_reply boolean
---@field viewer_can_resolve boolean
---@field viewer_can_unresolve boolean
---@field comments CommentInfo[]

---@class CommentInfo
---@field database_id integer
---@field author string
---@field body string
---@field published_at string
---@field updated_at string
---@field viewer_did_author boolean
---@field start_line integer
---@field end_line integer
---@field viewer_can_update boolean
---@field viewer_can_react boolean
---@field viewer_can_delete boolean
---@field reaction_groups CommentReactionGroup[]

---@class CommentReactionGroup
---@field content string
---@field viewerHasReacted boolean
---@field reactors CommentReactionReactors

---@class CommentReactionReactors
---@field totalCount integer
---@field nodes CommentReactionReactorsNode[]

---@class CommentReactionReactorsNode
---@field database_id integer
---@field content string
---@field user string

---@alias Comments table<string, ReviewThread[]>

---@class Hunk
---@field hunk_start integer
---@field hunk_end integer
---@field type string  -- "Add" | "Del" | "Change"

---@alias Hunks table<string, Hunk[]>

---@class ReactionPaletteEntry
---@field content string Canonical content key, used everywhere across the plugin
---@field glyph string Display glyph

---@class PRSummary
---@field number integer
---@field title string
---@field author string
---@field state "open"|"draft"|"closed"|"merged"
---@field branch string
---@field url string
---@field updated_at string
---@field unread_count integer?
---@field reviewers string[]
---@field is_mine boolean
---@field is_assignee boolean
---@field is_review_requested boolean

---@class PRMetadata
---@field number integer
---@field title string
---@field body string
---@field state "open"|"draft"|"closed"|"merged"
---@field author string
---@field head_ref string
---@field base_ref string
---@field labels string[]
---@field reviewers ReviewerStatus[]
---@field assignees string[]
---@field url string
---@field updated_at string

---@class ReviewerStatus
---@field user string
---@field state "approved"|"changes_requested"|"commented"|"pending"

---@class CheckRun
---@field name string
---@field status "queued"|"in_progress"|"completed"
---@field conclusion "success"|"failure"|"cancelled"|"skipped"|"neutral"|nil
---@field duration_seconds integer?
---@field url string

return {}
