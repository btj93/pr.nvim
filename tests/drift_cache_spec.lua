local drift = require("pr.drift")

local function mktmp_repo(lines)
	local p = vim.fn.tempname()
	vim.fn.mkdir(p, "p")
	vim.fn.system({ "sh", "-c", "cd " .. p .. " && git init -q && git config user.email a@b && git config user.name a" })
	vim.fn.writefile(lines, p .. "/file.txt")
	vim.fn.system({ "sh", "-c", "cd " .. p .. " && git add file.txt && git commit -q -m init" })
	return p
end

local function open_buf(path)
	vim.cmd("edit " .. path)
	return vim.api.nvim_get_current_buf()
end

describe("drift.get_for_buffer", function()
	after_each(function()
		drift.invalidate_all()
	end)

	it("returns a DriftMap derived from HEAD content vs. current buffer", function()
		local root = mktmp_repo({ "a", "b", "c" })
		local buf = open_buf(root .. "/file.txt")
		vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "X", "Y" }) -- replace "b" with X, Y

		local done = false
		local d = nil
		drift.get_for_buffer(buf, root, "file.txt", function(map)
			d = map
			done = true
		end)
		vim.wait(2000, function()
			return done
		end)

		assert.is_not_nil(d)
		-- "a" stays at 1; "b" was replaced by X (line 2); commit line 3 is now buffer line 4.
		assert.equals(1, drift.commit_to_buffer(d, 1))
		assert.equals(4, drift.commit_to_buffer(d, 3))
	end)

	it("invalidate forces a refetch", function()
		local root = mktmp_repo({ "a", "b", "c" })
		local buf = open_buf(root .. "/file.txt")
		drift.invalidate(buf) -- safe to call on cold cache
		local done = false
		drift.get_for_buffer(buf, root, "file.txt", function(_)
			done = true
		end)
		vim.wait(2000, function()
			return done
		end)
		assert.is_true(done)
	end)
end)
