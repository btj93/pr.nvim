# Contributing to pr.nvim

Thanks for your interest in improving `pr.nvim`. This guide covers the local dev
loop, the test architecture, and the two "parity axes" (providers and pickers)
that most changes have to respect. For a deeper architectural tour, read
[`CLAUDE.md`](CLAUDE.md) — this document is the short version.

## Requirements

- **Neovim 0.10+** (the plugin relies on 0.10 APIs; `:checkhealth pr` enforces the floor).
- `git`, plus the CLI for the provider you develop against: `gh` (GitHub),
  `glab` (GitLab), or `curl` (Bitbucket Cloud).
- [`stylua`](https://github.com/JohnnyMorganz/StyLua) and
  [`luacheck`](https://github.com/mpeterv/luacheck) for formatting and linting.
- Runtime deps (`nui.nvim`, `plenary.nvim`) are cloned automatically by the test
  harness — you do not need them installed globally to run the suite.

## Dev setup

```sh
git clone https://github.com/<you>/pr.nvim
cd pr.nvim

make test          # run the full plenary.busted suite over tests/
make lint          # luacheck lua/ tests/
make format        # stylua lua/ tests/  (rewrites in place)
make format-check  # stylua --check lua/ tests/  (CI uses this)
```

On the first `make test`, `tests/minimal_init.lua` shallow-clones
`plenary.nvim` and `nui.nvim` into temp directories and prepends them to the
runtimepath. Override the clone locations with environment variables:

```sh
PLENARY_DIR=~/.local/share/nvim/lazy/plenary.nvim \
NUI_DIR=~/.local/share/nvim/lazy/nui.nvim \
make test
```

(defaults: `PLENARY_DIR=/tmp/plenary.nvim`, `NUI_DIR=/tmp/nui.nvim`.)

### Running a single spec

Do **not** use `-c "PlenaryBustedFile ..."`: it forks a child nvim that does not
inherit `-u tests/minimal_init.lua`, so nui and the `helpers.*` modules drop off
the path and every harness-dependent flow spec fails spuriously. Use the
in-process `require("plenary.busted").run(...)` form, which keeps the harness:

```sh
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c 'lua require("plenary.busted").run("tests/<spec>.lua")' \
  -c "qa!"
```

## The three test layers

The suite spans three layers. Pick the lowest layer that can prove your change;
add a flow or CLI-shim spec only when the behavior can't be reached from pure
helpers. Full detail is in [`CLAUDE.md`](CLAUDE.md#testing) — the summary:

| Layer | Files | Exercises | Reach for it when… |
|---|---|---|---|
| **Unit** | `tests/*_spec.lua` (pure) | Pure helpers directly — no nui, no subprocess (diff parsing, normalization, drift, suggestions, render helpers). | Your change is a pure function or can be factored into one. Fastest and most robust; prefer this. |
| **Flow** | `tests/flow_*_spec.lua` | Real nui popups + real keymaps over a **fake provider** inside a headless UI sandbox. Backed by `helpers/fake_provider.lua` (full-contract in-memory provider + call log), `helpers/ui_env.lua` (headless UI stubs + `feed`/`wait_for`), and `helpers/git_repo.lua` (throwaway real git repos). | A keymap, popup render, or multi-step UI flow needs to be driven end-to-end. |
| **CLI-shim** | `tests/*_cli_spec.lua` | The **real** provider modules end-to-end (argv assembly, async `plenary.job` chains, JSON extraction/normalization, fetch-once caching, error hints). Only the CLI binary (`gh`/`glab`/`curl`) is faked via `helpers/cli_shim.lua`; `git` always runs for real. | You touched a provider's subprocess plumbing, argv, or JSON parsing — the layer the fake provider short-circuits. |

Writing a flow spec, in brief: guard on nui at the top
(`if not pcall(require, "nui.popup") then return end`), `env = ui_env.setup()`
and `fake, uninstall = fake_provider.install("<name>", { <scenario> })` in
`before_each`, mount the real UI and `env.wait_for` the rendered text, `env.feed`
the real keymap, then `env.wait_for` + assert on the observable effect
(`fake_provider.called(fake, "reply")`, a mutated scenario, or re-rendered
text). Tear down with `env.drain()` → `uninstall()` → `env.teardown()`.

## Parity rules

Two strategy points are resolved by string lookup, so `pr.nvim` ships **three
provider backends** (`github`, `gitlab`, `bitbucket`) and **three picker
backends** (`snacks`, `telescope`, `fzf`). Contributions must keep all backends
in lockstep.

### Adding a provider method

When you add a method to the provider surface, do **all** of the following or the
contract spec fails loudly:

1. Document it in `lua/pr/providers/interface.lua` (LuaCATS types + contract, no runtime code).
2. Real implementation in `lua/pr/providers/github.lua`.
3. At minimum a **silent stub** in `lua/pr/providers/gitlab.lua` and `lua/pr/providers/bitbucket.lua`
   (return `nil` / `{}` / `(false, "not implemented")`, matching the sibling stubs).
   Consumers guard optional methods with `type(git.foo) == "function"`.
4. Add the name to `REQUIRED_METHODS` in `tests/provider_contract_spec.lua`.
5. Add it to `SURFACE` in `lua/pr/health.lua` so `:checkhealth pr` verifies it.

See "Provider parity" in [`CLAUDE.md`](CLAUDE.md) for which methods are real vs.
stubbed on each backend today.

### Touching a picker feature

Any picker-facing change must work across all three backends
(`pickers/{snacks,telescope,fzf}.lua`). The pure item-builder / confirm surface
(`_build_*_items` / `_confirm_*`) is characterized per backend
(`picker_{snacks,telescope,fzf}_items_spec.lua`) and pinned across backends by
the cross-backend equivalence net `tests/picker_items_spec.lua` — identical row
counts, target `(path, line)` sets, PR-number sets, and dispatch. If you add a
picker capability, extend that equivalence spec. Filter state is shared in
`lua/pr/pickers/filter.lua`; do not fold filtering into a builder.

## Style

- **Indentation is tabs**, not spaces (Lua files). `stylua` enforces this; run
  `make format` before committing.
- Line width **160 columns** (`stylua.toml`).
- `luacheck` config is `.luacheckrc` (`vim` is a declared global). Keep
  `make lint` clean.
- Every Lua module follows `local M = {} ... return M`.
- Keep LuaCATS annotations (`---@param`, `---@class`, `---@field`) in sync when
  you add fields to the public API or provider data shapes.
- User-visible messages: `vim.notify` for transient info,
  `vim.api.nvim_echo({{msg, "ErrorMsg"|"WarningMsg"}}, true, {})` for
  errors/warnings. Subprocess failures use the literal hints
  "Is a gh cli installed?" / "Is a git cli installed?" for a consistent signal.

## Commit messages

Follow the conventional-commit style already in the history — a
`type(scope): summary` subject, with an optional body explaining the *why*:

```
feat(drafts): persist edit drafts from the live inline-edit path
fix(ui): dispatch `r` to the applicable resolve/unresolve via can_perform
test: cross-backend picker item/dispatch equivalence
docs: contributing guide, changelog, issue/PR templates
refactor(fzf): export pure line builders and confirm dispatchers
```

Common types in this repo: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`.
Scopes are optional and free-form (`ui`, `github`, `telescope`, `review`, …).

## Before opening a PR

- `make test`, `make lint`, and `make format-check` all pass.
- Tests added at the appropriate layer for the change.
- Both parity axes considered — all three providers and all three pickers, or a
  note in the PR explaining why a backend is N/A.
- `CHANGELOG.md` updated under `## [Unreleased]` for any user-visible change.

CI (`.github/workflows/ci.yml`) runs the tests, `luacheck`, and
`stylua --check` on every push and pull request.
