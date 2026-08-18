# pr.nvim Release Stabilization Design

Date: 2026-08-13
Status: Proposed
Scope: Phase 0 release blockers and v0.1.0 publication readiness

## Summary

`pr.nvim` already has a broad user-facing review workflow and a strong automated test suite. The next development cycle will not add product features. It will make the current release candidate safe and correct under failure, empty-result, concurrent-fetch, and large-PR conditions, then prepare it for a controlled public v0.1.0 release.

The work is split into four independently reviewable implementation slices:

1. Remove sensitive command data from logs and notifications.
2. Give provider fetches explicit lifecycle state and settle every caller exactly once.
3. Fetch every page of provider review data instead of silently truncating it.
4. Verify a clean installation and prepare the corrected commit for publication.

The existing public Lua API, provider selection proxy, picker contracts, command names, normalized comment shape, and CLI-only network boundary remain intact.

## Context

The local branch is a substantial release candidate: it is 56 commits ahead of `origin/main`, contains the v0.1.0 release hardening work, and passes the full test, lint, and formatting gates. The public repository does not yet expose that state, so there is no external usage signal to justify another feature wave.

Four correctness problems should be addressed before publication:

- Bitbucket failure output currently includes the full curl argument vector. With environment-based authentication this contains `BITBUCKET_USERNAME:BITBUCKET_APP_PASSWORD`; mutation requests can also expose draft comment bodies.
- GitHub and GitLab GraphQL reads cap review connections at 100, and Bitbucket comment reads request a single 100-item page. Large reviews are therefore incomplete without an explicit warning.
- The comment and hunk caches use an empty table for both “not loaded” and “loaded with no results.” Empty reviews are repeatedly fetched, and concurrent callers can start duplicate jobs.
- Several provider failures return without invoking their callback. Callers can remain in a loading state indefinitely, and `clear_*` calls cannot reliably distinguish or invalidate in-flight work.

Provider feature stubs and UI/module decomposition are real follow-up concerns, but they are not v0.1.0 blockers and are explicitly outside this design.

## Goals

- Never expose credentials, authorization material, request bodies, GraphQL bodies, or user-authored draft text through normal notifications or debug output.
- Treat an empty successful result as a cached result.
- Coalesce concurrent requests for the same provider resource into one subprocess chain.
- Invoke each registered callback exactly once on success, failure, or invalidation.
- Ignore stale subprocess completions after a cache clear or repository-context change.
- Return complete comment/thread collections when a provider paginates them.
- Preserve the existing normalized `Comments`, `Hunks`, `PRSummary`, and callback-first provider interfaces.
- Keep all provider CLI calls asynchronous and schedule Neovim API work onto the main thread.
- Publish only after the existing test matrix and a clean-install smoke path are green.

## Non-goals

- New review features, commands, pickers, or providers.
- Completing GitLab or Bitbucket feature parity.
- Splitting `ui.lua` or rewriting provider modules.
- Introducing a new HTTP client; provider traffic continues through `gh`, `glab`, or `curl`.
- Multi-repository provider state within one Neovim process.
- Automatic retries of remote mutations. A failed mutation must never be replayed implicitly.
- Changing the public provider proxy or removing the provider module cache fields consumed by existing code.
- Publishing tags, releases, or repository metadata without a separate explicit external-write step.

## Design principles

### Prefer small seams over a provider rewrite

Security and fetch lifecycle behavior will be centralized in small internal helpers, while provider-specific command construction and normalization stay in their current modules. This keeps the release diff reviewable and lets the later shared-process-runner work proceed with real failure data rather than speculation.

### Preserve observable compatibility

Existing callbacks that accept one argument continue to work. Fetch callbacks may receive an optional second `err` value, but no current consumer is required to accept it. Comment and hunk fetch failures settle with an empty table plus an error. Providers continue to emit one concise user-facing failure notification until consumers gain structured error UI in a later release.

### Never trade safety for debug convenience

Normal operation logs only an operation name and a concise cause. Debug mode may include sanitized argv metadata, exit codes, and stderr, but it uses the same redaction path and cannot print raw credentials or payloads.

## Component design

### 1. Safe diagnostic formatting

Add an internal module, `lua/pr/log.lua`, responsible for sanitizing subprocess diagnostics. Provider modules will no longer call `vim.notify(table.concat(args, " "))` or dump raw result tables directly.

The module exposes pure formatting helpers and a small notification wrapper:

- `redact_argv(args, secrets?) -> string[]`
- `redact_text(text, secrets?) -> string`
- `command_failed(operation, command, args, stderr, opts?)`

Redaction rules:

- Replace values following credential or body flags such as `-u`, `--user`, `-d`, `--data`, `--data-raw`, and `--data-binary` with `<redacted>`.
- Replace sensitive key/value fields such as `body=...`, `query=...`, `Authorization: ...`, `Cookie: ...`, `token=...`, `password=...`, and `secret=...` while retaining the key name.
- Remove URL userinfo (`scheme://user:password@host`) and redact every non-empty secret explicitly passed by the provider.
- Do not mutate the original argv table.
- In normal mode, show only the operation and stable install/auth hint. Sanitized argv and stderr are available only when `config.opts.debug` is true.

Bitbucket passes its username and app password as explicit secrets. GitHub and GitLab use the same formatter so user-authored bodies and GraphQL documents cannot leak when their commands fail.

The formatter is defensive, not an authentication redesign. Environment credentials still appear in the curl child-process argv; the documentation will recommend `~/.netrc` as the safer Bitbucket option. Moving credentials off argv entirely belongs to the later process-runner/authentication design because it requires secure stdin or temporary-file lifecycle work.

> **ERRATUM (2026-08-18, implementation of `470b186..609cf99`).** This spec contradicts itself about normal-mode output. The "Never trade safety for debug convenience" principle above says normal operation logs "an operation name and a concise cause", while the last redaction-rules bullet in this section says normal mode shows "only the operation and stable install/auth hint" (no cause).
>
> **Resolved in favor of the principle: normal mode DOES show a redacted one-line cause.** Implemented in commit `eba6037` — `log.command_failed` renders `<operation> failed. <first non-blank redacted stderr line, capped at 160 bytes> <hint>` in both modes; `debug` adds the exit code, redacted argv, and full redacted stderr on top. Rationale: the hint alone ("Is a gh cli installed?") actively misleads on an HTTP 422/401, and the cause line goes through the same redaction as the debug output, so it leaks nothing the debug path would not.
>
> The bullet above is therefore stale — do NOT "fix" the cause line back out in a later slice. Coverage: `tests/log_spec.lua` plus the normal-mode assertions in `tests/{github,gitlab,bitbucket}_cli_spec.lua`.

### 2. Fetch lifecycle state

Add `lua/pr/fetch_state.lua`, an internal state coordinator for provider read resources. Each provider owns one coordinator and continues to store normalized values in its existing module fields.

Each named resource has:

- `status`: `cold`, `loading`, `loaded`, or `error`
- `generation`: incremented by invalidation
- `waiters`: callbacks registered while a fetch is active
- `error`: the last error string for debugging

The helper surface is:

- `begin(resource, callback) -> action, token`
  - `loaded`: the provider invokes the callback immediately with its public cached value.
  - `joined`: append the callback to the current waiter list.
  - `start`: transition from `cold`/`error` to `loading`; the provider starts its subprocess chain using `token`.
- `resolve(resource, token, value)`
  - Accept only the current generation/token, mark `loaded`, and drain waiters once.
- `reject(resource, token, fallback, err)`
  - Accept only the current token, mark `error`, drain waiters once with `(fallback, err)`, then allow a later explicit call to retry.
- `invalidate(resource, fallback, reason?)`
  - Increment the generation, return to `cold`, and settle any current waiters with the fallback and an invalidation error.
- `invalidate_all(...)`

The helper does not know about provider data shapes and does not start jobs. Providers read and write their existing `M.comments`, `M.hunks`, and related fields around it.

`resolve`, `reject`, and `invalidate` synchronously drain the accepted waiter list. Providers therefore call them only from `vim.schedule_wrap`-protected completion paths, preserving the provider contract that public callbacks run on the main thread.

Initial Phase 0 adoption covers `comments` and `hunks` on all providers because those are the automatic background fetches most exposed to duplicate and empty-result behavior. The helper is designed for later adoption by PR lists, metadata, checks, collaborators, and issues, but expanding those resources is not required for v0.1.0.

Provider getter behavior becomes:

1. Ask the coordinator to begin.
2. Return immediately on `loaded` or `joined`.
3. On `start`, run the existing provider-specific asynchronous chain.
4. Route every exit branch through either `resolve` or `reject`.
5. Assign `M.comments`/`M.hunks` only when `resolve` accepts the current token.

Fine-grained `clear_comments` and `clear_hunks` reset the public field and invalidate the matching resource. A completion from the previous generation cannot repopulate cleared state.

### 3. Pagination

Pagination remains provider-specific, but all implementations follow the same rules:

- Follow pages until the provider indicates no next page.
- Merge raw thread/comment nodes across pages, normalize the completed collection once, and invoke the public callback once.
- Abort the chain on the first malformed or failed page; do not cache a partial success as complete.
- Detect repeated cursors/URLs and fail instead of looping forever.
- Keep page requests sequential initially. Predictable API load and ordering are more important than parallelism for v0.1.0.

#### GitHub

The review-thread GraphQL query gains `pageInfo { hasNextPage endCursor }` and an `after` variable. Fetch all `reviewThreads` pages sequentially.

Each returned thread also requests comment page information. Threads with more than 100 comments are completed through a follow-up node query using the thread’s opaque GraphQL id and comment cursor. The accumulated raw thread nodes are then passed through the existing normalization path.

Reaction pagination is not part of Phase 0. The query limit will be raised from 10 to 100, which covers ordinary reviews, but a comment with more than 100 reactions may still lack the current user’s removable reaction id. Full nested reaction pagination is deferred because it would add a request per affected comment and does not affect whether review threads themselves are present.

#### GitLab

The discussions query gains connection page information and a cursor variable. Fetch all discussion pages sequentially. Each discussion also exposes note page information; discussions exceeding 100 notes are completed with a follow-up query addressed by the discussion’s opaque id.

Existing diff refs are captured from the first successful page and checked for consistency on later pages. Award emoji remain embedded in the note data and are normalized as today.

#### Bitbucket

Add a JSON-page helper around `run_curl` that follows the response’s `next` URL until absent. It accepts both API-relative and absolute `api.bitbucket.org` URLs, rejects other hosts, and guards against repeated URLs.

Use it for PR comments in Phase 0. PR-list pagination remains out of scope for this release-stabilization cycle.

### 4. Clean-install and release readiness

Harden `tests/minimal_init.lua` so failed dependency clones produce an immediate, actionable error instead of a later `module 'plenary.busted' not found` failure. Existing `PLENARY_DIR` and `NUI_DIR` overrides remain supported.

Add a CI smoke step that starts Neovim with the repository plus test dependencies on the runtimepath, loads `plugin/pr.lua`, verifies lazy command registration, and exits without provider network calls. The normal test matrix remains the main behavioral gate.

Release readiness requires:

- Full tests on Neovim 0.10.4 and stable; nightly remains informational.
- `make lint`, `make format-check`, and vimdoc helptags pass.
- `CHANGELOG.md` describes the security, cache, pagination, and harness changes.
- The v0.1.0 tag’s remote state is checked before any tag mutation. The existing local tag is annotated and targets the current release-candidate commit. If it has never been published, it may be recreated on the corrected release commit with explicit approval. If it is already remote, the corrected build is v0.1.1.
- External publication—push, GitHub release creation, description/topics, and demo media—is a separate authorized operation after local verification.

## Error handling

- Read failures notify once with a stable operation name and provider-specific remediation hint.
- Fetch waiters receive the resource-appropriate fallback and an optional error string, so no caller hangs.
- A failed read is not cached as a successful empty result. The next explicit fetch may retry.
- An actual empty successful read is cached as `loaded` until invalidated.
- Mutation failures are never retried automatically.
- Pagination failures discard the accumulated partial result for cache purposes.
- Invalidated in-flight completions are ignored after their already-registered waiters have been settled by invalidation.
- JSON decode errors report the provider and operation without echoing the response body, which may contain user-authored text.

## Testing strategy

### Pure unit tests

- Redaction covers credentials, body flags, key/value payloads, authorization headers, URL userinfo, configured secrets, and input immutability.
- Fetch lifecycle covers cold start, immediate loaded hit, concurrent join, successful empty result, rejection and retry, invalidation during loading, stale resolution, and exactly-once waiter delivery.
- Bitbucket next-URL validation and loop detection are pure-tested.

### CLI-shim tests

- Every provider’s representative failure path asserts that notifications omit credential values, request bodies, GraphQL bodies, and raw response bodies.
- GitHub and GitLab fixtures include a second connection page and at least one thread/discussion whose nested comments/notes require a follow-up page.
- Bitbucket fixtures include a `next` URL and verify ordered page requests plus merged normalization.
- Empty comments and hunks are fetched once, cached, invalidated, and then fetched once again.
- Two callers arriving before a deferred CLI completion produce one CLI invocation and both receive the result.

### Existing gates

All current unit, flow, provider contract, picker equivalence, vimdoc, lint, format, and Neovim matrix checks must remain green. Tests continue to avoid real provider network access in the default suite.

## Implementation sequence

Each slice lands green and reviewable before the next begins:

1. `fix(security): redact provider command diagnostics`
2. `fix(provider): model comment and hunk fetch lifecycle`
3. `fix(provider): paginate review comment collections`
4. `test(release): harden clean-install smoke path`
5. `chore(release): prepare corrected v0.1 release metadata`

The security slice ships first and can be released independently if later pagination work expands unexpectedly. Cache lifecycle precedes pagination so multi-page chains have a single, tested completion and invalidation mechanism.

## Success criteria

Phase 0 is complete when:

- No tested failure notification contains a credential, authorization value, request payload, GraphQL document, or user-authored body.
- Empty comments/hunks do not refetch until invalidated.
- Concurrent comment/hunk callers share one provider fetch.
- Every fetch caller is settled exactly once on success, failure, or invalidation.
- Page-two review threads and comments appear in the canonical cache for all three providers.
- No partial paginated response is cached after a page failure.
- A clean dependency bootstrap fails clearly or completes successfully.
- The complete local verification suite passes and the changelog is ready.

## Follow-up after v0.1.0

Real-user feedback determines ordering, but the intended v0.1.x/v0.2 candidates are:

- A full shared subprocess runner with timeout/cancellation and secure Bitbucket credential transport.
- Explicit provider capability flags and honest health/UI reporting instead of callable “not implemented” stubs.
- Responsive popup sizing.
- GitLab PR list/checkout parity.
- Screen-by-screen `ui.lua` decomposition behind the existing `pr.ui` facade.

These follow-ups are not prerequisites for the corrected initial release.
