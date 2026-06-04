# kbpkg

A lightweight CLI package manager for deploying and running web projects from the [kbpkg](https://codeberg.org/kbpkg) ecosystem.

## Requirements

- `git`
- `python3`

The installer will offer to install these automatically if they are missing.

## Install

```bash
curl -fsSL https://codeberg.org/kbpkg/kbpkg/raw/branch/main/install.sh | bash
```

Then reload your shell:

```bash
source ~/.bashrc
```

## Usage

```bash
kbpkg install REPONAME [LOCALNAME]   # Clone a package into the current directory
kbpkg update [LOCALNAME]             # Update one or all packages
kbpkg run LOCALNAME                  # Serve a web package locally and open browser
kbpkg list                           # List installed packages
kbpkg remove LOCALNAME [-y]          # Remove a package
kbpkg clean                          # Remove stale entries from state
```

## Example

Create your project directory and open your terminal in this folder (in most file browsers you should right-click and select `Open in terminal`). Then install your package:
```
kbpkg install clubledger myprojectname
```

Then run with:

```
kbpkg run myprojectname
```

## Packages

Browse available packages at [codeberg.org/kbpkg](https://codeberg.org/kbpkg).