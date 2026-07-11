# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [0.1.0] - 2026-07-11

Initial public release: inline PR review comments and diff hunks for Neovim
with floating-window UI for reading, replying, reviewing, and editing across
GitHub, GitLab, and Bitbucket Cloud — plus a three-layer programmatic test
suite (780 tests) covering every user-facing flow.

The entries below record what changed during the release-hardening campaign
relative to the pre-release development tree.

### Added

- `:PRComment` command — open the review-thread popup for the thread under
  the cursor (equivalent to `require("pr").popup()`).
- `plugin/pr.lua` auto-setup entry: all ten `:PR*` commands are registered on
  startup as lazy bootstrap stubs that require and set up `pr` on first use, so
  the commands work without an explicit `require("pr").setup()` call.
- Edit-draft persistence on the live inline-edit path: an in-progress comment
  edit is saved to disk (keyed by comment id) and restored on re-open when the
  upstream comment is unchanged; a stale draft (upstream edited remotely) is
  dropped. Only a successful commit deletes the draft, so cancel/quit is
  crash-safe.
- `:checkhealth pr` now asserts the Neovim 0.10 floor, reporting an error that
  names 0.10 when the version is too old (the check runs first, since the rest
  assume 0.10+ APIs).
- Vimdoc reference: `:help pr` (topic tags `:help pr-commands`,
  `:help pr-keymaps`, `:help pr-providers`, `:help pr-api`), kept in sync with
  the real commands by a coverage spec.

### Changed

- Reviews may now be submitted as a bare `APPROVE` with no body — GitHub permits
  approving with no body and no pending comments, so the empty-content guard now
  applies only to `COMMENT` and `REQUEST_CHANGES`.

### Fixed

- Pressing `r` on a thread now reliably resolves or unresolves it. Both actions
  bind `r` in normal mode; the dispatcher previously trusted keymap
  registration order, so on some `pairs()` orderings `r` silently did nothing.
  It now resolves the applicable action via `can_perform` at dispatch time.
- Removing your own reaction no longer removes the wrong person's reaction. The
  emoji-menu remove path compared against a never-set field (`nil == nil` matched
  the first reactor); it now targets the viewer's own reactor correctly.
- The new-comment composer no longer crashes on open. Binding `<M-s>` with a
  table mode (`{ "n", "i" }`) raised `Invalid 'mode'` and crashed the layout on
  mount; each mode is now bound separately.
- Filing a new comment from a visual selection on (or within two lines of) the
  last line of a file no longer crashes with "Index out of bounds". The
  visual-selection comment composer (`comment.M.comment`) over-read two lines
  past EOF when capturing the selected text.
- Forward comment/hunk cycling now lands on the *nearest* thread/hunk below the
  cursor and wraps past the last item, instead of jumping to the farthest one
  and stopping at the end.
- `:PRInfo` edit mode opens again. `<C-s>` was bound with a table mode
  (`{ "n", "i" }`) which crashed `make_pr_edit_layout` on mount; each mode is now
  bound separately.
- A `REQUEST_CHANGES` review with an empty body and no pending comments is now
  rejected (previously it was submitted as a change request with no rationale).
- GitHub API requests send clean `Accept` headers; a dead command field and a
  stray debug `vim.notify` were removed from the provider.
- Telescope picker previews now resolve when Neovim's working directory is not
  the git root — the entries carry absolute paths (Telescope resolves the
  previewer target against cwd, which broke relative paths).
- Reading a thread popup no longer crashes when the popup is closed before an
  in-flight re-fetch lands, and no longer prints a spurious
  `W10: Changing a readonly file` warning into `:messages` on every render
  (`readonly` was dropped from the popup buffers; `modifiable=false` is enough).
- `plugin/pr.lua` no longer clobbers the real `:PR*` commands (losing completion
  and strict argument specs) when it is sourced after `setup()` has already run.

[Unreleased]: https://github.com/btj93/pr.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/btj93/pr.nvim/releases/tag/v0.1.0
