#!/usr/bin/env bash
#
# install-raptor-tools.sh
#
# Installs the external tools RAPTOR reports as missing, each via the pathway
# that actually makes sense for it:
#
#   apt      -> gdb, rr, afl++, coccinelle
#   pip      -> semgrep, frida-tools (frida + frida-trace), tree-sitter
#   download -> codeql, jadx   (GitHub release tarballs, latest resolved live)
#
# Safe to re-run: every step checks whether the tool is already present first.
#
# User-space installs (pip, codeql, jadx) go under ~/.local so no root is
# needed for them. Only the apt step uses sudo.

set -uo pipefail

# ---- config ---------------------------------------------------------------
PREFIX="${PREFIX:-$HOME/.local}"
OPT_DIR="$PREFIX/opt"
BIN_DIR="$PREFIX/bin"

mkdir -p "$OPT_DIR" "$BIN_DIR"

# ---- pretty output --------------------------------------------------------
c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'
say()  { printf '%s==>%s %s\n' "$c_bold" "$c_reset" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_reset" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_yel" "$c_reset" "$*"; }
err()  { printf '  %s✗%s %s\n' "$c_red" "$c_reset" "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

RESULTS=()
record() { RESULTS+=("$1"); }

# ---- 1. apt tools ---------------------------------------------------------
install_apt() {
  say "apt packages: gdb, rr, afl++, coccinelle, unzip, default-jre"
  # unzip is needed to extract jadx; default-jre is jadx's runtime.
  local want=(gdb rr afl++ coccinelle unzip default-jre) missing=()
  for p in "${want[@]}"; do
    # map package name -> a binary to probe
    case "$p" in
      afl++)       have afl-fuzz && { ok "afl++ already present"; continue; } ;;
      default-jre) have java     && { ok "java already present";  continue; } ;;
      *)           have "$p"     && { ok "$p already present";    continue; } ;;
    esac
    missing+=("$p")
  done

  if [ ${#missing[@]} -eq 0 ]; then
    record "apt: nothing to do"
    return
  fi

  if ! have sudo; then
    err "sudo not found; run as root: apt install -y ${missing[*]}"
    record "apt: SKIPPED (no sudo) -> ${missing[*]}"
    return
  fi

  say "installing: ${missing[*]}  (needs sudo)"
  if sudo apt-get update && sudo apt-get install -y "${missing[@]}"; then
    ok "apt install complete"
    record "apt: installed ${missing[*]}"
  else
    err "apt install failed"
    record "apt: FAILED -> ${missing[*]}"
  fi
}

# ---- 2. pip tools ---------------------------------------------------------
# Install into the active virtualenv if one is set (RAPTOR runs inside
# $VIRTUAL_ENV, e.g. /home/debian/raptor-venv). Only outside a venv do we
# fall back to a --user install, since --user is rejected inside a venv.
pip_install() {
  if [ -n "${VIRTUAL_ENV:-}" ]; then
    python3 -m pip install --upgrade "$@"
  else
    python3 -m pip install --user --upgrade "$@"
  fi
}

install_semgrep() {
  say "semgrep via pip"
  if [ -n "${VIRTUAL_ENV:-}" ]; then say "target venv: $VIRTUAL_ENV"; fi
  if have semgrep; then
    ok "semgrep already present"; record "semgrep: already present"; return
  fi
  if pip_install semgrep; then
    ok "semgrep installed"; record "semgrep: installed"
  else
    err "semgrep install failed"
    record "semgrep: FAILED"
  fi
}

install_frida() {
  say "frida-tools (frida, frida-trace) via pip"
  if [ -n "${VIRTUAL_ENV:-}" ]; then say "target venv: $VIRTUAL_ENV"; fi
  if have frida && have frida-trace; then
    ok "frida already present"; record "frida: already present"; return
  fi
  if pip_install frida-tools; then
    ok "frida-tools installed"; record "frida: installed"
  else
    err "frida-tools install failed (needs build-essential python3-dev for a source build)"
    record "frida: FAILED"
  fi
}

install_treesitter() {
  say "tree-sitter python bindings via pip"
  if python3 -c 'import tree_sitter' 2>/dev/null; then
    ok "tree_sitter already importable"; record "tree-sitter: already present"; return
  fi
  # tree_sitter_languages is unmaintained (no Python >=3.12 wheels); the
  # maintained tree-sitter-language-pack replaces it and supports 3.13.
  if pip_install tree_sitter tree-sitter-language-pack; then
    ok "tree-sitter installed"; record "tree-sitter: installed"
  else
    err "tree-sitter install failed"
    record "tree-sitter: FAILED"
  fi
}

# ---- 3. GitHub-release downloads ------------------------------------------
# Resolve the latest release asset download URL matching a regex.
latest_asset() {
  local repo="$1" pattern="$2"
  curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
    | grep -oE '"browser_download_url": *"[^"]+"' \
    | cut -d'"' -f4 \
    | grep -E "$pattern" \
    | head -n1
}

install_codeql() {
  say "codeql CLI bundle (GitHub release)"
  if have codeql; then ok "codeql already on PATH"; record "codeql: already present"; return; fi
  if [ -x "$OPT_DIR/codeql/codeql" ]; then
    ln -sf "$OPT_DIR/codeql/codeql" "$BIN_DIR/codeql"
    ok "codeql already extracted; relinked"; record "codeql: relinked"; return
  fi

  local url tmp
  url="$(latest_asset github/codeql-action 'codeql-bundle-linux64\.tar\.(gz|zst)$')"
  if [ -z "$url" ]; then
    err "could not resolve codeql bundle URL"; record "codeql: FAILED (no url)"; return
  fi
  say "downloading $url"
  tmp="$(mktemp -d)"
  if curl -fSL "$url" -o "$tmp/codeql.tar.gz" && tar -xf "$tmp/codeql.tar.gz" -C "$OPT_DIR"; then
    # bundle extracts to $OPT_DIR/codeql/
    ln -sf "$OPT_DIR/codeql/codeql" "$BIN_DIR/codeql"
    ok "codeql installed -> $OPT_DIR/codeql"
    record "codeql: installed"
  else
    err "codeql download/extract failed"; record "codeql: FAILED"
  fi
  rm -rf "$tmp"
}

install_jadx() {
  say "jadx (GitHub release)"
  if have jadx; then ok "jadx already on PATH"; record "jadx: already present"; return; fi
  if [ -x "$OPT_DIR/jadx/bin/jadx" ]; then
    ln -sf "$OPT_DIR/jadx/bin/jadx" "$BIN_DIR/jadx"
    ln -sf "$OPT_DIR/jadx/bin/jadx-gui" "$BIN_DIR/jadx-gui" 2>/dev/null || true
    ok "jadx already extracted; relinked"; record "jadx: relinked"; return
  fi

  if ! have java; then
    warn "java not found — jadx needs a JRE at runtime (sudo apt install default-jre)"
  fi

  local url tmp
  url="$(latest_asset skylot/jadx 'jadx-[0-9].*\.zip$')"
  if [ -z "$url" ]; then
    err "could not resolve jadx release URL"; record "jadx: FAILED (no url)"; return
  fi
  say "downloading $url"
  tmp="$(mktemp -d)"
  if curl -fSL "$url" -o "$tmp/jadx.zip" && unzip -q "$tmp/jadx.zip" -d "$OPT_DIR/jadx"; then
    chmod +x "$OPT_DIR/jadx/bin/jadx" 2>/dev/null || true
    ln -sf "$OPT_DIR/jadx/bin/jadx" "$BIN_DIR/jadx"
    ln -sf "$OPT_DIR/jadx/bin/jadx-gui" "$BIN_DIR/jadx-gui" 2>/dev/null || true
    ok "jadx installed -> $OPT_DIR/jadx"
    record "jadx: installed"
  else
    err "jadx download/extract failed (need 'unzip')"; record "jadx: FAILED"
  fi
  rm -rf "$tmp"
}

# ---- run ------------------------------------------------------------------
say "RAPTOR tool installer  (user prefix: $PREFIX)"
have curl  || { err "curl is required"; exit 1; }
have unzip || warn "unzip missing — jadx step will fail (sudo apt install unzip)"

install_apt
install_semgrep
install_frida
install_treesitter
install_codeql
install_jadx

# ---- summary --------------------------------------------------------------
echo
say "Summary"
for r in "${RESULTS[@]}"; do printf '   - %s\n' "$r"; done

echo
if ! printf '%s\n' "${PATH//:/$'\n'}" | grep -qx "$BIN_DIR"; then
  warn "add $BIN_DIR to PATH:"
  printf '     echo '\''export PATH="%s:$PATH"'\'' >> ~/.bashrc && source ~/.bashrc\n' "$BIN_DIR"
fi
say "Done. Restart RAPTOR to refresh the tool banner."
