#!/usr/bin/env bash
# kbpkg - simple package manager for kbpkg.org projects
#
# To fork kbpkg for your own use, edit the CONFIGURATION block below.
# Codeberg and any Forgejo instance use identical API behaviour.
# GitHub uses a slightly different releases API — adapt _fetch_release()
# if you add GitHub as a binary source.

# --- CONFIGURATION ---

KBPKG_DIR="$HOME/.kbpkg"
STATE_FILE="$KBPKG_DIR/packages.json"

# Package sources — checked in order, first match wins.
# For Forgejo/Codeberg: "https://yourhost.org/yourorg"
# For GitHub: "https://github.com/yourorg"
SOURCES=(
  "https://codeberg.org/kbpkg"
  "https://git.benestad.net/kbpkg"
  "https://github.com/kbpkg"
)

# Location of kbpkg itself — update these if hosting your fork elsewhere.
KBPKG_VERSION="2026-06-08"
KBPKG_URL="https://codeberg.org/kbpkg/kbpkg/raw/branch/main/kbpkg.sh"
KBPKG_UPDATE_URL="https://codeberg.org/kbpkg/kbpkg/raw/branch/main/UPDATE"
KBPKG_SCRIPT="$KBPKG_DIR/kbpkg.sh"

# --- END CONFIGURATION ---

# --- progress helpers ---

_spinner() {
  local pid=$1 msg=$2
  local frames='|/-\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  %s %s" "${frames:$((i % 4)):1}" "$msg" >&2
    sleep 0.1
    i=$((i + 1))
  done
  printf "\r\033[K" >&2
}

_step() {
  local n=$1 total=$2 msg=$3
  printf "(%s/%s) %s\n" "$n" "$total" "$msg" >&2
}

_ok()   { printf "      done.\n" >&2; }
_fail() { printf "      failed.\n" >&2; }

# --- state file helpers ---

_init_state() {
  mkdir -p "$KBPKG_DIR"
  if [ ! -f "$STATE_FILE" ]; then
    echo '{"packages":[]}' > "$STATE_FILE"
  fi
}

_state_get() {
  # usage: _state_get LOCALNAME
  python3 -c "
import json, sys
data = json.load(open('$STATE_FILE'))
for p in data['packages']:
    if p['localname'] == sys.argv[1]:
        print(json.dumps(p))
        sys.exit(0)
" "$1"
}

_state_add() {
  # usage: _state_add NAME LOCALNAME VERSION TYPE SOURCE PATH
  python3 -c "
import json, sys
from datetime import datetime, timezone
data = json.load(open('$STATE_FILE'))
now = datetime.now(timezone.utc).isoformat()
data['packages'].append({
    'name': sys.argv[1],
    'localname': sys.argv[2],
    'version': sys.argv[3],
    'type': sys.argv[4],
    'source': sys.argv[5],
    'path': sys.argv[6],
    'installed': now,
    'updated': now
})
json.dump(data, open('$STATE_FILE','w'), indent=2)
" "$1" "$2" "$3" "$4" "$5" "$6"
}

_state_update_timestamp() {
  # usage: _state_update_timestamp LOCALNAME VERSION
  python3 -c "
import json, sys
from datetime import datetime, timezone
data = json.load(open('$STATE_FILE'))
now = datetime.now(timezone.utc).isoformat()
for p in data['packages']:
    if p['localname'] == sys.argv[1]:
        p['updated'] = now
        p['version'] = sys.argv[2]
json.dump(data, open('$STATE_FILE','w'), indent=2)
" "$1" "$2"
}

_state_update_version() {
  # usage: _state_update_version LOCALNAME VERSION PATH
  python3 -c "
import json, sys
from datetime import datetime, timezone
data = json.load(open('$STATE_FILE'))
now = datetime.now(timezone.utc).isoformat()
for p in data['packages']:
    if p['localname'] == sys.argv[1]:
        p['updated'] = now
        p['version'] = sys.argv[2]
        p['path'] = sys.argv[3]
json.dump(data, open('$STATE_FILE','w'), indent=2)
" "$1" "$2" "$3"
}

_state_remove() {
  # usage: _state_remove LOCALNAME
  python3 -c "
import json, sys
data = json.load(open('$STATE_FILE'))
data['packages'] = [p for p in data['packages'] if p['localname'] != sys.argv[1]]
json.dump(data, open('$STATE_FILE','w'), indent=2)
" "$1"
}

_get_version() {
  # read version from kbpkg.yml in a cloned repo path
  local path="$1"
  if [ -f "$path/kbpkg.yml" ]; then
    grep '^version:' "$path/kbpkg.yml" | awk '{print $2}' | tr -d '"'
  else
    echo "unknown"
  fi
}

_get_type() {
  local path="$1"
  if [ -f "$path/kbpkg.yml" ]; then
    grep '^type:' "$path/kbpkg.yml" | awk '{print $2}' | tr -d '"'
  else
    echo "web"
  fi
}


_get_major_version() {
  echo "$1" | cut -d. -f1
}

_get_breaking_changes() {
  local path="$1"
  if [ -f "$path/kbpkg.yml" ]; then
    grep '^breakingchanges:' "$path/kbpkg.yml" | awk '{print $2}' | tr -d '"'
  else
    echo "no"
  fi
}

_get_breaking_message() {
  local path="$1"
  if [ -f "$path/kbpkg.yml" ]; then
    grep '^breakingmessage:' "$path/kbpkg.yml" | sed 's/^breakingmessage: *//' | tr -d '"'
  else
    echo ""
  fi
}

_get_docs_url() {
  local path="$1"
  if [ -f "$path/kbpkg.yml" ]; then
    python3 -c "
import sys
try:
    for line in open('$path/kbpkg.yml'):
        line = line.strip()
        if line.startswith('docs:'):
            print(line.split(':', 1)[1].strip())
            break
except: pass
" 2>/dev/null
  fi
}

# --- source URL helpers ---

_parse_source_host() {
  echo "$1" | sed 's|https://||' | cut -d'/' -f1
}

_parse_source_org() {
  echo "$1" | sed 's|https://[^/]*/||'
}

# --- try cloning from source list ---

_try_clone() {
  local reponame="$1"
  local dest="$2"
  local tmp_err
  tmp_err=$(mktemp)
  for base in "${SOURCES[@]}"; do
    # Redirect stderr to temp file; on success replay it so git's live
    # progress (with \r rewrites) reaches the terminal via a subshell-safe path.
    # On failure discard it so "not found" noise from other sources is hidden.
    if git clone --progress "$base/$reponame.git" "$dest" 2>"$tmp_err"; then
      cat "$tmp_err" >&2
      rm -f "$tmp_err"
      echo "$base/$reponame"
      return 0
    fi
  done
  rm -f "$tmp_err"
  return 1
}


# --- platform detection and binary install ---

_detect_platform() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)

  case "$os" in
    linux)
      # Check for Debian/Ubuntu
      if command -v dpkg &>/dev/null && command -v apt &>/dev/null; then
        echo "linux-deb"
      else
        echo "linux"
      fi
      ;;
    darwin)
      echo "mac"
      ;;
    msys*|mingw*|cygwin*)
      echo "windows"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

_get_bin_url() {
  local yml_path="$1"
  local platform="$2"
  python3 -c "
import sys
platform = sys.argv[2]
yml = open(sys.argv[1]).read()
in_bin = False
for line in yml.splitlines():
    if line.strip() == 'bin:':
        in_bin = True
        continue
    if in_bin:
        if not line.startswith(' ') and not line.startswith('	'):
            break
        key, _, val = line.strip().partition(':')
        if key.strip() == platform:
            print(val.strip())
            break
" "$yml_path" "$platform" 2>/dev/null
}

_install_binary() {
  local repo_path="$1"
  local reponame="$2"
  local platform
  platform=$(_detect_platform)

  if [ "$platform" = "unknown" ]; then
    echo "Error: Unsupported platform." >&2
    return 1
  fi

  local bin_url
  # Try platform-specific first, fall back to linux if linux-deb not found
  bin_url=$(_get_bin_url "$repo_path/kbpkg.yml" "$platform")
  if [ -z "$bin_url" ] && [ "$platform" = "linux-deb" ]; then
    bin_url=$(_get_bin_url "$repo_path/kbpkg.yml" "linux")
    platform="linux"
  fi

  if [ -z "$bin_url" ]; then
    echo "Error: No binary entry found for platform '$platform' in kbpkg.yml. Check that the package has a 'bin:' section." >&2
    return 1
  fi

  local bin_path="$repo_path/$bin_url"
  if [ ! -f "$bin_path" ]; then
    echo "Error: Binary not found at '$bin_path'. The path in kbpkg.yml may be wrong." >&2
    return 1
  fi

  local install_dir
  case "$platform" in
    linux|linux-deb) install_dir="$HOME/.local/bin" ;;
    mac)             install_dir="/usr/local/bin" ;;
    windows)         install_dir="$USERPROFILE/AppData/Local/Microsoft/WindowsApps" ;;
  esac

  mkdir -p "$install_dir"

  local bin_name="$reponame"
  [ "$platform" = "windows" ] && bin_name="$reponame.exe"

  if [ "$platform" = "linux-deb" ] && [[ "$bin_path" == *.deb ]]; then
    printf "      Installing .deb package (requires sudo)..." >&2
    sudo dpkg -i "$bin_path" >/dev/null 2>&1 &
    _spinner $! "Installing .deb package..."
    wait $!
    if [ $? -ne 0 ]; then
      _fail
      echo "Error: dpkg -i failed." >&2
      return 1
    fi
    _ok
    local deb_bin
    for candidate in "/usr/bin/$bin_name" "/usr/local/bin/$bin_name" "$install_dir/$bin_name"; do
      if [ -x "$candidate" ]; then
        deb_bin="$candidate"
        break
      fi
    done
    if [ -z "$deb_bin" ]; then
      echo "Error: Could not locate installed binary after dpkg. Please check /usr/bin or /usr/local/bin." >&2
      return 1
    fi
    echo "$deb_bin"
    return 0
  fi

  printf "      Copying to %s..." "$install_dir/$bin_name" >&2
  cp "$bin_path" "$install_dir/$bin_name" &
  _spinner $! "Copying..."
  wait $!
  local cp_status=$?
  if [ $cp_status -ne 0 ]; then
    _fail
    echo "Error: Failed to copy binary to $install_dir/$bin_name (exit $cp_status). Check permissions." >&2
    return 1
  fi
  chmod +x "$install_dir/$bin_name"
  _ok

  # Mac quarantine flag
  if [ "$platform" = "mac" ]; then
    xattr -d com.apple.quarantine "$install_dir/$bin_name" 2>/dev/null || true
  fi

  echo "$install_dir/$bin_name"
}

# --- commands ---

cmd_install() {
  local reponame="$1"
  local localname="${2:-$reponame}"

  if [ -z "$reponame" ]; then
    echo "Usage: kbpkg install REPONAME [LOCALNAME]"
    return 1
  fi

  # Check if this repo name is already in state
  local existing existing_type
  existing=$(python3 -c "
import json, sys
data = json.load(open('$STATE_FILE'))
for p in data['packages']:
    if p['name'] == sys.argv[1]:
        print(p['localname'])
        break
" "$reponame")
  existing_type=$(python3 -c "
import json, sys
data = json.load(open('$STATE_FILE'))
for p in data['packages']:
    if p['name'] == sys.argv[1]:
        print(p.get('type', 'web'))
        break
" "$reponame")

  if [ -n "$existing" ]; then
    if [ "$existing_type" = "web" ]; then
      echo "You have already installed $reponame. You can run this app with 'kbpkg run $existing'."
      echo "Do you want to continue with installing a new instance in this folder and set a new local name, or abort?"
      echo ""
      printf "[A]bort / [C]ontinue and set new name: "
      read -r answer
      answer="${answer:-A}"
      if [ "$answer" != "C" ] && [ "$answer" != "c" ]; then
        echo "Aborted."
        return 0
      fi
      printf "Enter new local name: "
      read -r localname
      if [ -z "$localname" ]; then
        echo "No name entered. Aborted."
        return 1
      fi
    else
      echo "You have already installed $reponame. You can run this app with 'kbpkg run $existing'."
      echo "You can abort the installation and keep your current app, or update it from kbpkg."
      echo ""
      printf "[A]bort / [U]pdate: "
      read -r answer
      answer="${answer:-A}"
      if [ "$answer" = "U" ] || [ "$answer" = "u" ]; then
        cmd_update "$existing"
        return $?
      else
        echo "Aborted."
        return 0
      fi
    fi
  fi

  local dest="$(pwd)/$localname"

  if [ -d "$dest/.git" ]; then
    echo "Already installed at $dest. Use 'kbpkg update $localname' to update."
    return 1
  fi

  local version type total_steps=3
  local source

  _step 1 $total_steps "Fetching $reponame..."
  source=$(_try_clone "$reponame" "$dest")
  if [ $? -ne 0 ]; then
    echo "Error: Could not find '$reponame' in any source." >&2
    return 1
  fi

  version=$(_get_version "$dest")
  type=$(_get_type "$dest")
  _step 2 $total_steps "Detected: $type"

  if [ "$type" = "binary" ]; then
    _step 3 $total_steps "Installing binary..."
    local bin_install_path
    bin_install_path=$(_install_binary "$dest" "$reponame")
    if [ $? -ne 0 ]; then
      rm -rf "$dest"
      return 1
    fi
    rm -rf "$dest"
    _state_add "$reponame" "$reponame" "$version" "$type" "$source" "$bin_install_path"
    echo ""
    echo "Installed $reponame ($version) → $bin_install_path"
  else
    _step 3 $total_steps "Setting up in $dest..."
    _state_add "$reponame" "$localname" "$version" "$type" "$source" "$dest"
    echo ""
    echo "Installed $reponame ($version) → $dest"
  fi
}

cmd_update() {
  local localname="$1"
  local force="$2"

  if [ -z "$localname" ]; then
    # update all
    local skipped=()
    while read -r name; do
      cmd_update "$name" "$force"
      if [ $? -eq 2 ]; then
        skipped+=("$name")
      fi
    done < <(python3 -c "
import json
data = json.load(open('$STATE_FILE'))
for p in data['packages']:
    print(p['localname'])
")
    if [ ${#skipped[@]} -gt 0 ]; then
      echo ""
      echo "${#skipped[@]} package(s) skipped: ${skipped[*]}"
    fi
    return
  fi

  local entry
  entry=$(_state_get "$localname")
  if [ -z "$entry" ]; then
    echo "Error: '$localname' is not installed."
    return 1
  fi

  local path old_version pkg_type source
  path=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['path'])" "$entry")
  old_version=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['version'])" "$entry")
  pkg_type=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('type','web'))" "$entry")
  source=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['source'])" "$entry")

  if [ "$pkg_type" = "binary" ]; then
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local tmp_err
    tmp_err=$(mktemp)
    _step 1 3 "Fetching $localname..."
    if ! git clone --progress "$source.git" "$tmp_dir" 2>"$tmp_err"; then
      _fail
      echo "Error: Could not fetch '$localname' from $source." >&2
      rm -rf "$tmp_dir"; rm -f "$tmp_err"
      return 1
    fi
    sed 's/^/      /' "$tmp_err" >&2; rm -f "$tmp_err"

    local remote_yml
    remote_yml=$(cat "$tmp_dir/kbpkg.yml" 2>/dev/null)

    local new_version breaking_changes breaking_message docs_url
    new_version=$(echo "$remote_yml" | grep '^version:' | awk '{print $2}' | tr -d '"')
    breaking_changes=$(echo "$remote_yml" | grep '^breakingchanges:' | awk '{print $2}' | tr -d '"')
    breaking_message=$(echo "$remote_yml" | grep '^breakingmessage:' | sed 's/^breakingmessage: *//' | tr -d '"')
    docs_url=$(echo "$remote_yml" | grep '^\s*docs:' | sed 's/.*docs: *//' | tr -d '"')

    new_version="${new_version:-unknown}"
    breaking_changes="${breaking_changes:-no}"

    local warn=0 warn_type=""
    if [ "$breaking_changes" = "yes" ]; then
      warn=1; warn_type="breaking"
    elif [ "$old_version" != "unknown" ] && [ "$new_version" != "unknown" ]; then
      local old_major new_major
      old_major=$(_get_major_version "$old_version")
      new_major=$(_get_major_version "$new_version")
      if [ "$new_major" -gt "$old_major" ] 2>/dev/null; then
        warn=1; warn_type="major"
      fi
    fi

    if [ "$warn" -eq 1 ] && [ "$force" != "-y" ]; then
      echo ""
      if [ "$warn_type" = "breaking" ]; then
        echo "BREAKING CHANGES: $localname contains breaking changes."
        [ -n "$breaking_message" ] && echo "  $breaking_message"
      else
        echo "MAJOR UPDATE: $localname is updating from version $old_version to $new_version."
      fi
      [ -n "$docs_url" ] && echo "  Please consult the documentation at $docs_url before updating."
      echo ""
      printf "[A]bort / [U]pdate: "
      read -r answer
      answer="${answer:-A}"
      if [ "$answer" != "U" ] && [ "$answer" != "u" ]; then
        echo "Skipped $localname."
        rm -rf "$tmp_dir"
        return 2
      fi
    fi

    _step 2 3 "Checked: $old_version → $new_version"
    _step 3 3 "Installing binary..."
    local reponame
    reponame=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['name'])" "$entry")
    local new_bin_path
    new_bin_path=$(_install_binary "$tmp_dir" "$reponame")
    local install_status=$?
    rm -rf "$tmp_dir"
    if [ $install_status -ne 0 ]; then
      echo "Error: Failed to install updated binary." >&2
      return 1
    fi
    _state_update_version "$localname" "$new_version" "$new_bin_path"
    echo ""
    echo "Updated $localname ($new_version) → $new_bin_path"
    return 0
  fi

  if [ ! -d "$path/.git" ]; then
    echo "Error: '$localname' path not found at $path. Try 'kbpkg clean'." >&2
    return 1
  fi

  _step 1 3 "Fetching $localname..."
  local tmp_err
  tmp_err=$(mktemp)
  git -C "$path" fetch --progress 2>"$tmp_err"
  sed 's/^/      /' "$tmp_err" >&2; rm -f "$tmp_err"

  # Read incoming kbpkg.yml from remote to check flags before pulling
  local remote_yml
  remote_yml=$(git -C "$path" show FETCH_HEAD:kbpkg.yml 2>/dev/null)

  local new_version breaking_changes breaking_message docs_url
  new_version=$(echo "$remote_yml" | grep '^version:' | awk '{print $2}' | tr -d '"')
  breaking_changes=$(echo "$remote_yml" | grep '^breakingchanges:' | awk '{print $2}' | tr -d '"')
  breaking_message=$(echo "$remote_yml" | grep '^breakingmessage:' | sed 's/^breakingmessage: *//' | tr -d '"')
  docs_url=$(echo "$remote_yml" | grep '^\s*docs:' | sed 's/.*docs: *//' | tr -d '"')

  new_version="${new_version:-unknown}"
  breaking_changes="${breaking_changes:-no}"

  # Determine if warning needed
  local warn=0
  local warn_type=""
  if [ "$breaking_changes" = "yes" ]; then
    warn=1
    warn_type="breaking"
  elif [ "$old_version" != "unknown" ] && [ "$new_version" != "unknown" ]; then
    local old_major new_major
    old_major=$(_get_major_version "$old_version")
    new_major=$(_get_major_version "$new_version")
    if [ "$new_major" -gt "$old_major" ] 2>/dev/null; then
      warn=1
      warn_type="major"
    fi
  fi

  if [ "$warn" -eq 1 ] && [ "$force" != "-y" ]; then
    echo ""
    if [ "$warn_type" = "breaking" ]; then
      echo "BREAKING CHANGES: $localname contains breaking changes."
      [ -n "$breaking_message" ] && echo "  $breaking_message"
    else
      echo "MAJOR UPDATE: $localname is updating from version $old_version to $new_version."
    fi
    [ -n "$docs_url" ] && echo "  Please consult the documentation at $docs_url before updating."
    echo ""
    printf "[A]bort / [U]pdate: "
    read -r answer
    answer="${answer:-A}"
    if [ "$answer" != "U" ] && [ "$answer" != "u" ]; then
      echo "Skipped $localname."
      return 2
    fi
  fi

  _step 2 3 "Checked: $old_version → $new_version"
  _step 3 3 "Applying update..."
  git -C "$path" merge --quiet FETCH_HEAD &
  _spinner $! "Merging..."
  wait $!
  _ok
  local version
  version=$(_get_version "$path")
  _state_update_timestamp "$localname" "$version"
  echo ""
  echo "Updated $localname ($version)"
}

cmd_run() {
  local localname="$1"

  if [ -z "$localname" ]; then
    echo "Usage: kbpkg run LOCALNAME"
    return 1
  fi

  local entry
  entry=$(_state_get "$localname")
  if [ -z "$entry" ]; then
    echo "Error: '$localname' is not installed."
    return 1
  fi

  local path
  path=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['path'])" "$entry")

  if [ ! -d "$path" ]; then
    echo "Error: Path not found at $path. Try 'kbpkg clean'."
    return 1
  fi

  echo "Starting server for $localname at http://localhost:8000"
  (
    sleep 1
    if command -v xdg-open &>/dev/null; then
      xdg-open http://localhost:8000
    elif command -v open &>/dev/null; then
      open http://localhost:8000
    fi
  ) &
  python3 -m http.server 8000 --directory "$path"
}

_fetch_latest_version() {
  local pkg_type="$1"
  local path="$2"
  local source="$3"
  local remote_yml=""

  if [ "$pkg_type" = "binary" ]; then
    local host
    host=$(echo "$source" | sed 's|https://||' | cut -d'/' -f1)
    if echo "$host" | grep -q "github.com"; then
      local slug
      slug=$(echo "$source" | sed 's|https://github.com/||')
      remote_yml=$(curl -fsSL "https://raw.githubusercontent.com/$slug/main/kbpkg.yml" 2>/dev/null)
      [ -z "$remote_yml" ] && remote_yml=$(curl -fsSL "https://raw.githubusercontent.com/$slug/master/kbpkg.yml" 2>/dev/null)
    else
      remote_yml=$(curl -fsSL "$source/raw/branch/main/kbpkg.yml" 2>/dev/null)
      [ -z "$remote_yml" ] && remote_yml=$(curl -fsSL "$source/raw/branch/master/kbpkg.yml" 2>/dev/null)
    fi
  else
    if [ -d "$path/.git" ]; then
      git -C "$path" fetch --quiet 2>/dev/null
      remote_yml=$(git -C "$path" show FETCH_HEAD:kbpkg.yml 2>/dev/null)
    fi
  fi

  echo "$remote_yml" | grep '^version:' | awk '{print $2}' | tr -d '"'
}

cmd_list() {
  _check_version

  local pkgs
  pkgs=$(python3 -c "
import json, sys
data = json.load(open('$STATE_FILE'))
if not data['packages']:
    sys.exit(1)
for p in data['packages']:
    print(p['localname'], p.get('type','web'), p['path'], p['source'])
" 2>/dev/null)
  if [ $? -ne 0 ]; then
    echo "No packages installed."
    return
  fi

  echo "Checking for updates..." >&2

  # Build latest version map: localname=version pairs, newline-separated
  local latest_pairs=""
  while IFS=' ' read -r localname pkg_type path source; do
    local latest
    latest=$(_fetch_latest_version "$pkg_type" "$path" "$source")
    latest_pairs+="$localname=${latest:-unknown}"$'\n'
  done <<< "$pkgs"

  python3 -c "
import json, sys

state   = json.load(open('$STATE_FILE'))
pkgs    = state['packages']

# Parse latest_pairs passed via argv[1]: 'localname=version\n...'
latest_map = {}
for line in sys.argv[1].splitlines():
    if '=' in line:
        k, _, v = line.partition('=')
        latest_map[k] = v

fmt = '{:<20} {:<12} {:<12} {:<14} {:<10} {}'
print(fmt.format('NAME', 'LOCALNAME', 'INSTALLED', 'LATEST', 'TYPE', 'PATH'))
print('-' * 96)

outdated = 0
for p in pkgs:
    name      = p['name']
    localname = p['localname']
    installed = p['version']
    pkg_type  = p.get('type', 'web')
    path      = p['path']
    latest    = latest_map.get(localname, 'unknown')
    marker    = ''
    if latest not in ('unknown', '') and latest != installed:
        marker   = ' *'
        outdated = 1
    print(fmt.format(name, localname, installed, latest + marker, pkg_type, path))

if outdated:
    print()
    print(\"You have one or more outdated packages. Run \\\`kbpkg update\\\` to update.\")
" "$latest_pairs"
}

cmd_remove() {
  local localname="$1"
  local force="$2"

  if [ -z "$localname" ]; then
    echo "Usage: kbpkg remove REPONAME [-y]"
    return 1
  fi

  local entry
  entry=$(_state_get "$localname")
  if [ -z "$entry" ]; then
    echo "Error: '$localname' is not installed."
    return 1
  fi

  local path pkg_type
  path=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['path'])" "$entry")
  pkg_type=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('type','web'))" "$entry")

  if [ "$force" != "-y" ]; then
    if [ "$pkg_type" = "binary" ]; then
      echo "Warning: This will permanently delete the binary at $path"
    else
      echo "Warning: This will permanently delete $path"
    fi
    printf "Are you sure? [y/N] "
    read -r answer
    if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
      echo "Cancelled."
      return 0
    fi
  fi

  _step 1 2 "Removing files..."
  if [ "$pkg_type" = "binary" ]; then
    rm -f "$path" &
  else
    rm -rf "$path" &
  fi
  _spinner $! "Removing..."
  wait $!
  _ok
  _step 2 2 "Updating state..."
  _state_remove "$localname"
  echo ""
  echo "Removed $localname."
}

cmd_clean() {
  python3 -c "
import json, os
data = json.load(open('$STATE_FILE'))
before = len(data['packages'])
def is_valid(p):
    pkg_type = p.get('type', 'web')
    if pkg_type == 'binary':
        return os.path.isfile(p['path'])
    return os.path.isdir(os.path.join(p['path'], '.git'))
data['packages'] = [p for p in data['packages'] if is_valid(p)]
after = len(data['packages'])
json.dump(data, open('$STATE_FILE','w'), indent=2)
removed = before - after
if removed:
    print(f'Removed {removed} stale entry/entries from state.')
else:
    print('Nothing to clean.')
"
}

cmd_upgrade() {
  _check_version
  echo "Upgrading kbpkg..."
  local tmp
  tmp=$(mktemp)
  if ! curl -fsSL "$KBPKG_URL" -o "$tmp"; then
    echo "Error: Could not download update. Check your internet connection."
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$KBPKG_SCRIPT"
  chmod +x "$KBPKG_SCRIPT"
  echo "kbpkg upgraded. Open a new terminal to use the updated version."
}

cmd_uninstall() {
  echo "This will remove kbpkg entirely:"
  echo "  - $KBPKG_DIR (state file and kbpkg script)"
  echo "  - kbpkg lines from $HOME/.bashrc"
  echo ""
  echo "Your installed packages will not be deleted."
  printf "Proceed? [Y]es/[N]o "
  read -r answer
  answer="${answer:-Y}"
  if [ "$answer" != "Y" ] && [ "$answer" != "y" ]; then
    echo "Cancelled."
    return 0
  fi

  rm -rf "$KBPKG_DIR"

  local tmp
  tmp=$(mktemp)
  grep -v '# kbpkg' "$HOME/.bashrc" | grep -v 'kbpkg.sh' > "$tmp"
  mv "$tmp" "$HOME/.bashrc"

  echo "kbpkg removed. Open a new terminal to complete uninstall."
}

cmd_packages() {
  local found=0
  for source in "${SOURCES[@]}"; do
    local host org repos_json
    host=$(_parse_source_host "$source")
    org=$(_parse_source_org "$source")

    if [ "$host" = "github.com" ]; then
      repos_json=$(curl -fsSL "https://api.github.com/orgs/$org/repos?per_page=100" 2>/dev/null)
    else
      repos_json=$(curl -fsSL "https://$host/api/v1/orgs/$org/repos?limit=50" 2>/dev/null)
    fi

    [ -z "$repos_json" ] && continue

    local output
    output=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    if not isinstance(data, list) or not data:
        sys.exit(1)
    fmt = '{:<25} {}'
    print(fmt.format('NAME', 'DESCRIPTION'))
    print('-' * 70)
    for r in sorted(data, key=lambda x: x.get('name', '')):
        name = r.get('name', '')
        desc = r.get('description', '') or ''
        if name:
            print(fmt.format(name, desc))
except Exception:
    sys.exit(1)
" "$repos_json" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$output" ]; then
      echo "Available packages from $source:"
      echo ""
      echo "$output"
      found=1
      break
    fi
  done

  if [ "$found" -eq 0 ]; then
    echo "Error: Could not retrieve package list. Check your internet connection."
    return 1
  fi
}

cmd_details() {
  local reponame="$1"

  if [ -z "$reponame" ]; then
    echo "Usage: kbpkg details REPONAME"
    return 1
  fi

  local found=0
  for source in "${SOURCES[@]}"; do
    local host org repo_json kbpkg_raw
    host=$(_parse_source_host "$source")
    org=$(_parse_source_org "$source")

    if [ "$host" = "github.com" ]; then
      repo_json=$(curl -fsSL "https://api.github.com/repos/$org/$reponame" 2>/dev/null)
      kbpkg_raw=$(curl -fsSL "https://raw.githubusercontent.com/$org/$reponame/main/kbpkg.yml" 2>/dev/null)
    else
      repo_json=$(curl -fsSL "https://$host/api/v1/repos/$org/$reponame" 2>/dev/null)
      kbpkg_raw=$(curl -fsSL "https://$host/$org/$reponame/raw/branch/main/kbpkg.yml" 2>/dev/null)
    fi

    local valid
    valid=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print('yes' if 'name' in d else 'no')
except:
    print('no')
" "$repo_json" 2>/dev/null)

    [ "$valid" != "yes" ] && continue

    found=1

    python3 -c "
import json, sys
d = json.loads(sys.argv[1])
name      = d.get('name', '')
desc      = d.get('description', '') or '(none)'
stars     = d.get('stars_count', d.get('stargazers_count', 0))
forks     = d.get('forks_count', 0)
updated   = (d.get('updated', '') or d.get('updated_at', ''))[:10]
clone_url = d.get('clone_url', '')
topics    = d.get('topics', [])
print(f'Name:         {name}')
print(f'Description:  {desc}')
print(f'Stars:        {stars}')
print(f'Forks:        {forks}')
print(f'Last updated: {updated}')
print(f'Clone URL:    {clone_url}')
if topics:
    print(f'Topics:       {\", \".join(topics)}')
" "$repo_json"

    if [ -n "$kbpkg_raw" ] && echo "$kbpkg_raw" | grep -q '^version:'; then
      echo ""
      echo "Package info:"
      local version type docs breaking
      version=$(echo "$kbpkg_raw" | grep '^version:'          | awk '{print $2}'           | tr -d '"')
      type=$(echo    "$kbpkg_raw" | grep '^type:'             | awk '{print $2}'           | tr -d '"')
      docs=$(echo    "$kbpkg_raw" | grep '^docs:'             | sed 's/^docs: *//'         | tr -d '"')
      breaking=$(echo "$kbpkg_raw" | grep '^breakingchanges:' | awk '{print $2}'           | tr -d '"')
      [ -n "$version"  ]                          && echo "  Version:  $version"
      [ -n "$type"     ]                          && echo "  Type:     $type"
      [ -n "$docs"     ]                          && echo "  Docs:     $docs"
      [ -n "$breaking" ] && [ "$breaking" != "no" ] && echo "  Breaking changes flagged"
    fi

    echo ""
    local installed_entry
    installed_entry=$(python3 -c "
import json, sys
data = json.load(open('$STATE_FILE'))
for p in data['packages']:
    if p['name'] == sys.argv[1]:
        print(json.dumps(p))
        break
" "$reponame" 2>/dev/null)

    if [ -n "$installed_entry" ]; then
      local inst_version inst_localname inst_path
      inst_version=$(python3  -c "import json,sys; print(json.loads(sys.argv[1]).get('version',''))"   "$installed_entry")
      inst_localname=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('localname',''))" "$installed_entry")
      inst_path=$(python3     -c "import json,sys; print(json.loads(sys.argv[1]).get('path',''))"      "$installed_entry")
      echo "Installed:    yes — $inst_localname v$inst_version at $inst_path"
    else
      echo "Installed:    no"
    fi

    break
  done

  if [ "$found" -eq 0 ]; then
    echo "Error: Could not find '$reponame' in any source."
    return 1
  fi
}

_check_version() {
  local remote
  remote=$(curl -fsSL "$KBPKG_UPDATE_URL" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$remote" ]; then
    return 0
  fi
  if [ "$remote" \> "$KBPKG_VERSION" ]; then
    echo "Your version of kbpkg is outdated. Please run 'kbpkg upgrade' for the latest version."
    echo ""
  fi
}

# --- main ---

kbpkg() {
  _init_state
  local cmd="$1"
  shift
  case "$cmd" in
    install)  cmd_install "$@" ;;
    update)   cmd_update "$@" ;;
    run)      cmd_run "$@" ;;
    list)     cmd_list ;;
    remove)   cmd_remove "$@" ;;
    clean)    cmd_clean ;;
    upgrade)  cmd_upgrade ;;
    uninstall) cmd_uninstall ;;
    packages) cmd_packages ;;
    details)  cmd_details "$@" ;;
    *)
      _check_version
      echo "kbpkg - package manager"
      echo ""
      echo "Commands:"
      echo "  install REPONAME [LOCALNAME]  Install a package"
      echo "  update [LOCALNAME] [-y]       Update one or all packages (skip warnings with -y)"
      echo "  run LOCALNAME                 Run a web package locally"
      echo "  list                          List installed packages"
      echo "  remove LOCALNAME [-y]         Remove a package"
      echo "  clean                         Remove stale state entries"
      echo "  upgrade                       Upgrade kbpkg to the latest version"
      echo "  uninstall                     Remove kbpkg from this machine"
      echo "  packages                      List all available packages from sources"
      echo "  details REPONAME              Show metadata for a package"
      ;;
  esac
}
