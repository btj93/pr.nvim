local drift = require("pr.drift")

local created_dirs = {}

local function mktmp()
	local p = vim.fn.tempname()
	vim.fn.mkdir(p, "p")
	table.insert(created_dirs, p)
	return p
end

local function run(cmd, cwd)
	vim.fn.system({ "sh", "-c", "cd " .. vim.fn.shellescape(cwd) .. " && " .. cmd })
	assert.equals(0, vim.v.shell_error, "command failed: " .. cmd)
end

describe("drift.fetch_committed_lines", function()
	-- plenary.busted's after_each MUST live inside a describe to take effect;
	-- declaring it at the top of the file is silently ignored.
	after_each(function()
		for _, p in ipairs(created_dirs) do
			vim.fn.delete(p, "rf")
		end
		created_dirs = {}
	end)

	it("returns the HEAD-committed lines for a tracked file", function()
		local root = mktmp()
		run("git init -q && git config user.email a@b && git config user.name a", root)
		vim.fn.writefile({ "alpha", "beta", "gamma" }, root .. "/file.txt")
		run("git add file.txt && git commit -q -m init", root)

		local done = false
		local got = nil
		drift.fetch_committed_lines(root, "file.txt", function(lines)
			got = lines
			done = true
		end)
		vim.wait(2000, function()
			return done
		end)

		assert.is_true(done, "callback never fired")
		assert.are.same({ "alpha", "beta", "gamma" }, got)
	end)

	it("returns empty list when the path is not in HEAD", function()
		local root = mktmp()
		run("git init -q && git config user.email a@b && git config user.name a", root)
		vim.fn.writefile({ "x" }, root .. "/file.txt")
		run("git add file.txt && git commit -q -m init", root)

		local done = false
		local got = nil
		drift.fetch_committed_lines(root, "nonexistent.txt", function(lines)
			got = lines
			done = true
		end)
		vim.wait(2000, function()
			return done
		end)

		assert.is_true(done, "callback never fired")
		assert.are.same({}, got)
	end)

	it("returns empty list when the directory is not a git repo", function()
		local root = mktmp() -- no `git init`

		local done = false
		local got = nil
		drift.fetch_committed_lines(root, "file.txt", function(lines)
			got = lines
			done = true
		end)
		vim.wait(2000, function()
			return done
		end)

		assert.is_true(done, "callback never fired")
		assert.are.same({}, got)
	end)
end)
