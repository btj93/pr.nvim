-- Local on-disk state for pending review comments. Used by providers that
-- don't have a server-side draft-review concept (GitLab, Bitbucket).
--
-- Persistence file: stdpath('data')/pr.nvim/pending_review.json
-- Shape:
--   { version = 1, entries = { ["<provider>:<owner>:<repo>:<pr>"] = PendingComment[] } }
--
-- Atomic writes via tmpfile + rename so a crash mid-write can't corrupt the file.

local M = {}

local DEFAULT_PATH = vim.fn.stdpath("data") .. "/pr.nvim/pending_review.json"
local path = DEFAULT_PATH
local cache = nil

---For testing only.
---@param p string
function M._set_path(p)
	path = p
	cache = nil
end

---For testing only — drop in-memory cache so the next read hits disk.
function M._clear_cache()
	cache = nil
end

local function read()
	if cache then
		return cache
	end
	local ok, content = pcall(vim.fn.readfile, path)
	if not ok or not content or #content == 0 then
		cache = { version = 1, entries = {} }
		return cache
	end
	local decoded_ok, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
	if not decoded_ok or type(data) ~= "table" then
		cache = { version = 1, entries = {} }
		return cache
	end
	cache = data
	cache.entries = cache.entries or {}
	return cache
end

local function write()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local tmp = path .. ".tmp"
	vim.fn.writefile(vim.split(vim.fn.json_encode(cache), "\n", { plain = true }), tmp)
	local uv = vim.uv or vim.loop
	uv.fs_rename(tmp, path)
end

local function key(provider, owner, repo, pr)
	return string.format("%s:%s:%s:%s", provider, owner or "", repo or "", tostring(pr or 0))
end

---Append a pending comment.
---@param provider string
---@param owner string
---@param repo string
---@param pr integer
---@param comment PendingComment
function M.save(provider, owner, repo, pr, comment)
	local data = read()
	local k = key(provider, owner, repo, pr)
	data.entries[k] = data.entries[k] or {}
	table.insert(data.entries[k], comment)
	write()
end

---List the pending comments for the keyed tuple.
---@param provider string
---@param owner string
---@param repo string
---@param pr integer
---@return PendingComment[]
function M.load(provider, owner, repo, pr)
	local data = read()
	return data.entries[key(provider, owner, repo, pr)] or {}
end

---Clear the pending comments for the keyed tuple.
---@param provider string
---@param owner string
---@param repo string
---@param pr integer
function M.clear(provider, owner, repo, pr)
	local data = read()
	data.entries[key(provider, owner, repo, pr)] = nil
	write()
end

return M
