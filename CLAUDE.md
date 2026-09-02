# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`pr.nvim` is a Neovim plugin (pure Lua) that surfaces PR review comments and diff hunks inline in the buffer, and provides floating-window UI for reading, replying, reviewing, and editing across GitHub, GitLab, and Bitbucket Cloud. It shells out to the `gh`/`glab` CLI or `curl` for all platform API work; it does not call HTTPS directly.

Runtime dependencies (required at the user's site): `nui.nvim` (UI primitives) and `plenary.nvim` (`plenary.job` for async subprocess calls). External CLI dependencies: `git` plus the configured provider's CLI (`gh`, `glab`, or `curl`).

## Commands

- `make test` — runs `plenary.busted` over `tests/`. `tests/minimal_init.lua` shallow-clones `plenary.nvim` to `$PLENARY_DIR` (default `/tmp/plenary.nvim`) **and** `nui.nvim` to `$NUI_DIR` (default `/tmp/nui.nvim`) on first run, then adds `./tests/?.lua` to `package.path` so `helpers.*` resolve.
- `make lint` — `luacheck lua/ plugin/ tests/` (config in `.luacheckrc`, `vim` declared as a global).
- `make format` / `make format-check` — `stylua` (config in `stylua.toml`: tabs, 160-column).
- Run one spec: `nvim --headless --noplugin -u tests/minimal_init.lua -c 'lua require("plenary.busted").run("tests/<spec>.lua")' -c "qa!"`. **Do not** use `-c "PlenaryBustedFile ..."` — it forks a child nvim that does **not** inherit `minimal_init`, so nui isn't on the rtp and `helpers.*` don't resolve, and every harness-dependent flow spec fails spuriously. The `require(...).run(...)` form runs in-process and keeps the harness.

CI (`.github/workflows/ci.yml`) runs four jobs on push and PR: `test` over a Neovim matrix (`v0.10.4` / `stable` / `nightly`, with `nightly` set `continue-on-error` so it never fails the badge), `luacheck`, `stylua --check`, and a `docs` job that generates vimdoc helptags.

## Architecture

### Pluggable provider + picker backends

Two strategy points are resolved by string lookup:

- `lua/pr/provider.lua` → `require("pr.providers." .. config.opts.provider)`
- `lua/pr/picker.lua`   → `require("pr.pickers."   .. config.opts.picker)`

`config.opts.provider` defaults to `"github"` and `config.opts.picker` defaults to `"snacks"`.

**All three providers (`github.lua`, `gitlab.lua`, `bitbucket.lua`) are real implementations** for the core comment / hunk / review-state surface. Some newer methods are real on github and stubbed on gitlab/bitbucket (see "Provider parity" below). The canonical method surface is enumerated in `tests/provider_contract_spec.lua` (`REQUIRED_METHODS` + `REQUIRED_FIELDS`) and `lua/pr/health.lua` (`SURFACE`); both check that every concrete provider implements every method.

**All three pickers (`pickers/snacks.lua`, `pickers/telescope.lua`, `pickers/fzf.lua`) are real implementations.** Picker-touching features must work across all three; the backends share a uniform pure item-builder / confirm-dispatcher surface (`_build_*_items` / `_confirm_*`), and `tests/picker_items_spec.lua` is the cross-backend equivalence spec that enforces it — one shared fixture must yield the same rows, targets, PRs, glyphs, and confirm dispatch through every backend (see "Picker layer" under Testing). Filter state lives in `lua/pr/pickers/filter.lua` (`show_resolved`, `show_outdated`, `pr_list_filter`).

`provider.get_provider()` (with no argument) returns a **metatable proxy** that resolves `config.opts.provider` on every attribute access. This is what makes the pervasive `local git = require("pr.provider").get_provider()` at module-load time work — `setup({ provider = "..." })` can still take effect because the binding is to the proxy, not to a captured module. Don't change consumers to cache `git.foo` either, for the same reason.

### Module map

| Module | Responsibility |
|---|---|
| `plugin/pr.lua` | Classic plugin entry (sourced at startup): registers every `:PR*` command as a lazy bootstrap stub that requires + sets up `pr` on first use. Two clobber-guard belts (`vim.g.loaded_pr` + `:PRRefresh` existence check) prevent it from overwriting the real commands after `setup()` ran. |
| `init.lua` | `setup()`, user commands (`M._register_commands` + the `COMMANDS` table, `M._ensure_setup`, `M._dispatch`), auto-refresh timers/autocmds, public M.* aliases (status, winbar, comment_with_suggestion, etc.) |
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
| `log.lua` | Redaction helpers (`redact_text`, `redact_argv`, `payload_secrets`) + `command_failed`, the only path that prints subprocess diagnostic detail; argv/stderr detail is gated on `config.opts.debug` |
| `util.lua` | Cross-cutting helpers (`open_pr_file`, `is_valid_win/buf`) + `start_job`, the shared `Job:new` spawn guard every provider routes its subprocess launches through |

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

**Edit-in-place** (`_start_inline_edit`): toggles `modifiable = true`, places `PRCommentEditDim` line-hl extmarks outside the focused comment's `body_range`, installs `nvim_buf_attach` `on_lines` that splices back the out-of-range snapshot on out-of-range edits, and **commits on `InsertLeave`** (if the body changed, sends it to `git.edit_comment`; otherwise tears down with no API call). `<C-c>` in insert mode is the explicit cancel — it sets `skip_commit_on_leave` so the `InsertLeave` handler tears down without committing. A persisted edit draft (keyed by `comment.database_id`) is pre-filled into the body range on entry, unless its `updated_at` no longer matches (stale draft is dropped). **Conflict-aware** (when `config.opts.conflict_detection.enabled` and `git.refetch_comment` available): re-fetches before commit; on `updated_at` mismatch, prompts via `vim.fn.confirm` (Overwrite / Refresh / Abort, default Abort). The pure `M._conflict_decision(fresh, snapshot_updated_at, confirm_choice)` returns the decision string; tested in `tests/conflict_edit_spec.lua`.

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

## Testing

`make test` drives `plenary.busted` over every `tests/*_spec.lua` sequentially. Specs split into two tiers: **unit specs** exercise pure helpers directly (no nui, no subprocess), and **flow specs** (`tests/flow_*_spec.lua`) mount real UI and run real keymaps over a fake provider inside a headless harness.

### The harness (`minimal_init.lua`)

`tests/minimal_init.lua` prepends the repo root, shallow-clones both `plenary.nvim` (→ `$PLENARY_DIR`, default `/tmp/plenary.nvim`) and `nui.nvim` (→ `$NUI_DIR`, default `/tmp/nui.nvim`) on first run and prepends each to the rtp, then appends `./tests/?.lua` to `package.path` so every `tests/helpers/<x>.lua` resolves as `require("helpers.<x>")`. `tests/harness_smoke_spec.lua` asserts both invariants (nui `require`-able, helpers on `package.path`). Because `PlenaryBustedFile`'s child nvim does **not** inherit `-u minimal_init.lua`, run a single spec with the in-process `require("plenary.busted").run(...)` form (see Commands) — `PlenaryBustedFile` drops nui + helpers and fails every harness-dependent spec spuriously.

### Testing layers (`tests/helpers/`)

Three helpers back the flow specs; each installs cleanly and restores on teardown.

**`fake_provider.lua`** — a full-contract in-memory provider (implements every name in `tests/provider_contract_spec.lua`).

- `install(name, scenario?) → fake, uninstall`: registers the fake under `package.loaded["pr.providers." .. name]` and flips `config.opts.provider` to `name`; the returned `uninstall()` restores both. Call it in `before_each`, `uninstall()` in `after_each`. `M.new(scenario)` builds the table directly (used by `install`).
- **Scenario** is the mutable source of truth (`comments`, `hunks`, `prs`, `pending`, `pr_metadata`, `checks`, `collaborators`, `issues`, `git_root`/`git_user`/`pr_number`/`base_sha`, ...), with sane defaults deep-merged in. Getters copy the matching field into the exposed cache field (`fake.comments`, ...).
- **Calls log**: every method appends `{ method, args = {...} }` to `fake.calls`; `fake_provider.called(fake, method)` returns the first logged call (or nil). Assert both that a call fired and its args.
- **Deferred/fire**: methods run their callback synchronously by default. Set `fake.deferred[name] = true` to capture the callback instead, then `fake.fire(name)` runs the captured one later — this drives the loading→loaded transition of an async fetch on demand.
- **Scenario mutation**: mutators (`reply`, `comment`, `edit_comment`, `resolve_thread`, ...) update `scenario` in place, so a following getter observes the change and the re-render shows it. `clear_*` reset only the exposed cache fields (not `scenario`), mirroring the real invalidate-then-refetch.

**`ui_env.lua`** — a headless UI sandbox.

- `setup() → env`: widens the editor (220×60) and swaps `vim.notify`, `vim.ui.select`, `vim.ui.open`, `vim.fn.confirm` for non-blocking capturing stand-ins; also redirects `drafts` / `review_local` on-disk paths to tempfiles.
- `env.notifications` / `env.opened_urls` collect captured `vim.notify` / `vim.ui.open` calls. `env.confirm_choice` (int the `confirm` stub returns) and `env.select_choice` (int index, or a predicate `fn(item)->bool`, consumed by the `select` stub) script the prompts **before** you trigger them.
- `env.feed(keys)` types termcodes (`nvim_feedkeys` with mode `"mx"`, so mappings run and it blocks until drained).
- `env.wait_for(pred, ms?=2000, label?)` spins `vim.wait` until `pred` is true, asserting with `label` on timeout — the workhorse for awaiting async render/call state.
- `env.floats()` lists currently-open floating windows.
- `env.teardown()` restores every stub + dimensions, closes floats, and wipes all buffers. Always pair it with `setup()`.

**`git_repo.lua`** — real throwaway git repos for integration specs; every command runs via `git -C root` (independent of Neovim's cwd).

- `create(opts?) → repo`: inits a `main` repo with a test identity + `origin` remote (`opts.origin`, default a github URL), writes `opts.files`, makes an initial commit.
- `repo.write(relpath, lines)`, `repo.commit(msg?) → sha`, `repo.checkout(branch, create?)`, `repo.head() → sha`, `repo.cleanup()` (deletes the tree — call in `after_each`).

### Writing a flow spec

1. Guard on nui at the top: `if not pcall(require, "nui.popup") then return end` (a unit-only environment without nui then skips the file cleanly).
2. `before_each`: `env = ui_env.setup()`; `fake, uninstall = fake_provider.install("<name>", { <scenario> })`.
3. **Mount** the real UI (e.g. `local layout, comments_popup, new_reply_popup = ui.make_comments_layout(thread, relative_path)` then `layout:mount()`), and **`env.wait_for`** until the expected rendered text appears in the popup buffer — never assert immediately after mount, render is scheduled.
4. **`env.feed`** the real keymap (`<CR>`, `r`, `a`, ...) — or set the buffer lines and focus the target window first.
5. **`env.wait_for`** on the observable effect: `fake_provider.called(fake, "reply")`, a mutated `scenario`, or re-rendered text — then **assert** the recorded call args / final state.
6. `after_each`: drain any scheduled re-render with `env.drain(ms?=100)` — the **teardown-only** loop-spin helper (a constant-false `vim.wait`); never use it to await an observable effect in a test body, that's what `env.wait_for` is for — **before** `uninstall()` + `env.teardown()`, so nui's buffer-wipe auto-unmount can't race a pending re-render.

### CLI-shim layer (`tests/*_cli_spec.lua`)

The layer-2 fakes stop at `config.opts.provider` — `fake_provider` swaps the whole provider module out, so nothing below `get_comments`/`reply` ever runs. The **CLI-shim layer** exercises the **real** provider modules (`pr.providers.{github,gitlab,bitbucket}`) end-to-end: argv assembly, the async getter chains (`plenary.job`, driven by predicate `vim.wait`s), `--jq`/`-q` extraction, JSON plumbing + normalization, fetch-once caching + `clear_*` invalidation, and the error-hint branches — everything the fakes short-circuit. Only the CLI binary (`gh`/`glab`/`curl`) is replaced; the provider Lua runs for real.

**`cli_shim.lua`** — generates fake `gh`/`glab`/`curl` executables that log their argv and serve canned routes.

- `cli_shim.new() → shim` mints a fresh temp `bindir`. `shim.stub(name, routes)` writes a `/bin/sh` fake at `bindir/name`; `shim.install()` prepends `bindir` to `$PATH` (saving the prior value); `shim.calls(name)` returns one argv-table per invocation (logged with `\x1e`/`\x1f` byte separators kept out-of-band so no real token collides); `shim.uninstall()` restores `$PATH` and deletes the `bindir`.
- **Routes** are `{ match = { <tokens> }, stdout = / stdout_file =, stderr =, exit = }`. Tried in order; the first whose `match` tokens appear in argv as an ordered **substring-subsequence** wins (each token is matched as a *substring* of the `\x1f`-joined argv, consuming left-to-right past each hit). No match → exit 99 with argv echoed to stderr (self-diagnosing).
- **Anchored-tokens footgun**: because tokens match as substrings, a bare `-u` also matches inside `--url`, and `{ "pr", "view" }` matches both `--json number` and `--json baseRefOid` — so order specific routes before broad ones, and in assertions anchor a whole argv element by wrapping the probe in the field separator (`join(argv):find("\31-u\31")`, `"\31-f\31commit_id="`) instead of a bare substring.
- **stderr trailing-newline**: `stdout` is emitted **verbatim** (include your own `\n` when the provider decodes line-wise, e.g. `stdout = "42\n"`), but `route.stderr` gets exactly one trailing `\n` appended by the shim — don't add your own.

**Never shim `git`.** Only the provider CLI is faked; `git` always runs for real against a throwaway repo from `git_repo.create`, so `git remote get-url origin` parses real owner/repo from the fabricated host-shaped URL and `git rev-parse`/`fetch` behave. `checkout_pr` needs a genuinely fetchable origin: pass `bare_origin = true` for a sibling bare repo at `repo.bare`, `repo.push_bare(branch)` a branch into it, then `repo.set_origin_url(repo.bare)` **after** `repo_info` is cached (the parse needs the host-shaped URL first, the real fetch needs the bare path) — see the bitbucket checkout spec.

**Fixtures** live under `tests/fixtures/<provider>/`. JSON decoding is **per-provider**: github decodes only the **first stdout line**, so `review_threads.json` MUST be single-line; gitlab and bitbucket join ALL `result()` lines with `\n` before `vim.json.decode`, so a multi-line fixture would also parse — but all fixtures are kept single-line/compact for parity. Reference a fixture by an absolute path resolved from the spec's own `debug.getinfo(1, "S").source` at module-load time (the `FIXTURES` local), since each test `cd`s into the temp repo.

**Restore discipline**: every `_cli_spec` saves and restores the process globals it perturbs — `before_each` snapshots `cwd` + `vim.notify` (bitbucket also the `BITBUCKET_USERNAME`/`APP_PASSWORD` env, normalized to unset); `after_each` `pcall`s `cd` back, restores `notify` + env, `shim.uninstall()` (PATH + `bindir`), `repo.cleanup()`, and unloads `package.loaded["pr.providers.<x>"]`. The `vim.cmd` `checktime` spies in the checkout specs run their wait + asserts under `pcall` and restore unconditionally, so a `wait_for` timeout can't leave the global wrapped for `after_each`'s `cd`.

### Picker layer (`tests/picker_*_items_spec.lua`)

All three pickers (`pickers/{snacks,telescope,fzf}.lua`) share a **uniform pure surface** extracted out of the inline `Snacks.picker()` / telescope `pickers.new()` / `fzf_exec` closures: `_build_comment_items(comments, git_root)` / `_build_hunk_items(hunks, git_root)` / `_build_pr_items(prs)` build the finder rows, and `_confirm_comment` / `_confirm_hunk` / `_confirm_pr` dispatch the file-open / checkout. Extracting them lets a spec `require` and exercise the surface **without** the picker plugin installed — each backend keeps its plugin dependency out of the pure exports' reach — telescope/fzf defer the `require` inside the `pick_*` functions; snacks `pcall`-wraps it at module top level — and the pure exports never touch it. The builders are filter-agnostic: `filter.apply` runs in the `pick_*` caller on every finder run and the *already-filtered* Comments map is handed in — **do not fold filtering into a builder**. `git_root` is passed to every comment/hunk builder for signature uniformity even though each backend embeds only the *relative* path in its row (the absolute path is re-resolved from the provider at confirm time).

- **Per-backend native row shapes differ**, and each characterization spec pins its own verbatim:
	- **snacks** — item tables carrying `file` (relative) + `pos`/`end_pos` `{ line, col }` + a `data` payload (author/body/resolved/outdated, or hunk bounds/type, or PR fields).
	- **telescope** — entry tables carrying `value` (confirm/display payload) + `path`/`lnum` (previewer target) + `ordinal` + `display` (a *function* for comments/hunks, a *string* for PRs).
	- **fzf** — the comment/hunk builders return a bare `string[]` where each row is `"file:line:col:label"` (fzf-lua's builtin-previewer format); the confirm reverse-parses file+line back out with `^([^:]+):(%d+):`, so there is no per-row lookup. PR rows can't be reverse-parsed to a payload, so `_build_pr_items` **alone** returns `{ lines, lookup }` (row-string → `PRSummary`) and `_confirm_pr(selected, lookup)` resolves through it. fzf confirms take fzf's `selected` *table* and read `selected[1]`.
- **The real picker UIs are NOT driven headlessly** (unlike the flow specs, which mount real nui). fzf-lua spawns a real `fzf` binary (a terminal-mode child process, not a Lua float), and snacks/telescope floats are timing-fragile under `nvim_feedkeys` in a headless harness. So the picker specs stop at the pure surface — feed a builder a fixture, drive each `_confirm_*` through its native argument shape, and assert the downstream `util.open_pr_file` / `pr_list.checkout` call. Plugin-owned windowing is left untested here; the `filter` toggles / pre-filters are covered separately in `tests/picker_filter_spec.lua`.
- **Enforcement points:** three **characterization specs** (`picker_{snacks,telescope,fzf}_items_spec.lua`) each pin one backend's native shape, and **`picker_items_spec.lua` is the cross-backend equivalence net** — fed one shared fixture (three threads spanning unresolved/resolved/outdated, two hunks, two PRs) it proves the surfaces are *interchangeable*: identical row counts per kind, identical `(path, line)` target sets, identical PR-number sets, identical `filter.state_glyph` per thread, and — through each backend's native confirm shape — identical file-open / checkout dispatch. All comparisons are order-independent sets, so `pairs()` traversal order across backends never matters.

### Calling `pr.setup()` in a spec (danger)

`pr.setup()` with defaults starts a **live 300s libuv refresh timer** and, via `run_on_start.comments = true`, **shells out** to `gh`. Every `setup()` in a spec MUST pass `run_on_start = { comments = false, hunks = false }` and `auto_refresh = { interval = 0, on_branch_change = false, on_head_change = false }` unless the case under test needs one enabled, and `after_each` MUST call `pr.set_refresh_interval(0)` (stops + closes the timer) and delete every `PR*` augroup so nothing leaks into later specs. Reload `package.loaded["pr"] = nil` per test to reset `setup()`'s internal state (`last_branch`, timer handle), but never reload `pr.config` — the provider proxy captured it at load, so reloading desyncs them.

### nui gotchas

- `Popup:map(mode, ...)` forwards `mode` straight to `nvim_buf_set_keymap`, which requires a **string**. A table like `{ "n", "i" }` raises `Invalid 'mode'` and crashes the layout at construction (two such production crashes were fixed on this branch). Bind each mode in a `for _, mode in ipairs({ "n", "i" }) do popup:map(mode, ...) end` loop.

## Conventions

- Lua module pattern: every file is `local M = {} ... return M`.
- Indentation is **tabs**, not spaces — match this in edits.
- LuaCATS annotations (`---@param`, `---@class`, `---@field`) are used throughout for the public API and provider data shapes; keep them in sync when adding fields.
- User-visible messages go through `vim.notify` for transient info and `vim.api.nvim_echo({{msg, "ErrorMsg"|"WarningMsg"}}, true, {})` for errors/warnings. Match the surrounding style of the function you're editing.
- Errors from `gh`/`git` subprocesses are reported with the literal hint "Is a gh cli installed?" / "Is a git cli installed?" — keep this phrasing if you add similar error paths so users get a consistent signal.
- Provider subprocess failure branches must route through `log.command_failed` (or `log.redact_text` for an error string handed back to a caller). Never `vim.notify` raw argv, `j:result()`, or `j:stderr_result()` — argv carries `body=`/`query=` payloads and Bitbucket's `-u user:app-password`, and stdout is the full API response. `tests/log_spec.lua` pins the redaction contract; the audit greps in the release-stabilization plan catch the common regressions.
- `M.actions` entries use `menu_text` / `menu_desc` / `popup_hint` / `show_hint` (NOT `menu` / `hint`). Spec docs that say otherwise are stale.

## Things to know before changing behavior

- Adding a new provider method: add it to `providers/interface.lua` docs, real impl on `providers/github.lua`, **at minimum a silent stub** on `providers/gitlab.lua` and `providers/bitbucket.lua`, then add to `tests/provider_contract_spec.lua` `REQUIRED_METHODS` and `lua/pr/health.lua` `SURFACE`. The contract spec will fail loudly if any provider is missing the method.
- `plugin/pr.lua` is the zero-cost bootstrap: at startup it registers each `:PR*` name as a permissive stub (`nargs="*"`, `range`, `bang`) that on first invocation calls `require("pr")._ensure_setup()` (runs `setup({})` once, which re-registers the **real** strict commands over the stubs) then `require("pr")._dispatch(name, a)` — handing the already-parsed `a` straight through so bang/range/nargs parity is preserved without reconstructing `vim.cmd`. **Two clobber belts** keep it from ever overwriting the real commands: `vim.g.loaded_pr` (set by both the plugin file and `M.setup`) and a `vim.fn.exists(":PRRefresh") == 2` guard for exotic orderings where `setup()` ran without the flag. Registering the real commands is idempotent (nvim overwrites stubs silently) whether the user hits a command first or calls `setup()` themselves. Adding a new `:PR*` command means adding its name to the `commands` list in `plugin/pr.lua` too, not just the `COMMANDS` table in `init.lua`.
- `:PRComment` opens the review-thread popup for the thread under the cursor (equivalent to `require("pr").popup()`); the visual-selection new-comment composer is `comment.M.comment`.
- The `M.actions["unresolve"].key` and `M.actions["resolve"].key` both bind `"r"` in normal mode. In the unified `make_comments_layout`, the per-action keymap loop binds **every** action's key **unconditionally** (nui's `:map` is last-write-wins, so which of the two `r` closures survives is just `pairs()` order). The surviving closure resolves the applicable action **at dispatch time**: it runs its own `action.can_perform(thread, comment)` for the focused thread/comment, and if that is false it scans **sibling actions sharing the same `key`+`mode`** and dispatches to whichever `can_perform` returns true (fixed in commit `afdc887`; the earlier "gate `popup:map` on `can_perform`" scheme only worked for the legacy single-comment popup). `can_perform` is still the gate — it's just evaluated across every action on the binding instead of trusting binding order. Don't "fix" the duplicate `r` key, and **don't drop the sibling `can_perform` fall-through** in that dispatch closure, or only one of resolve/unresolve stays reachable.
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
