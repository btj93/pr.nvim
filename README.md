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
    -- Show outdated threads inline. Defaults to false because their line numbers
    -- refer to a previous commit's file state. Outdated threads remain visible
    -- via the popup and picker filters regardless.
    show_outdated_inline = false,
    -- Show resolved threads inline. Defaults to false to reduce buffer clutter;
    -- resolved threads remain visible via the popup and picker filters. When
    -- set to true, resolved threads publish at `diagnostics.severity_resolved`
    -- (INFO by default) so your diagnostic config can color them distinctly.
    show_resolved_inline = false,
    diagnostics = {
      -- All inline comment text now flows through vim.diagnostic. Inline display
      -- itself (below the line / at end-of-line) follows your `vim.diagnostic.config`
      -- — see the "Inline comment display" section below. Trouble, lsp_lines,
      -- :Telescope diagnostics, and statusline plugins pick the entries up.
      enabled = true,
      severity = vim.diagnostic.severity.HINT, -- unresolved threads (default HINT
      -- so PR threads don't override real LSP/lint errors).
      severity_resolved = vim.diagnostic.severity.INFO, -- resolved threads, when shown.
      -- include_resolved / include_outdated default to nil = follow show_*_inline.
      -- Set to true/false here to override the unified knob.
      include_resolved = nil,
      include_outdated = nil,
      source = "PR", -- shown in source column of diagnostic plugins
    },
    drafts = {
      -- Persist in-progress comment bodies (edits, new comments, and replies)
      -- so a Neovim crash doesn't lose your work. Drafts live in
      -- stdpath('data') .. "/pr.nvim/drafts.json" (atomic tmp+rename writes).
      enabled = true,
      -- path = nil  -- override default location if needed
    },
    conflict_detection = {
      -- Before committing an in-place edit, re-fetch the comment's freshest
      -- updated_at and prompt if it changed remotely (Overwrite / Refresh /
      -- Abort, default Abort). Set false to skip the refetch.
      enabled = true,
    },
    winbar = {
      -- Optional built-in winbar showing `[PR #1234 · N unresolved]` on
      -- buffers under the PR's git root. Off by default — if you already
      -- drive winbar with heirline / lualine, wire `require("pr").winbar()`
      -- into your own setup instead of enabling this.
      enabled = false,
      format = "[PR #%d · %d unresolved]",
    },
    completion = {
      -- Omnifunc-backed @user / #issue completion inside comment popups.
      -- Trigger with <C-x><C-o> in insert mode after typing @ or #.
      enabled = true,
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
- `gx` — open the thread in the system browser (uses `vim.ui.open`; requires Neovim 0.10+). Useful for content the plugin can't render — e.g. Copilot's "Suggested changeset" autofixes, which aren't exposed via the GitHub API.
- `q` — close the comments popup.
- `?` — open the keymap help menu showing every available action, including ones with no direct binding (like `edit`).

Editing an existing comment is reached from the `?` menu (the `edit` action has no direct key). It opens an in-place edit mode on the comment's body; press `<CR>` to commit the edit or `<Esc><Esc>` to cancel.

## Picking PRs

`:PRList` (or `require("pr.picker").pick_prs()`) opens the configured picker over your open PRs. The default filter is `all`; the picker title shows the active filter.

### Picking the initial filter

- `:PRList` — opens with the current filter (defaults to `all`).
- `:PRList mine` / `:PRList assigned` / `:PRList review-requested` / `:PRList all` — open with that filter (tab-completed).
- `require("pr.picker").pick_prs({ filter = "mine" })` — same, programmatically.

### Cycling the filter while the picker is open

`<C-f>` cycles `mine → assigned → review-requested → all → mine` across all three pickers (snacks, telescope, fzf-lua). The picker rebuilds with the new filter and the title prefix updates.

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

## Inline comment display

**Inline comment text (below the line or at end-of-line) is rendered by `vim.diagnostic`.** pr.nvim publishes each thread as a `vim.diagnostic` entry in the `pr_threads` namespace; how — and whether — the comment text appears in your buffer is decided by your diagnostic UI config:

- **Lines below the comment** (the multi-line wrapped view): `vim.diagnostic.config({ virtual_lines = true })` (Neovim 0.11+) or install [`lsp_lines.nvim`](https://git.sr.ht/~whynothugo/lsp_lines.nvim).
- **End-of-line text**: `vim.diagnostic.config({ virtual_text = true })`.
- **Nothing inline** (popup-only access): leave both off; `:PRComment` / `[c`/`]c` still work; the signcolumn glyphs still show.
- **Scope just to pr.nvim's threads** (e.g. keep LSP diagnostics inline but suppress PR threads): pass the namespace as the second argument —
  ```lua
  vim.diagnostic.config({ virtual_lines = false, virtual_text = false }, require("pr.diagnostics").namespace)
  ```

The signcolumn glyphs — `󰅺` for single-line threads and the `┌`/`│`/`└` connectors for multi-line ranges — are placed by pr.nvim directly via `vim.fn.sign_place`. They show regardless of your diagnostic config. (pr.nvim also disables `vim.diagnostic`'s own auto-placed severity signs for the `pr_threads` namespace so the gutter doesn't show two signs per thread.)

**Resolved vs unresolved.** pr.nvim publishes resolved threads at `INFO` severity and unresolved threads at `HINT` (configurable via `diagnostics.severity` and `diagnostics.severity_resolved`). Style them distinctly by overriding the severity-based highlight groups in your colorscheme (e.g. `DiagnosticVirtualLinesInfo`, `DiagnosticVirtualLinesHint`). Resolved threads are hidden inline by default — set `show_resolved_inline = true` to include them.

**`:checkhealth pr` warning.** If no virtual-lines / virtual-text renderer is active, `:checkhealth pr` flags it so you know inline text won't display. The signcolumn glyphs still work in that case; you just access the comment body via the popup (`:PRComment`).

## Diagnostics + quickfix

Plugins that read `vim.diagnostic` — trouble.nvim, the built-in `:Telescope diagnostics`, lualine's diagnostics component, etc. — pick up PR threads alongside LSP errors and linter warnings.

By default the severity is `HINT` (unresolved) / `INFO` (resolved) so threads don't overshadow real LSP/lint errors. Tune via:

```lua
diagnostics = {
  enabled = true,
  severity = vim.diagnostic.severity.WARN, -- promote unresolved threads if you want them louder
  severity_resolved = vim.diagnostic.severity.INFO,
  -- include_resolved / include_outdated default to nil = follow `show_*_inline`.
  -- Set explicitly here to override the unified knob (e.g. show resolved in Trouble
  -- but not inline, or vice versa).
  include_resolved = nil,
  include_outdated = nil,
  source = "PR",
}
```

Set `diagnostics.enabled = false` to opt out entirely (signcolumn glyphs continue to work).

`:PRQuickfix` dumps all unresolved threads across the PR into the quickfix list — useful when you want to walk every thread without opening files manually. Filter modes:

- `:PRQuickfix` (default) — unresolved threads.
- `:PRQuickfix outdated` — only outdated threads.
- `:PRQuickfix file` — threads on the current file only.
- `:PRQuickfix all` — every thread regardless of state.

Combine with `:cdo` / `:cfdo` for batch operations across the PR.

## Drafts + conflict-aware editing

### Drafts

In-progress comment bodies persist to `stdpath('data') .. "/pr.nvim/drafts.json"` so a Neovim crash, restart, or switch to another buffer doesn't lose your work. Drafts cover three popup kinds:

- **Edit drafts** — keyed by the comment's `database_id`. Auto-dropped when the comment changes remotely (the `updated_at` mismatch signals the upstream content moved on).
- **New-comment drafts** — keyed by `path:start:end` of the visual selection that opened the popup. Persist until you submit (`<CR>`) or queue (`<C-r>`) the comment.
- **Reply drafts** — keyed by thread id. Same persistence semantics as new-comment drafts.

On-disk shape is JSON v2; if you have a pre-v2 file (the old flat `comment_id -> draft` map), it migrates automatically on first load.

Disable entirely via `drafts.enabled = false`.

### Conflict-aware edit

When you commit an in-place edit of an existing comment, pr.nvim re-fetches the comment's current `updated_at` and compares to the snapshot taken when you started editing. If they differ (someone else — or you, on another machine — edited the comment while you were typing), you get a prompt:

```
Comment changed remotely since edit started.
[O]verwrite  [R]efresh and re-edit  [A]bort (default)
```

- **Overwrite** sends your body anyway.
- **Refresh** replaces the buffer's edit content with the freshest body so you can re-apply your changes.
- **Abort** does nothing; the edit context stays alive — press `i` to keep typing.

The refetch costs one extra `gh api` call per submit; disable via `conflict_detection.enabled = false` if you prefer to skip the check. Providers that don't implement `refetch_comment` (currently gitlab/bitbucket) silently skip the check.

### Validation on PR-info edits

`:PRInfo edit` rejects:

- Empty title (gh would silently no-op).
- Empty body (same).
- Newlines in the title (insert-mode `<CR>` is bound to `<Nop>` so you can't insert them).

Both empty-string cases produce a clear error notification; the edit popup stays open so you can fix and retry.

## Statusline + winbar

`require("pr").status()` returns a counters table you can wire into lualine, heirline, or the native statusline:

```lua
{
  pr_number      = 1234,  -- nil when no PR is associated with the branch
  total          = 12,    -- total cached threads
  unresolved     = 7,
  resolved       = 5,
  outdated       = 2,
  on_buffer      = 1,     -- (reserved; use compute_for_buffer for live values)
  pending_review = 3,     -- comments queued under a draft review (S1c)
}
```

Example lualine wiring:

```lua
lualine_x = {
  function()
    local s = require("pr").status()
    if not s.pr_number then return "" end
    return ("PR #%d %d↻"):format(s.pr_number, s.unresolved)
  end,
},
```

The function is cheap — it reads only in-memory cache, no network calls. Statusline plugins can subscribe to refresh events instead of polling:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = { "PRCommentsRefreshed", "PRHunksRefreshed" },
  callback = function() vim.cmd("redrawstatus") end,
})
```

### Built-in winbar

If you don't already drive winbar with a plugin, enable the built-in:

```lua
winbar = { enabled = true, format = "[PR #%d · %d unresolved]" }
```

The plugin installs a `BufWinEnter` autocmd that sets `vim.wo.winbar` on buffers under the PR's git root. It re-applies on `User PRCommentsRefreshed` so the unresolved counter stays accurate.

`require("pr").winbar(bufnr)` returns the formatted string for any buffer (empty when no PR or when `winbar.enabled = false`).

## Markdown popup + completion

### Markdown rendering

Comment popups (read-mode threads, edit-mode bodies, new-comment popups, and reply popups) set `filetype = markdown`, so treesitter (if installed) syntax-highlights fenced code blocks, headings, lists, and emphasis. Suggestion boxes, horizontal rules, and emoji rows render through as plain text — they don't conflict with markdown syntax.

### @user / #issue completion

Inside the new-comment or reply popup, type `@` or `#` and trigger Neovim's omnifunc with `<C-x><C-o>` (in insert mode):

- `@<prefix>` — completes against the repo's collaborators. Menu shows the user's display name when available.
- `#<prefix>` — completes against issues + PRs (GitHub uses one number space; the cache merges both). Menu shows the issue/PR title. An exact-prefix match (`#42` when `#42` exists) short-circuits to just that entry.

The first trigger after a Neovim restart spawns an async `gh api` fetch and returns an empty list — press `<C-x><C-o>` again once the notification clears.

Caches are long-lived because collaborators and issues change slowly. Invalidate explicitly:

- `:PRRefreshUsers` — clear collaborator cache; next completion re-fetches.
- `:PRRefreshIssues` — clear issue + PR cache; next completion re-fetches.

Disable completion entirely via `completion = { enabled = false }`.

### Provider parity

- **GitHub** (`gh`): full support — fetches collaborators and issues/PRs.
- **GitLab** / **Bitbucket Cloud**: stubs — completion returns empty lists. Real `glab` / Bitbucket REST equivalents are planned for a follow-up.

## Commands

- `:PRRefresh` — manually refresh PR comments, hunks, and PR number.
- `:PRList` — open a picker of your open PRs (mine / assigned / review-requested / all) and check one out. See "Picking PRs" above for picker-specific keybindings.
- `:PRInfo` — show the current branch's PR title, body, state, labels, reviewers, assignees, and CI checks in a floating popup. `:PRInfo edit` opens directly in edit mode.
- `:PRReview` — open the review-submission layout for the current PR (queues pending comments + lets you submit as approve / request-changes / comment).
- `:PRReviewDiscard` — discard the current pending review without opening the layout.
- `:PRSuggest` — open a new-comment popup with the visual selection wrapped as a ` ```suggestion ` block. Use from visual mode to author a suggested change for the lines under selection. See "Suggested edits" above.
- `:PRQuickfix [unresolved|outdated|all|file]` — populate the quickfix list with PR threads (`unresolved` by default). Then `:cnext` / `:cprev` to navigate, `:cdo` / `:cfdo` for batch ops. See "Diagnostics + quickfix" below.
- `:PRRefreshUsers` — clear the cached collaborator list (next `<C-x><C-o>` triggers a re-fetch).
- `:PRRefreshIssues` — clear the cached issue + PR list.
- `:checkhealth pr` — verify CLI tools (`gh` / `glab` / `curl` / `git`), Lua dependencies (`nui.nvim`, `plenary.nvim`), the configured picker plugin, and that the chosen provider implements the full method surface.
