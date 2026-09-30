package main

/*
The gloaming CLI host: a one-shot
process — resolve project, load dictionary, run one command, emit,
exit. No daemon, by design: qdct restore is milliseconds, and
re-analysis only happens under init/add/variant. Global flags
precede the command; stdout carries only the result, stderr only
diagnostics.
*/

import "core:fmt"
import "core:os"
import "core:strings"

Globals :: struct {
	project: string,
	quiet:   bool,
	variant: string,
}

/*
The command surface as data: dispatch and the usage listing walk the
same rows, so a command cannot appear in one and not the other. Rows
whose usage line a sibling already carries (status | docs, add | remove)
leave usage empty.
*/
Command :: struct {
	name:  string,
	run:   proc(rest: []string, g: ^Globals) -> int,
	usage: string,
}

USAGE_HEADER :: "usage: gloaming [--project <dir>] [--quiet] [--variant <name>] <command> [args]\n\ncommands:\n"

USAGE_NOTES :: `
--doc accepts a document id or a unique path suffix; evidence spans
(<doc>:<start>-<end>) are decimal byte ranges; keyness --reference
defaults to rest (the corpus minus the target).
measures: differential lift jaccard ochiai chi2 chi2-yates fisher
dunning (default). cluster methods: ward (default) average complete;
cluster distances: jaccard (default) euclid cosine dice simpson;
coords --format dot is a neato scatter (pinned positions). Entries
files:
surface<TAB>pos<TAB>lemma<TAB>reading[<TAB>cost]; ids default 0/0,
cost -3000. exit codes: 0 ok, 1 usage, 2 pattern, 3 analysis refusal,
4 project/IO.
`

COMMANDS: [23]Command = {
	{"init", cmd_init, `  init <corpus…> --lang <ja|zh-CN|zh-TW|zh-HK|en-GB|en-US|de> [--dict <csv>]
                [--variant-of <project>:<variant>]`},
	{"status", cmd_status, `  status | docs`},
	{"docs", cmd_docs, ""},
	{"add", cmd_add, `  add <file…> | remove <doc>`},
	{"remove", cmd_remove, ""},
	{"query", cmd_query, `  query '<dsl>' [--doc D] [--count] [--limit N] [--offset M]`},
	{"unknown", cmd_unknown, `  unknown [--min-count N] [--min-len L] [--sample K] [--limit N] [--format tsv]`},
	{"kwic", cmd_kwic, `  kwic '<dsl>' [--left N] [--right N] [--center <name>] [--sort surface|position]
        [--limit N] [--offset M] [--format json]`},
	{"freq", cmd_freq, `  freq [--pos-prefix P]… [--lemma] [--min-count N] [--min-len L]
       [--stopwords <file>] [--doc D] [--limit N] [--format tsv]`},
	{"cooc", cmd_cooc, `  cooc [--pos-prefix P]… [--lemma] [--cap N] [--doc D] [--format tsv]`},
	{"variant", cmd_variant, `  variant add <name> <entries.tsv> [--cost C]
        | variant list | variant remove <name>
        | variant diff <a> <b> [--top N] [--lemma] [--pos-prefix P]…`},
	{"attr", cmd_attr, `  attr set <doc> <key> <value> | attr get <doc> | attr list`},
	{"entity", cmd_entity, `  entity add <kind> <name> [alias…] | entity alias <entity> <alias>…
        | entity merge <into> <from> | entity list`},
	{"relation", cmd_relation, `  relation add <kind> <from> <to> [--evidence <doc>:<s>-<e>]… [--derived]
        | relation list`},
	{"mention", cmd_mention, `  mention add <entity> <doc>:<start>-<end> | mention list`},
	{"codes", cmd_codes, `  codes <kind> <from> <to> <patA> <patB> [--window N] [--cap M] [--dry-run]`},
	{"toposort", cmd_toposort, `  toposort [--kind K]… [--format tsv|json]`},
	{"keyness", cmd_keyness, `  keyness --target <all|doc:D,…|key=val> [--reference <sel>]
          [--measure M] [--basis docs|tokens] [filter flags…] [--top N] [--format tsv]`},
	{"crosstab", cmd_crosstab, `  crosstab --attr <key> [--test] [filter flags…] [--top N] [--format tsv]`},
	{"graph", cmd_graph, `  graph [filter flags…] [--window N] [--cap N] [--top N] [--clusters N]
        [--method ward|average|complete] [--distance jaccard|euclid|cosine|dice|simpson]
        [--doc D] [--format dot|mermaid|json]`},
	{"cluster", cmd_cluster, `  cluster [filter flags…] [--doc D] [--window N] [--cap N] [--top N]
          [--method ward|average|complete]
          [--distance jaccard|euclid|cosine|dice|simpson]
          [--k N] [--format tsv|json|dot|mermaid]`},
	{"coords", cmd_coords, `  coords [filter flags…] [--doc D] [--window N] [--cap N] [--top N]
         [--tol F] [--max-iter N] [--format tsv|json|dot]`},
	{"help", cmd_help, ""},
}

usage_text :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, USAGE_HEADER)
	for &c in COMMANDS {
		if c.usage != "" {
			strings.write_string(&b, c.usage)
			strings.write_string(&b, "\n")
		}
	}
	strings.write_string(&b, USAGE_NOTES)
	return strings.to_string(b)
}

cmd_help :: proc(rest: []string, g: ^Globals) -> int {
	fmt.print(usage_text())
	return EXIT_OK
}

/*
The global flag surface as data: the parser and the unknown-flag
refusal walk the same rows, so a flag cannot be accepted in one and
rejected in the other.
*/
Global_Flag :: struct {
	name:  string,
	takes: bool, // consumes the next argument as its value
	help:  bool, // prints usage and exits OK
	alt:   string, // the short spelling, "" when none
}

GLOBAL_FLAGS: [4]Global_Flag = {
	{"--project", true,  false, ""},
	{"--quiet",   false, false, ""},
	{"--variant", true,  false, ""},
	{"--help",    false, true,  "-h"},
}

main :: proc() {
	args := os.args[1:]
	g := Globals{}
	i := 0
	for ; i < len(args); i += 1 {
		arg := args[i]
		fi := -1
		for f, x in GLOBAL_FLAGS {
			if arg == f.name || (f.alt != "" && arg == f.alt) {
				fi = x
				break
			}
		}
		if fi < 0 {
			if strings.starts_with(arg, "--") {
				os.exit(usage_errorf("unknown global flag %s", arg))
			}
			break // the command word
		}
		f := GLOBAL_FLAGS[fi]
		if f.help {
			fmt.print(usage_text())
			os.exit(EXIT_OK)
		}
		if !f.takes {
			g.quiet = true
			continue
		}
		v, ok := flag_value(args, &i, f.name)
		if !ok { os.exit(EXIT_USAGE) }
		switch f.name {
		case "--project": g.project = v
		case "--variant": g.variant = v
		}
	}
	if i >= len(args) {
		fmt.eprint(usage_text())
		os.exit(EXIT_USAGE)
	}

	cmd := args[i]
	rest := args[i + 1:]
	code := EXIT_USAGE
	found := false
	for &c in COMMANDS {
		if c.name == cmd {
			code = c.run(rest, &g)
			found = true
			break
		}
	}
	if !found { code = usage_errorf("unknown command %s", cmd) }
	os.exit(code)
}
