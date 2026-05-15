# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`pr.nvim` is a Neovim plugin (pure Lua) that surfaces PR review comments and diff hunks inline in the buffer, and provides floating-window UI for reading, replying, reviewing, and editing across GitHub, GitLab, and Bitbucket Cloud. It shells out to the `gh`/`glab` CLI or `curl` for all platform API work; it does not call HTTPS directly.

Runtime dependencies (required at the user's site): `nui.nvim` (UI primitives) and `plenary.nvim` (`plenary.job` for async subprocess calls). External CLI dependencies: `git` plus the configured provider's CLI (`gh`, `glab`, or `curl`).

## Commands

- `make test` — runs `plenary.busted` over `tests/`. `tests/minimal_init.lua` shallow-clones `plenary.nvim` to `$PLENARY_DIR` (default `/tmp/plenary.nvim`) on first run.
- `make lint` — `luacheck lua/ tests/` (config in `.luacheckrc`, `vim` declared as a global).
- `make format` / `make format-check` — `stylua` (config in `stylua.toml`: tabs, 160-column).
- Run one spec: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/<spec>.lua" -c "qa!"`.

CI (`.github/workflows/ci.yml`) runs tests, luacheck, and `stylua --check` on push and PR.

## Architecture

### Pluggable provider + picker backends

Two strategy points are resolved by string lookup:

- `lua/pr/provider.lua` → `require("pr.providers." .. config.opts.provider)`
- `lua/pr/picker.lua`   → `require("pr.pickers."   .. config.opts.picker)`

`config.opts.provider` defaults to `"github"` and `config.opts.picker` defaults to `"snacks"`.

**All three providers (`github.lua`, `gitlab.lua`, `bitbucket.lua`) are real implementations** for the core comment / hunk / review-state surface. Some newer methods are real on github and stubbed on gitlab/bitbucket (see "Provider parity" below). The canonical method surface is enumerated in `tests/provider_contract_spec.lua` (`REQUIRED_METHODS` + `REQUIRED_FIELDS`) and `lua/pr/health.lua` (`SURFACE`); both check that every concrete provider implements every method.

**All three pickers (`pickers/snacks.lua`, `pickers/telescope.lua`, `pickers/fzf.lua`) are real implementations.** Picker-touching features must work across all three. Filter state lives in `lua/pr/pickers/filter.lua` (`show_resolved`, `show_outdated`, `pr_list_filter`).

`provider.get_provider()` (with no argument) returns a **metatable proxy** that resolves `config.opts.provider` on every attribute access. This is what makes the pervasive `local git = require("pr.provider").get_provider()` at module-load time work — `setup({ provider = "..." })` can still take effect because the binding is to the proxy, not to a captured module. Don't change consumers to cache `git.foo` either, for the same reason.

### Module map

| Module | Responsibility |
|---|---|
| `init.lua` | `setup()`, user commands, auto-refresh timers/autocmds, public M.* aliases (status, winbar, comment_with_suggestion, etc.) |
| `provider.lua` | Provider-resolution proxy |
| `providers/{github,gitlab,bitbucket}.lua` | Real provider implementations (one CLI each) |
| `providers/interface.lua` | LuaCATS types + method contract (no runtime code) |
| `picker.lua` | Picker-resolution proxy: `pick_comments`, `pick_hunks`, `pick_prs` |
| `pickers/{snacks,telescope,fzf}.lua` | Picker implementations |
| `pickers/filter.lua` | Shared filter state across all three pickers |
| `comment.lua` | Review-thread render + cycle + inline-comment author flow |
| `hunk.lua` | Diff-hunk line-background highlights |
| `ui.lua` | All nui-based popups: `make_comments_layout`, `make_new_reply_popup`, `make_pr_info_layout`, `make_pr_edit_layout`, `make_review_layout`, `make_checks_menu`, `make_emoji_menu`, `make_help_menu`. Plus the central `M.actions` table. |
| `drift.lua` | Translate line numbers between HEAD-committed state and current buffer state via `vim.diff` |
| `pr_list.lua` | `:PRList` orchestration + `gh pr checkout` wrapper |
| `pr_info.lua` | `:PRInfo` view + edit-mode flow |
| `review.lua` | `:PRReview` orchestration over the github draft-review API |
| `review_local.lua` | Local-state pending-review JSON for gitlab/bitbucket |
| `suggestion.lua` | Pure helpers + apply algorithm for ` ```suggestion ` blocks |
| `diagnostics.lua` | Surface unresolved threads as `vim.diagnostic` entries |
| `quickfix.lua` | `:PRQuickfix` builder for the qflist |
| `status.lua` | Counters table + winbar string (read-only over caches) |
| `drafts.lua` | Persisted edit / new-comment / reply drafts at `stdpath('data')/pr.nvim/drafts.json` (atomic tmp+rename, debounced 1s) |
| `completion.lua` | Omnifunc for `@user` / `#issue` completion |
| `highlights.lua` | All `nvim_set_hl` definitions, re-applied on `ColorScheme` |
| `health.lua` | `:checkhealth pr` |
| `config.lua` | Default `M.opts` + `setup()` merge |
| `util.lua` | Cross-cutting helpers (`open_pr_file`, `is_valid_win/buf`) |

### Two parallel feature modules: `comment` and `hunk`

`lua/pr/comment.lua` (review threads, signs, virtual lines) and `lua/pr/hunk.lua` (line-background highlights for added/changed/deleted regions) follow an identical shape:

- Module-level `M.bufs` / `M.wins` / `M.enabled` track which buffers/windows are decorated.
- `start()` bootstraps caches (user → hunks → comments) then installs a `BufWinEnter,WinNew` autocmd in `augroup PRComment` (for `comment.lua`) or `augroup PRHunk` (for `hunk.lua`) that calls `attach_comment` / `attach_hunk`.
- `attach(win)` calls `nvim_buf_attach` with an `on_lines` that re-runs `draw(buf)` until disabled.
- `stop()` clears its own namespace, deletes its augroup, and calls the provider's fine-grained `clear_comments()` / `clear_hunks()` (falling back to `clear()` only if the provider doesn't expose them).
- `M.refresh()` (both modules) invalidates just this feature's provider cache, re-fetches, and redraws all currently-attached windows. `comment.refresh` also (a) emits `User PRCommentsRefreshed`, (b) calls `drafts.invalidate_orphans` to drop drafts whose target no longer exists, and (c) calls `diagnostics.publish` per attached buffer.

Use `require("pr").refresh()` or `:PRRefresh` to refresh comments + hunks + pr_number + pr_list + pr_metadata + checks + pending_review + drift in one shot.

### Provider state is global and cached in module fields

`providers/github.lua` holds all fetched data on the module table:

- Comment/hunk: `M.comments`, `M.hunks`, `M.repo_info`, `M.pr_number`, `M.git_root`, `M.git_user`, `M.base_sha`.
- PR list (S1a): `M.pr_list` (keyed by filter).
- PR info (S1b): `M.pr_metadata`, `M.checks`.
- Submit review (S1c): `M.pending_review_id` (github only — server-side state).
- Completion (S3b): `M.collaborators`, `M.issues`.

Every getter is "fetch-once": short-circuits if the field is already populated, else spawns a `plenary.job`, populates on success, invokes the callback. Invalidation: `clear()` (everything), or fine-grained `clear_comments`, `clear_hunks`, `clear_pr_number`, `clear_pr_list`, `clear_pr_metadata`, `clear_checks`, `clear_pending_review`, `clear_collaborators`, `clear_issues`. `M.refresh()` in `init.lua` calls all the fine-grained clears.

All `gh`/`git` calls are async via `plenary.job`. Callbacks that touch Neovim APIs must be wrapped in `vim.schedule_wrap` — done consistently; any new provider work must follow suit.

### Comment data shape

`get_comments` returns `Comments = table<relative_path, ReviewThread[]>`. Each `ReviewThread` has a `comments` array of `CommentInfo` (see `providers/interface.lua`). Normalization:

- `start_line`/`end_line` always have integer values (falling back through `startLine` → `originalStartLine` → `line` → `originalLine`, treating `vim.NIL` as missing).
- `reactionGroups[*].reactors.nodes` is populated by cross-referencing the separately-fetched `reactions` list, so each reaction group carries the actual reactor records (needed for `databaseId` on deletion).

Threads whose comments have `line == vim.NIL` and `originalLine == vim.NIL` (file-level or PR-level comments) are silently dropped.

`is_outdated` is provider-specific:
- **github**: trusts the GraphQL `isOutdated` field directly.
- **gitlab**: heuristic — a note is outdated when `newLine == nil and oldLine != nil`.
- **bitbucket**: file-level heuristic — a thread is outdated when its anchored path isn't in the current PR's hunk list.

### UI layer (`ui.lua`)

Built on `nui.nvim`'s `Popup` / `Layout` / `Menu`. Entry points:

- `make_comments_layout(thread, relative_path?)` — read an existing thread, reply, react, resolve, queue-as-review (`<C-r>`).
- `make_new_comment_layout(lines, ft, relative_path, start_line, end_line)` — file a new comment from a visual selection.
- `make_pr_info_layout(metadata, checks, callbacks)` / `make_pr_edit_layout(metadata, callbacks)` — `:PRInfo` read + edit mode.
- `make_checks_menu(checks, on_select)` — `[c]` from PR info.
- `make_review_layout(pending, callbacks)` — `:PRReview` pending-list + body editor.
- `make_emoji_menu` / `make_help_menu` — supporting menus.

**`make_comments_layout` uses a single scrollable read-only popup** for the entire conversation, plus a separate always-visible `new_reply_popup` below it inside the same `Layout`. `_render_thread` is the pure function that produces `{ lines, line_to_comment, comment_meta }`; exposed for testing in `tests/render_thread_spec.lua`.

The action table `ui.M.actions` is the single source of truth for keybindings — each entry has `mode`, `key`, `can_perform(thread, comment)`, `perform(thread, comment, new_reply_popup, popup_winid, ctx)`, plus `menu_text` / `menu_desc` / `popup_hint` / `show_hint`. The unified view binds each action's key on the comments popup and dispatches to the comment under cursor (via `line_to_comment`). `ctx` carries `{ bufnr, winid, body_range, re_render, unmount, relative_path, source_bufnr }`.

**Markdown filetype** is set on every popup that holds user-authored or rendered markdown (`comments_popup`, `new_reply_popup`, edit popups, PR-info popup, review-body popup), plus `spell = false` and `foldenable = false` on the win_options. Treesitter highlights code fences, headings, lists when installed.

**Suggestion blocks** ( ` ```suggestion ` ) are detected by `suggestion.extract_suggestions` and rendered into the unified buffer as a visual `╔═ ║ + ╚═` box. The `apply_suggestion` action (`a`) replaces the anchored lines in the underlying buffer via `drift.commit_to_buffer` mapping. The `yank_suggestion` action (`ya`) yanks the content to `+` and `"`.

**Hint virt_text**: cursor-aware action hints anchored to the focused comment's `footer_line`. `compute_hint_text(thread, comment, mode)` reuses `can_perform` + `show_hint` filter. Refreshes on `CursorMoved` / `CursorMovedI` / `ModeChanged` / `BufEnter`.

**Edit-in-place** (`_start_inline_edit`): toggles `modifiable = true`, places `PRCommentEditDim` line-hl extmarks outside the focused comment's `body_range`, installs `nvim_buf_attach` `on_lines` that calls `vim.cmd("silent! undo")` on out-of-range edits, binds `<CR>` to commit and `<Esc><Esc>` to cancel. **Conflict-aware** (when `config.opts.conflict_detection.enabled` and `git.refetch_comment` available): re-fetches before commit; on `updated_at` mismatch, prompts via `vim.fn.confirm` (Overwrite / Refresh / Abort, default Abort). The pure `M._conflict_decision(fresh, snapshot_updated_at, confirm_choice)` returns the decision string; tested in `tests/conflict_edit_spec.lua`.

**nui requires are pcall-wrapped** so `pr.ui` loads in test environments without nui installed; the runtime-only `Popup`/`Layout`/`Menu` variables resolve to nil there, which is harmless because pure helpers like `_render_thread` and `_diff_comments` don't reference them.

Width is **hardcoded to `BODY_WIDTH = 78`** (= outer popup width 80 - 2 for the border). Several places multiply or subtract from this; the constant is at the top of `ui.lua`.

### Drafts persistence

`lua/pr/drafts.lua` persists in-progress comment bodies to `stdpath('data')/pr.nvim/drafts.json` (atomic tmp+rename, **debounced 1s** to avoid per-keystroke disk writes). Three kinds:

- **Edit drafts** keyed by `comment.database_id`. Pre-fill on popup mount; dropped when `updated_at` mismatches (upstream comment was edited remotely).
- **New-comment drafts** keyed by `<path>:<start>:<end>`.
- **Reply drafts** keyed by `thread.id`.

`M.flush()` is called from `VimLeavePre` so the last keystrokes survive a quit. `M.invalidate_orphans(known)` is called from the end of `comment.refresh` to drop drafts whose target (file path / thread id / comment id) is no longer in the live cache.

On-disk format is JSON v2; v1 (flat `comment_id -> draft` map) migrates on first load.

Honor `config.opts.drafts.enabled = false` to disable persistence entirely — all `save_*`/`get_*` become no-ops.

### Highlights and signs

`lua/pr/highlights.lua` centralizes every `nvim_set_hl` definition. `M.apply()` is called once at `setup()` and again from a `ColorScheme` autocmd (`augroup PRColorScheme`) so highlights survive `:colorscheme <other>`. All definitions use `default = true`, meaning user colorschemes win when they define the group names. Colors are themable via `config.opts.colors`.

### vim.diagnostic + quickfix integration

`lua/pr/diagnostics.lua` publishes unresolved (and not outdated) threads into a `pr_threads` namespace. Drift-aware: uses `drift.commit_to_buffer`. Skips special buffers (`buftype ~= ""`). Plugins like trouble.nvim, lsp_lines, and `:Telescope diagnostics` pick them up automatically. Default severity is `HINT`.

`lua/pr/quickfix.lua` provides `:PRQuickfix [unresolved|outdated|file|all]` for batch navigation via `:cnext` / `:cdo`.

## Provider parity

Real on github; stubbed on gitlab/bitbucket (consumer should guard with `type(git.foo) == "function"`):

- `submit_review` end-to-end (review_local-backed pending state exists on gitlab/bitbucket, but submit emits a WARN).
- `get_pr_metadata` / `update_pr_metadata` / `get_checks` (stubs return `nil` / `(false, "not implemented")` / `{}`).
- `refetch_comment` (stub returns `nil`; conflict-aware edit skips the check).
- `list_collaborators` / `list_issues` (stubs return `{}`; completion menu is empty).

Real on github + bitbucket (real REST impl); stubbed on gitlab:

- `list_prs` / `checkout_pr` (gitlab stubs notify "not implemented").

Always real on all three:

- All core comment/hunk methods, `thread_url`, the draft-review surface (gitlab/bitbucket use `review_local` for the local queue).

## Conventions

- Lua module pattern: every file is `local M = {} ... return M`.
- Indentation is **tabs**, not spaces — match this in edits.
- LuaCATS annotations (`---@param`, `---@class`, `---@field`) are used throughout for the public API and provider data shapes; keep them in sync when adding fields.
- User-visible messages go through `vim.notify` for transient info and `vim.api.nvim_echo({{msg, "ErrorMsg"|"WarningMsg"}}, true, {})` for errors/warnings. Match the surrounding style of the function you're editing.
- Errors from `gh`/`git` subprocesses are reported with the literal hint "Is a gh cli installed?" / "Is a git cli installed?" — keep this phrasing if you add similar error paths so users get a consistent signal.
- `M.actions` entries use `menu_text` / `menu_desc` / `popup_hint` / `show_hint` (NOT `menu` / `hint`). Spec docs that say otherwise are stale.

## Things to know before changing behavior

- Adding a new provider method: add it to `providers/interface.lua` docs, real impl on `providers/github.lua`, **at minimum a silent stub** on `providers/gitlab.lua` and `providers/bitbucket.lua`, then add to `tests/provider_contract_spec.lua` `REQUIRED_METHODS` and `lua/pr/health.lua` `SURFACE`. The contract spec will fail loudly if any provider is missing the method.
- The `M.actions["unresolve"].key` and `M.actions["resolve"].key` both bind `"r"` in normal mode. The popup map loop gates `popup:map` on `action.can_perform(thread, comment)`, so only the applicable one is bound. Don't "fix" the duplicate key — and **don't drop the `can_perform` gate** in that loop, or the collision returns.
- Similarly, `M.actions["apply_suggestion"].key` is `"a"`. The dispatcher falls through to `try_start_inline_edit` when `can_perform` returns false, so `a` still opens insert mode on user-authored comments without suggestions.
- `cycle_comments_in_buffer` and `cycle_hunks_in_buffer` assume threads/hunks come back in ascending line order from the provider; preserve this when modifying the parsing in `parse_diff_hunks` or the GraphQL response handling.
- `parse_diff_hunks` (file-local in `providers/github.lua`) is unit-tested via the `M._parse_diff_hunks` test-only export. If you refactor the parser, update both `tests/parse_diff_hunks_spec.lua` and the export.
- `init.lua` installs an autocmd (`augroup PRAutoRefresh`) on `FocusGained`/`DirChanged` that asks `git rev-parse --abbrev-ref HEAD` and calls `M.refresh()` when the branch differs. Gated by `config.opts.auto_refresh.on_branch_change` (default `true`). `last_branch` is seeded during `setup()` so the first focus event doesn't refresh.
- `init.lua` also keeps a single libuv timer for periodic refresh, controlled by `config.opts.auto_refresh.interval` (seconds; `0` disables, default `300`). `M.set_refresh_interval(seconds)` swaps the interval at runtime — it stops/closes the previous timer before creating a new one. The timer's callback gates on `comment.enabled or hunk.enabled`, so a refresh never runs while both features are off.
- `M.refresh(opts)` and `comment.refresh(opts)` accept `{ show_diff = false }` to suppress the change-summary notification. Branch-change refreshes pass `show_diff = false` (diffing against a different PR's data is meaningless), while `:PRRefresh` and the periodic timer use the default `true`. `comment.lua` snapshots `git.comments` via `vim.deepcopy` before invalidating, then calls `_diff_comments(old, new)` after the re-fetch to produce a single-line `vim.notify` summary.
- `comment._diff_comments` is pure — exposed for testing in `tests/diff_comments_spec.lua`. Categories: `new thread`, `new reply`, `resolved`, `reopened`, `edited`, `deleted thread`, `deleted comment`.
- `comment.lua` defers `require("pr.ui")` until `M.comment` actually runs, so unit tests can `require("pr.comment")` without nui installed.
- A `refresh_in_progress` guard in `comment.lua` prevents the periodic timer from launching a second fetch over a still-in-flight one.
- User-visible events fire after refreshes: `User PRCommentsRefreshed` (from `comment.refresh`) and `User PRHunksRefreshed` (from `hunk.refresh`). Statusline plugins should subscribe instead of polling.
- `init.lua` autocmds also: `PRColorScheme` (re-apply highlights), `PRWinbar` (set `vim.wo.winbar` per buffer when `winbar.enabled`), `PRDraftsFlush` (`drafts.flush` on `VimLeavePre`), `PRHeadChange` / `PRAutoRefresh` (branch + head detection).
