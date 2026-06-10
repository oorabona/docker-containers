#!/usr/bin/env bash
# setup-buildx-homebrew.sh — ensure a local `docker buildx` + (optionally) a
# rootless BuildKit backend, for dependency-ordered builds (ADR-013 / bake).
#
# Idempotent: safe to re-run. Detects existing installs (Homebrew, on-PATH binary,
# docker cli-plugin), only acts on gaps, never clobbers ~/.docker/config.json
# (merges), never installs a Docker daemon, never touches podman.
#
# Usage:
#   bash scripts/setup-buildx-homebrew.sh                 # ensure buildx + smoke (--print)
#   bash scripts/setup-buildx-homebrew.sh --start-buildkit  # also start rootless buildkitd + wire a buildx builder
#   bash scripts/setup-buildx-homebrew.sh --help
#
# Real multi-arch builds additionally require QEMU binfmt handlers (see --help).
set -euo pipefail

MIN_BUILDX_VER="0.10.0"                    # `target:` contexts stable well before this
SPIKE="docs/adr/ADR-013-bake-spike.hcl"    # smoke target (DAG resolve, no build)
BK_BUILDER="rootless-bk"                    # buildx builder name for the rootless backend
BK_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/buildkit/buildkitd.sock"
BK_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/buildkitd.log"

log()  { printf '   %s\n' "$*"; }
ok()   { printf '✅ %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
setup-buildx-homebrew.sh — ensure a local `docker buildx` + (optionally) a
rootless BuildKit backend, for dependency-ordered builds (ADR-013 / bake).

Idempotent: detects existing installs, acts only on gaps, merges (never clobbers)
~/.docker/config.json, installs no Docker daemon, never touches podman.

Usage:
  bash scripts/setup-buildx-homebrew.sh                  # ensure buildx + smoke (--print)
  bash scripts/setup-buildx-homebrew.sh --start-buildkit # also start rootless buildkitd + wire a buildx builder
  bash scripts/setup-buildx-homebrew.sh --install-qemu   # register arm64 emulation (podman/docker) for multi-arch
  bash scripts/setup-buildx-homebrew.sh --help

Multi-arch (arm64) local builds need QEMU binfmt handlers (this host is x86_64):
  podman run --privileged --rm tonistiigi/binfmt --install arm64
  # (or install qemu-user-static + enable the binfmt_misc service)
Without them, only the host architecture builds locally.
EOF
}

# ── buildx discovery ─────────────────────────────────────────────────────────
find_buildx() {
  local c d p
  for c in docker-buildx buildx; do command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }; done
  if command -v brew >/dev/null 2>&1; then
    p="$(brew --prefix docker-buildx 2>/dev/null)/bin/docker-buildx"; [ -x "$p" ] && { echo "$p"; return 0; }
  fi
  for d in "$HOME/.docker/cli-plugins" /usr/local/lib/docker/cli-plugins \
           /usr/libexec/docker/cli-plugins /usr/lib/docker/cli-plugins; do
    [ -x "$d/docker-buildx" ] && { echo "$d/docker-buildx"; return 0; }
  done
  return 1
}
ver_of() { "$1" version 2>/dev/null | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p' | head -1; }
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

brew_ensure() {  # brew_ensure <formula>  — install only if missing (idempotent)
  command -v brew >/dev/null 2>&1 || { warn "no brew; install '$1' manually"; return 1; }
  brew list "$1" >/dev/null 2>&1 || brew install "$1"
}

# ── QEMU / multi-arch emulation (podman- OR docker-compatible) ────────────────
qemu_arm64_present() {  # true iff the qemu-aarch64 binfmt handler is registered+enabled
  grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null
}

container_runtime() {  # a runtime able to `run --privileged`: prefer podman, else docker
  command -v podman >/dev/null 2>&1 && { echo podman; return 0; }
  command -v docker >/dev/null 2>&1 && { echo docker; return 0; }
  return 1
}

build_platforms() {  # platforms buildable on this host given QEMU state
  if qemu_arm64_present; then echo "linux/amd64,linux/arm64"; else echo "linux/amd64"; fi
}

ensure_qemu() {  # detect arm64 emulation; offer to install if missing (idempotent)
  if qemu_arm64_present; then
    ok "QEMU arm64 emulation present (binfmt qemu-aarch64) — multi-arch buildable."
    return 0
  fi
  warn "QEMU arm64 emulation NOT registered on the host — only $(uname -m) builds locally."
  local rt; rt="$(container_runtime || true)"
  if [ -z "$rt" ]; then
    warn "No podman/docker available. Install one, then (rootful) run:"
    warn "  sudo <runtime> run --privileged --rm tonistiigi/binfmt --install arm64"
    return 1
  fi
  # NB: a ROOTLESS registration does NOT persist to the host binfmt_misc — it lands
  # in the container's ephemeral namespace and vanishes with --rm (you'll see
  # "installing: arm64 OK" but the host handler won't exist). Use sudo (rootful) so
  # it reaches the host kernel. On WSL it may need re-running after a WSL restart
  # (or set up a systemd binfmt unit / qemu-user-static for persistence).
  local cmd="sudo $rt run --privileged --rm tonistiigi/binfmt --install arm64"
  if [ -t 0 ]; then
    printf '   Register arm64 emulation (rootful, persists to host) via:\n     %s\n   Proceed? [y/N] ' "$cmd"
    local ans; read -r ans || true
    case "$ans" in
      [yY]|[yY][eE][sS])
        if eval "$cmd"; then ok "arm64 emulation registered."; else warn "binfmt install failed."; fi ;;
      *) log "skipped — run it yourself when ready: $cmd" ;;
    esac
  else
    log "non-interactive — to enable arm64 run: $cmd"
  fi
}

ensure_buildx() {
  if BX="$(find_buildx)"; then
    V="$(ver_of "$BX" || true)"
    if [ -n "$V" ] && ver_ge "$V" "$MIN_BUILDX_VER"; then
      ok "buildx present: $BX (v$V ≥ $MIN_BUILDX_VER)"
    else
      warn "buildx $BX v${V:-?} < $MIN_BUILDX_VER — consider: brew upgrade docker-buildx"
    fi
  else
    log "buildx missing — installing…"; brew_ensure docker-buildx
    BX="$(find_buildx)" || { warn "buildx still not found after install"; exit 1; }
    ok "installed: $BX"
  fi
}

ensure_config() {  # merge plugin dir into ~/.docker/config.json (real docker CLI only; harmless under podman)
  command -v brew >/dev/null 2>&1 || return 0
  local dir; dir="$(brew --prefix 2>/dev/null)/lib/docker/cli-plugins"; [ -d "$dir" ] || return 0
  local cfg="$HOME/.docker/config.json"; mkdir -p "$HOME/.docker"; [ -f "$cfg" ] || echo '{}' >"$cfg"
  command -v jq >/dev/null 2>&1 || { warn "no jq; manually add $dir to cliPluginsExtraDirs"; return 0; }
  if jq -e --arg d "$dir" '(.cliPluginsExtraDirs // []) | index($d)' "$cfg" >/dev/null; then
    ok "config.json already lists the plugin dir — unchanged."
  else
    local t; t="$(mktemp)"
    jq --arg d "$dir" '.cliPluginsExtraDirs = ((.cliPluginsExtraDirs // []) + [$d] | unique)' "$cfg" >"$t" && mv "$t" "$cfg"
    ok "added $dir to config.json cliPluginsExtraDirs."
  fi
}

smoke() {
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  [ -f "$root/$SPIKE" ] || { log "smoke skipped ($SPIKE not found)"; return 0; }
  if ( cd "$root" && "$BX" bake -f "$SPIKE" --print >/dev/null 2>&1 ); then
    ok "smoke: '$BX bake --print' resolved the DAG ($SPIKE)."
  else
    warn "smoke failed — run:  (cd $root && $BX bake -f $SPIKE --print)"
  fi
}

# ── rootless BuildKit backend (opt-in: --start-buildkit) ─────────────────────
bk_alive() {  # true iff a buildkitd actually RESPONDS on the socket (not just a stale file)
  timeout 10 buildctl --addr "unix://$BK_SOCK" debug workers >/dev/null 2>&1
}

start_buildkit() {
  ensure_buildx
  brew_ensure buildkit || true       # provides buildkitd + buildctl
  brew_ensure rootlesskit || true
  command -v buildkitd  >/dev/null 2>&1 || { warn "buildkitd not found"; exit 1; }
  command -v rootlesskit >/dev/null 2>&1 || { warn "rootlesskit not found"; exit 1; }

  # 1. buildkitd (rootless) — start only if no daemon actually RESPONDS (a stale
  #    socket file is not enough; the builder goes 'inactive' against a dead sock).
  if bk_alive; then
    ok "buildkitd already responding: $BK_SOCK"
  else
    if [ -S "$BK_SOCK" ]; then warn "stale socket (no daemon) — removing"; rm -f "$BK_SOCK"; fi
    mkdir -p "$(dirname "$BK_SOCK")" "$(dirname "$BK_LOG")"
    log "starting rootless buildkitd (background, log: $BK_LOG)…"
    # default rootless socket is $XDG_RUNTIME_DIR/buildkit/buildkitd.sock
    nohup rootlesskit buildkitd >"$BK_LOG" 2>&1 &
    for _ in $(seq 1 30); do bk_alive && break; sleep 0.5; done
    if bk_alive; then
      ok "buildkitd up and responding: $BK_SOCK"
    else
      warn "buildkitd did not come up at $BK_SOCK — check $BK_LOG"; exit 1
    fi
  fi

  # 2. buildx builder (remote driver → the rootless socket). Idempotent.
  if "$BX" inspect "$BK_BUILDER" >/dev/null 2>&1; then
    ok "buildx builder '$BK_BUILDER' already exists."
  else
    "$BX" create --name "$BK_BUILDER" --driver remote "unix://$BK_SOCK"
    ok "created buildx builder '$BK_BUILDER' → unix://$BK_SOCK"
  fi
  "$BX" use "$BK_BUILDER"
  if "$BX" inspect --bootstrap "$BK_BUILDER" >/dev/null 2>&1; then
    ok "builder bootstrapped and selected."
  else
    warn "bootstrap reported an issue — inspect: $BX inspect $BK_BUILDER"
  fi

  ensure_qemu
  echo "── ready: real builds via '$BX bake' on platforms: $(build_platforms) ──"
  echo "   e.g.  $BX bake -f $SPIKE --set \"*.platform=$(build_platforms)\" debian"
}

# ── main ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --start-buildkit)
    echo "── buildx + rootless BuildKit setup (idempotent) ──"
    start_buildkit ;;
  --install-qemu)
    echo "── QEMU multi-arch emulation (podman/docker) ──"
    ensure_qemu ;;
  "")
    echo "── buildx local setup (idempotent) ──"
    ensure_buildx; ensure_config; smoke
    if qemu_arm64_present; then
      ok "arm64 emulation available — multi-arch buildable."
    else
      log "arm64 emulation not registered (amd64-only); enable: bash $0 --install-qemu"
    fi
    echo "── done. Invoke bake directly (NOT 'podman buildx'):  $BX bake -f $SPIKE --print"
    echo "   For real builds, run:  bash $0 --start-buildkit" ;;
  *) warn "unknown arg: ${1}"; usage; exit 2 ;;
esac
