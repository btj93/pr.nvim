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
  event = "VeryLazy",
  keys = {
    {
      "<leader>gc",
      function()
        require("pr").toggle()
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
        require("pr.picker").picker()
      end,
      { desc = "Check PR" },
    },
    {
      "]c",
      function()
        require("pr").cycle_comments_in_buffer("forward")
      end,
    },
    {
      "[c",
      function()
        require("pr").cycle_comments_in_buffer("backward")
      end,
    },
  },
}
```

## Coming Soon

- [ ] Add support for other git providers
- [ ] Add support for other pickers
- [ ] Visual mode select lines to comment
- [ ] Visual mode select comment to quote reply
- [ ] PR explorer
- [ ] Switch to a PR branch
- [ ] Add support for actions such as adding new comments and resolving comments
- [ ] Auto refresh PR comments when changing branches
- [ ] Auto refresh PR comments by interval
- [ ] Auto refresh PR comments by autocmd
