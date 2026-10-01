# Custom dictionary

Terms and corrections (`CustomDictionary.swift`). Corrections also run both sides of polishing; see `docs/polisher.md`.

## A term is a phonetic rule, not just a prompt hint

Terms began as text pasted into the prompt, and measured over six runs each that repaired a mishearing 5 times out of 24 against a baseline of 0. Useful, but not something to rely on for a name. They still do that job (they stop the model rewriting words it does not know: `flyinpublic.com` survived 0/6 without a hint and 5/6 with one), but the repair now happens in `applyTerms`, deterministically and with no model, so it works with polishing off and on macOS 14.

Matching is a Soundex-style consonant code that is **not truncated**. Real Soundex stops at three digits, which collapses "flyinpublic" and "flamboyant" into the same F451. Full length separates them while still ignoring vowels, which is exactly where mishearings differ: "Goossens", "Gossens", "Goosens", "Gaussens" and "Gusens" all code to g252.

Two guards make it safe to run unattended, and removing either makes it dangerous:

1. **At least five letters** for a single word, eight across a phrase. Short codes collide constantly; a term of "R2" would rewrite half of what anyone dictates.
2. **Never replace a real word**, for single-word terms only. `/usr/share/dict/words` with cheap suffix stripping, because that list is from 1934 and has no plurals, so "codes" and "dogs" are absent from it and would otherwise be fair game. Without this a term of "Codex" rewrites "codes".

A phrase is deliberately exempt from the second rule. "Cloud coat" is two perfectly good English words and still obviously a misheard "Claude Code"; requiring otherwise makes multi-word terms useless, which is how they shipped first. Every word matching in sequence is the stronger signal that replaces it.

Sounds-like runs only on the raw transcript, before polishing. Mishearings come from the microphone, not from the model.

## Corrections apply longest pattern first, not in list order

Overlapping corrections are normal in a real dictionary, and list order breaks them. From an imported one: "maxim" to "Maxime" and "maxim Gusens" to "Maxime Goossens". Alphabetical order runs the short rule first, and the long one then finds "Maxime Gusens", which it does not match, so the surname becomes unfixable by any rule the user could add.

Sorting by pattern length makes the pair compose and needs no reordering UI. `sorted(by:)` is not stable, so the comparator falls back to the list index, otherwise equal-length rules would shuffle between runs.
