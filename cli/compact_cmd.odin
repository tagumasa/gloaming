package main

/*
compact: rewrite the base store to its current state — live
documents, live curation rows, dead ids preserved as tombstones,
current attrs — reclaiming the registry's write history and orphan
payload bytes. Registry-only open (no dictionary load, no decode),
like the graph-row commands; base-only, no --variant (variant
stores are replayed copies).
*/

import "core:fmt"

import gl "gloaming:gloaming"

cmd_compact :: proc(rest: []string, g: ^Globals) -> int {
	if len(rest) != 0 { return usage_errorf("compact takes no arguments") }
	if g.variant != "" { return base_state_errorf("compact", "") }

	dir, code := discover_project(g, context.temp_allocator)
	if code != 0 { return code }
	m, mcode := manifest_load(dir, context.temp_allocator)
	if mcode != 0 { return mcode }
	ds, ocode := open_registry_store(dir, &m, context.allocator)
	if ocode != 0 { return ocode }

	before_reg, before_pay := ds.log_end, ds.pay_end
	if cerr := gl.disk_store_compact(ds); cerr != gl.Store_Err.None {
		_ = gl.disk_store_close(ds)
		if cerr == .Interrupted {
			return analysis_errorf("compact interrupted — the store is unchanged")
		}
		return io_errorf("compact: %v — close and reopen the store", cerr)
	}
	after_reg, after_pay := ds.log_end, ds.pay_end

	if qerr := gl.disk_store_close(ds); qerr != gl.Store_Err.None {
		return io_errorf("store close: %v", qerr)
	}
	if !g.quiet {
		fmt.printfln("compacted: registry %d -> %d B, payloads %d -> %d B",
			before_reg, after_reg, before_pay, after_pay)
	}
	return EXIT_OK
}
