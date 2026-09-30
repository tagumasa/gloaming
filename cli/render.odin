package main

/*
Output framing: stdout is the result,
stderr is diagnostics, and every failure class maps onto one exit
code. JSON results print through the glexport envelope; TSV/text
renderings escape their cells (\\, tab, newline, carriage return) so a
surface containing the separator can never forge a row. Row sorts go
through the library's sort_with_buffer, the stable buffer merge —
deterministic order is part of every output contract, and stability
keeps equal-key rows in the order the counting passes produced.
*/

import "core:fmt"
import "core:mem"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

EXIT_OK        :: 0
EXIT_USAGE     :: 1
EXIT_PATTERN   :: 2
EXIT_ANALYSIS  :: 3
EXIT_IO        :: 4

usage_errorf :: proc(msg: string, args: ..any) -> int {
	fmt.eprintf("usage error: ")
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\nrun 'gloaming' with no command for usage\n")
	return EXIT_USAGE
}

analysis_errorf :: proc(msg: string, args: ..any) -> int {
	fmt.eprintf("error: ")
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
	return EXIT_ANALYSIS
}

io_errorf :: proc(msg: string, args: ..any) -> int {
	fmt.eprintf("project/IO error: ")
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
	return EXIT_IO
}

// the write-path policy: base-state commands refuse under --variant,
// every one with the same trailing clause (tail carries the reason
// parenthetical, empty when the lead already says it)
base_state_errorf :: proc(lead, tail: string) -> int {
	return usage_errorf("%s — unset --variant%s", lead, tail)
}

// every command's unknown-flag rejection, one wording
unknown_flag_errorf :: proc(cmd, flag: string) -> int {
	return usage_errorf("%s: unknown flag %s", cmd, flag)
}

// the pattern layer's refusal vocabulary, one message per member
// (.None never reaches a caller; its slot keeps the fallback wording)
QUERY_ERR_TEXT: [gl.Query_Err]string = {
	.None           = "unknown",
	.Bad_Syntax     = "syntax",
	.Unknown_Field  = "unknown field",
	.No_Group       = "'~' needs a lemma group (none registered)",
	.No_Custom      = "'%' names no registered proc",
	.Bad_Quantifier = "quantifier caps",
	.Bad_Value      = "bad value form",
	.Bad_Argument   = "bad argument",
	.Too_Long       = "pattern past the parse cap",
	.Interrupted    = "interrupted",
	.Work_Capped    = "work budget exhausted",
	.Memo_Capped    = "memo cap for pattern × stream",
	.Set_Capped     = "set past the member cap (~ over an oversized group)",
}

query_err_text :: proc(e: gl.Query_Err) -> string {
	return QUERY_ERR_TEXT[e]
}

pattern_errorf :: proc(e: gl.Query_Err, pos: int) -> int {
	if pos >= 0 {
		fmt.eprintf("pattern error: %s at byte %d\n", query_err_text(e), pos)
	} else {
		fmt.eprintf("pattern error: %s\n", query_err_text(e))
	}
	return EXIT_PATTERN
}

emit_envelope :: proc(command: string, dict: u64, variant: string,
                      truncated: bool, rows: string, a: mem.Allocator,
                      extra: string = "") {
	fmt.print(glexport.envelope_json(command, dict, variant, truncated, rows, a, extra))
}

// the stats layer's refusal vocabulary (stats.odin's Freq_Err); the
// members no message names keep the fallback wording
FREQ_ERR_TEXT: [gl.Freq_Err]string = {
	.None        = "unknown",
	.Bad_Scope   = "unknown",
	.Bad_Window  = "unknown",
	.Bad_Count   = "invalid counts (an empty population, a duplicate key, or a cell outside its population)",
	.Bad_Budget  = "a tolerance or iteration budget out of range",
	.Interrupted = "interrupted",
}

freq_err_text :: proc(e: gl.Freq_Err) -> string {
	return FREQ_ERR_TEXT[e]
}

// ["…","…"] from row strings already rendered as JSON objects
join_rows :: proc(rows: []string, a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	strings.write_string(&b, "[")
	for r, i in rows {
		if i > 0 { strings.write_string(&b, ",") }
		strings.write_string(&b, r)
	}
	strings.write_string(&b, "]")
	return strings.to_string(b)
}

tsv_esc :: proc(s: string, b: ^strings.Builder) {
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '\\': strings.write_string(b, "\\\\")
		case '\t': strings.write_string(b, "\\t")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case:      strings.write_byte(b, s[i])
		}
	}
}

// one KWIC text row: doc:center-start, the left context, the center
// bracketed, the right context — no padding (determinism over
// prettiness), control bytes escaped so a row is always one line
kwic_text_row :: proc(r: gl.Kwic_Row, text: string, a: mem.Allocator) -> string {
	b := strings.builder_make(a)
	fmt.sbprintf(&b, "%d:%d  ", u32(r.match.span.doc), r.center.start)
	tsv_esc(span_text(text, r.left), &b)
	strings.write_string(&b, " 【")
	tsv_esc(span_text(text, r.center), &b)
	strings.write_string(&b, "】 ")
	tsv_esc(span_text(text, r.right), &b)
	return strings.to_string(b)
}

span_text :: proc(text: string, s: gl.Span) -> string {
	if s.start < 0 || s.end > len(text) || s.start > s.end { return "" }
	return text[s.start:s.end]
}

// lexicographic string order in the comparator shape the library's
// sort_with_buffer takes (^T)
str_less :: proc(x, y: ^string) -> bool {
	return strings.compare(x^, y^) < 0
}
