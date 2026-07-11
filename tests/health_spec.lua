describe("pr.health", function()
	local calls
	before_each(function()
		calls = { start = {}, ok = {}, warn = {}, error = {} }
		_G._orig_executable = vim.fn.executable
		_G._orig_has = vim.fn.has
		_G._orig_health = vim.health
		vim.health = {
			start = function(name)
				table.insert(calls.start, name)
			end,
			ok = function(msg)
				table.insert(calls.ok, msg)
			end,
			warn = function(msg)
				table.insert(calls.warn, msg)
			end,
			error = function(msg)
				table.insert(calls.error, msg)
			end,
		}
		package.loaded["pr.health"] = nil
		package.loaded["pr.config"] = nil
	end)
	after_each(function()
		vim.fn.executable = _G._orig_executable
		vim.fn.has = _G._orig_has
		vim.health = _G._orig_health
	end)

	it("reports OK for installed CLIs", function()
		vim.fn.executable = function(_)
			return 1
		end
		require("pr.config").setup({ provider = "github" })
		require("pr.health").check()
		assert.is_true(#calls.ok > 0)
		local found_gh = false
		for _, m in ipairs(calls.ok) do
			if m:match("^gh found") then
				found_gh = true
			end
		end
		assert.is_true(found_gh)
	end)

	it("reports OK for the Neovim 0.10 floor on a supported version", function()
		vim.fn.executable = function(_)
			return 1
		end
		require("pr.config").setup({ provider = "github" })
		require("pr.health").check()
		local found = false
		for _, m in ipairs(calls.ok) do
			if m:find("0.10", 1, true) then
				found = true
			end
		end
		assert.is_true(found, "expected an OK naming Neovim 0.10")
	end)

	it("errors when Neovim is older than 0.10", function()
		vim.fn.executable = function(_)
			return 1
		end
		vim.fn.has = function(feature)
			if feature == "nvim-0.10" then
				return 0
			end
			return _G._orig_has(feature)
		end
		require("pr.config").setup({ provider = "github" })
		require("pr.health").check()
		local found = false
		for _, m in ipairs(calls.error) do
			if m:find("0.10", 1, true) then
				found = true
			end
		end
		assert.is_true(found, "expected an error naming Neovim 0.10")
	end)

	it("errors when provider CLI is missing", function()
		vim.fn.executable = function(_)
			return 0
		end
		require("pr.config").setup({ provider = "github" })
		require("pr.health").check()
		assert.is_true(#calls.error > 0)
	end)

	it("includes thread_url in the provider surface check", function()
		vim.fn.executable = function(_)
			return 1
		end
		require("pr.config").setup({ provider = "github" })
		require("pr.health").check()
		-- The provider-surface check produces either an OK ("provider surface complete (N/N)")
		-- or a WARN ("provider surface N/N; missing: ..."). Either way, thread_url must
		-- NOT appear in any warn message.
		for _, m in ipairs(calls.warn) do
			assert.is_nil(m:match("missing:.*thread_url"), "thread_url unexpectedly missing")
		end
	end)
end)
