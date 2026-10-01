#!/usr/bin/env bash
# Tests for the /stridify Step 8.5 preview-and-approval gate
# and the Step 1 --yes / --auto-approve bypass documented in
# commands/stridify.md (W1161; ports upstream G235/W1140). OpenCode's question UI is
# only available inside a live OpenCode session, so this test embeds a
# reference shell implementation of the documented flag parse + preview render
# + gate and exercises it against a fixture batch JSON. The human approve /
# decline answer is injected as a parameter (standing in for the prompt result).
#
# The reference implementations below MUST stay consistent with Step 1 and
# Step 8.5 in commands/stridify.md. If you edit one, edit
# both — this test exists to prevent the doc and the on-the-wire behavior from
# drifting apart. A PowerShell mirror lives at lib/test-stridify-preview.ps1.
#
# Run:
#   ./lib/test-stridify-preview.sh
#
# Exits 0 if all tests pass, non-zero otherwise.

set -u

PASS=0
FAIL=0
TMP=""

cleanup() {
  if [ -n "$TMP" ] && [ -d "$TMP" ]; then
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

TMP="$(mktemp -d)"

pass() { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
fail() {
  FAIL=$(( FAIL + 1 ))
  printf 'FAIL  %s\n' "$1"
  if [ "${2:-}" != "" ]; then
    printf '      %s\n' "$2"
  fi
}

# --- reference --yes / --auto-approve parser -------------------------------
#
# Mirrors commands/stridify.md Step 1. --yes and --auto-approve are bare boolean tokens
# (no value form). Prints two lines: line 1 = AUTO_APPROVE (true|false),
# line 2 = the trimmed remaining arguments.

parse_yes_flag() {
  local args="$1"
  local yes=false
  local out=""
  # shellcheck disable=SC2206
  local toks=( $args )
  local t
  for t in "${toks[@]}"; do
    case "$t" in
      --yes|--auto-approve) yes=true ;;
      *) out="${out:+$out }$t" ;;
    esac
  done
  printf '%s\n%s\n' "$yes" "$out"
}

# --- reference --batch parser ------------------------------------------------
#
# Mirrors commands/stridify.md Step 1's --batch rules. Prints one line:
#   batch=<path>|yes=<true|false>|err=<usage|goal|doc|>|rest=<remainder>
# err=usage: --batch with no value (bare, `--batch=`, or followed by a flag),
#            or neither --batch nor a doc path; err=goal: --batch with --goal;
# err=doc: --batch with a requirements-doc path left over.

parse_batch_args() {
  # shellcheck disable=SC2206
  local toks=( $1 )
  local batch="" have_batch=false goal="" yes=false rest="" err="" i=0 t
  while [ "$i" -lt "${#toks[@]}" ]; do
    t="${toks[$i]}"
    case "$t" in
      --batch)
        have_batch=true
        if [ $(( i + 1 )) -lt "${#toks[@]}" ] && [ "${toks[$(( i + 1 ))]#--}" = "${toks[$(( i + 1 ))]}" ]; then
          batch="${toks[$(( i + 1 ))]}"; i=$(( i + 1 ))
        else
          err=usage
        fi ;;
      --batch=*) have_batch=true; batch="${t#--batch=}"; [ -n "$batch" ] || err=usage ;;
      --goal) goal="${toks[$(( i + 1 ))]:-}"; i=$(( i + 1 )) ;;
      --goal=*) goal="${t#--goal=}" ;;
      --yes|--auto-approve) yes=true ;;
      *) rest="${rest:+$rest }$t" ;;
    esac
    i=$(( i + 1 ))
  done
  if [ -z "$err" ]; then
    if [ "$have_batch" = true ] && [ -n "$goal" ]; then err=goal
    elif [ "$have_batch" = true ] && [ -n "$rest" ]; then err=doc
    elif [ "$have_batch" = false ] && [ -z "$rest" ]; then err=usage
    fi
  fi
  printf 'batch=%s|yes=%s|err=%s|rest=%s\n' "$batch" "$yes" "$err" "$rest"
}

# --- reference preview render ----------------------------------------------
#
# Mirrors commands/stridify.md Step 8.5a. Reads ONLY the on-disk batch JSON (no auth
# material) and prints the goal/task tree + cross-goal claim order.

render_preview() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fp:
    data = json.load(fp)

goals = data.get("goals", [])
notes = data.get("decomposition_notes", "")

print()
print("Goals and tasks to be created:")
print()
for goal in goals:
    title = goal.get("title", "(no title)")
    tasks = goal.get("tasks", []) or []
    n = len(tasks)
    print(f"  Goal: {title}  ({n} task{'s' if n != 1 else ''})")
    for task in tasks:
        print(f"    - {task.get('title', '(no title)')}")
print()
if notes:
    print("Cross-goal claim order:")
    print(f"  {notes}")
    print()
PY
}

# --- POST stub + sentinel: confirm whether POST is reached ------------------
#
# The real Step 9 POST is never called in this test. post_stub stands in for
# "control reached the POST"; it writes a sentinel file the assertions check.

post_stub() { echo "POST_ATTEMPTED" > "$TMP/post_was_attempted"; }
post_was_attempted() { [ -f "$TMP/post_was_attempted" ]; }
reset_post_sentinel() { rm -f "$TMP/post_was_attempted"; }

# --- reference preview + gate ----------------------------------------------
#
# Mirrors commands/stridify.md Step 8.5 a/b/c. Args:
#   <batch-path> <auto-approve:true|false> <answer:approve|decline>
# Always renders the preview. On bypass (auto=true) or an explicit approve, it
# calls post_stub (proceed to Step 9). On decline it prints the clean-stop
# message and returns 10 WITHOUT touching the on-disk JSON or calling POST.

render_and_gate() {
  local batch="$1" auto="$2" answer="$3"
  render_preview "$batch"
  if [ "$auto" = "true" ]; then
    post_stub        # 8.5b bypass: straight to Step 9
    return 0
  fi
  case "$answer" in
    approve)
      post_stub      # 8.5c approval: proceed to Step 9
      return 0
      ;;
    *)
      # 8.5c decline: clean stop, no POST, JSON untouched. Real impl exit 0.
      echo "stride-ideation: declined. The batch JSON is on disk at $batch; no POST was attempted."
      echo "Ship it later, unchanged, with: /stridify --batch \"$batch\""
      return 10
      ;;
  esac
}

# === fixture: a multi-goal batch JSON with cross-goal claim order ==========

BATCH="$TMP/2026-05-12T120000-fixture-stride-batch.json"
cat > "$BATCH" <<'EOF'
{
  "source_spec": "2026-05-12T120000-fixture-requirements.md",
  "source_spec_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "decomposition_notes": "Claim Goal A (data layer) first; Goal B (UI) depends on A's API surface.",
  "goals": [
    {
      "title": "Goal A — data layer",
      "type": "goal",
      "tasks": [
        { "title": "Create the schema migration" },
        { "title": "Add the context module" }
      ]
    },
    {
      "title": "Goal B — UI layer",
      "type": "goal",
      "tasks": [
        { "title": "Wire the LiveView" }
      ]
    }
  ]
}
EOF

BATCH_SHA_BEFORE="$(shasum -a 256 "$BATCH" | awk '{print $1}')"

# === case 1: --yes / --auto-approve parse (both forms + absence) ===========

y_yes="$(parse_yes_flag "--yes /path/to/doc.md")"
y_auto="$(parse_yes_flag "--auto-approve /path/to/doc.md")"
y_none="$(parse_yes_flag "/path/to/doc.md")"

if [ "$(printf '%s' "$y_yes" | sed -n 1p)" = "true" ] \
   && [ "$(printf '%s' "$y_auto" | sed -n 1p)" = "true" ] \
   && [ "$(printf '%s' "$y_none" | sed -n 1p)" = "false" ]; then
  pass "case 1: --yes and --auto-approve set bypass=true; absence leaves bypass=false (AC3)"
else
  fail "case 1: bypass flag parse wrong" \
    "yes=$(printf '%s' "$y_yes" | sed -n 1p) auto=$(printf '%s' "$y_auto" | sed -n 1p) none=$(printf '%s' "$y_none" | sed -n 1p)"
fi

if [ "$(printf '%s' "$y_yes" | sed -n 2p)" = "/path/to/doc.md" ] \
   && [ "$(printf '%s' "$y_none" | sed -n 2p)" = "/path/to/doc.md" ]; then
  pass "case 1: the flag token is consumed and REQUIREMENTS_PATH remainder is preserved"
else
  fail "case 1: remainder wrong after flag consumption" \
    "yes_rem=$(printf '%s' "$y_yes" | sed -n 2p) none_rem=$(printf '%s' "$y_none" | sed -n 2p)"
fi

# === case 2: bypass path reaches POST without an approval prompt (AC3) ======

reset_post_sentinel
render_and_gate "$BATCH" true "" >"$TMP/run_bypass.log" 2>&1
rc_bypass=$?
if [ "$rc_bypass" -eq 0 ] && post_was_attempted; then
  pass "case 2: --yes bypass proceeds to POST (sentinel set, rc 0)"
else
  fail "case 2: bypass did not reach POST" "rc=$rc_bypass"
fi
if ! grep -qiF "declined" "$TMP/run_bypass.log"; then
  pass "case 2: bypass path prints no decline / prompt text"
else
  fail "case 2: bypass path unexpectedly printed decline text"
fi

# === case 3: decline path does NOT POST and leaves JSON on disk (AC1/AC4) ===

reset_post_sentinel
render_and_gate "$BATCH" false decline >"$TMP/run_decline.log" 2>&1
rc_decline=$?
if [ "$rc_decline" -eq 10 ] && ! post_was_attempted; then
  pass "case 3: decline does NOT attempt the POST (no sentinel)"
else
  fail "case 3: decline attempted the POST (regression)" "rc=$rc_decline"
fi
if [ -f "$BATCH" ]; then
  pass "case 3: declined batch JSON remains on disk"
else
  fail "case 3: declined batch JSON was removed (regression)"
fi
BATCH_SHA_AFTER="$(shasum -a 256 "$BATCH" | awk '{print $1}')"
if [ "$BATCH_SHA_BEFORE" = "$BATCH_SHA_AFTER" ]; then
  pass "case 3: declined batch JSON is byte-for-byte unchanged (recovery artifact preserved)"
else
  fail "case 3: declined batch JSON was rewritten (pitfall violated)"
fi
if grep -qiF "no POST was attempted" "$TMP/run_decline.log"; then
  pass "case 3: decline message states the POST was not attempted"
else
  fail "case 3: decline message missing 'No POST was attempted'"
fi

# === case 4: approve path proceeds to POST (AC2) ===========================

reset_post_sentinel
render_and_gate "$BATCH" false approve >"$TMP/run_approve.log" 2>&1
rc_approve=$?
if [ "$rc_approve" -eq 0 ] && post_was_attempted; then
  pass "case 4: explicit approval proceeds to POST (sentinel set, rc 0)"
else
  fail "case 4: approval did not reach POST" "rc=$rc_approve"
fi

# === case 5: render lists every goal and its task count (AC1) ==============

render_preview "$BATCH" > "$TMP/preview.txt" 2>&1
if grep -qF "Goal: Goal A — data layer  (2 tasks)" "$TMP/preview.txt" \
   && grep -qF "Goal: Goal B — UI layer  (1 task)" "$TMP/preview.txt"; then
  pass "case 5: preview lists each goal with its task count (singular/plural correct)"
else
  fail "case 5: goal/task-count render wrong" "$(cat "$TMP/preview.txt")"
fi
if grep -qF -- "- Create the schema migration" "$TMP/preview.txt" \
   && grep -qF -- "- Add the context module" "$TMP/preview.txt" \
   && grep -qF -- "- Wire the LiveView" "$TMP/preview.txt"; then
  pass "case 5: preview lists every task title"
else
  fail "case 5: task titles missing from render" "$(cat "$TMP/preview.txt")"
fi

# === case 6: render shows cross-goal claim order from decomposition_notes (AC1, edge case) ===

if grep -qF "Cross-goal claim order:" "$TMP/preview.txt" \
   && grep -qF "Claim Goal A (data layer) first" "$TMP/preview.txt"; then
  pass "case 6: preview shows cross-goal claim order from decomposition_notes"
else
  fail "case 6: cross-goal claim order missing from render" "$(cat "$TMP/preview.txt")"
fi

# === case 7: --goal scoped (single-goal) batch renders the one goal (edge case) ===

SINGLE="$TMP/2026-05-12T120000-fixture-kanban-app-stride-batch.json"
cat > "$SINGLE" <<'EOF'
{
  "source_spec": "2026-05-12T120000-fixture-requirements.md",
  "source_spec_sha256": "1111111111111111111111111111111111111111111111111111111111111111",
  "decomposition_notes": "Single-goal shape, no cross-goal coordination.",
  "goals": [
    {
      "title": "Kanban app — review queue",
      "type": "goal",
      "tasks": [
        { "title": "Add the review column" }
      ]
    }
  ]
}
EOF
render_preview "$SINGLE" > "$TMP/preview_single.txt" 2>&1
if grep -qF "Goal: Kanban app — review queue  (1 task)" "$TMP/preview_single.txt" \
   && [ "$(grep -cF 'Goal: ' "$TMP/preview_single.txt")" = "1" ]; then
  pass "case 7: --goal scoped batch renders exactly the single scoped goal"
else
  fail "case 7: single-goal render wrong" "$(cat "$TMP/preview_single.txt")"
fi

# === case 8: pitfall — no token / auth material in any gate output =========

if grep -qE 'stride_(dev|prod)_|Bearer |Authorization:' \
     "$TMP/preview.txt" "$TMP/run_bypass.log" "$TMP/run_decline.log" "$TMP/run_approve.log"; then
  fail "case 8: gate output contains potential auth material (pitfall violated)"
else
  pass "case 8: no Bearer/token/Authorization strings in preview or gate output (pitfall avoided)"
fi

# === cases 9-14: /stridify --batch parse and gate ==========================

expect_parse() { # expect_parse <label> <args> <expected line>
  local got; got="$(parse_batch_args "$2")"
  if [ "$got" = "$3" ]; then pass "$1"; else fail "$1" "got [$got] want [$3]"; fi
}
expect_parse "case 9: --batch <path> selects batch mode" "--batch docs/x-stride-batch.json" "batch=docs/x-stride-batch.json|yes=false|err=|rest="
expect_parse "case 10: --batch=<path> splits on the first = only" "--batch=docs/a=b.json" "batch=docs/a=b.json|yes=false|err=|rest="
expect_parse "case 11a: a bare trailing --batch is a usage error" "--batch" "batch=|yes=false|err=usage|rest="
expect_parse "case 11b: --batch= with no value is a usage error" "--batch=" "batch=|yes=false|err=usage|rest="
expect_parse "case 11c: --batch followed by a flag never takes the flag as its path" "--batch --yes" "batch=|yes=true|err=usage|rest="
expect_parse "case 12: --batch together with --goal is rejected" "--batch b.json --goal 2" "batch=b.json|yes=false|err=goal|rest="
expect_parse "case 13: --batch with a requirements-doc path left over is rejected" "--batch b.json docs/x-requirements.md" "batch=b.json|yes=false|err=doc|rest=docs/x-requirements.md"
expect_parse "case 14a: --batch --yes keeps the path and sets the bypass" "--batch b.json --yes" "batch=b.json|yes=true|err=|rest="
reset_post_sentinel
render_and_gate "$BATCH" true "" >"$TMP/run_batch_yes.log" 2>&1
rc_batch_yes=$?
if [ "$rc_batch_yes" -eq 0 ] && post_was_attempted && ! grep -q 'declined' "$TMP/run_batch_yes.log" \
   && grep -q 'Goals and tasks to be created:' "$TMP/run_batch_yes.log"; then
  pass "case 14b: --batch --yes renders the preview and reaches the POST with no prompt"
else
  fail "case 14b: --batch --yes did not render-then-POST" "rc=$rc_batch_yes"
fi

# === summary ==============================================================

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
