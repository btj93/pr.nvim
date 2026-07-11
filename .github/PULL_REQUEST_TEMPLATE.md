<!--
Thanks for contributing to pr.nvim! Please fill in the summary and run through
the checklist. See CONTRIBUTING.md for the test layers and parity rules.
-->

## Summary

<!-- What does this change do, and why? -->

## Checklist

- [ ] Tests added at the right layer (unit / flow / CLI-shim) — or an explanation
      below why none were needed.
- [ ] **Provider parity**: all three providers (github, gitlab, bitbucket)
      considered — implemented, stubbed, or N/A with a reason below. New provider
      methods are added to `interface.lua`, `github.lua`, the gitlab/bitbucket
      stubs, `provider_contract_spec.lua`, and `health.lua` SURFACE.
- [ ] **Picker parity**: all three pickers (snacks, telescope, fzf) considered —
      or N/A with a reason below. Picker-facing changes extend the cross-backend
      equivalence spec (`picker_items_spec.lua`).
- [ ] `make test` passes.
- [ ] `make lint` passes.
- [ ] `make format-check` passes.
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` for any user-visible change.

## Parity / test notes

<!-- If a provider or picker is N/A, or a change is untested, explain here. -->
