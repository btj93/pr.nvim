# PR.nvim

PR.nvim is a Neovim plugin that displays inline comments from GitHub pull requests.

## Installation

Install the plugin with your favorite package manager:

- [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
return {
  "btj93/pr.nvim",
  dependencies = {
    "MunifTanjim/nui.nvim",
    "nvim-lua/plenary.nvim",
  },
  opts = {},
  lazy = false,
  keys = {
    {
      "<leader>gc",
      function()
        require("pr"):toggle()
      end,
      { desc = "toggle PR comments" },
    },
    {
      "<leader>gp",
      function()
        require("pr").popup()
      end,
      { desc = "Show comment thread in floating window" },
    },
    {
      "<leader>fg",
      function()
        require("pr").picker()
      end,
      { desc = "Check PR" },
    },
  },
  dev = true,
}
```

## Coming Soon

- [ ] Add support for other providers
- [ ] PR explorer
- [ ] Switch to a PR branch
- [ ] Add support for other pickers
- [ ] Add support for actions such as adding new comments and resolving comments
- [ ] Add keymap help menu
