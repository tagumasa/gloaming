package main

/*
The flag vocabularies as data: the name a flag accepts, the value it
parses to, and the legal-value menu a refusal prints are the same
rows, so a menu can never drift from its parser.
*/

import "core:strings"

import gl "gloaming:gloaming"
import moli "moli:moli"

// one row shape for every vocabulary
Vocab :: struct($T: typeid) {
	name:  string,
	value: T,
}

Lang_Spec :: struct {
	lang: moli.Language,
	kind: Lang_Kind,
}

KEY_MEASURES: [8]Vocab(gl.Key_Measure) = {
	{"differential", .Differential},
	{"lift",         .Lift},
	{"jaccard",      .Jaccard},
	{"ochiai",       .Ochiai},
	{"chi2",         .Chi_Square},
	{"chi2-yates",   .Chi_Square_Yates},
	{"fisher",       .Fisher_Exact},
	{"dunning",      .Log_Likelihood},
}

LINKAGES: [3]Vocab(gl.Linkage) = {
	{"ward",     .Ward},
	{"average",  .Average},
	{"complete", .Complete},
}

DISTANCES: [5]Vocab(Dist_Kind) = {
	{"jaccard", .Jaccard},
	{"euclid",  .Euclid},
	{"cosine",  .Cosine},
	{"dice",    .Dice},
	{"simpson", .Simpson},
}

LANGS: [7]Vocab(Lang_Spec) = {
	{"ja",    {lang = .Japanese,  kind = .Moli}},
	{"zh-CN", {lang = .ChineseCN, kind = .Moli}},
	{"zh-TW", {lang = .ChineseTW, kind = .Moli}},
	{"zh-HK", {lang = .ChineseHK, kind = .Moli}},
	{"en-GB", {lang = .EnglishGB, kind = .Fixture}},
	{"en-US", {lang = .EnglishUS, kind = .Fixture}},
	{"de",    {lang = .German,    kind = .Moli}},
}

KWIC_SORTS: [2]Vocab(gl.Kwic_Sort_Key) = {
	{"position", .Position},
	{"surface",  .Surface},
}

// the string-valued flags' legal sets — the parser check and the
// refusal menu walk the same rows (the Vocab rule, string form)
FORMAT_GRAPH:   []string = {"dot", "mermaid", "json"}
FORMAT_CLUSTER: []string = {"tsv", "json", "dot", "mermaid"}
FORMAT_KWIC:    []string = {"json", "text"}
FORMAT_UNKNOWN: []string = {"json", "tsv"}

// "a|b|c" — the menu form every flag refusal prints. The message is
// printed before the process exits, so the builder rides the temp
// allocator.
vocab_menu :: proc($T: typeid, rows: []Vocab(T)) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r, i in rows {
		if i > 0 { strings.write_string(&b, "|") }
		strings.write_string(&b, r.name)
	}
	return strings.to_string(b)
}

// the same menu over a plain string list — the string-valued flags'
// legal sets
choice_menu :: proc(legal: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for x, i in legal {
		if i > 0 { strings.write_string(&b, "|") }
		strings.write_string(&b, x)
	}
	return strings.to_string(b)
}

// one string-valued flag's legality check: membership against the same
// rows the refusal menu prints
choice_ok :: proc(cmd, flag: string, v: string, legal: []string) -> int {
	for x in legal {
		if x == v { return 0 }
	}
	return usage_errorf("%s: %s %s", cmd, flag, choice_menu(legal))
}

parse_measure :: proc(s: string) -> (gl.Key_Measure, bool) {
	for e in KEY_MEASURES {
		if e.name == s { return e.value, true }
	}
	return .Differential, false
}

dist_kind_from_string :: proc(v: string, cmd: string) -> (Dist_Kind, int) {
	for e in DISTANCES {
		if e.name == v { return e.value, 0 }
	}
	return .Jaccard, usage_errorf("%s: --distance %s", cmd, vocab_menu(Dist_Kind, DISTANCES[:]))
}

linkage_from_string :: proc(v: string, cmd: string) -> (gl.Linkage, int) {
	for e in LINKAGES {
		if e.name == v { return e.value, 0 }
	}
	return .Ward, usage_errorf("%s: --method %s", cmd, vocab_menu(gl.Linkage, LINKAGES[:]))
}

kwic_sort_from_string :: proc(v: string, cmd: string) -> (gl.Kwic_Sort_Key, int) {
	for e in KWIC_SORTS {
		if e.name == v { return e.value, 0 }
	}
	return .Position, usage_errorf("%s: --sort %s", cmd, vocab_menu(gl.Kwic_Sort_Key, KWIC_SORTS[:]))
}

lang_of :: proc(s: string) -> (moli.Language, Lang_Kind, bool) {
	for e in LANGS {
		if e.name == s { return e.value.lang, e.value.kind, true }
	}
	return .Japanese, .Fixture, false
}
