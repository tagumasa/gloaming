# Contributing to gloaming

## Bug fixes

Bug fixes are always welcome. If you find a bug, please open an issue
with a minimal reproduction — for the query DSL, the smallest pattern
and input that misbehaves — or submit a pull request with a fix.

## New features and specification changes

The specification governs the implementation
([docs/design.md](docs/design.md)): layer rules (core is `core:*`-only,
no FFI, the library never imports an analyzer), API discipline
(cursors, caller-dial caps with visible truncated flags, bounded
caches, optional stop-checks), and the exact-and-deterministic
statistics contract. Features that touch any of these — a new measure,
a new read path, a storage format change — require prior discussion:
please open an issue before starting work on a pull request, so scope
aligns before effort is spent.

## Gates

`just check` and `just test` must pass; they are self-contained (the
Odin toolchain alone). Verdicts for `just test` come from the log —
zero error/warn/leak lines — not the exit status alone. The adapter,
CLI, and bench gates additionally need the vendored moli submodule
([github.com/tagumasa/moli](https://github.com/tagumasa/moli), checked
out at `vendor/moli` — `git submodule update --init`); they skip with
a note when it is not initialized.

The toolchain is the pinned Odin nightly (see
[.github/workflows/ci.yml](.github/workflows/ci.yml) for the current
pin). After any compiler update the gates are re-run and the pin
re-baselined, together with [docs/benchmarks.md](docs/benchmarks.md).

## Release cadence

Releases are tagged `v*` from main. The current state ships no binary
artifacts — the library and CLI build with the Odin toolchain alone —
so a release is the source tree plus the version stamp.

## Quick clarifications

Typo fixes, documentation improvements, and test coverage gaps are
welcome as direct pull requests without prior discussion.
