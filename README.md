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
    -- Suppress inline rendering of outdated review threads (still accessible
    -- through the popup and picker filters). Defaults to false.
    show_outdated_inline = false,
    -- Suppress inline rendering of resolved threads. Defaults to true (no
    -- change from previous behavior).
    show_resolved_inline = true,
    diagnostics = {
      -- Surface unresolved PR threads as vim.diagnostic entries (so plugins like
      -- trouble.nvim, lsp_lines, and :Telescope diagnostics pick them up).
      enabled = true,
      severity = vim.diagnostic.severity.HINT, -- default: HINT so PR threads don't
      -- override real LSP/lint errors.
      include_resolved = false,
      include_outdated = false,
      source = "PR", -- shown in source column of diagnostic plugins
    },
    -- Optional palette overrides. pr.nvim re-applies these on every
    -- ColorScheme event so a colorscheme switch no longer drops the colors.
    -- Note: definitions use `default = true`, so colorschemes that
    -- explicitly define these group names (e.g. `PRDiffAdd`) win over our
    -- defaults — pick whichever you prefer.
    -- colors = {
    --   diff_add_bg = "#0d3a0d",
    --   diff_change_bg = "#2a3a57",
    --   diff_delete_bg = "#893f45",
    --   sign_fg = "LightBlue",
    --   unresolved_bg = "#997570",
    --   resolved_bg = "#82A67D",
    -- },
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
      "<leader>fp",
      function()
        require("pr.picker").pick_prs()
      end,
      { desc = "Pick PR" },
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
    {
      "<leader>cs",
      function()
        require("pr.suggestion").comment_with_suggestion()
      end,
      mode = "v",
      { desc = "Suggest change for visual selection" },
    },
  },
}
```

## Inside a comments popup

Once you open a thread (e.g. via `<leader>gp`), these keymaps are available on the focused comment:

- `c` — write a reply. In visual mode, quote-reply the selected text (prepopulates the reply buffer with the selection quoted).
- `e` — open the emoji / reactions menu (hidden on providers without reaction support, e.g. Bitbucket).
- `r` — resolve / unresolve the thread (depending on its state and your permissions).
- `a` — apply the suggestion in the focused comment to the underlying buffer (only when the comment contains a ` ```suggestion ` block; drift-aware). See "Suggested edits" below.
- `ya` — yank the suggestion content to the system clipboard (only when the comment contains a ` ```suggestion ` block).
- `<M-d>` — delete the comment (if you authored it).
- `yl` — yank the thread's web URL to the clipboard (works on github / gitlab / bitbucket).
- `q` — close the comments popup.
- `?` — open the keymap help menu showing every available action, including ones with no direct binding (like `edit`).

Editing an existing comment is reached from the `?` menu (the `edit` action has no direct key). It opens an in-place edit mode on the comment's body; press `<CR>` to commit the edit or `<Esc><Esc>` to cancel.

## Picking PRs

`:PRList` (or `require("pr.picker").pick_prs()`) opens the configured picker over your open PRs. The picker title shows the active filter; cycle filters in place:

- **snacks / telescope** — `<Tab>` cycles `mine → assigned → review-requested → all`. Telescope binds `<Tab>` in both insert and normal mode.
- **fzf-lua** — `<C-t>` cycles (fzf-lua reserves `<Tab>` for multi-select).

`<CR>` checks out the chosen PR via `gh pr checkout` (github) or the equivalent provider call. Open buffers automatically reload on the branch switch, and PR comments/hunks refresh.

### Provider parity

- **GitHub** (`gh`): full support — all four filters work.
- **Bitbucket Cloud** (`curl`): real REST-backed implementation. The `assigned` filter falls through to `all` because Bitbucket Cloud has no assignee concept; a one-time notification fires when it's picked.
- **GitLab** (`glab`): `list_prs` and `checkout_pr` are stubs (`vim.notify("not implemented yet for gitlab")`) pending a follow-up implementation. Other features (comments, hunks, etc.) work fully.

## PR info popup

`:PRInfo` opens a floating, markdown-rendered popup with the current branch's PR title, body, state, labels, reviewers, assignees, and CI checks. Inside the popup:

- `e` — switch into edit mode (title and body become writable; `<C-s>` to save, `<Esc><Esc>` or `q` to cancel).
- `c` — open the CI checks menu; `<CR>` on a check yanks its log URL.
- `u` — refresh metadata + checks.
- `q` — close.

Saving an edit performs a remote-change check: if someone else (or you on another machine) edited the PR while you were typing, a confirm prompt offers Overwrite / Refresh / Abort.

`:PRInfo edit` skips view mode and jumps straight into edit mode.

### Provider parity

- **GitHub** (`gh`): full support.
- **Bitbucket Cloud** / **GitLab**: stubs — `:PRInfo` will notify "get_pr_metadata not implemented yet for <provider>". Real implementations slated for a follow-up plan.

## Reviewing a PR

`:PRReview` opens a two-popup layout: the **pending comments** queued under your current draft review, and a **review body** editor below.

Inside the layout (works from either popup):

- `a` — submit as **APPROVE** with the body.
- `r` — submit as **REQUEST_CHANGES**.
- `c` — submit as **COMMENT**.
- `d` — discard the pending review (with confirm prompt).
- `q` or `<Esc><Esc>` — close without submitting (pending comments are retained).

### Queuing a comment as part of a review

When authoring a new comment from visual mode (the popup opened by `M.comment` / your visual-mode keybind), the title bar shows `<M-s> Toggle suggestion` and `<C-r> Queue review`:

- `<CR>` (existing) submits immediately as a free-standing comment.
- `<C-r>` (new) — adds the comment to your draft review without submitting. Run `:PRReview` later to see all queued comments and submit the whole review at once.

### Provider parity

- **GitHub** (`gh`): full support. Pending reviews live server-side via the GitHub draft-review API, so they survive Neovim restarts and match the web UI's behavior. Re-opening `:PRReview` picks up any pending review you may have created via the web UI.
- **GitLab** / **Bitbucket Cloud**: pending comments are stored locally in `stdpath('data')/pr.nvim/pending_review.json` (keyed by provider/owner/repo/pr_number) so you can queue and inspect them. `:PRReview` submit will currently emit a warning that end-to-end submission is not yet wired through (`glab` and Bitbucket REST equivalents are planned for a follow-up).

## Suggested edits

GitHub-flavored ` ```suggestion ` blocks render as a visual box inside the thread popup, with each suggested line prefixed by `║ +`. Two new actions are available when the focused comment contains a suggestion:

- `a` — apply the suggestion to the underlying buffer. Uses the same drift mapping as inline rendering, so a suggestion authored against an older commit still lands on the right buffer rows.
- `ya` — yank the suggestion content to the `+` and `"` registers.

Both actions are gated by `can_perform`, so they only bind when the focused comment actually contains a suggestion block. If the focused comment has no suggestion, `a` and `ya` fall through to their default Neovim meaning.

### Authoring a suggestion

From visual mode, select the lines you want to suggest changes for and run `:PRSuggest` (or wire it to a keybinding like `<leader>cs` — see the `keys = { ... }` example above). A new-comment popup opens pre-filled with a ` ```suggestion ` block containing your selection. Edit the lines inside the fence to the desired replacement, and add prose outside the fence to explain.

Inside the new-comment popup, `<M-s>` toggles wrap / unwrap: if the buffer content is currently a complete suggestion fence, it strips the fence; otherwise it wraps the whole buffer content in a fence. The title bar exposes this as `<M-s> Toggle suggestion` alongside `<C-r> Queue review`.

## Diagnostics + quickfix

pr.nvim publishes unresolved PR threads as `vim.diagnostic` entries in a dedicated namespace (`pr_threads`). Anything that reads diagnostics — trouble.nvim, lsp_lines, the built-in `:Telescope diagnostics`, lualine's diagnostics component, etc. — automatically picks up PR threads alongside LSP errors and linter warnings.

By default the severity is `HINT` so threads don't overshadow real LSP/lint errors. Tune via:

```lua
diagnostics = {
  enabled = true,
  severity = vim.diagnostic.severity.WARN, -- promote to WARN if you want them louder
  include_resolved = false, -- set true to show resolved threads too
  include_outdated = true, -- show outdated threads (caveat: line numbers may be stale)
  source = "PR",
}
```

Set `diagnostics.enabled = false` to opt out entirely (inline signs continue to work).

`:PRQuickfix` dumps all unresolved threads across the PR into the quickfix list — useful when you want to walk every thread without opening files manually. Filter modes:

- `:PRQuickfix` (default) — unresolved threads.
- `:PRQuickfix outdated` — only outdated threads.
- `:PRQuickfix file` — threads on the current file only.
- `:PRQuickfix all` — every thread regardless of state.

Combine with `:cdo` / `:cfdo` for batch operations across the PR.

## Commands

- `:PRRefresh` — manually refresh PR comments, hunks, and PR number.
- `:PRList` — open a picker of your open PRs (mine / assigned / review-requested / all) and check one out. See "Picking PRs" above for picker-specific keybindings.
- `:PRInfo` — show the current branch's PR title, body, state, labels, reviewers, assignees, and CI checks in a floating popup. `:PRInfo edit` opens directly in edit mode.
- `:PRReview` — open the review-submission layout for the current PR (queues pending comments + lets you submit as approve / request-changes / comment).
- `:PRReviewDiscard` — discard the current pending review without opening the layout.
- `:PRSuggest` — open a new-comment popup with the visual selection wrapped as a ` ```suggestion ` block. Use from visual mode to author a suggested change for the lines under selection. See "Suggested edits" above.
- `:PRQuickfix [unresolved|outdated|all|file]` — populate the quickfix list with PR threads (`unresolved` by default). Then `:cnext` / `:cprev` to navigate, `:cdo` / `:cfdo` for batch ops. See "Diagnostics + quickfix" below.
- `:checkhealth pr` — verify CLI tools (`gh` / `glab` / `curl` / `git`), Lua dependencies (`nui.nvim`, `plenary.nvim`), the configured picker plugin, and that the chosen provider implements the full method surface.
