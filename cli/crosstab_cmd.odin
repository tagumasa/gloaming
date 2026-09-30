package main

/*
Cross-tabulation: the word × attr-value table — occurrence cells
(strength) beside doc-presence cells (breadth), grouped through
doc_groups over the external variables, with the per-key
independence statistic and adjusted residuals under --test. The
table applies no per-group count threshold by design, so
--min-count post-filters rows on total occurrences — dropping rows
without distorting the columns. The tsv rendering carries a '#'
header line: its columns are two per group (occurrences, docs) and
would be opaque without one.
*/

import "core:fmt"
import "core:strings"

import gl "gloaming:gloaming"
import glexport "gloaming:glexport"

cmd_crosstab :: proc(rest: []string, g: ^Globals) -> int {
	a := context.allocator
	attr := ""
	with_test := false
	top := 50
	format := "json"
	fs := Filter_Spec{pos_prefixes = make([dynamic]string, 0, 4, a)}
	for i := 0; i < len(rest); i += 1 {
		code := parse_filter_flags(rest, &i, &fs, a)
		if code == -1 {
			arg := rest[i]
			if arg == "--attr" {
				v, ok := flag_value(rest, &i, "--attr")
				if !ok { return EXIT_USAGE }
				attr = v
			} else if arg == "--test" {
				with_test = true
			} else if arg == "--top" {
				v, ok := flag_int(rest, &i, "--top", 1)
				if !ok { return EXIT_USAGE }
				top = v
			} else if arg == "--format" {
				v, ok := flag_value(rest, &i, "--format")
				if !ok { return EXIT_USAGE }
				if v != "json" && v != "tsv" { return usage_errorf("crosstab: --format json|tsv") }
				format = v
			} else {
				return unknown_flag_errorf("crosstab", arg)
			}
		} else if code != 0 {
			return code
		}
	}
	if attr == "" { return usage_errorf("crosstab: --attr <key> required") }

	rs, code := open_read(g, a)
	if code != 0 { return code }
	defer close_read(&rs, a)
	ids, icode := doc_ids(&rs.m, "", a)
	if icode != 0 { return icode }
	if len(ids) == 0 { return analysis_errorf("crosstab: the project holds no documents") }

	groups := gl.doc_groups(gl.graph_doc_attrs(&rs.ds.graph), attr, ids, a)
	table, terr := gl.cross_table(rs.st, groups, build_filter(&fs), a)
	if terr != .None { return analysis_errorf("cross_table: %v", terr) }

	tests: []gl.Cross_Test
	tstat := 0.0
	if with_test {
		tt, cerr := gl.cross_chi2(&table, a)
		if cerr != .None { return analysis_errorf("cross_chi2: %s", freq_err_text(cerr)) }
		tests = tt
		ts, terr2 := gl.table_chi2(&table)
		if terr2 != .None { return analysis_errorf("table_chi2: %s", freq_err_text(terr2)) }
		tstat = ts
	}

	if format == "tsv" {
		bh := strings.builder_make(a)
		strings.write_string(&bh, "#key")
		for v in table.vals {
			strings.write_string(&bh, "\t")
			tsv_esc(v, &bh)
			strings.write_string(&bh, ":n")
		}
		for v in table.vals {
			strings.write_string(&bh, "\t")
			tsv_esc(v, &bh)
			strings.write_string(&bh, ":d")
		}
		if with_test {
			strings.write_string(&bh, "\tchi2")
			for v in table.vals {
				strings.write_string(&bh, "\tres:")
				tsv_esc(v, &bh)
			}
		}
		fmt.println(strings.to_string(bh))
		emitted := 0
		ti := 0
		g := len(table.vals)
		for k, i in table.keys {
			cells := table.cells[i * g : i * g + g]
			docs := table.docs[i * g : i * g + g]
			total := 0
			for c in cells { total += c }
			if total < fs.min_count { continue }
			if emitted >= top { break }
			b := strings.builder_make(a)
			tsv_esc(k, &b)
			for c in cells { fmt.sbprintf(&b, "\t%d", c) }
			for d in docs { fmt.sbprintf(&b, "\t%d", d) }
			if with_test {
				// tests are the table's keys in order minus the
				// absent-everywhere rows cross_chi2 skips
				for ti < len(tests) && tests[ti].key != k { ti += 1 }
				if ti < len(tests) {
					strings.write_string(&b, "\t")
					glexport.fmt_f6(&b, tests[ti].chi2)
					for r in tests[ti].residuals {
						strings.write_string(&b, "\t")
						glexport.fmt_f6(&b, r)
					}
					ti += 1
				}
			}
			fmt.println(strings.to_string(b))
			emitted += 1
		}
		return EXIT_OK
	}
	// kept counts the rows past the occurrence floor before the top
	// cut — the same walk that emitted the rows, so the two cannot
	// drift
	rows_json, kept := glexport.cross_rows_json(&table, tests, with_test, top, fs.min_count, a)
	extra := glexport.cross_header_json(&table, attr, tstat, with_test, a)
	emit_envelope("crosstab", rs.eng.hash, g.variant, kept > top, rows_json, a, extra)
	return EXIT_OK
}
