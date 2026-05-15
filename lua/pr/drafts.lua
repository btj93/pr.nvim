-- Persisted comment drafts. Three kinds:
--   edit_drafts  keyed by existing comment.database_id (was the v1 shape)
--   new_drafts   keyed by "<path>:<start>:<end>" (visual-mode new-comment popups)
--   reply_drafts keyed by thread.id
--
-- On-disk shape (v2):
--   { version = 2, edit_drafts = {...}, new_drafts = {...}, reply_drafts = {...} }
-- v1 was a flat `comment_id -> draft` map; v1 → v2 migration loads the flat map
-- into edit_drafts. The next write persists as v2.
--
-- Atomic writes via tmp + rename so a crash mid-write can't corrupt the file.

local M = {}

local DEFAULT_PATH = vim.fn.stdpath("data") .. "/pr.nvim/drafts.json"
local path = DEFAULT_PATH
local cache = nil

local function enabled()
	local ok, config = pcall(require, "pr.config")
	if not ok then
		return true
	end
	if not config.opts or not config.opts.drafts then
		return true
	end
	-- Default to true if the field is absent.
	return config.opts.drafts.enabled ~= false
end

---For testing.
---@param p string
function M._set_path(p)
	M.flush()
	path = p
	cache = nil
end

---For testing — flush pending writes then drop in-memory cache so the next
---read hits disk.
function M._reload()
	M.flush()
	cache = nil
end

local function read()
	if cache then
		return cache
	end
	local ok_read, content = pcall(vim.fn.readfile, path)
	if not ok_read or not content or #content == 0 then
		cache = { version = 2, edit_drafts = {}, new_drafts = {}, reply_drafts = {} }
		return cache
	end
	local ok_decode, data = pcall(vim.fn.json_decode, table.concat(content, "\n"))
	if not ok_decode or type(data) ~= "table" then
		cache = { version = 2, edit_drafts = {}, new_drafts = {}, reply_drafts = {} }
		return cache
	end
	if not data.version then
		-- v1 was a flat comment_id -> { body, updated_at } map.
		cache = { version = 2, edit_drafts = data, new_drafts = {}, reply_drafts = {} }
	else
		cache = data
		cache.edit_drafts = cache.edit_drafts or {}
		cache.new_drafts = cache.new_drafts or {}
		cache.reply_drafts = cache.reply_drafts or {}
	end
	return cache
end

local function write_now()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local tmp = path .. ".tmp"
	vim.fn.writefile(vim.split(vim.fn.json_encode(cache), "\n", { plain = true }), tmp)
	local uv = vim.uv or vim.loop
	uv.fs_rename(tmp, path)
end

-- Debounced write: cache is updated synchronously by save_*/delete_*, but the
-- disk write coalesces multiple rapid changes (every keystroke triggers one)
-- into a single flush after `DEBOUNCE_MS` of quiet. Reads always see the
-- latest in-memory cache, so this is invisible to callers.
local DEBOUNCE_MS = 1000
local pending_timer = nil

local function flush_timer()
	if pending_timer then
		pending_timer:stop()
		if not pending_timer:is_closing() then
			pending_timer:close()
		end
		pending_timer = nil
	end
end

local function write()
	flush_timer()
	local uv = vim.uv or vim.loop
	pending_timer = uv.new_timer()
	pending_timer:start(
		DEBOUNCE_MS,
		0,
		vim.schedule_wrap(function()
			flush_timer()
			write_now()
		end)
	)
end

---Flush any pending debounced write immediately. Call from VimLeavePre.
function M.flush()
	if not pending_timer then
		return
	end
	flush_timer()
	write_now()
end

-- ---- edit drafts ----

---@param comment_id integer|string
---@param draft { body: string, updated_at: string? }
function M.save_edit(comment_id, draft)
	if not enabled() then
		return
	end
	read().edit_drafts[tostring(comment_id)] = draft
	write()
end

---@param comment_id integer|string
function M.get_edit(comment_id)
	if not enabled() then
		return nil
	end
	return read().edit_drafts[tostring(comment_id)]
end

---@param comment_id integer|string
function M.delete_edit(comment_id)
	if not enabled() then
		return
	end
	read().edit_drafts[tostring(comment_id)] = nil
	write()
end

-- ---- new drafts ----

---@param key string  -- typically "<path>:<start>:<end>"
---@param draft { body: string, updated_at: string? }
function M.save_new(key, draft)
	if not enabled() then
		return
	end
	read().new_drafts[key] = draft
	write()
end

---@param key string
function M.get_new(key)
	if not enabled() then
		return nil
	end
	return read().new_drafts[key]
end

---@param key string
function M.delete_new(key)
	if not enabled() then
		return
	end
	read().new_drafts[key] = nil
	write()
end

-- ---- reply drafts ----

---@param thread_id integer|string
---@param draft { body: string, updated_at: string? }
function M.save_reply(thread_id, draft)
	if not enabled() then
		return
	end
	read().reply_drafts[tostring(thread_id)] = draft
	write()
end

---@param thread_id integer|string
function M.get_reply(thread_id)
	if not enabled() then
		return nil
	end
	return read().reply_drafts[tostring(thread_id)]
end

---@param thread_id integer|string
function M.delete_reply(thread_id)
	if not enabled() then
		return
	end
	read().reply_drafts[tostring(thread_id)] = nil
	write()
end

-- ---- orphan cleanup ----

---Drop drafts that no longer correspond to a live comment/thread/file in
---the provider's cache. Called from :PRRefresh once the comment cache lands.
---
---For each kind:
---- `edit_drafts`  — drop entries whose `comment_id` isn't in `comment_ids`.
---- `new_drafts`   — drop entries whose `path` (the part before the first `:`
---                  in the `path:start:end` key) isn't in `paths`.
---- `reply_drafts` — drop entries whose `thread_id` isn't in `thread_ids`.
---
---@param known { paths: table<string, boolean>, thread_ids: table<string, boolean>, comment_ids: table<string, boolean> }
function M.invalidate_orphans(known)
	if not enabled() then
		return
	end
	known = known or {}
	local data = read()
	local mutated = false

	for id, _ in pairs(data.edit_drafts or {}) do
		if known.comment_ids and not known.comment_ids[id] then
			data.edit_drafts[id] = nil
			mutated = true
		end
	end

	for key, _ in pairs(data.new_drafts or {}) do
		local draft_path = key:match("^(.-):%d+:%d+$") or key
		if known.paths and not known.paths[draft_path] then
			data.new_drafts[key] = nil
			mutated = true
		end
	end

	for id, _ in pairs(data.reply_drafts or {}) do
		if known.thread_ids and not known.thread_ids[id] then
			data.reply_drafts[id] = nil
			mutated = true
		end
	end

	if mutated then
		write()
	end
end

return M
