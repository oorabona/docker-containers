# docker-bake.hcl — EVALUATION SPIKE for ADR-013 (dependency-ordered builds)
# ─────────────────────────────────────────────────────────────────────────────
# NOT wired into CI. Purpose: prove locally that BuildKit orders base→consumer
# from a declarative graph, passing the base image IN MEMORY (no registry
# round-trip → the multi-arch single-arch race cannot occur).
#
# Chain modelled:  debian → github-runner:debian-trixie {base, dev}
#                  debian → web-shell:debian
#
# SEE THE ORDER WITHOUT BUILDING (buildx binary only — no daemon, podman untouched):
#   docker buildx bake -f docs/adr/ADR-013-bake-spike.hcl --print
# The JSON it prints shows each consumer's "contexts" pointing at "target:debian",
# i.e. the dependency edge. bake will build `debian` first, automatically.
#
# The dependency is IMPLICIT, from the reference — exactly like Terraform infers
# order when one resource references another. The line that does it:
#     contexts = { "ghcr.io/oorabona/debian:trixie" = "target:debian" }
# It redirects the consumer's `FROM ghcr.io/oorabona/debian:trixie` to the locally
# built `debian` target. No Dockerfile edit needed.
#
# REAL BUILD (needs a BuildKit backend AND the template Dockerfiles materialised):
#   # github-runner + web-shell use the template+generator pattern (ADR-006).
#   # A standalone bake build must materialise their per-distro Dockerfile first;
#   # this is exactly the integration work Option B in ADR-013 requires.
#   ./web-shell/generate-dockerfile.sh web-shell/Dockerfile debian > web-shell/Dockerfile.debian
#   docker buildx bake -f docs/adr/ADR-013-bake-spike.hcl
# Native multi-arch additionally needs a multi-platform builder (a remote/arm64
# node or QEMU) — out of scope for this --print evaluation.
# ─────────────────────────────────────────────────────────────────────────────

variable "REMOTE_CR"    { default = "ghcr.io/oorabona" }
variable "DEBIAN_VER"   { default = "trixie" }
variable "RUNNER_VER"   { default = "2.334.0" }
variable "WEBSHELL_VER" { default = "1.7.7" }

# All three consumers carry this exact string in their FROM; the per-target
# `contexts` remap redirects it to the locally-built `debian` target.
variable "DEBIAN_REF"   { default = "ghcr.io/oorabona/debian:trixie" }

group "default" {
  targets = [
    "github-runner-debian-trixie-base",
    "github-runner-debian-trixie-dev",
    "web-shell-debian",
  ]
}

# ── Layer 0: the base ────────────────────────────────────────────────────────
target "debian" {
  context    = "debian"
  dockerfile = "Dockerfile"               # committed; no generation
  platforms  = ["linux/amd64", "linux/arm64"]
  args = {
    REMOTE_CR = "docker.io"               # debian itself pulls upstream library/debian
    VERSION   = "${DEBIAN_VER}"
  }
  tags = ["${DEBIAN_REF}"]
}

# ── Layer 1: consumers of debian ─────────────────────────────────────────────
# `contexts` is the dependency edge: it remaps the FROM ref to "target:debian",
# so bake builds debian first and hands its image to the consumer in memory.

target "github-runner-debian-trixie-base" {
  context    = "github-runner"
  dockerfile = "Dockerfile.debian-trixie-base"   # template-generated for a real build
  platforms  = ["linux/amd64", "linux/arm64"]
  contexts   = { "ghcr.io/oorabona/debian:trixie" = "target:debian" }
  args = {
    DEBIAN_TRIXIE_BASE = "${DEBIAN_REF}"
    VERSION            = "${RUNNER_VER}"
  }
  tags = ["${REMOTE_CR}/github-runner:${RUNNER_VER}-debian-trixie-base"]
}

target "github-runner-debian-trixie-dev" {
  context    = "github-runner"
  dockerfile = "Dockerfile.debian-trixie-dev"    # sibling of base — also FROM debian directly
  platforms  = ["linux/amd64", "linux/arm64"]
  contexts   = { "ghcr.io/oorabona/debian:trixie" = "target:debian" }
  args = {
    DEBIAN_TRIXIE_BASE = "${DEBIAN_REF}"
    VERSION            = "${RUNNER_VER}"
  }
  tags = ["${REMOTE_CR}/github-runner:${RUNNER_VER}-debian-trixie-dev"]
}

target "web-shell-debian" {
  context    = "web-shell"
  dockerfile = "Dockerfile.debian"               # GENERATED (pre-step) for a real build
  platforms  = ["linux/amd64", "linux/arm64"]
  contexts   = { "ghcr.io/oorabona/debian:trixie" = "target:debian" }
  args = {
    REMOTE_CR  = "${REMOTE_CR}"
    VERSION    = "${WEBSHELL_VER}"
    DEBIAN_TAG = "${DEBIAN_VER}"
    SHELL_USER = "debian"
  }
  tags = ["${REMOTE_CR}/web-shell:debian-${WEBSHELL_VER}"]
}
