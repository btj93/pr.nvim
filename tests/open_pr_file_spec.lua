local util = require("pr.util")

local function mktmp()
	local p = vim.fn.tempname()
	vim.fn.mkdir(p, "p")
	return p
end

describe("util.open_pr_file", function()
	it("opens an existing file via :edit", function()
		local root = mktmp()
		local file = root .. "/foo.txt"
		vim.fn.writefile({ "hello" }, file)

		util.open_pr_file(file, "foo.txt", { line = 1 })
		vim.wait(200)
		-- macOS resolves /var/folders -> /private/var/folders via symlink;
		-- compare the resolved real-paths to side-step the difference.
		local expected = vim.uv.fs_realpath(file) or file
		local actual = vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) or vim.api.nvim_buf_get_name(0)
		assert.equals(expected, actual)
	end)

	-- Note: the "deleted-in-PR" branch needs a real git repo + a base sha;
	-- covered by manual smoke. Add an integration test if/when test fixtures
	-- grow to include a fixture repo with deleted-file history.
end)
