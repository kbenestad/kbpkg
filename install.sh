#!/usr/bin/env bash
# kbpkg installer
# Usage: curl -fsSL https://raw.codeberg.page/kbpkg/kbpkg/main/install.sh | bash

set -e

# --- dependency check ---

_detect_install_cmd() {
  if command -v apt &>/dev/null; then
    echo "sudo apt install git python3"
  elif command -v dnf &>/dev/null; then
    echo "sudo dnf install git python3"
  elif command -v brew &>/dev/null; then
    echo "xcode-select --install"
  else
    echo ""
  fi
}

_check_dependencies() {
  local missing=0
  command -v git &>/dev/null || missing=1
  command -v python3 &>/dev/null || missing=1

  if [ "$missing" -eq 1 ]; then
    local install_cmd
    install_cmd=$(_detect_install_cmd)

    if [ -z "$install_cmd" ]; then
      echo "Required dependencies (Python and/or Git) are missing."
      echo "Could not detect a package manager. Please install Git and Python manually."
      exit 1
    fi

    echo "Required dependencies (Python and/or Git) are missing. To continue, kbpkg must run:"
    echo "  $install_cmd"
    echo ""
    echo "You need the root (administrator) password to continue."
    printf "Proceed? [Y]es/[N]o "
    read -r answer
    answer="${answer:-Y}"
    if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
      eval "$install_cmd"
    else
      echo ""
      echo "Python and Git are required dependencies to use kbpkg. To use kbpkg, please contact your administrator and ensure that the above dependencies are met before installing kbpkg again."
      exit 0
    fi
  fi
}

_check_dependencies

KBPKG_URL="https://codeberg.org/kbpkg/kbpkg/raw/branch/main/kbpkg.sh"
KBPKG_DIR="$HOME/.kbpkg"
KBPKG_SCRIPT="$KBPKG_DIR/kbpkg.sh"
BASHRC="$HOME/.bashrc"

echo "Installing kbpkg..."

mkdir -p "$KBPKG_DIR"

if ! curl -fsSL "$KBPKG_URL" -o "$KBPKG_SCRIPT"; then
  echo "Error: Could not download kbpkg. Check your internet connection."
  exit 1
fi

chmod +x "$KBPKG_SCRIPT"

# Check if already sourced
if grep -q 'kbpkg.sh' "$BASHRC" 2>/dev/null; then
  echo "kbpkg already in $BASHRC, skipping."
else
  echo "" >> "$BASHRC"
  echo "# kbpkg" >> "$BASHRC"
  echo "source $KBPKG_SCRIPT" >> "$BASHRC"
  echo "Added kbpkg to $BASHRC"
fi

echo ""
echo "Done. Open a new terminal or run:"
echo "  source ~/.bashrc"
echo ""
echo "Then try:"
echo "  kbpkg install mdcms"