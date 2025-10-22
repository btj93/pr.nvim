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
      "<leader>fh",
      function()
        require("pr.picker").pick_hunks()
      end,
      { desc = "Pick PR hunks" },
    },
    {
      "<leader>fg",
      function()
        require("pr.picker").pick_comments()
      end,
      { desc = "Pick PR comments" },
    },
    {
      "]ph",
      function()
        require("pr").cycle_hunks_in_buffer("forward")
      end,
    },
    {
      "[ph",
      function()
        require("pr").cycle_hunks_in_buffer("backward")
      end,
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
- [ ] Visual mode select comment to quote reply
- [ ] PR explorer
- [ ] Switch to a PR branch
- [ ] Auto refresh PR comments when changing branches
- [ ] Auto refresh PR comments manually by command
- [ ] Auto refresh PR comments by interval
- [ ] Auto refresh PR comments by autocmd
- [ ] Local comment drafts
