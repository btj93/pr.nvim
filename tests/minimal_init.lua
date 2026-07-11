-- Minimal init used by `make test` and CI to drive plenary.busted.
-- Clones plenary.nvim into PLENARY_DIR (defaulting to /tmp/plenary.nvim) on first run.

local plenary_dir = os.getenv("PLENARY_DIR") or "/tmp/plenary.nvim"
if vim.fn.isdirectory(plenary_dir) == 0 then
	vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/nvim-lua/plenary.nvim", plenary_dir })
end

vim.opt.rtp:prepend(".")
vim.opt.rtp:prepend(plenary_dir)

-- Clone nui.nvim for mount-based UI specs (same pattern as plenary above).
local nui_dir = os.getenv("NUI_DIR") or "/tmp/nui.nvim"
if vim.fn.isdirectory(nui_dir) == 0 then
	vim.fn.system({ "git", "clone", "--depth=1", "https://github.com/MunifTanjim/nui.nvim", nui_dir })
end
vim.opt.rtp:prepend(nui_dir)

-- Make tests/helpers/* requireable as helpers.* from any spec.
package.path = package.path .. ";./tests/?.lua"

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
