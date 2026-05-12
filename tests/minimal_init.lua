-- Minimal init used by `make test` and CI to drive plenary.busted.
-- Clones plenary.nvim into PLENARY_DIR (defaulting to /tmp/plenary.nvim) on first run.

local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
if vim.fn.isdirectory(plenary_dir) == 0 then
	vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/nvim-lua/plenary.nvim", plenary_dir })
end

vim.opt.rtp:prepend(".")
vim.opt.rtp:prepend(plenary_dir)

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
