-- Fetch lifecycle coordinator for provider read resources.
--
-- Providers keep storing normalized values in their own module fields
-- (`M.comments`, `M.hunks`); this only tracks whether a fetch is cold, in
-- flight, settled, or failed, and guarantees every registered callback is
-- settled exactly once. It never starts jobs and knows nothing about data
-- shapes.
--
-- `resolve`/`reject`/`invalidate` drain waiters SYNCHRONOUSLY, so providers
-- must call them only from `vim.schedule_wrap`-protected completions — that is
-- what keeps the public provider contract of main-thread callbacks.

local M = {}

local Coordinator = {}
Coordinator.__index = Coordinator

---@return table
function M.new()
	return setmetatable({ resources = {} }, Coordinator)
end

local function entry(self, name)
	local e = self.resources[name]
	if not e then
		e = { status = "cold", generation = 0, waiters = {}, error = nil }
		self.resources[name] = e
	end
	return e
end

--- "cold" | "loading" | "loaded" | "error"
---@param name string
---@return string
function Coordinator:status(name)
	return entry(self, name).status
end

---@param name string
---@return string|nil
function Coordinator:error(name)
	return entry(self, name).error
end

--- Register interest in a resource.
--- Returns "loaded" (caller invokes its own callback with the cached value),
--- "joined" (a fetch is already in flight; callback queued), or
--- "start" plus a token (caller owns the fetch and must settle it with that
--- token). A `nil` callback is legal: the caller just wants the action.
---@param name string
---@param callback fun(value: any, err: string|nil)|nil
---@return string action, table|nil token
function Coordinator:begin(name, callback)
	local e = entry(self, name)
	if e.status == "loaded" then
		return "loaded", nil
	end
	if e.status == "loading" then
		if callback then
			table.insert(e.waiters, callback)
		end
		return "joined", nil
	end
	-- cold, or error from a previous attempt: this caller owns the retry.
	e.status = "loading"
	e.error = nil
	e.waiters = {}
	if callback then
		table.insert(e.waiters, callback)
	end
	return "start", { generation = e.generation }
end

--- True while `token` still owns the in-flight fetch for `name`. Providers use
--- this to decide whether to publish into their own cache field: a completion
--- that lost its token must not overwrite state a newer fetch or an
--- invalidation already replaced.
---@param name string
---@param token table|nil
---@return boolean
function Coordinator:owns(name, token)
	local e = entry(self, name)
	return token ~= nil and e.status == "loading" and token.generation == e.generation
end

local function drain(e, value, err)
	local waiters = e.waiters
	e.waiters = {}
	for _, cb in ipairs(waiters) do
		cb(value, err)
	end
end

--- Mark a successful fetch. An empty-but-successful value counts as loaded and
--- will NOT be refetched until invalidated. Returns false for a stale token.
---@param name string
---@param token table|nil
---@param value any
---@return boolean accepted
function Coordinator:resolve(name, token, value)
	if not self:owns(name, token) then
		return false
	end
	local e = entry(self, name)
	e.status = "loaded"
	e.error = nil
	drain(e, value)
	return true
end

--- Mark a failed fetch. Waiters settle with `(fallback, err)`; the resource
--- returns to a retryable state rather than caching the failure as success.
---@param name string
---@param token table|nil
---@param fallback any
---@param err string|nil
---@return boolean accepted
function Coordinator:reject(name, token, fallback, err)
	if not self:owns(name, token) then
		return false
	end
	local e = entry(self, name)
	e.status = "error"
	e.error = err
	drain(e, fallback, err)
	return true
end

--- Drop cached state and settle anyone waiting. Bumps the generation, so a
--- completion from the previous fetch can no longer resolve or reject.
---@param name string
---@param fallback any
---@param reason string|nil
function Coordinator:invalidate(name, fallback, reason)
	local e = entry(self, name)
	e.generation = e.generation + 1
	e.status = "cold"
	e.error = nil
	drain(e, fallback, reason or "invalidated")
end

---@param fallback any
---@param reason string|nil
function Coordinator:invalidate_all(fallback, reason)
	for name, _ in pairs(self.resources) do
		self:invalidate(name, fallback, reason)
	end
end

return M
