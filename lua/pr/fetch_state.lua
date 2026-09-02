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

--- One resource's lifecycle record.
---@class pr.FetchStateEntry
---@field status "cold"|"loading"|"loaded"|"error"
---@field generation integer Bumped whenever a fetch cycle ends without success, so old tokens stop matching.
---@field waiters fun(value: any, err: string|nil)[]
---@field error string|nil

--- Ownership ticket for one fetch cycle of one resource. Opaque to providers:
--- mint it from `begin`, hand it back to `owns`/`resolve`/`reject` unread.
---@class pr.FetchToken
---@field name string
---@field generation integer

--- Per-provider fetch lifecycle coordinator.
---@class pr.FetchState
---@field resources table<string, pr.FetchStateEntry>
local Coordinator = {}
Coordinator.__index = Coordinator

---@return pr.FetchState
function M.new()
	return setmetatable({ resources = {} }, Coordinator)
end

---@param self pr.FetchState
---@param name string
---@return pr.FetchStateEntry
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
---@return string action, pr.FetchToken|nil token
function Coordinator:begin(name, callback)
	local e = entry(self, name)
	if e.status == "loaded" then
		-- Deliberately NOT queued. Every getter passes its callback here and then
		-- invokes it itself on the "loaded" branch, which reads like a double
		-- settle and is not one only because of this early return. Queue the
		-- callback here and all six getters start settling twice.
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
	if callback then
		table.insert(e.waiters, callback)
	end
	return "start", { name = name, generation = e.generation }
end

--- True while `token` still owns the in-flight fetch for `name`. Providers use
--- this to decide whether to publish into their own cache field: a completion
--- that lost its token must not overwrite state a newer fetch or an
--- invalidation already replaced. A token only ever owns the resource it was
--- minted for, so a provider holding two live tokens in one closure cannot
--- settle one resource with the other's token.
---@param name string
---@param token pr.FetchToken|nil
---@return boolean
function Coordinator:owns(name, token)
	local e = entry(self, name)
	return token ~= nil and token.name == name and e.status == "loading" and token.generation == e.generation
end

--- Settle every queued waiter. The list is swapped out before iterating so a
--- waiter that re-enters `begin` queues onto the next cycle instead of the list
--- under the loop, and each call is isolated so one waiter raising cannot
--- strand the callers behind it, who are already dequeued and would otherwise
--- never be settled and never retry. Reporting that failure is isolated the
--- same way: a user `vim.notify` wrapper (noice.nvim, nvim-notify) that raises
--- would otherwise abort the loop on the reporting path and strand exactly the
--- waiters the `pcall` above exists to protect.
---@param name string
---@param e pr.FetchStateEntry
---@param value any
---@param err string|nil
local function drain(name, e, value, err)
	local waiters = e.waiters
	e.waiters = {}
	for _, cb in ipairs(waiters) do
		local ok, failure = pcall(cb, value, err)
		if not ok then
			pcall(function()
				vim.notify(("pr.fetch_state: a %s waiter errored: %s"):format(name, tostring(failure)), vim.log.levels.ERROR)
			end)
		end
	end
end

--- Mark a successful fetch. An empty-but-successful value counts as loaded and
--- will NOT be refetched until invalidated. Returns false for a stale token.
---@param name string
---@param token pr.FetchToken|nil
---@param value any
---@return boolean accepted
function Coordinator:resolve(name, token, value)
	if not self:owns(name, token) then
		return false
	end
	local e = entry(self, name)
	e.status = "loaded"
	e.error = nil
	drain(name, e, value)
	return true
end

--- Mark a failed fetch. Waiters settle with `(fallback, err)`; the resource
--- returns to a retryable state rather than caching the failure as success.
--- Bumps the generation like `invalidate` does, so the failed fetch's token
--- cannot settle the retry that follows it. The ownership check above still
--- runs against the pre-bump generation.
---@param name string
---@param token pr.FetchToken|nil
---@param fallback any
---@param err string|nil
---@return boolean accepted
function Coordinator:reject(name, token, fallback, err)
	if not self:owns(name, token) then
		return false
	end
	local e = entry(self, name)
	e.generation = e.generation + 1
	e.status = "error"
	e.error = err
	drain(name, e, fallback, err)
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
	drain(name, e, fallback, reason or "invalidated")
end

---@param fallback any
---@param reason string|nil
function Coordinator:invalidate_all(fallback, reason)
	-- Snapshot the keys first: a drained waiter may `begin` a resource that
	-- does not exist yet, and inserting into a table mid-`pairs` is undefined.
	local names = {}
	for name, _ in pairs(self.resources) do
		names[#names + 1] = name
	end
	for _, name in ipairs(names) do
		self:invalidate(name, fallback, reason)
	end
end

return M
