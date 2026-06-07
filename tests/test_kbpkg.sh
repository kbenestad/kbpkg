#!/usr/bin/env bash
# kbpkg test suite — run with: bash tests/test_kbpkg.sh

set -euo pipefail

PASS=0
FAIL=0
ERRORS=()

_pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
_fail() { echo "  FAIL  $1"; ERRORS+=("$1"); FAIL=$((FAIL+1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    _pass "$desc"
  else
    _fail "$desc (expected='$expected' got='$actual')"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    _pass "$desc"
  else
    _fail "$desc (looking for '$needle' in '$haystack')"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    _pass "$desc"
  else
    _fail "$desc (did NOT want '$needle' in output)"
  fi
}

# ── Set up isolated environment ──────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
mkdir -p "$HOME"

KBPKG_DIR="$TMPDIR/kbpkg_state"
STATE_FILE="$KBPKG_DIR/packages.json"
export KBPKG_STATE="$STATE_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../kbpkg.sh
source "$SCRIPT_DIR/../kbpkg.sh"

# Re-export with test paths
KBPKG_DIR="$TMPDIR/kbpkg_state"
STATE_FILE="$KBPKG_DIR/packages.json"
export KBPKG_STATE="$STATE_FILE"
_init_state

# ── Helpers ───────────────────────────────────────────────────────────────────

_add_test_package() {
  # _add_test_package NAME LOCALNAME VERSION TYPE LOCKED
  local name="$1" localname="$2" version="$3" type="${4:-web}" locked="${5:-false}"
  local fake_path="$TMPDIR/pkg_${localname}"
  mkdir -p "$fake_path/.git"
  _state_add "$name" "$localname" "$version" "$type" "https://example.com/$name" "$fake_path"
  if [ "$locked" = "true" ]; then
    _state_set_locked "$localname" true
  fi
}

# ── Tests: _init_state ────────────────────────────────────────────────────────
echo ""
echo "=== _init_state ==="

assert_eq "state file created" "0" "$([ -f "$STATE_FILE" ] && echo 0 || echo 1)"
assert_contains "state file valid JSON" '"packages"' "$(cat "$STATE_FILE")"

# ── Tests: _state_add and _state_get ─────────────────────────────────────────
echo ""
echo "=== _state_add / _state_get ==="

_add_test_package "myapp" "myapp" "1.0.0"
entry=$(_state_get "myapp")

assert_eq "get name"    "myapp" "$(echo "$entry" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")"
assert_eq "get version" "1.0.0" "$(echo "$entry" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['version'])")"
assert_eq "get type"    "web"   "$(echo "$entry" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['type'])")"
assert_eq "locked default false" "False" "$(echo "$entry" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('locked',False))")"

# JSON safety: special characters in values
_add_test_package 'quote"pkg' 'quotepkg' '2.0.0'
entry2=$(_state_get "quotepkg")
assert_eq "name with quotes stored safely" 'quote"pkg' \
  "$(echo "$entry2" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")"

_add_test_package 'backslash\pkg' "bspkg" "1.0.0"
entry3=$(_state_get "bspkg")
assert_eq "name with backslash stored safely" 'backslash\pkg' \
  "$(echo "$entry3" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['name'])")"

# ── Tests: _state_update_timestamp ───────────────────────────────────────────
echo ""
echo "=== _state_update_timestamp ==="

_state_update_timestamp "myapp" "1.1.0"
entry=$(_state_get "myapp")
assert_eq "version bumped" "1.1.0" \
  "$(echo "$entry" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['version'])")"

# ── Tests: _state_set_locked ─────────────────────────────────────────────────
echo ""
echo "=== _state_set_locked / cmd_removeupdateflag ==="

_state_set_locked "myapp" true
entry=$(_state_get "myapp")
assert_eq "locked set to true" "True" \
  "$(echo "$entry" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('locked'))")"

_state_set_locked "myapp" false
entry=$(_state_get "myapp")
assert_eq "locked set back to false" "False" \
  "$(echo "$entry" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('locked'))")"

# ── Tests: _state_remove ──────────────────────────────────────────────────────
echo ""
echo "=== _state_remove ==="

_add_test_package "removeme" "removeme" "0.1.0"
_state_remove "removeme"
entry=$(_state_get "removeme")
assert_eq "entry gone after remove" "" "$entry"

# ── Tests: cmd_list output ────────────────────────────────────────────────────
echo ""
echo "=== cmd_list ==="

echo '{"packages":[]}' > "$STATE_FILE"
_add_test_package "alpha" "alpha" "1.0.0" "web" "false"
_add_test_package "beta"  "beta"  "2.0.0" "web" "false"

# Suppress network calls
_check_version() { :; }
_fetch_latest_version() { echo "unknown"; }

list_out=$(cmd_list)

assert_contains "list shows INSTALLED header" "INSTALLED" "$list_out"
assert_contains "list shows LATEST header"    "LATEST"    "$list_out"
assert_contains "alpha in list"               "alpha"     "$list_out"
assert_contains "beta in list"                "beta"      "$list_out"
assert_contains "version shown"               "1.0.0"     "$list_out"

# ── Tests: _get_version / _get_type from kbpkg.yml ───────────────────────────
echo ""
echo "=== _get_version / _get_type ==="

PKG_DIR="$TMPDIR/fake_pkg"
mkdir -p "$PKG_DIR"
cat > "$PKG_DIR/kbpkg.yml" <<'EOF'
name: fakepkg
version: 3.2.1
type: binary
breakingchanges: yes
breakingmessage: "Please re-configure."
urls:
  docs: https://docs.example.com
EOF

assert_eq "get version from yml" "3.2.1"  "$(_get_version  "$PKG_DIR")"
assert_eq "get type from yml"    "binary" "$(_get_type     "$PKG_DIR")"
assert_eq "breaking changes"     "yes"    "$(_get_breaking_changes "$PKG_DIR")"
assert_eq "breaking message"     "Please re-configure." "$(_get_breaking_message "$PKG_DIR")"

docs=$(_get_docs_url "$PKG_DIR")
assert_eq "docs url" "https://docs.example.com" "$docs"

assert_eq "unknown version when no yml" "unknown" "$(_get_version "$TMPDIR/nonexistent")"

# ── Tests: _detect_platform ───────────────────────────────────────────────────
echo ""
echo "=== _detect_platform ==="

platform=$(_detect_platform)
assert_eq           "platform not empty"   "1" "$([ -n "$platform" ] && echo 1 || echo 0)"
assert_not_contains "platform not unknown" "unknown" "$platform"

# Verify platform matches known arch-aware format (os[-deb]-arch)
valid_platforms="linux-amd64 linux-deb-amd64 linux-arm64 linux-deb-arm64 linux-386 linux-deb-386 mac-amd64 mac-arm64 windows-amd64"
found=0
for p in $valid_platforms; do
  [ "$p" = "$platform" ] && found=1 && break
done
assert_eq "detected platform is a known value" "1" "$found"

# ── Tests: cmd_run port argument parsing ──────────────────────────────────────
echo ""
echo "=== cmd_run port parsing ==="

run_err=$(cmd_run --port 9999 nonexistent 2>&1 || true)
assert_contains "run unknown package errors correctly" "not installed" "$run_err"

run_err2=$(cmd_run -p 9998 nonexistent 2>&1 || true)
assert_contains "run -p short flag works" "not installed" "$run_err2"

run_err3=$(cmd_run 2>&1 || true)
assert_contains "run with no args shows usage" "Usage:" "$run_err3"

# ── Tests: cmd_removeupdateflag ───────────────────────────────────────────────
echo ""
echo "=== cmd_removeupdateflag ==="

echo '{"packages":[]}' > "$STATE_FILE"
_add_test_package "locktest" "locktest" "1.0.0" "web" "true"

locked_before=$(python3 -c "
import json, os
data = json.load(open(os.environ['KBPKG_STATE']))
for p in data['packages']:
    if p['localname'] == 'locktest':
        print(p.get('locked', False))
")
assert_eq "package starts locked" "True" "$locked_before"

cmd_removeupdateflag "locktest" > /dev/null
locked_after=$(python3 -c "
import json, os
data = json.load(open(os.environ['KBPKG_STATE']))
for p in data['packages']:
    if p['localname'] == 'locktest':
        print(p.get('locked', False))
")
assert_eq "locked cleared by removeupdateflag" "False" "$locked_after"

rflag_err=$(cmd_removeupdateflag "doesnotexist" 2>&1 || true)
assert_contains "removeupdateflag unknown package" "not installed" "$rflag_err"

# ── Tests: _get_major_version ─────────────────────────────────────────────────
echo ""
echo "=== _get_major_version ==="

assert_eq "major from 1.2.3"  "1"  "$(_get_major_version "1.2.3")"
assert_eq "major from 10.0.0" "10" "$(_get_major_version "10.0.0")"
assert_eq "major from 0.9.1"  "0"  "$(_get_major_version "0.9.1")"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
if [ ${#ERRORS[@]} -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
  echo ""
  exit 1
fi
echo "All tests passed."
echo "========================================"
