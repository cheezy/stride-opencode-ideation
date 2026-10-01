#!/usr/bin/env bash
# Tests for the bash fragments in commands/ideate.md and commands/stridify.md.
#
# OpenCode runs every bash call in a fresh process and expands each
# dollar-sign-plus-digit sequence in a command template into the user's
# arguments before the model reads it. So this suite:
#
#   1. Lints both command files: no dollar-digit sequence, no <plugin-root>,
#      the fresh-shell rule stated once, and in every fenced bash block the
#      helper resolver and the helper source precede every sti_ call, and
#      every variable read is assigned in the block or named on its
#      "# Carried forward:" line. Planted bad files prove each rule fires.
#   2. Expands each template the way OpenCode does and checks it is unchanged.
#   3. Runs every fragment in `bash --noprofile --norc -u` with only the
#      literal values it is handed, chaining the "carry:" lines it prints,
#      in a scratch git repo with the helpers installed project-locally.
#   4. Checks the resolver: project install before global, global alone, a
#      stride-opencode-ideation checkout, and a refusal (that sources nothing)
#      for a user's project that merely has its own lib/filename.sh.
#
# A PowerShell mirror of the lint lives at lib/test-command-templates.ps1.
#
# Run:
#   ./lib/test-command-templates.sh
#
# Exits 0 if all tests pass, non-zero otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ ! -f "$BUNDLE/commands/ideate.md" ] || [ ! -f "$BUNDLE/commands/stridify.md" ]; then
  # Installed copies of lib/ have no commands/ beside them; this suite needs
  # a checkout.
  printf 'SKIP  commands/ not found beside lib/ (run this from a checkout)\n\n0 passed, 0 failed\n'
  exit 0
fi

PASS=0
FAIL=0
ROOT=""

cleanup() {
  if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
    rm -rf "$ROOT"
  fi
}
trap cleanup EXIT

ROOT="$(mktemp -d)"
# A space in every scratch path, so an unquoted expansion anywhere fails.
TMP="$ROOT/command templates"
mkdir -p "$TMP"

ok() { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
no() { FAIL=$(( FAIL + 1 )); printf 'FAIL  %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      %s\n' "$2"; fi; }

# --- the lint ---------------------------------------------------------------

# Agent names the @-reference rule protects: this bundle's agents/*.md.
LINT_AGENTS="$(cd "$BUNDLE/agents" && ls *.md | sed 's/\.md$//' | paste -sd, -)"
# Map every sti_ function to the lib/*.sh file that defines it.
LINT_HELPERS="$(cd "$BUNDLE/lib" && grep -oE '^sti_[a-z_]+\(\)' *.sh | sed -E 's/^([^:]+):(sti_[a-z_]+)\(\)$/\2=\1/' | paste -sd, -)"
export LINT_AGENTS LINT_HELPERS
cat > "$TMP/lint.py" <<'PY'
"""Lint OpenCode command templates. Prints one line per violation."""
import os
import re
import sys

RESOLVER_FIRST = '# Find the helpers: the project install, then the global install, then a stride-opencode-ideation checkout.'
RULE = '**Every bash call is a fresh shell.**'
DOLLAR_DIGIT = re.compile(r'\$\{?[0-9]')
FENCE = re.compile(r'^(\s*)```bash\s*$')
VAR_READ = re.compile(r'\$\{?([A-Z_][A-Z0-9_]*)')
VAR_SET = re.compile(r'(?:^|[\s;(])([A-Z_][A-Z0-9_]*)=')
READ_VARS = re.compile(r'\bread\s+(?:-r\s+)?([A-Z_][A-Z0-9_ ]*)')
STI_CALL = re.compile(r'\b(sti_[a-z_]+)\b')
SOURCE = re.compile(r'^\s*\.\s+"\$STI_LIB/([a-z_]+\.sh)"')
ALWAYS_SET = {'HOME', 'STI_ROOT', 'STI_LIB'}
# OpenCode's @-reference pattern for command templates (1.16): an @ that does
# not follow a word character or a backtick. A match naming an agent becomes
# an agent call at expansion time, before any step runs.
FILE_REF = re.compile(r'(?<![\w`])@(\.?[^\s`,.]*(?:\.[^\s`,.]+)*)')
AGENTS = {a for a in os.environ.get('LINT_AGENTS', '').split(',') if a}


# Which lib/*.sh defines each sti_ function, from LINT_HELPERS
# ("name=file,..."), built from the helpers' own definitions.
HELPERS = dict(kv.split('=', 1) for kv in os.environ.get('LINT_HELPERS', '').split(',') if '=' in kv)


def helper_file(fn):
    return HELPERS.get(fn, 'an unknown helper file')


def blocks(text):
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if m:
            indent = m.group(1)
            j = i + 1
            body = []
            while j < len(lines) and lines[j].strip() != '```':
                body.append(lines[j][len(indent):] if lines[j].startswith(indent) else lines[j])
                j += 1
            yield i + 1, body
            i = j
        i += 1


def lint(path):
    out = []
    text = open(path, encoding='utf-8').read()
    for n, line in enumerate(text.split('\n'), 1):
        if DOLLAR_DIGIT.search(line):
            out.append(f'{path}:{n}: dollar-digit sequence (OpenCode rewrites it): {line.strip()}')
        if '<plugin-root>' in line:
            out.append(f'{path}:{n}: <plugin-root> placeholder: {line.strip()}')
        for ref in FILE_REF.findall(line):
            if ref in AGENTS:
                out.append(f'{path}:{n}: bare @{ref} (OpenCode turns it into an agent call at expansion time): {line.strip()}')
    if text.count(RULE) != 1:
        out.append(f'{path}: the fresh-shell rule {RULE} appears {text.count(RULE)} times, want 1')
    for start, body in blocks(text):
        where = f'{path}:{start}'
        if not body or not body[0].startswith('# Carried forward:'):
            out.append(f'{where}: block does not start with a "# Carried forward:" line')
            continue
        carried = set(re.findall(r'\b[A-Z_][A-Z0-9_]*\b', re.sub(r'\([^)]*\)', '', body[0])))
        code = [l for l in body[1:] if not l.lstrip().startswith('#') or l.startswith('#!')]
        joined = '\n'.join(body)
        resolver_at = next((k for k, l in enumerate(body) if l == RESOLVER_FIRST), None)
        uses_lib = any('$STI_LIB' in l for l in body)
        sti_lines = [(k, f) for k, l in enumerate(body) for f in STI_CALL.findall(l)]
        if (uses_lib or sti_lines) and resolver_at is None:
            out.append(f'{where}: uses the helpers but has no resolver')
        sourced = {}
        for k, l in enumerate(body):
            m = SOURCE.match(l)
            if m:
                sourced.setdefault(m.group(1), k)
                if resolver_at is None or k < resolver_at:
                    out.append(f'{where}: sources {m.group(1)} before resolving the helper dir')
        for k, fn in sti_lines:
            need = helper_file(fn)
            if need not in sourced or sourced[need] > k:
                out.append(f'{where}: calls {fn} without sourcing {need} earlier in the same block')
        assigned = set(ALWAYS_SET)
        for l in code:
            assigned.update(VAR_SET.findall(l))
            for m in READ_VARS.finditer(l):
                assigned.update(m.group(1).split())
        for l in code:
            for v in VAR_READ.findall(l):
                if v not in assigned and v not in carried:
                    out.append(f'{where}: reads {v}, which is neither assigned nor carried forward')
        for v in carried:
            if v in ('Carried', 'forward', 'none'):
                continue
            if not re.search(r':\s+"\$\{' + v + r':?\?', joined):
                out.append(f'{where}: carried value {v} has no ${{{v}?...}} check')
    return out


violations = []
for p in sys.argv[1:]:
    violations += lint(p)
print('\n'.join(violations))
sys.exit(1 if violations else 0)
PY

lint_ok() { # lint_ok <label> <file...>
  local label="$1"; shift
  local out
  if out="$(python3 "$TMP/lint.py" "$@" 2>&1)"; then ok "$label"; else no "$label" "$(printf '%s' "$out" | head -n 8 | tr '\n' ' ')"; fi
}
lint_catches() { # lint_catches <label> <needle> <file>
  local out
  out="$(python3 "$TMP/lint.py" "$3" 2>&1)"
  if [ $? -ne 0 ] && printf '%s' "$out" | grep -qF -- "$2"; then ok "$1"; else no "$1" "lint said: $out"; fi
}

printf 'Lint of the real command files\n'
lint_ok "lint: commands/ideate.md is clean" "$BUNDLE/commands/ideate.md"
lint_ok "lint: commands/stridify.md is clean" "$BUNDLE/commands/stridify.md"

printf '\nThe lint catches planted defects\n'
RESOLVER_TEXT="$(sed -n '/^# Find the helpers:/,/^else echo/p' "$BUNDLE/commands/ideate.md" | head -n 6)"
plant() { # plant <name> <block body> — a command file with the rule and one block
  { printf '%s\n\n' '**Every bash call is a fresh shell.**'; printf '```bash\n%s\n```\n' "$2"; } > "$TMP/$1.md"
}
plant dollar "# Carried forward: none
printf '%s' x | awk '{print \$1}'"
lint_catches "lint: catches an awk positional field" "dollar-digit" "$TMP/dollar.md"
plant braced "# Carried forward: none
echo \"\${2}\""
lint_catches "lint: catches a braced positional parameter" "dollar-digit" "$TMP/braced.md"
plant escaped "# Carried forward: none
echo \"\\\$1\""
lint_catches "lint: catches a backslash-escaped one too (OpenCode still rewrites it)" "dollar-digit" "$TMP/escaped.md"
plant placeholder "# Carried forward: none
. <plugin-root>/lib/filename.sh"
lint_catches "lint: catches <plugin-root>" "<plugin-root>" "$TMP/placeholder.md"
plant nosource "# Carried forward: TOPIC
: \"\${TOPIC?x}\"
$RESOLVER_TEXT
SLUG=\"\$(sti_slugify \"\$TOPIC\")\""
lint_catches "lint: catches a helper call with no source in the block" "without sourcing filename.sh" "$TMP/nosource.md"
plant wrongsource "# Carried forward: SLUG
: \"\${SLUG?x}\"
$RESOLVER_TEXT
. \"\$STI_LIB/filename.sh\" || exit 1
sti_draft_find .stride \"\$SLUG\""
lint_catches "lint: catches a draft helper sourced from the wrong file" "without sourcing draft.sh" "$TMP/wrongsource.md"
plant noresolver "# Carried forward: none
. \"\$STI_LIB/filename.sh\" || exit 1
sti_slugify x"
lint_catches "lint: catches a block with no resolver" "has no resolver" "$TMP/noresolver.md"
plant uncarried "# Carried forward: none
echo \"\$TARGET_PATH\""
lint_catches "lint: catches a value read but never carried forward" "reads TARGET_PATH" "$TMP/uncarried.md"
plant unchecked "# Carried forward: SLUG
echo \"\$SLUG\""
lint_catches "lint: catches a carried value with no check" "has no" "$TMP/unchecked.md"
plant nocarry "echo hi"
lint_catches "lint: catches a block with no Carried forward line" "Carried forward" "$TMP/nocarry.md"
printf '%s\n\nThen dispatch @requirements-decomposer with the prompt.\n' '**Every bash call is a fresh shell.**' > "$TMP/atref.md"
lint_catches "lint: catches a bare @agent reference" "bare @requirements-decomposer" "$TMP/atref.md"
printf '%s\n\nNever use `@requirements-decomposer`; call the task tool.\n' '**Every bash call is a fresh shell.**' > "$TMP/atref-ok.md"
lint_ok "lint: a backticked @agent name is left alone" "$TMP/atref-ok.md"
printf '```bash\n# Carried forward: none\necho hi\n```\n' > "$TMP/norule.md"
lint_catches "lint: catches a file without the fresh-shell rule" "appears 0 times" "$TMP/norule.md"

# --- agent prompts: every json example parses ----------------------------------

printf '\nAgent prompt json examples parse\n'
for agent in "$BUNDLE"/agents/*.md; do
  if out="$(python3 - "$agent" <<'PY' 2>&1
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for n, block in enumerate(re.findall(r"```json\n(.*?)```", text, re.S), 1):
    try:
        json.loads(block)
    except ValueError as exc:
        sys.exit(f"block {n}: {exc}")
PY
)"; then ok "agents: every json block in $(basename "$agent") parses (a model copying it emits valid JSON)"; else no "agents: a json block in $(basename "$agent") does not parse" "$out"; fi
done

# --- OpenCode's template expansion ------------------------------------------

printf "\nOpenCode's template expansion leaves the files unchanged\n"
cat > "$TMP/expand.py" <<'PY'
import re
import sys

# OpenCode replaces each dollar-sign-plus-digit with the matching argument
# (empty when there is none). Mirror that, with arguments from argv.
src, dst, args = sys.argv[1], sys.argv[2], sys.argv[3:]
text = open(src, encoding='utf-8').read()
out = re.sub(r'\$(\d+)', lambda m: args[int(m.group(1)) - 1] if 0 < int(m.group(1)) <= len(args) else '', text)
open(dst, 'w', encoding='utf-8').write(out)
PY
for f in ideate stridify; do
  python3 "$TMP/expand.py" "$BUNDLE/commands/$f.md" "$TMP/expanded-$f.md" docs/x-requirements.md --goal 2
  if cmp -s "$BUNDLE/commands/$f.md" "$TMP/expanded-$f.md"; then
    ok "expansion: $f.md is byte-identical after expanding with 'docs/x-requirements.md --goal 2'"
  else
    no "expansion: $f.md changed under expansion" "$(diff "$BUNDLE/commands/$f.md" "$TMP/expanded-$f.md" | head -n 4 | tr '\n' ' ')"
  fi
done

# --- extract the fragments from the EXPANDED files --------------------------

cat > "$TMP/extract.py" <<'PY'
"""Write each fenced bash block to <out>/<prefix>-step<N>-<k>.sh."""
import os
import re
import sys

src, out, prefix = sys.argv[1:4]
step, seen = 'none', {}
lines = open(src, encoding='utf-8').read().split('\n')
i = 0
while i < len(lines):
    h = re.match(r'^### Step ([0-9.]+[a-z]?)\b', lines[i])
    if h:
        step = h.group(1)
    m = re.match(r'^(\s*)```bash\s*$', lines[i])
    if m:
        indent, body, j = m.group(1), [], i + 1
        while j < len(lines) and lines[j].strip() != '```':
            body.append(lines[j][len(indent):] if lines[j].startswith(indent) else lines[j])
            j += 1
        seen[step] = seen.get(step, 0) + 1
        with open(os.path.join(out, f'{prefix}-step{step}-{seen[step]}.sh'), 'w', encoding='utf-8') as fp:
            fp.write('\n'.join(body) + '\n')
        i = j
    i += 1
PY
mkdir -p "$TMP/frags"
python3 "$TMP/extract.py" "$TMP/expanded-ideate.md" "$TMP/frags" ideate
python3 "$TMP/extract.py" "$TMP/expanded-stridify.md" "$TMP/frags" stridify

# --- scratch project with a project-local install ---------------------------

PROJ="$TMP/project repo"
FAKEHOME="$TMP/empty home"
mkdir -p "$PROJ" "$FAKEHOME" "$TMP/bin"
git -C "$PROJ" init -q
git -C "$PROJ" config user.email t@example.com
git -C "$PROJ" config user.name tester
git -C "$PROJ" commit -q --allow-empty -m init
mkdir -p "$PROJ/.opencode/stride-ideation"
cp -R "$BUNDLE/lib" "$PROJ/.opencode/stride-ideation/lib"
cp -R "$BUNDLE/fixtures" "$PROJ/.opencode/stride-ideation/fixtures"

# Fake curl for the Step 9 fragment: answers 201 with a created-goal body.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; esac
  shift
done
cat > /dev/null
printf '{"success":true,"goals":[{"goal":{"identifier":"G7","title":"Dark mode"},"child_tasks":[{"identifier":"W70","title":"Toggle"}]}]}' > "$out"
printf '201'
EOF
chmod +x "$TMP/bin/curl"
printf -- '- **API URL:** `https://stride.example`\n- **API Token:** `stride_dev_TEMPLATES_TEST_0000`\n' > "$TMP/auth.md"

# run_frag <fragment> [NAME=value ...] — runs one fragment in a brand-new
# `bash --noprofile --norc -u` from $RUN_DIR (default: the project), with the
# carried values prepended as single-quoted assignments. Leaves $OUT, $ERR,
# $RC, and CARRY_<NAME> for each "carry: NAME=value" line printed.
run_frag() {
  local frag="$TMP/frags/$1" stale; shift
  # Forget every value an earlier fragment carried, so an assertion can only
  # pass on what THIS fragment printed.
  for stale in ${!CARRY_@}; do unset "$stale"; done
  if [ ! -f "$frag" ]; then no "fragment $(basename "$frag") exists"; RC=99; OUT=""; ERR=""; return; fi
  local script="$TMP/run.sh" kv name val
  : > "$script"
  for kv in "$@"; do
    name="${kv%%=*}"; val="${kv#*=}"
    printf "%s='%s'\n" "$name" "$(printf '%s' "$val" | sed "s/'/'\\\\''/g")" >> "$script"
  done
  cat "$frag" >> "$script"
  OUT="$(cd "${RUN_DIR:-$PROJ}" && env -i PATH="$TMP/bin:$PATH" HOME="${RUN_HOME:-$FAKEHOME}" \
    STRIDE_AUTH_FILE="$TMP/auth.md" bash --noprofile --norc -u "$script" 2> "$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
  while IFS= read -r line; do
    case "$line" in
      carry:\ *=*) name="${line#carry: }"; name="${name%%=*}"; val="${line#carry: *=}"; printf -v "CARRY_$name" '%s' "$val" ;;
    esac
  done <<< "$OUT"
}
expect_rc() { if [ "$RC" = "$2" ]; then ok "$1"; else no "$1" "rc=$RC want $2; stderr: $(printf '%s' "$ERR" | head -c 300)"; fi; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$2] want [$3]"; fi; }
expect_has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1" "missing [$3] in: $(printf '%s' "$2" | head -c 300)"; fi; }

# --- /ideate, fresh session -----------------------------------------------------

printf '\n/ideate fragments, fresh session, each in a brand-new shell\n'
run_frag ideate-step2-1.sh
expect_rc "ideate Step 2: runs" 0
TS="${CARRY_SESSION_TS:-}"
if printf '%s' "$TS" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}$'; then ok "ideate Step 2: prints carry SESSION_TS"; else no "ideate Step 2: SESSION_TS shape" "$TS"; fi

run_frag ideate-step3-1.sh "CONTINUE_PATH=" "TOPIC=Bob's idea: dark mode!"
expect_rc "ideate Step 3: runs under set -u with CONTINUE_PATH empty" 0
expect_eq "ideate Step 3: slugifies a topic with a quote and punctuation" "${CARRY_SLUG:-}" "bob-s-idea-dark-mode"
run_frag ideate-step3-1.sh "TOPIC=x"
expect_rc "ideate Step 3: stops when CONTINUE_PATH was not carried" 1
expect_has "ideate Step 3: names the missing value" "$ERR" "CONTINUE_PATH was not carried forward"

run_frag ideate-step4-1.sh "SESSION_TS=$TS" "SLUG=bob-s-idea-dark-mode" "CONTINUE_PATH="
expect_rc "ideate Step 4: runs" 0
expect_eq "ideate Step 4: carries TARGET_PATH" "${CARRY_TARGET_PATH:-}" "docs/ideation/$TS-bob-s-idea-dark-mode-requirements.md"
run_frag ideate-step4-1.sh "SESSION_TS=$TS" "CONTINUE_PATH="
expect_rc "ideate Step 4: stops without SLUG" 1
expect_has "ideate Step 4: says SLUG was not carried" "$ERR" "SLUG was not carried forward"
TARGET="docs/ideation/$TS-bob-s-idea-dark-mode-requirements.md"

run_frag ideate-step4d-1.sh "SESSION_TS=$TS" "SLUG=bob-s-idea-dark-mode"
expect_rc "ideate Step 4d: runs with no draft" 0
expect_eq "ideate Step 4d: no existing draft" "${CARRY_EXISTING_DRAFT-unset}" ""
expect_eq "ideate Step 4d: fresh draft path" "${CARRY_FRESH_DRAFT_PATH:-}" ".stride/$TS-bob-s-idea-dark-mode-draft.md"
expect_eq "ideate Step 4d: makes .stride/ ignore itself" "$(cat "$PROJ/.stride/.gitignore" 2>/dev/null)" "*"
printf 'draft prose\n' > "$PROJ/.stride/$TS-bob-s-idea-dark-mode-draft.md"
expect_eq "ideate Step 4d: a draft never shows in git status" "$(git -C "$PROJ" status --porcelain --untracked-files=all -- .stride)" ""
rm -f "$PROJ/.stride/$TS-bob-s-idea-dark-mode-draft.md"
mkdir -p "$PROJ/.stride"
printf 'old draft\n' > "$PROJ/.stride/2026-01-01T000000-bob-s-idea-dark-mode-draft.md"
run_frag ideate-step4d-1.sh "SESSION_TS=$TS" "SLUG=bob-s-idea-dark-mode"
expect_eq "ideate Step 4d: finds an unfinished same-slug draft" "${CARRY_EXISTING_DRAFT:-}" ".stride/2026-01-01T000000-bob-s-idea-dark-mode-draft.md"
run_frag ideate-step4d-2.sh "EXISTING_DRAFT=.stride/2026-01-01T000000-bob-s-idea-dark-mode-draft.md"
expect_rc "ideate Step 4d start-fresh: runs" 0
if [ ! -e "$PROJ/.stride/2026-01-01T000000-bob-s-idea-dark-mode-draft.md" ]; then ok "ideate Step 4d start-fresh: discards the old draft"; else no "ideate Step 4d start-fresh: old draft still there"; fi

run_frag ideate-step7-1.sh "SESSION_TS=$TS" "SLUG=bob-s-idea-dark-mode" "TARGET_PATH=$TARGET"
expect_rc "ideate Step 7: runs" 0
expect_eq "ideate Step 7: keeps an untaken TARGET_PATH" "${CARRY_TARGET_PATH:-}" "$TARGET"
mkdir -p "$PROJ/docs/ideation"
printf 'someone else\n' > "$PROJ/$TARGET"
run_frag ideate-step7-1.sh "SESSION_TS=$TS" "SLUG=bob-s-idea-dark-mode" "TARGET_PATH=$TARGET"
expect_eq "ideate Step 7: moves to a fresh path when TARGET_PATH was taken" "${CARRY_TARGET_PATH:-}" "docs/ideation/$TS-bob-s-idea-dark-mode-requirements-2.md"
expect_eq "ideate Step 7: never touches the existing file" "$(cat "$PROJ/$TARGET")" "someone else"
rm -f "$PROJ/$TARGET"

printf '# Doc\n' > "$PROJ/$TARGET"
printf 'draft\n' > "$PROJ/.stride/$TS-bob-s-idea-dark-mode-draft.md"
run_frag ideate-step9-1.sh "TARGET_PATH=$TARGET" "SLUG=bob-s-idea-dark-mode" "CONTINUE_PATH=" "DRAFT_PATH=.stride/$TS-bob-s-idea-dark-mode-draft.md"
expect_rc "ideate Step 9: commits" 0
expect_eq "ideate Step 9: commit subject" "$(git -C "$PROJ" log -1 --format=%s)" "stride-ideation: requirements for bob-s-idea-dark-mode"
expect_eq "ideate Step 9: commits only the doc" "$(git -C "$PROJ" show --name-only --format= HEAD)" "$TARGET"
if [ ! -e "$PROJ/.stride/$TS-bob-s-idea-dark-mode-draft.md" ]; then ok "ideate Step 9: clears the draft after the commit"; else no "ideate Step 9: draft left behind"; fi

printf '\n/ideate --continue\n'
run_frag ideate-step3-1.sh "CONTINUE_PATH=$TARGET" "TOPIC="
expect_eq "ideate Step 3 --continue: inherits the slug" "${CARRY_SLUG:-}" "bob-s-idea-dark-mode"
run_frag ideate-step4-1.sh "SESSION_TS=$TS" "SLUG=bob-s-idea-dark-mode" "CONTINUE_PATH=$TARGET"
expect_rc "ideate Step 4 --continue: runs" 0
expect_eq "ideate Step 4 --continue: never targets the source doc" "${CARRY_TARGET_PATH:-}" "docs/ideation/$TS-bob-s-idea-dark-mode-requirements-2.md"

# --- /stridify -------------------------------------------------------------------

printf '\n/stridify fragments, each in a brand-new shell\n'
REQ="docs/ideation/2026-05-12T120000-dark-mode-toggle-requirements.md"
cp "$BUNDLE/fixtures/2026-05-12T120000-dark-mode-toggle-requirements.md" "$PROJ/$REQ"
printf '\n## Decomposition seams\n\n1. **Kanban app** — owns the contract\n2. **Stride plugin** — adapter\n3. **Docs site** — guides\n4. **CLI** — flags\n' >> "$PROJ/$REQ"
git -C "$PROJ" add "$REQ" && git -C "$PROJ" commit -q -m "add req"

printf '\n/stridify --batch (Step 1b)\n'
mkdir -p "$PROJ/batches"
cp "$BUNDLE/fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json" "$PROJ/batches/ok batch.json"
run_frag stridify-step1b-1.sh "BATCH_PATH=batches/ok batch.json"
expect_rc "stridify Step 1b: a valid batch passes validation" 0
expect_has "stridify Step 1b: warns that re-shipping creates duplicates" "$ERR" "shipping it again creates every goal and task a second time"
run_frag stridify-step1b-1.sh "BATCH_PATH=batches/missing.json"
expect_rc "stridify Step 1b: a missing batch file stops" 1
expect_has "stridify Step 1b: names the missing file" "$ERR" "batch JSON not found at batches/missing.json"
printf '{"tasks": []}' > "$PROJ/batches/bad.json"
run_frag stridify-step1b-1.sh "BATCH_PATH=batches/bad.json"
expect_rc "stridify Step 1b: an invalid batch stops before anything is sent" 1
expect_has "stridify Step 1b: surfaces the validator's message" "$ERR" "root key 'tasks'"
run_frag stridify-step1b-1.sh "BATCH_PATH=-rf.json"
expect_rc "stridify Step 1b: a path starting with '-' is refused" 1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["decomposition_notes"]="pasted: stride_dev_TEMPLATES_TEST_0000"; json.dump(d, open(sys.argv[2], "w"))' "$PROJ/batches/ok batch.json" "$PROJ/batches/token.json"
run_frag stridify-step1b-1.sh "BATCH_PATH=batches/token.json"
expect_rc "stridify Step 1b: a batch carrying the API token is refused before the preview" 1
if printf '%s' "$OUT$ERR" | grep -qF 'stride_dev_TEMPLATES_TEST_0000'; then no "stridify Step 1b: the refused token is never printed"; else ok "stridify Step 1b: the refused token is never printed"; fi
mkdir -p "$TMP/outside"
cp "$PROJ/batches/ok batch.json" "$TMP/outside/elsewhere.json"
run_frag stridify-step1b-1.sh "BATCH_PATH=$TMP/outside/elsewhere.json"
expect_rc "stridify Step 1b: a batch file outside the repository is accepted" 0

run_frag stridify-step2-1.sh "REQUIREMENTS_PATH=$REQ"
expect_rc "stridify Step 2.3 section gate: a complete doc passes" 0
printf '# Thin\n\n## Problem\n\np\n\n## Goal\n\ng\n' > "$PROJ/docs/ideation/thin-requirements.md"
run_frag stridify-step2-1.sh "REQUIREMENTS_PATH=docs/ideation/thin-requirements.md"
expect_rc "stridify Step 2.3 section gate: a doc missing sections stops" 1
expect_has "stridify Step 2.3 section gate: names the missing sections" "$ERR" "missing required section(s): Outcome, Assumptions, Constraints, Non-goals, Success metrics"
run_frag stridify-step2-2.sh "REQUIREMENTS_PATH=$REQ" "GOAL_ARG="
expect_rc "stridify Step 2 advisory: runs and never fails" 0
expect_has "stridify Step 2 advisory: counts 4 surfaces" "$ERR" "enumerates 4 surfaces"
printf '# B\n\n## Decomposition seams\n\n- **One** — a\n- **Two** — b\n  - nested note\n- **Three** — c\n- **Four** — d\n' > "$PROJ/docs/ideation/bulleted-requirements.md"
run_frag stridify-step2-2.sh "REQUIREMENTS_PATH=docs/ideation/bulleted-requirements.md" "GOAL_ARG="
expect_has "stridify Step 2 advisory: counts bulleted seams the resolver accepts" "$ERR" "enumerates 4 surfaces"
printf '# M\n\n## Decomposition seams\n\n1. **One** — a\n2. **Two** — b\n3. **Three** — c\n\nShared:\n- **X** — n\n- **Y** — n\n- **Z** — n\n- **W** — n\n' > "$PROJ/docs/ideation/mixed-requirements.md"
run_frag stridify-step2-2.sh "REQUIREMENTS_PATH=docs/ideation/mixed-requirements.md" "GOAL_ARG="
expect_eq "stridify Step 2 advisory: secondary bullets do not inflate the count (stays quiet at 3)" "$ERR" ""

run_frag stridify-step2b-1.sh "REQUIREMENTS_PATH=$REQ" "GOAL_ARG=2"
expect_rc "stridify Step 2b: resolves --goal 2" 0
expect_eq "stridify Step 2b: GOAL_INDEX" "${CARRY_GOAL_INDEX:-}" "2"
expect_eq "stridify Step 2b: GOAL_NAME" "${CARRY_GOAL_NAME:-}" "Stride plugin"
expect_eq "stridify Step 2b: GOAL_SLUG" "${CARRY_GOAL_SLUG:-}" "stride-plugin"
run_frag stridify-step2b-1.sh "REQUIREMENTS_PATH=$REQ" "GOAL_ARG=docs site"
expect_eq "stridify Step 2b: resolves a goal by name" "${CARRY_GOAL_INDEX:-}" "3"
run_frag stridify-step2b-1.sh "REQUIREMENTS_PATH=$REQ" "GOAL_ARG=nope"
expect_rc "stridify Step 2b: an unknown goal fails" 1
expect_has "stridify Step 2b: lists the seams with index, name and slug" "$ERR" "  4. CLI (slug: cli)"

run_frag stridify-step3-1.sh
expect_rc "stridify Step 3: auth preflight runs through the resolved ship.sh" 0
expect_has "stridify Step 3: reports the auth file" "$OUT$ERR" "auth file OK"

run_frag stridify-step4-1.sh "REQUIREMENTS_PATH=$REQ"
expect_eq "stridify Step 4: SOURCE_TS" "${CARRY_SOURCE_TS:-}" "2026-05-12T120000"
expect_eq "stridify Step 4: SLUG" "${CARRY_SLUG:-}" "dark-mode-toggle"

run_frag stridify-step5-1.sh "REQUIREMENTS_PATH=$REQ" "SOURCE_TS=2026-05-12T120000" "SLUG=dark-mode-toggle" "GOAL_SLUG=stride-plugin"
expect_eq "stridify Step 5: per-goal TARGET_PATH" "${CARRY_TARGET_PATH:-}" "docs/ideation/2026-05-12T120000-dark-mode-toggle-stride-plugin-stride-batch.json"
run_frag stridify-step5-1.sh "REQUIREMENTS_PATH=$REQ" "SOURCE_TS=2026-05-12T120000" "SLUG=dark-mode-toggle" "GOAL_SLUG="
expect_eq "stridify Step 5: all-goals TARGET_PATH (GOAL_SLUG empty under set -u)" "${CARRY_TARGET_PATH:-}" "docs/ideation/2026-05-12T120000-dark-mode-toggle-stride-batch.json"

run_frag stridify-step6-1.sh "REQUIREMENTS_PATH=$REQ"
WANT_SHA="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$PROJ/$REQ")"
expect_eq "stridify Step 6: SOURCE_SHA is the file's SHA-256" "${CARRY_SOURCE_SHA:-}" "$WANT_SHA"
if printf '%s' "${CARRY_SOURCE_SHA:-}" | grep -qE '^[0-9a-f]{64}$'; then ok "stridify Step 6: SOURCE_SHA is 64 lowercase hex chars"; else no "stridify Step 6: SOURCE_SHA shape"; fi
run_frag stridify-step6-2.sh "REQUIREMENTS_PATH=$REQ"
expect_eq "stridify Step 6: SOURCE_SPEC is repo-relative" "${CARRY_SOURCE_SPEC:-}" "$REQ"

run_frag stridify-step7-1.sh "REQUIREMENTS_PATH=$REQ" "GOAL_INDEX=2"
expect_rc "stridify Step 7e: scopes the doc" 0
expect_has "stridify Step 7e: keeps the chosen seam" "$OUT" "Stride plugin"
if printf '%s' "$OUT" | grep -qF 'Kanban app'; then no "stridify Step 7e: drops the other seams"; else ok "stridify Step 7e: drops the other seams"; fi

run_frag stridify-step7.5-1.sh "REQUIREMENTS_PATH=$REQ" "SOURCE_TS=2026-05-12T120000" "SLUG_FOR_PATH=dark-mode-toggle"
expect_eq "stridify Step 7.5a: PROMPT_PATH" "${CARRY_PROMPT_PATH:-}" "docs/ideation/2026-05-12T120000-dark-mode-toggle-decomposer-prompt.md"
expect_eq "stridify Step 7.5a: STI_LIB is the absolute project install" "${CARRY_STI_LIB:-}" "$(cd "$PROJ/.opencode/stride-ideation/lib" && pwd -P)"

mkdir -p "$PROJ/.stride"
cp "$BUNDLE/fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json" "$PROJ/.stride/stridify-subagent-output.json"
run_frag stridify-step8-1.sh
expect_rc "stridify Step 8a: validates the scratch file" 0
printf '{"tasks": []}' > "$PROJ/.stride/stridify-subagent-output.json"
run_frag stridify-step8-1.sh
expect_rc "stridify Step 8a: rejects an invalid batch" 1
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["goals"][0]["tasks"][0]["description"]="token: stride_dev_TEMPLATES_TEST_0000"; json.dump(d, open(sys.argv[2], "w"))' "$BUNDLE/fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json" "$PROJ/.stride/stridify-subagent-output.json"
run_frag stridify-step8-1.sh
expect_rc "stridify Step 8a: refuses decomposer output carrying the API token" 1
if printf '%s' "$OUT$ERR" | grep -qF 'stride_dev_TEMPLATES_TEST_0000'; then no "stridify Step 8a: the refused token is never printed"; else ok "stridify Step 8a: the refused token is never printed"; fi

BATCH="docs/ideation/2026-05-12T120000-dark-mode-toggle-stride-batch.json"
run_frag stridify-step8-2.sh "REQUIREMENTS_PATH=$REQ" "SOURCE_TS=2026-05-12T120000" "SLUG_FOR_PATH=dark-mode-toggle" "TARGET_PATH=$BATCH"
expect_rc "stridify Step 8c: runs" 0
expect_eq "stridify Step 8c: keeps an untaken TARGET_PATH" "${CARRY_TARGET_PATH:-}" "$BATCH"
printf '{}' > "$PROJ/$BATCH"
run_frag stridify-step8-2.sh "REQUIREMENTS_PATH=$REQ" "SOURCE_TS=2026-05-12T120000" "SLUG_FOR_PATH=dark-mode-toggle" "TARGET_PATH=$BATCH"
expect_rc "stridify Step 8c: runs when TARGET_PATH was taken" 0
expect_eq "stridify Step 8c: moves to a fresh path when TARGET_PATH was taken" "${CARRY_TARGET_PATH:-}" "docs/ideation/2026-05-12T120000-dark-mode-toggle-stride-batch-2.json"
expect_eq "stridify Step 8c: never touches the existing file" "$(cat "$PROJ/$BATCH")" "{}"
rm -f "$PROJ/$BATCH"
cp "$BUNDLE/fixtures/2026-05-12T120000-dark-mode-toggle-stride-batch.json" "$PROJ/$BATCH"
run_frag stridify-step8-3.sh "TARGET_PATH=$BATCH" "SLUG=dark-mode-toggle" "GOAL_SLUG="
expect_rc "stridify Step 8d: commits" 0
expect_eq "stridify Step 8d: commit subject" "$(git -C "$PROJ" log -1 --format=%s)" "stride-ideation: decomposition for dark-mode-toggle"
expect_eq "stridify Step 8d: carries BATCH_PATH" "${CARRY_BATCH_PATH:-}" "$BATCH"
if git -C "$PROJ" show --name-only --format= HEAD | grep -qF '.stride/'; then no "stridify Step 8d: the scratch file is never committed"; else ok "stridify Step 8d: the scratch file is never committed"; fi

run_frag stridify-step8.5-1.sh "BATCH_PATH=$BATCH"
expect_has "stridify Step 8.5a: renders the tree" "$OUT" "Goals and tasks to be created:"
python3 -c 'import json,sys; json.dump({"goals": [{"title": "Real goal\u001b[2K\rForged", "type": "goal", "tasks": [{"title": "T1\n    - Hidden task", "type": "work"}]}]}, open(sys.argv[1], "w"))' "$PROJ/batches/escapes.json"
run_frag stridify-step8.5-1.sh "BATCH_PATH=batches/escapes.json"
if printf '%s' "$OUT" | LC_ALL=C grep -q "$(printf '\033')"; then no "stridify Step 8.5a: control characters in titles are shown escaped"; else ok "stridify Step 8.5a: control characters in titles are shown escaped"; fi
expect_has "stridify Step 8.5a: a newline in a title cannot forge a task line" "$OUT" 'T1\n    - Hidden task'
run_frag stridify-step8.5-2.sh "BATCH_PATH=$BATCH"
expect_rc "stridify Step 8.5c decline: exits 0" 0
expect_has "stridify Step 8.5c decline: points at /stridify --batch" "$ERR" "/stridify --batch \"$BATCH\""

run_frag stridify-step9-1.sh "BATCH_PATH=$BATCH"
expect_rc "stridify Step 9: ships through the resolved ship.sh" 0
expect_has "stridify Step 9: renders the created identifiers" "$OUT" "G7"
if printf '%s' "$OUT$ERR" | grep -qF 'stride_dev_TEMPLATES_TEST_0000'; then no "stridify Step 9: never prints the token"; else ok "stridify Step 9: never prints the token"; fi

printf '\n/stridify with a requirements path containing spaces\n'
SPACED="docs/my ideas/2026-05-13T090000-spaced-out-requirements.md"
mkdir -p "$PROJ/docs/my ideas"
cp "$PROJ/$REQ" "$PROJ/$SPACED"
run_frag stridify-step4-1.sh "REQUIREMENTS_PATH=$SPACED"
expect_rc "spaces: Step 4 runs" 0
expect_eq "spaces: Step 4 SLUG" "${CARRY_SLUG:-}" "spaced-out"
run_frag stridify-step5-1.sh "REQUIREMENTS_PATH=$SPACED" "SOURCE_TS=2026-05-13T090000" "SLUG=spaced-out" "GOAL_SLUG="
expect_eq "spaces: Step 5 puts the batch beside the doc" "${CARRY_TARGET_PATH:-}" "docs/my ideas/2026-05-13T090000-spaced-out-stride-batch.json"
run_frag stridify-step6-1.sh "REQUIREMENTS_PATH=$SPACED"
expect_eq "spaces: Step 6 SOURCE_SHA" "${CARRY_SOURCE_SHA:-}" "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$PROJ/$SPACED")"
run_frag stridify-step6-2.sh "REQUIREMENTS_PATH=$SPACED"
expect_eq "spaces: Step 6 SOURCE_SPEC" "${CARRY_SOURCE_SPEC:-}" "$SPACED"
run_frag stridify-step8-2.sh "REQUIREMENTS_PATH=$SPACED" "SOURCE_TS=2026-05-13T090000" "SLUG_FOR_PATH=spaced-out" "TARGET_PATH=docs/my ideas/2026-05-13T090000-spaced-out-stride-batch.json"
expect_rc "spaces: Step 8c runs" 0
expect_eq "spaces: Step 8c keeps the path" "${CARRY_TARGET_PATH:-}" "docs/my ideas/2026-05-13T090000-spaced-out-stride-batch.json"

# --- the resolver --------------------------------------------------------------

printf '\nHelper-dir resolver\n'
GLOBAL_HOME="$TMP/global home"
mkdir -p "$GLOBAL_HOME/.config/opencode/stride-ideation"
cp -R "$BUNDLE/lib" "$GLOBAL_HOME/.config/opencode/stride-ideation/lib"
RUN_HOME="$GLOBAL_HOME" run_frag stridify-step7.5-1.sh "REQUIREMENTS_PATH=$REQ" "SOURCE_TS=2026-05-12T120000" "SLUG_FOR_PATH=x"
expect_rc "resolver: runs with both installs present" 0
expect_eq "resolver: the project install wins over the global one" "${CARRY_STI_LIB:-}" "$(cd "$PROJ/.opencode/stride-ideation/lib" && pwd -P)"

mkdir -p "$PROJ/docs/ideation/deeper"
RUN_DIR="$PROJ/docs/ideation/deeper" run_frag stridify-step7.5-1.sh "REQUIREMENTS_PATH=../2026-05-12T120000-dark-mode-toggle-requirements.md" "SOURCE_TS=2026-05-12T120000" "SLUG_FOR_PATH=x"
expect_rc "resolver: runs from a subdirectory" 0
expect_eq "resolver: finds the project install from a subdirectory" "${CARRY_STI_LIB:-}" "$(cd "$PROJ/.opencode/stride-ideation/lib" && pwd -P)"

OTHER="$TMP/other project"
mkdir -p "$OTHER/lib"
git -C "$OTHER" init -q
# A user's own lib/filename.sh: sourcing it would leave a marker behind.
printf 'touch "%s/SOURCED"\n' "$OTHER" > "$OTHER/lib/filename.sh"
RUN_DIR="$OTHER" RUN_HOME="$GLOBAL_HOME" run_frag ideate-step3-1.sh "CONTINUE_PATH=" "TOPIC=Global one"
expect_eq "resolver: falls back to the global install" "${CARRY_SLUG:-}" "global-one"
RUN_DIR="$OTHER" run_frag ideate-step3-1.sh "CONTINUE_PATH=" "TOPIC=x"
expect_rc "resolver: no install anywhere stops the fragment" 1
expect_has "resolver: says the helpers cannot be found" "$ERR" "cannot find the stride-ideation helpers"
if [ ! -e "$OTHER/SOURCED" ]; then ok "resolver: never sources a user project's own lib/filename.sh"; else no "resolver: sourced the user's lib/filename.sh"; fi

RUN_DIR="$BUNDLE" run_frag ideate-step3-1.sh "CONTINUE_PATH=" "TOPIC=From the checkout"
expect_eq "resolver: a stride-opencode-ideation checkout uses its own lib/" "${CARRY_SLUG:-}" "from-the-checkout"

# --- summary -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
