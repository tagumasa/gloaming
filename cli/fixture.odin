package main

/*
The fixture tokenizer for analyzer-less languages: a word is a
maximal run of ASCII letters, digits, and
hyphen, or of non-ASCII bytes (UTF-8 letters live there); any other
ASCII byte is its own punctuation token; whitespace separates. The
word grammar is the one the bench's EN arm measures, so token counts
stay comparable with docs/benchmarks.md's EN-arm rows. Every token is
id-less — kind .Idless, lemma =
surface, no POS, reading "*" — the schema a non-morphological
pipeline rides, with the payload bit-17 path that never routes
through a resolver.
*/

import gl "gloaming:gloaming"

fixture_tokenize :: proc(text: string, out: ^[dynamic]gl.Token) {
	word_byte :: proc(c: u8) -> bool {
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '-' || c >= 0x80
	}
	i, n := 0, len(text)
	for i < n {
		c := text[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' { i += 1; continue }
		j := i + 1
		if word_byte(c) {
			for j < n && word_byte(text[j]) { j += 1 }
		}
		append(out, gl.Token{
			surface = text[i:j],
			lemma = text[i:j],
			pos = "",
			reading = "*",
			start = i,
			end = j,
			kind = .Idless,
			entry_id = -1,
		})
		i = j
	}
}

// rejecting every id makes any resolver attempt a visible Not_Found
// instead of silent garbage — the decode path's proof it never happened
fixture_resolve :: proc(_: rawptr, _: i32, _: string) ->
	(pos, lemma, reading: string, ok: bool) {
	return "", "", "", false
}
