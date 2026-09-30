package gloaming

import "core:mem"
import "core:strings"

/*
Lemma groups: named equivalence classes of lemmas — the data behind
synonym expansion (`~"見る"` compiles to a Set predicate) and behind
deterministic notation-variation work. Loaded from a user TSV (one
group per line, tab-separated; the first column is both the group
name and a member). This table is library territory on purpose:
curators — human or automated — reliably overlook notation variation
and near-synonyms, and host judgment is not reproducible — what runs
on every query and corpus pass must not depend on it.

Ownership (the query_parse contract): every group name, member,
and index key is cloned into the parse allocator, so the caller may
free the TSV text once lemma_groups_parse returns.
*/

Lemma_Group_Id :: distinct u32

Lemma_Group :: struct {
	id:     Lemma_Group_Id,
	name:   string,
	lemmas: []string,
}

Lemma_Groups :: struct {
	groups:       []Lemma_Group,
	member_index: map[string]Lemma_Group_Id, // built by lemma_groups_parse
}

Thesaurus_Err :: enum {
	None,
	Bad_Syntax,
	Duplicate_Lemma,
}

/*
One lemma group per line, tab-separated; the first column is both the
group name and a member. Blank and `#`-prefixed lines are skipped and
CRLF tolerated; a single-column line is a legal group of one; ids are
sequential from 0 in file order. A lemma occurring in two groups (or
twice on one line) is Duplicate_Lemma — curated groups stay disjoint,
which is what keeps `group_of` single-valued. An empty member (a
stray tab) is Bad_Syntax. Hosts read the file and hand over the
text — the core stays file-free.

A refusal allocates nothing net: every clone made so far — the line in
progress and every completed group — is freed before the return, so a
non-arena caller strands nothing.
*/
lemma_groups_parse :: proc(src: string, a: mem.Allocator) -> (Lemma_Groups, Thesaurus_Err) {
	groups: [dynamic]Lemma_Group = make([dynamic]Lemma_Group, 0, 16, a)
	index := make(map[string]Lemma_Group_Id, a)

	// the error-path reclaim, shared by both refusals
	clean :: proc(groups: ^[dynamic]Lemma_Group, members: ^[dynamic]string,
	              index: ^map[string]Lemma_Group_Id, a: mem.Allocator) {
		for m in members^ {
			if len(m) > 0 { mem.free(raw_data(m), a) }
		}
		for g in groups^ {
			for l in g.lemmas {
				if len(l) > 0 { mem.free(raw_data(l), a) }
			}
			if len(g.lemmas) > 0 { mem.free(raw_data(g.lemmas), a) }
		}
		delete(members^)
		delete(groups^)
		delete(index^)
	}

	s := src
	id := u32(0)
	for line in strings.split_lines_iterator(&s) {
		ln := strings.trim_space(line)
		if ln == "" || strings.has_prefix(ln, "#") { continue }

		members: [dynamic]string = make([dynamic]string, 0, 8, a)
		ms := 0
		for i := 0; i < len(ln) + 1; i += 1 {
			if i < len(ln) && ln[i] != '\t' { continue }
			field := ln[ms:i]
			ms = i + 1
			if len(field) == 0 {
				clean(&groups, &members, &index, a)
				return {}, .Bad_Syntax
			}
			// the duplicate probe reads the view — a refusal clones nothing
			if _, dup := index[field]; dup {
				clean(&groups, &members, &index, a)
				return {}, .Duplicate_Lemma
			}
			clone := clone_str(field, a)
			index[clone] = Lemma_Group_Id(id)
			append(&members, clone)
		}
		append(&groups, Lemma_Group{
			id     = Lemma_Group_Id(id),
			name   = members[0],
			lemmas = members[:],
		})
		id += 1
	}

	return Lemma_Groups{groups = groups[:], member_index = index}, .None
}

/*
The group holding `lemma`, by member-index lookup. A table not built
by lemma_groups_parse carries no index and holds nothing — build
tables through the loader. group_of_scan is the linear-scan twin kept
as the loader's differential check.
*/
group_of :: proc(groups: ^Lemma_Groups, lemma: string) -> (Lemma_Group_Id, bool) {
	if groups.member_index == nil { return 0, false }
	gid, ok := groups.member_index[lemma]
	return gid, ok
}

group_of_scan :: proc(groups: ^Lemma_Groups, lemma: string) -> (Lemma_Group_Id, bool) {
	for g in groups.groups {
		for l in g.lemmas {
			if l == lemma { return g.id, true }
		}
	}
	return 0, false
}
