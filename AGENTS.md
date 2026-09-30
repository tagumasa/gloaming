# AGENTS.md — gloaming

Rules and policy for coding agents on the gloaming codebase — not
session records or measurements. User-facing documentation lives in
README.md and docs/.

# Project description

## Overview

gloaming is a document-intelligence **library** written in Odin: a
pattern-query engine over annotated token sequences (`[]Token`), an
evidence-bearing document graph, corpus statistics, and a tiered store
(memory and disk backends). Deterministic, core-only, host-agnostic —
the application surface (UI, protocols, tools) belongs to the hosts
that embed it. The first host is the standalone CLI (`cli/`, package
main, one-shot process by design).

### Package layout and dependency direction

```
src/gloaming        the library body — core:* only
                    (core:os appears in store_disk and nowhere else)
  ↑ src/glexport    auxiliary text interchange (dot/mermaid/JSON over
                    returned data — outside the body)
  ↑ adapter_src/moli_adapter    the bridge package: imports gloaming
                    AND moli (the core never imports moli)
  ↑ cli             the host: library + glexport + adapter + moli
                    (the host may import moli — the library may not)
vendor/moli         pinned submodule — the public moli repository
                    (the adapter's input; src/ never imports it)
tests/              separate package, imports the library through
                    -collection:gloaming=src
```

- The library never imports moli and never imports glexport; both
  directions are the point. Adapters live outside `src/` precisely so
  the body cannot grow the import.
- `vendor/moli` is the moli dependency: a pinned submodule of the
  public repository (`.gitmodules` records it). The adapter gates read
  it in-tree; the two self-contained gates run without it initialized.
- `bench/` is a preserved measurement artifact, skip-guarded on the
  vendored submodule and the staged corpus (below) — do not "clean it
  up".
- `corpus/` is local-only (gitignored except its README): the bench
  corpus never enters the tree, in any form.
- `scripts/` is host-side tooling outside the library (the Aozora
  staging pass that produces the bench corpus).

# Project principles

These principles govern every part below; each one names the sections
that carry its rules.

- **Correctness, processing performance, and resource behaviour are the
  product.** A change that trades any of them for convenience is a
  defect. Enforced in: Design rules; Bench, measurements, and
  attribution.
- **The specification governs the implementation.**
  [docs/design.md](docs/design.md) is the specification; where code and
  specification disagree, one of them is defective — determine which,
  and fix that side. Enforced in: Design rules.
- **Every measure is exact and deterministic.** No stochastic models in
  the library, no hidden tiebreaks: outputs are byte-stable, and the
  determinism rule (row order) is named where it binds. Enforced in:
  Design rules.
- **The library returns data; hosts render.** Nothing in the body draws,
  formats for display, or frames a protocol. Enforced in: Design rules.
- **Every resource has one owner and one bound.** There is no GC safety
  net: results live on the caller's arena, caches are bounded, keys own
  their bytes, and a leak is a finding, not a style note. Enforced in:
  Design rules; Testing conventions.
- **Verdicts come from artifacts.** Suite outcomes come from the log,
  never the exit status alone; performance claims come from the bench
  record, re-measured before they are believed. Enforced in: Build,
  test, commit; Bench, measurements, and attribution.
- **Write for the next reader.** Comments state constraints the code
  cannot show; no text cites material the reader does not have.
  Enforced in: Comment self-containment.
- **moli is a pinned public submodule, not a sibling tree.** The
  dependency lives in-tree at `vendor/moli` (the public repository,
  recorded in `.gitmodules`); the public build story stays the two
  self-contained gates, and the adapter/CLI/bench recipes skip with a
  note when the submodule is not initialized. The bench corpus remains
  locally staged. Enforced in: Build, test, commit.

## Research principles (all sessions)

Grounding rules for anything reported to the user. They override
harness defaults that favour delegation or compressed summaries.

- Every `file:line` cited in a report must have been read directly in
  this session. Facts sourced from sub-agent output are not reportable
  until re-grounded against the code.
- Terminology is verified before use: quote an identifier only after
  confirming it in this repo. Unverified sub-agent vocabulary is
  verified or dropped — never relayed as fact.
- File references name the repo and the absolute path.
- A reported finding is answered with its grounding — one line of
  file:line or command output; the record is corrected when new
  evidence displaces it, and restating the same evidence changes
  nothing.

## Comment self-containment

Committed code, docs, and error strings must be self-contained: no
citations of private notebooks, session logs (`tmp/`), or local machine
paths, no dates or change-history narration in comments, and no
design-phase or work-round numbers in file names or comment identity
tags — **code names domains, not design phases** (`keyness_cmd.odin`,
never `tier3.odin`). Where a constraint needs its reasoning, state the
reasoning in prose and point at a section of docs/design.md by name.

The same discipline bounds the figures written here: exact numbers that
move while the code evolves (suite sizes, default constants) rot between
edits, and session measurements (timings, byte counts) are records, not
rules. Where a magnitude carries a rule, write it as about/over/under
and name the identifier that owns the exact value.

# Development guide

## Coding conventions live in a skill

The Odin coding conventions — naming, error-model vocabulary, and
structural idioms — are also maintained as a skill, tracked at
[docs/skills/odin-conventions/SKILL.md](docs/skills/odin-conventions/SKILL.md).
If your harness supports skills, load it when writing, reviewing, or
renaming Odin code; if it does not, read the file directly. AGENTS.md's
Design rules remain the source of truth; the skill is its loadable
mirror — change a rule in both or not at all.

## Build, test, commit

```sh
just check          # odin check -vet -strict-style over the library + glexport
just test           # serial suite, log-gated (self-contained)
just check-adapter  # adapter package (needs the moli submodule; skips if uninitialized)
just test-adapter   # adapter suite (same guard)
just check-cli      # CLI type-check (same guard)
just cli            # build the CLI host to ./gloaming
just bench          # quantitative bench (needs the submodule + staged corpus; skips)
just corpus-ja      # stage the JP bench corpus from 青空文庫 (network)
```

- The two gates that matter everywhere are `just check` and `just
  test` — they need nothing but the Odin toolchain. CI runs exactly
  those two.
- Prefer the just recipes over raw odin commands: the recipes carry the
  collections, the thread pin, and the log gating.
- The toolchain is the pinned Odin nightly (currently
  `dev-2026-09-nightly:a2fb372`; CI pins the frozen dev-YYYY-M release
  plus a hard version assert). After any compiler update: re-run every
  gate, re-pin, and re-baseline docs/benchmarks.md.
- Commits are English conventional style (`fix:`, `feat:`, `perf:`,
  `docs:`, `chore:`, `bench:`); one comprehensive topical commit per
  change is the norm.

# Development rules in detail

## Design rules (code-review criteria)

These are settled structural rules. Violations get flagged in review.

- **The library body is `core:*` only.** No `os`/`thread` on analysis
  paths; `core:os` is confined to `store_disk` (the disk backend behind
  the store port). A new os/thread need in the body means the design
  boundary moved — take it to the specification first.
- **No FFI anywhere in this repository.** No `foreign` declarations, no
  vendored C, nothing that makes the build need a C toolchain.
  Pure-Odin external packages are fine (the moli adapter is the
  standing example); that line is about FFI, not external code.
- **gloaming never imports moli.** The host adapts morphemes into
  `[]Token`; the adapter package lives outside `src/` so the body
  cannot grow the import.
- **The body returns data; hosts render, cap, and stream.** Cursor
  iteration (`next_match`) with results on the caller's arena; the
  auxiliary `glexport` package serializes text interchange outside the
  body. No UI, protocol, or tool-session framing inside the library.
- **Caps are caller dials with visible flags.** Match lists take a
  mandatory limit and return `truncated`; the cursor streams the
  complete set; count tables (`freq_table` and kin) return complete,
  deterministically sorted rows — hosts slice top-k themselves.
- **Cancellation is the trailing stop-check.** Every pass whose cost
  scales with corpus size or n² takes an optional trailing
  `check`/`user` pair; a poll firing returns typed `.Interrupted` with
  scratch freed. Zero-work preprocessing polls nobody (the
  pagerank/toposort rule), and pure transforms over caller-dimensioned
  inputs (the stats matrix builders) carry no check — their cost is a
  dimension the caller chose. Do not build parallel timeout mechanisms.
- **Every cache is bounded; every long-lived map key is cloned on
  insert.** `m[k] = v` stores the key's header without cloning its
  bytes — a caller-owned key rots once the caller's memory dies, and
  later lookups miss silently. No process globals; state is passed
  explicitly.
- **Concurrency: the library never locks.** Exclusion is the host's,
  type by type: a parsed `Query` (and `Lemma_Groups`) is immutable and
  serves concurrent cursors; the store and `Doc_Graph` are single-writer
  under host-side exclusion; stats and glexport are call-scoped.
- **Memory lifetime is rule-bound (no GC).** Request results live on
  the caller's arena; procedure parameters that take an allocator keep
  the short `a` (or a role name — `arena`, `scratch` — when the role
  matters); struct fields that hold an allocator are `allocator`.
  Anonymous merge-sort buffers must not outlive their call:
  `sort_with_buffer` is the one merge-sort convention, and scratch
  ownership is proven by contract tests running whole layers on a
  tracking allocator that frees only the outputs.
- **Errors are closed per-boundary vocabularies propagated with
  explicit checks** (`if cerr != .None`): `_Err` enums (`Query_Err`,
  `Store_Err`, `Graph_Err`), no string-matching on error kinds, no
  panics on analysis paths — lookups return typed errors
  (`.Not_Found`, `.Stale`). `Store_Err.Stale` is the decode-refusal
  protocol: a payload whose dictionary version disagrees with the open
  dictionary answers Stale *before* decoding, because
  silent-wrong-resolution is the store's hazard to catch, not each
  host's.
- **Determinism is a named rule, not an accident.** Whole-graph passes
  tiebreak by row order; `graph_toposort`'s `order`/`cyclic` split,
  `graph_traverse`'s visit order, and every count-table sort are
  byte-stable across runs. If a change can reorder output, that change
  is a semantic change — gate it like one.
- **Graph rows are full-state and single-path.** Append is
  `id == len`, rewrite is the same id again, dead rows keep their slot
  as tombstones; the `graph_apply_*` procs are the only mutation path —
  disk writers serialize a row, commit the batch (write + sync), then
  apply, so memory never runs ahead of the log and open-replay runs the
  same records through the same applies. `graph_entity_merge` lands its
  whole plan as ONE batch (a torn merge repairs to the pre-merge
  state). Relation evidence absorbs as a set — a span the row already
  holds is not repeated — so re-running a rule or re-citing a passage
  is idempotent.
- **Parser bound checks precede the make.** A count parsed from a few
  bytes of body can demand gigabytes; validate before allocating (the
  rec_parse rule).
- **On-disk formats are versioned and refusual-bearing.**
  `PAYLOAD_VERSION` / `RECLOG_VERSION` name the writer's version;
  readers accept a stated range and refuse everything else. A format
  change bumps the version and carries its migration rule in the same
  change.

## Testing conventions

- **Verdicts come from the log, never the exit status alone.**
  `odin test` runs every test under a tracking allocator and prints a
  `[WARN]`-shaped block per leaked allocation — a leak does not fail
  the test, so the gate is the grep: the justfile pattern
  `\[ERROR\]|\[FATAL\]|\[WARN \]|\[WARN\]|\+\+\+ leak|bad free|out of
  range` over the suite log. The `[WARN ]` (padded) alternative is
  load-bearing — the framework prints per-test leak blocks under a
  padded header. Always `grep -a` (a failing text test can spill bytes
  that make grep treat the log as binary and silently match nothing).
  The leak discipline is zero leak lines — any leak line is a new
  finding.
- **Suites run with `ODIN_TEST_THREADS=1`** (`just test` passes it).
- **The full suite is the verdict — never a single-test
  `-define:ODIN_TEST_NAMES` build.** Single-test builds changed the
  binary's layout and segfaulted on green code once; reproduce any
  single-test crash against the full run before debugging the code.
- **Committed fixtures stay synthetic** (business-style documents,
  hand-written sentences, the golden DSL→match table under
  `tests/fixtures/`). The corpus never enters the tree; numbers derived
  from the bench corpus are recorded in docs/benchmarks.md as
  measurements only, never text.
- **The storage gate is the differential contract**: the memory store
  and the disk store must return exactly the same thing for the same
  corpus — the test that proves it stays green in both directions,
  including reopen and torn-tail repair.
- **Ownership is tested, not assumed**: layers with scratch run a
  contract test on a tracking allocator that frees only the outputs
  (the stats precedent). A new long-lived collection or scratch shape
  gets the same treatment.

## Cross-platform file handling

The library is core-only, so portability is mostly by construction;
CI verifies ubuntu / macOS / Windows natively (no cross-compilation as
"verification" — anything aimed at another OS belongs to the CI
matrix).

- Build paths with the `core:os` filepath procedure group — never
  concatenate separators by hand.
- The store's on-disk byte order and record framing are
  platform-neutral by construction; keep it that way (no
  `platform-dependent` layouts in the formats).

## Bench, measurements, and attribution

`just bench` (bench/) is the repeatable quantitative record;
docs/benchmarks.md is the committed, hand-curated baseline. The rules:

- **A provenance block precedes every run** (date, toolchain, both
  trees' HEADs with dirty flags, host) — a number without its
  provenance is not a record.
- **Stage tags attribute a moved number to the tree that owns it**
  (moli / seam / gloaming). Everything moved → toolchain or host. One
  stage moved → that side. A moved *count* means semantics changed, not
  performance — counts print beside the timings for exactly this
  check.
- **Identity gates before timing**: an optimization candidate dumps
  its outputs (pair tables, match lists, score bit patterns, compressed
  bytes) old-vs-new and they must be file-exact before any timing is
  read. Output-changing changes are deliberate decisions, recorded as
  such, never accidents of a perf round.
- **Adopt/reject deltas come from adjacent same-session runs** (A/B
  with a stashed counterpart, doubled when ambiguous) — cross-day drift
  exceeds the within-day spread in both directions.
- **Re-measure before treating a regression — or an "improvement" — as
  real.** Re-baselines rewrite the tables in place, in the same change
  as the shift that moved them — the committed doc is a cross-section,
  not a diary; each run's dated provenance stays in the harness log.
- The bench corpus is local-only, staged from public-domain sources
  (孤島の鬼 per corpus/README.md); the staging pass is part of the
  measurement record.

# Reference

## Odin language and stdlib

Facts that have bitten this codebase family. All of them are rules
about ownership or scope — the two things Odin makes explicit.

- `defer` fires at the end of the enclosing **scope**, not the
  procedure: a `defer` inside an `if`/`for` block runs when that block
  exits. For must-run-on-return cleanup, hoist the resource and use a
  procedure-scope `defer`.
- **A result buffer that ships must not be double-owned**: if a
  dynamic array's storage becomes the caller's result, the producer
  must drop its own `defer delete` and delete by hand only on the
  error/interrupted paths (the graph_traverse / pagerank precedent).
- `append` on a nil (zero-value) `[dynamic]` grows it through
  `context.allocator` — under `odin test` that is the per-test tracking
  allocator, and the stranded backing surfaces as a leak WARN. Create
  dynamic arrays with `make([dynamic]T, 0, cap, a)` before appending.
- The same auto-init rule applies to zero-value **maps** (first insert
  grows through `context.allocator`) — a struct that owns maps or
  dynamics `make`s every collection on its own allocator.
- A `[dynamic]T` or `map` made with `make(..., a)` **carries its
  allocator in the value** — bare `delete(x)` frees through the stored
  allocator and is correct. A plain `[]T` or `string` made with an
  explicit allocator carries nothing — freeing needs
  `delete(x, that_allocator)`; a bare `delete(x)` is a bad free in any
  caller whose `context.allocator` differs.
- **An exhausted arena fails silently**: `make` (slice, dynamic, or
  map) against a caller arena that cannot satisfy the request returns
  an empty collection, and subsequent `append`s drop — no error, no
  panic outside debug builds. An under-sized request arena therefore
  surfaces as wrong results (an empty table, a phantom count), never
  a typed refusal; sizing the arena for the whole request — parse,
  cursor, and results together — is a host contract (docs/design.md,
  "API discipline").
- A `[]T{...}` literal whose elements are compile-time constants lives
  in **static/stack storage** — `delete` on it is an immediate bad
  free, and anything a `defer` will delete must be `make`-made and
  filled, never a literal.
- **Odin syntax that differs from C and Go**:
  - `'abc'` is a RUNE literal — strings are always `"abc"`.
  - `case:` in a `switch` over an enum is NOT a default unless the
    switch is `#partial`.
  - `+` string concatenation works only on compile-time constants —
    runtime joins go through `strings.concatenate`/`strings.join`.
  - procedure parameters are immutable (copy into a local to mutate).
  - `for v, i in slice` binds value-then-index (a `for _, x in` binds
    the INDEX to x).
  - `for c in some_string` iterates RUNES — index bytes (`s[i]`) when
    building a `[]u8` buffer.
  - a `break` inside a `switch case` leaves the **switch**, not the
    enclosing `for`.
  - indexing a `::` constant with a variable index is a compile error —
    materialize the table into a local (`table := TOOLS`) and index
    that.
  - never return a string/view into a local stack buffer or a builder
    that a defer destroys — clone out.
  - a `Dynamic_Arena` is self-referential: never return or copy one by
    value out of the procedure that initialized it.
