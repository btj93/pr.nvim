# PR.nvim

PR.nvim is a Neovim plugin that surfaces pull-request review comments and diff hunks inline in your buffers, with floating-window UI for reading and replying to threads. Supports GitHub, GitLab, and Bitbucket Cloud.

## Requirements

### Neovim plugins (runtime)

- [`nui.nvim`](https://github.com/MunifTanjim/nui.nvim) — UI primitives (popups, layouts, menus).
- [`plenary.nvim`](https://github.com/nvim-lua/plenary.nvim) — async subprocess handling.

### Git provider CLI

Pick a `provider` and install the matching CLI. The plugin shells out to the CLI for all platform API calls — it does not call HTTPS directly.

| Provider        | `provider =`   | CLI                                                            | Authenticate                                                                                                                                                                                                                                              |
| --------------- | -------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GitHub _(default)_ | `"github"`  | [`gh`](https://cli.github.com/)                                | `gh auth login`                                                                                                                                                                                                                                            |
| GitLab          | `"gitlab"`     | [`glab`](https://gitlab.com/gitlab-org/cli) (≥ 1.21 for GraphQL) | `glab auth login`                                                                                                                                                                                                                                          |
| Bitbucket Cloud | `"bitbucket"`  | `curl` (ships with macOS/Linux)                                | `BITBUCKET_USERNAME` + `BITBUCKET_APP_PASSWORD` env vars, or a `~/.netrc` entry under `machine api.bitbucket.org`. Generate an app password at <https://bitbucket.org/account/settings/app-passwords/>. The account password itself will **not** work. |

`git` (the regular CLI) is also required by every provider — used to resolve the working tree, current branch, and remote URL.

Bitbucket Server / Data Center is **not** supported. Bitbucket Cloud only (bitbucket.org).

### Picker

Pick a `picker` and install the matching plugin. Defaults to `"snacks"`.

| Picker              | `picker =`     | Plugin                                                                 |
| ------------------- | -------------- | ---------------------------------------------------------------------- |
| Snacks _(default)_  | `"snacks"`     | [`snacks.nvim`](https://github.com/folke/snacks.nvim)                  |
| Telescope           | `"telescope"`  | [`telescope.nvim`](https://github.com/nvim-telescope/telescope.nvim)   |
| fzf-lua             | `"fzf"`        | [`fzf-lua`](https://github.com/ibhagwan/fzf-lua)                       |

## Installation

### lazy.nvim

```lua
return {
  "btj93/pr.nvim",
  dependencies = {
    "MunifTanjim/nui.nvim",
    "nvim-lua/plenary.nvim",
    "folke/snacks.nvim", -- or "nvim-telescope/telescope.nvim" / "ibhagwan/fzf-lua" to match `picker`
  },
  opts = {
    provider = "github", -- "github" | "gitlab" | "bitbucket"
    picker = "snacks", -- "snacks" | "telescope" | "fzf"
  },
  event = "VeryLazy",
  keys = {
    {
      "<leader>uh",
      function()
        require("pr").toggle_hunks()
      end,
      { desc = "toggle PR hunks" },
    },
    {
      "<leader>uc",
      function()
        require("pr").toggle_comments()
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

## Commands

- `:PRRefresh` — manually refresh PR comments, hunks, and PR number.

## Coming Soon

- [ ] PR explorer
- [ ] Switch to a PR branch
