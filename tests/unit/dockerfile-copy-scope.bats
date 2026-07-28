#!/usr/bin/env bats
#
# A container directory holds two kinds of shell script: what the image runs, and
# what the repository runs *about* the image — `test.sh`, which the e2e harness
# executes from the host against a running container, and `version.sh`, which the
# build system executes to discover the upstream release.
#
# A `COPY *.sh` glob cannot tell them apart. It ships test code into a published
# image, and it makes the image a dependant of files that can never change it, so
# every edit to either one queues a rebuild.

load "../test_helper"

# Directories holding a Dockerfile that is not generated from a template.
container_dirs() {
    local d
    for d in "$PROJECT_ROOT"/*/; do
        [ -f "${d}variants.yaml" ] || continue
        printf '%s\n' "${d%/}"
    done
}

@test "no Dockerfile globs *.sh out of a directory that also holds host-side scripts" {
    local offenders=""
    local dir name df line

    while IFS= read -r dir; do
        name=$(basename "$dir")
        # Only a directory that actually holds one of the host-side scripts can
        # be harmed by the glob.
        [ -f "$dir/test.sh" ] || [ -f "$dir/version.sh" ] || continue

        for df in "$dir"/Dockerfile*; do
            [ -f "$df" ] || continue
            while IFS= read -r line; do
                offenders="$offenders  $name/$(basename "$df"): $line"$'\n'
            done < <(grep -iE '^[[:space:]]*COPY([[:space:]]+--[^[:space:]]+)*[[:space:]]+(\./)?\*\.sh[[:space:]]' "$df" || true)
        done
    done < <(container_dirs)

    if [ -n "$offenders" ]; then
        printf 'A COPY glob would ship test.sh or version.sh into an image:\n%s' "$offenders" >&2
        return 1
    fi
}

@test "the two images that carried the glob still copy the entrypoint they run" {
    # Narrowing the glob must not have dropped the file the image actually needs.
    grep -qE '^[[:space:]]*COPY.*[[:space:]]docker-entrypoint\.sh([[:space:]]|$)' \
        "$PROJECT_ROOT/ansible/Dockerfile"
    grep -qE '^[[:space:]]*COPY.*[[:space:]]docker-entrypoint\.sh([[:space:]]|$)' \
        "$PROJECT_ROOT/wordpress/Dockerfile"
}

@test "every container's declared entrypoint script is one the Dockerfile copies" {
    # The failure this catches is narrowing a COPY past what the image invokes.
    local dir name df entry
    while IFS= read -r dir; do
        name=$(basename "$dir")
        df="$dir/Dockerfile"
        [ -f "$df" ] || continue
        entry=$(grep -oE '^[[:space:]]*ENTRYPOINT[[:space:]]*\[[[:space:]]*"[^"]+"' "$df" 2>/dev/null |
            grep -oE '"[^"]+"' | tr -d '"' | xargs -r basename 2>/dev/null || true)
        [ -n "$entry" ] || continue
        # Only check entrypoints that live in the container directory as a script.
        [ -f "$dir/$entry" ] || continue
        if ! grep -qE "^[[:space:]]*COPY.*([[:space:]]|/)${entry}([[:space:]]|$)" "$df" &&
           ! grep -qE '^[[:space:]]*COPY.*\*\.sh' "$df"; then
            printf '%s declares ENTRYPOINT %s but no COPY brings it in\n' "$name" "$entry" >&2
            return 1
        fi
    done < <(container_dirs)
}
