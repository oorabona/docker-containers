---
layout: post
title: "The cache that cached nothing — how a $(...) ate my memoization"
description: "I added a one-line memoization to skip redundant registry probes. It compiled, it would have passed every test I had — and it did absolutely nothing, because bash command substitution runs in a subshell. It got caught by reading the call site, not by a test. This is about the test that would have lied, and the one I wrote so it couldn't happen quietly again."
date: 2026-06-02 10:00:00 +0000
tags: [bash, perf, testing, ci, memoization, lessons-learned]
---

I maintain a small fleet of container images that watch their upstream base images for digest drift. Once a day a script walks every recorded build, asks the registry "is the digest you were built on still the current one?", and opens a rebase PR where it isn't. The probe that answers that question — `docker buildx imagetools inspect` — is the slow part. And it was running far more than it needed to.

The reason was boring: the same base image shows up in many builds. `alpine:latest` underpins eleven of mine, and the detector probed it eleven times a run — once per variant sitting on it. Forty-five probes for eleven distinct references; three-quarters redundant.

The fix is the first thing anyone reaches for. Memoize: probe each reference once, cache the digest, hand the cached value to every later caller. A few lines of bash.

## The cache, the obvious way

```bash
declare -A _DIGEST_CACHE   # base_image_ref -> digest

_probe_digest_cached() {
    local image_ref="$1"
    if [[ -v _DIGEST_CACHE[$image_ref] ]]; then
        printf '%s' "${_DIGEST_CACHE[$image_ref]}"   # hit
        return 0
    fi
    local digest
    if digest=$(_probe_digest "$image_ref"); then    # miss -> probe + store
        _DIGEST_CACHE[$image_ref]="$digest"
        printf '%s' "$digest"
        return 0
    fi
    return 1
}
```

And at the call site, the way every bash function returns a value:

```bash
current_digest=$(_probe_digest_cached "$base_image_ref")
```

Read it again — specifically that last line, `current_digest=$(_probe_digest_cached "$base_image_ref")`. There is nothing wrong with the cache function itself. That one assignment makes the entire cache do nothing.

## Why it caches nothing

`$( ... )` is command substitution, and command substitution runs its contents in a **subshell** — a forked copy of the shell with its own copy of every variable. Inside that subshell, `_DIGEST_CACHE[$image_ref]="$digest"` faithfully writes to the array. Then the subshell exits, and its memory — including that write — is thrown away. The parent shell's `_DIGEST_CACHE` is never touched.

Every call is a cold miss. The `[[ -v _DIGEST_CACHE[$image_ref] ]]` check at the top is always false, because the array the parent owns is always empty. `alpine:latest` gets probed eleven times, exactly as before. The optimization is a no-op.

The fix is to stop running the function inside a subshell. Return the value through a variable the parent owns, and call the function as a plain statement:

```bash
_probe_digest_cached() {
    local image_ref="$1"
    if [[ -v _DIGEST_CACHE[$image_ref] ]]; then
        _probe_digest_cached_out="${_DIGEST_CACHE[$image_ref]}"
        return 0
    fi
    local digest
    if digest=$(_probe_digest "$image_ref"); then
        _DIGEST_CACHE[$image_ref]="$digest"     # writes the PARENT's array now
        _probe_digest_cached_out="$digest"
        return 0
    fi
    return 1
}

# caller — no $(...)
if _probe_digest_cached "$base_image_ref"; then
    current_digest="$_probe_digest_cached_out"
fi
```

Same cache, same logic. The only change is that it now runs in the shell that owns the array. (That `_probe_digest_cached_out` global is the standard bash idiom for returning data without a subshell — it's how you return anything richer than an exit code.) Forty-five probes drop to eleven.

## The test that would have lied

Here is the part worth keeping. The first version — the broken one — would have passed a perfectly reasonable test:

```bash
@test "probe returns the recorded digest" {
    run detect_drift_for fixture-with-alpine
    assert_output --partial "sha256:abc..."
}
```

It passes. Of course it passes. The broken function still *returns the right digest* — it just computes it from scratch every time instead of from cache. A test that checks the **result** is completely blind to whether the cache exists. You can delete the entire `_DIGEST_CACHE` machinery and this test stays green.

That is the trap with performance work. The thing you changed — did the expensive operation happen fewer times? — is invisible to a test that only inspects the output. Correctness and performance are different properties, and a correctness assertion does not test a performance change. It will sit there, green and reassuring, over code that does nothing.

## How it actually got caught — and the test I wrote so it stays caught

Nothing automated caught this. It got caught the only way a dead cache can be, absent a test that's looking for it: someone read the call site, saw `current_digest=$(...)`, and knew what the subshell would do to the write two lines up. That's code review doing the one thing it's uniquely good at — catching what compiles, runs, and returns the right answer while still being wrong.

A reviewer happening to notice is too thin a net to leave it at, so I wrote the test that *would* have caught it, to lock the fix down. To test a cache you assert the thing a cache is *for*: that the expensive call happened less. The harness already stubs the probe with a fixture; I had the stub append a line to a counter file on every invocation, and asserted on the count:

```bash
@test "shared base image is probed once (not per-variant)" {
    # fixture: two variants, both on alpine:3.21
    run detect_drift_for fixture-two-variants-one-base
    assert_success
    # the real probe must have run exactly once for the shared ref
    [ "$(wc -l < "$PROBE_CALLS")" -eq 1 ]
}
```

Now mutate the code back to the broken `current_digest=$(...)` version and the count becomes `2`. The test fails. That is the whole point of a test: it has to be able to *fail* on the bug you care about, and "the cache doesn't cache" is a bug a result-only test can never fail on.

## Spotting it in your own code

The smell is short: **a function that mutates shared state — an array, a counter, a flag — invoked as `result=$(func)`.** The `$(...)` drops the mutation into a subshell, where it lands and then evaporates. Three places it hides:

- `digest=$(probe_and_cache "$ref")` — the cache write is lost. (This post.)
- `count=0; producer | while read -r line; do count=$((count+1)); done` — the `while` is the right-hand side of a pipe, so it runs in a subshell; `count` is still `0` afterward. Use `while read -r line; do ...; done < <(producer)` or `mapfile -t lines < <(producer)` to keep the loop in the parent.
- Any "flip a flag inside a pipeline" pattern.

Rule of thumb: if a function has side effects, call it as a bare statement and read its result from a variable the caller owns — never through `$(...)`.

## The takeaway

That subshell rule is narrow and old, and I still walked into it. But it isn't the part I'll carry. This is:

**A performance optimization needs a test that asserts the expensive work didn't happen — not a test that asserts the result is still correct.** Count the calls. Assert the cache hit. Check the fast path was taken. If your test would still pass after you delete the optimization, it isn't testing the optimization — it's just keeping you company while the code does nothing.
