#!/bin/sh
# Replay your own dictation history through the polishing chain, twice with the
# self-correction pass off and once with it on, and print only what differs.
#
#     ./replay_history.sh
#
# This is how to decide whether a change to the chain is an improvement. Made-up
# sentences show what a feature can do; this shows what it does to real speech,
# which is a different and less flattering question.
#
# The off case runs twice on purpose. A later request inside one process varies
# at about one run in six, so without a control there is no way to tell a
# difference the change caused from one it did not. Anything where the two off
# runs already disagree is reported as noise rather than attributed.
#
# Only dictations that trip `SpeechRepair` are replayed, since nothing else can
# differ: no gate, no request, no change.
SPEAK=${SPEAK:-/Applications/Speak.app/Contents/MacOS/Speak}
HISTORY="$HOME/Library/Application Support/Speak/history.jsonl"
[ -x "$SPEAK" ] || { echo "not installed, run ./install.sh first" >&2; exit 1; }
[ -f "$HISTORY" ] || { echo "no history at $HISTORY" >&2; exit 1; }

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT

# The gate, in Python, kept deliberately in step with SpeechRepair.swift. It
# only decides which dictations are worth replaying, so a small disagreement
# costs a wasted replay rather than a wrong answer.
python3 - "$HISTORY" "$LIST" <<'PY'
import json, re, sys

DET = {"the","a","an","my","our","your","his","her","their","its",
       "this","that","these","those"}
JOIN = {"and","or","but","then","plus","with","for","to","of","in",
        "on","at","from","by"}

def words(t): return re.findall(r"[a-z']+", t.lower())

def fires(t):
    w = words(t)
    for i in range(len(w) - 1):
        if w[i] == w[i + 1]: return True
    for i in range(len(w) - 3):
        if w[i] == w[i + 2] and w[i + 1] == w[i + 3]: return True
    for i, x in enumerate(w):
        if x not in DET: continue
        for j in range(i + 2, min(i + 4, len(w))):
            if w[j] != x: continue
            if any(k in JOIN for k in w[i + 1:j]): break
            return True
    j = " " + " ".join(w) + " "
    return " sorry " in j or " i mean " in j or " rather " in j

rows = [json.loads(l) for l in open(sys.argv[1])]
seen, out = set(), []
for r in rows:
    # `raw` is stored only when something changed the text, so it is the
    # engine's output when present and `text` is when it is not.
    t = (r.get("raw") or r.get("text") or "").strip().replace("\n", " ")
    if t and t not in seen and any(fires(s) for s in re.split(r"(?<=[.!?])\s+", t)):
        seen.add(t); out.append(t)
open(sys.argv[2], "w").write("\n".join(out))
print(f"{len(out)} of {len(rows)} dictations trip the gate and will be replayed")
PY

n=0; noisy=0; changed=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
    a1=$(printf '%s' "$line" | SPEAK_REPAIR=0 $SPEAK --polish - 2>/dev/null)
    a2=$(printf '%s' "$line" | SPEAK_REPAIR=0 $SPEAK --polish - 2>/dev/null)
    b=$(printf '%s' "$line" | SPEAK_REPAIR=1 $SPEAK --polish - 2>/dev/null)
    if [ "$a1" != "$a2" ]; then
        noisy=$((noisy + 1))
        printf '\n--- %d NOISY, the two off runs already disagree\n' "$n"
        printf '  off1: %s\n  off2: %s\n  on  : %s\n' "$a1" "$a2" "$b"
    elif [ "$a1" != "$b" ]; then
        changed=$((changed + 1))
        printf '\n--- %d CHANGED\n' "$n"
        printf '  said: %s\n  off : %s\n  on  : %s\n' "$line" "$a1" "$b"
    fi
done < "$LIST"

printf '\n%d replayed: %d changed, %d too noisy to attribute, %d identical\n' \
    "$n" "$changed" "$noisy" "$((n - changed - noisy))"
