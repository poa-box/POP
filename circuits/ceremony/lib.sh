#!/usr/bin/env bash
# Shared helpers for the POP zk-email phase-2 trusted-setup ceremony.
# Sourced by the phase2-*.sh scripts. No side effects beyond defining functions/vars.
#
# snarkjs is memory-hungry on the real circuits (v2 is ~1.2M constraints); always run it under a
# large old-space so node doesn't OOM mid-contribution.
set -euo pipefail

# Resolve snarkjs: prefer an explicit SNARKJS env, else the pop-zk-work checkout, else PATH.
: "${POP_ZK_WORK:=$HOME/pop-zk-work}"
: "${NODE_MAX_OLD_SPACE:=20000}"

_snarkjs_cli=""
if [[ -n "${SNARKJS:-}" && -f "${SNARKJS}" ]]; then
  _snarkjs_cli="${SNARKJS}"
elif [[ -f "${POP_ZK_WORK}/node_modules/snarkjs/build/cli.cjs" ]]; then
  _snarkjs_cli="${POP_ZK_WORK}/node_modules/snarkjs/build/cli.cjs"
fi

# sj: run snarkjs with a big node heap. Uses the resolved cli.cjs if found, else `npx snarkjs`.
sj() {
  if [[ -n "${_snarkjs_cli}" ]]; then
    node --max-old-space-size="${NODE_MAX_OLD_SPACE}" "${_snarkjs_cli}" "$@"
  else
    NODE_OPTIONS="--max-old-space-size=${NODE_MAX_OLD_SPACE}" npx --yes snarkjs "$@"
  fi
}

# sha256 of a file, portable across macOS (shasum) and Linux (sha256sum).
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

log() { printf '\033[1;36m[ceremony]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ceremony:error]\033[0m %s\n' "$*" >&2; exit 1; }

# Append a line to the ceremony transcript (append-only audit log).
transcript() {
  local file="$1"; shift
  printf '%s\n' "$*" >> "$file"
}
