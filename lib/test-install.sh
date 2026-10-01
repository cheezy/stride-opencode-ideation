#!/usr/bin/env bash
# Tests for install.sh — source detection (local checkout vs. piped stdin vs.
# a user's project that merely looks like a bundle), the bundle-owned
# stride-ideation/ helper layout, legacy-file handling, global mode, and the
# AGENTS.md managed block. A PowerShell mirror lives at lib/test-install.ps1.
#
# No network: `git` is replaced by a PATH-prepended fake that counts its
# calls and "clones" by copying this checkout's bundle files into the target.
# Global mode runs with HOME pointed at a scratch directory.
#
# Run:
#   ./lib/test-install.sh
#
# Exits 0 if all tests pass, non-zero otherwise.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL="${BUNDLE}/install.sh"

PASS=0
FAIL=0
ROOT=""

cleanup() {
  if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
    rm -rf "$ROOT"
  fi
}
trap cleanup EXIT

# A space in every scratch path, so an unquoted expansion anywhere fails.
ROOT="$(mktemp -d)"
TMP="$ROOT/install tests"
mkdir -p "$TMP"

ok() { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
no() { FAIL=$(( FAIL + 1 )); printf 'FAIL  %s\n' "$1"; if [ -n "${2:-}" ]; then printf '      %s\n' "$2"; fi; }

check() { # check <label> <command...> — passes when the command succeeds
  local label="$1"; shift
  if "$@"; then ok "$label"; else no "$label"; fi
}

# --- fake git ---------------------------------------------------------------

mkdir -p "$TMP/bin"
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
# Fake git for lib/test-install.sh: records the call, then "clones" by copying
# $FAKE_GIT_SRC's bundle files into the last argument.
echo "$*" >> "$FAKE_GIT_LOG"
[ "${1:-}" = "clone" ] || exit 0
for dest in "$@"; do :; done
printf '%s\n' "$dest" >> "$FAKE_GIT_LOG.dest"
mkdir -p "$dest"
for e in AGENTS.md README.md install.sh install.ps1 commands skills agents lib fixtures; do
  if [ -e "$FAKE_GIT_SRC/$e" ]; then cp -R "$FAKE_GIT_SRC/$e" "$dest/"; fi
done
EOF
chmod +x "$TMP/bin/git"

# run_install <case> <mode: local|piped> [args...] — runs install.sh in
# $TMP/<case>/project with the fake git. Leaves $P (project), $H (home),
# $C/out, $C/err, $C/rc and $C/git.log.
run_install() {
  local name="$1" how="$2"; shift 2
  C="$TMP/$name"; P="$C/project"; H="$C/home"
  mkdir -p "$P" "$H"
  : > "$C/git.log"
  if [ "$how" = "piped" ]; then
    (cd "$P" && PATH="$TMP/bin:$PATH" HOME="$H" FAKE_GIT_LOG="$C/git.log" \
      FAKE_GIT_SRC="${FAKE_SRC:-$BUNDLE}" bash -s -- "$@" < "$INSTALL" > "$C/out" 2> "$C/err")
  else
    (cd "$P" && PATH="$TMP/bin:$PATH" HOME="$H" FAKE_GIT_LOG="$C/git.log" \
      FAKE_GIT_SRC="${FAKE_SRC:-$BUNDLE}" bash "$INSTALL" "$@" > "$C/out" 2> "$C/err")
  fi
  echo "$?" > "$C/rc"
}

rc_is() {
  local got; got="$(cat "$C/rc")"
  if [ "$got" = "$2" ]; then ok "$1"; else no "$1" "exit $got, want $2; stderr: $(head -c 300 "$C/err")"; fi
}
git_calls() { wc -l < "$C/git.log" | tr -d ' '; }
first_line_of() { grep -nxF -- "$2" "$1" | head -1 | cut -d: -f1; }
count_lines() { grep -cxF -- "$2" "$1" || true; }

BEGIN_MARKER="<!-- BEGIN stride-ideation -->"
END_MARKER="<!-- END stride-ideation -->"

# A user's own project that looks like a bundle to a naive check.
make_lookalike_project() {
  mkdir -p "$1/skills/my-own-skill" "$1/agents"
  printf '# My project notes\nKeep this line.\n' > "$1/AGENTS.md"
  printf 'my skill\n' > "$1/skills/my-own-skill/SKILL.md"
  printf 'my agent\n' > "$1/agents/my-agent.md"
  printf -- '- **API Token:** `not-a-real-token`\n' > "$1/.stride_auth.md"
}

# --- 1. piped stdin from a project with its own AGENTS.md and skills/ ----------

printf 'Piped install (curl | bash) from a look-alike project\n'
mkdir -p "$TMP/piped/project"
make_lookalike_project "$TMP/piped/project"
run_install piped piped
rc_is "piped: exits 0" 0
if grep -q 'unbound variable' "$C/err"; then no "piped: no 'unbound variable' message" "$(cat "$C/err")"; else ok "piped: no 'unbound variable' message"; fi
check "piped: the bundle is cloned (git clone ran once)" [ "$(git_calls)" = "1" ]
check "piped: /stridify command installed" [ -f "$P/.opencode/commands/stridify.md" ]
check "piped: /ideate command installed" [ -f "$P/.opencode/commands/ideate.md" ]
check "piped: the user's own skill is NOT copied" [ ! -e "$P/.opencode/skills/my-own-skill" ]
check "piped: the user's own agent is NOT copied" [ ! -e "$P/.opencode/agents/my-agent.md" ]
check "piped: the bundle's skill is installed" [ -f "$P/.opencode/skills/stride-ideation/SKILL.md" ]
check "piped: helpers land in .opencode/stride-ideation/lib" [ -x "$P/.opencode/stride-ideation/lib/filename.sh" ]
check "piped: fixtures land in .opencode/stride-ideation/fixtures" [ -n "$(ls "$P/.opencode/stride-ideation/fixtures")" ]
check "piped: nothing is written to the shared .opencode/lib" [ ! -e "$P/.opencode/lib" ]
check "piped: nothing is written to the shared .opencode/fixtures" [ ! -e "$P/.opencode/fixtures" ]
check "piped: the user's AGENTS.md text stays OUTSIDE the managed block" \
  [ "$(head -n 2 "$P/AGENTS.md")" = "$(printf '# My project notes\nKeep this line.')" ]
check "piped: the managed block is appended after the user's text" \
  [ "$(first_line_of "$P/AGENTS.md" "$BEGIN_MARKER")" -gt 2 ]
check "piped: .stride_auth.md is never copied" [ -z "$(find "$P/.opencode" -name '.stride_auth.md')" ]
CLONE_DEST="$(head -n 1 "$C/git.log.dest")"
check "piped: the clone went to a temp dir outside the project" [ "${CLONE_DEST#"$P"}" = "$CLONE_DEST" ]
check "piped: the clone temp dir is removed afterwards" [ ! -e "$(dirname "$CLONE_DEST")" ]

# --- 2. run from a local checkout -----------------------------------------------

printf '\nLocal install (./install.sh) into a fresh project\n'
run_install local local
rc_is "local: exits 0" 0
check "local: the checkout itself is the source (git never runs)" [ "$(git_calls)" = "0" ]
check "local: commands installed" [ -f "$P/.opencode/commands/stridify.md" ]
check "local: agents installed" [ -n "$(ls "$P/.opencode/agents/"*.md 2>/dev/null)" ]
check "local: helpers land in .opencode/stride-ideation/lib" [ -x "$P/.opencode/stride-ideation/lib/ship.sh" ]
check "local: fixtures stay a sibling of lib (../fixtures resolves)" \
  [ -d "$P/.opencode/stride-ideation/lib/../fixtures" ]
check "local: AGENTS.md is created starting with the managed block" \
  [ "$(first_line_of "$P/AGENTS.md" "$BEGIN_MARKER")" = "1" ]
check "local: the summary names the helper directory" grep -qF '.opencode/stride-ideation/lib/' "$C/out"
check "local: no legacy notice on a fresh install" [ -z "$(grep -F 'Note: an older install' "$C/out")" ]

# --- 3. re-install is idempotent and preserves user content ---------------------

printf '\nRe-install over an existing install\n'
printf '\nMy note after the block.\n' >> "$P/AGENTS.md"
cp "$P/AGENTS.md" "$C/agents-before"
(cd "$P" && PATH="$TMP/bin:$PATH" HOME="$H" FAKE_GIT_LOG="$C/git.log" FAKE_GIT_SRC="$BUNDLE" \
  bash "$INSTALL" > "$C/out2" 2> "$C/err2")
check "reinstall: exits 0" [ "$?" = "0" ]
check "reinstall: still exactly one BEGIN marker" [ "$(count_lines "$P/AGENTS.md" "$BEGIN_MARKER")" = "1" ]
check "reinstall: still exactly one END marker" [ "$(count_lines "$P/AGENTS.md" "$END_MARKER")" = "1" ]
check "reinstall: the user's note after the block survives" grep -qxF 'My note after the block.' "$P/AGENTS.md"
check "reinstall: AGENTS.md is byte-identical to before" cmp -s "$C/agents-before" "$P/AGENTS.md"

# --- 4. legacy flat helpers are left alone and named once -----------------------

printf '\nLegacy flat .opencode/lib from an older install\n'
mkdir -p "$TMP/legacy/project/.opencode/lib" "$TMP/legacy/project/.opencode/fixtures"
printf 'legacy copy\n' > "$TMP/legacy/project/.opencode/lib/filename.sh"
printf 'sibling bundle file\n' > "$TMP/legacy/project/.opencode/lib/sibling-bundle.sh"
run_install legacy local
rc_is "legacy: exits 0" 0
check "legacy: the old .opencode/lib/filename.sh is untouched" \
  [ "$(cat "$P/.opencode/lib/filename.sh")" = "legacy copy" ]
check "legacy: a sibling bundle's file is untouched" \
  [ "$(cat "$P/.opencode/lib/sibling-bundle.sh")" = "sibling bundle file" ]
check "legacy: one notice line is printed" [ "$(grep -c 'Note: an older install' "$C/out")" = "1" ]
check "legacy: the notice names the leftover file" grep -qF '.opencode/lib/filename.sh' "$C/out"
if grep -qF 'sibling-bundle.sh' "$C/out"; then no "legacy: the notice does not name another bundle's file"; else ok "legacy: the notice does not name another bundle's file"; fi
check "legacy: the new copy is in .opencode/stride-ideation/lib" \
  cmp -s "$BUNDLE/lib/filename.sh" "$P/.opencode/stride-ideation/lib/filename.sh"

# --- 5. global mode ------------------------------------------------------------

printf '\nGlobal install (--global) with HOME in a scratch dir\n'
run_install global local --global
rc_is "global: exits 0" 0
G="$H/.config/opencode"
check "global: commands under \$HOME/.config/opencode" [ -f "$G/commands/stridify.md" ]
check "global: helpers under \$HOME/.config/opencode/stride-ideation/lib" [ -x "$G/stride-ideation/lib/filename.sh" ]
check "global: fixtures under \$HOME/.config/opencode/stride-ideation/fixtures" [ -d "$G/stride-ideation/fixtures" ]
check "global: AGENTS.md at the config root" grep -qxF "$BEGIN_MARKER" "$G/AGENTS.md"
check "global: no .opencode/ in the current project" [ ! -e "$P/.opencode" ]
check "global: no AGENTS.md in the current project" [ ! -e "$P/AGENTS.md" ]

# --- 6. an orphaned BEGIN marker appends, never truncates -----------------------

printf '\nAGENTS.md with an orphaned BEGIN marker\n'
mkdir -p "$TMP/orphan/project"
printf 'Before.\n%s\nAfter the orphan.\n' "$BEGIN_MARKER" > "$TMP/orphan/project/AGENTS.md"
cp "$TMP/orphan/project/AGENTS.md" "$TMP/orphan/agents-before"
run_install orphan local
rc_is "orphan: exits 0" 0
check "orphan: the original content is kept as a prefix" \
  [ "$(head -n 3 "$P/AGENTS.md")" = "$(cat "$TMP/orphan/agents-before")" ]
check "orphan: the block is appended (END marker now present)" grep -qxF "$END_MARKER" "$P/AGENTS.md"

# --- 7. a clone that is not this bundle installs nothing ------------------------

printf '\nPiped install whose download is not the bundle\n'
mkdir -p "$TMP/notbundle-src/skills/x"
printf 'impostor\n' > "$TMP/notbundle-src/AGENTS.md"
FAKE_SRC="$TMP/notbundle-src" run_install notbundle piped
rc_is "not-bundle: exits 1" 1
check "not-bundle: says nothing was installed" grep -qF 'nothing was installed' "$C/err"
check "not-bundle: no .opencode directory is created" [ ! -e "$P/.opencode" ]
check "not-bundle: no AGENTS.md is written" [ ! -e "$P/AGENTS.md" ]

# --- summary -----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
