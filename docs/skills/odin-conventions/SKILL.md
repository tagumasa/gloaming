---
name: odin-conventions
description: Odin coding conventions — naming, error-model vocabulary, and structural idioms. Use when writing, reviewing, or renaming Odin code or identifiers.
---

# Odin Conventions (settled project rules)

These conventions are settled project rules. Apply them as written.

## Naming

Base layer — every identifier falls in exactly one category, and each
category carries a rule:

- **Type names are Pascal_Case**, multiword as `Word_Word`
  (`Entry_Record`, `Query_Step`, `Char_Class`, `NBest_Path`);
  concatenated forms (`EntryRecord`) are not used.
- **Value constants are ALL_CAPS** (`CONNECTION_DEFAULT_COST`,
  `HANGUL_L_BASE`, `DISK_PAYLOADS`, `DP_UNREACHABLE`).
- **Enum members are Pascal_Case**; multiword members may be
  underscore-joined or concatenated — match the enum being extended
  (`File_Not_Found` and `OutOfMemory` are both in-repo practice).
- **Procedure names, struct fields, variables, and parameters are
  snake_case** (`tokenize_text`, `entry_count`, `cursor_pos`).
- **Package names are lowercase single words** (`moli`, `gloaming`,
  `jsonrpc`).

Role overlays — applied on top of the base layer:

- **Mutex fields are `mu`.** A struct with one mutex names it `mu`; a
  struct with several takes `*_mu` (`tx_mu`, `doc_mu`). C-side lock
  naming (`*_lock` in native extension code) is a separate domain,
  outside this rule.
- **Allocator fields are `allocator`.** A
  role-named allocator takes `<role>_allocator` (`arena_allocator`,
  `scratch_allocator`); a `mem.Arena` /
  `mem.Dynamic_Arena` value — the arena object, not the allocator view —
  keeps a plain role name (`scratch`, `arena`). Procedure *parameters*
  that take an allocator keep the short `a`.
- **Error type names follow the payload's shape**: a closed failure
  vocabulary as an enum or union takes `_Err` (`Read_Err`,
  `Query_Err`, `Load_Err`); a plain fault enum inside it takes `_Fault`
  (`Load_Fault`); a struct explaining a failure's circumstances takes
  `_Error` (`Path_Escape_Error`).
- **Bool fields**: `is_*` for state identification (`is_error`,
  `is_response`), `has_*` for component presence (`has_body`,
  `has_include`) — never `have_*` or a bare name where the prefix would
  clarify intent.

## Error-model idioms

- Failures are closed per-boundary vocabularies propagated with
  explicit checks (`if err != nil` / `if cerr != .None`); `or_return`
  is not the house idiom.
- No string-matching on error kinds; error codes are typed at the
  boundary layer.
- Panic is for startup invariant violations only; lookups return
  `.NotFound`-style values instead.

## Constant data

- Index constant tables (`::` slices and arrays) through a materialized
  local — `table := TOOLS` — or iterate them with a for-binding; the
  compiler rejects variable indexing straight into constant data
  ("Cannot index a constant").
