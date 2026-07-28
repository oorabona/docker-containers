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

# Top-level container directories holding a Dockerfile, whether or not they carry
# a variants.yaml — the build helpers support both. Deliberately not recursive:
# what this protects is the published images, and a Dockerfile under examples/ is
# illustration, not a tag anyone pulls.
container_dirs() {
    local d
    for d in "$PROJECT_ROOT"/*/; do
        compgen -G "${d}Dockerfile*" > /dev/null || continue
        printf '%s\n' "${d%/}"
    done
}

# Logical instructions, not physical lines: a continued `COPY --chmod=755 \`
# followed by `*.sh /` satisfies neither line on its own. Lines whose source is a
# build stage are dropped — `COPY --from=…` does not reach into the directory
# holding test.sh, so matching it would be a false alarm.
copy_instructions() { # dockerfile
    sed -e :a -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' "$1" |
        grep -iE '^[[:space:]]*(COPY|ADD)([[:space:]]|$)' |
        grep -ivE '^[[:space:]]*(COPY|ADD)([[:space:]]+--[^[:space:]]+)*[[:space:]]+--from=' || true
}

# What this checks and what it does not: it reads Dockerfile text for a copy whose
# source is a bare `*.sh` glob. It cannot prove that no host-side script reaches an
# image — only a built image can show that, and a `.dockerignore`, a directory
# copy or a multi-stage indirection would all escape a text scan. It exists to stop
# the one spelling that put test.sh into two published images from coming back.
@test "no container Dockerfile copies a bare *.sh glob out of its own directory" {
    local offenders=""
    local dir name df line

    while IFS= read -r dir; do
        name=$(basename "$dir")
        # Only a directory that actually holds one of the host-side scripts can
        # be harmed by the glob.
        [ -f "$dir/test.sh" ] || [ -f "$dir/version.sh" ] || continue

        for df in "$dir"/Dockerfile*; do
            [ -f "$df" ] || continue
            # Two steps rather than one expression: the instructions that bring
            # files in, then a bare `*.sh` token anywhere among their arguments.
            # Written as one regex it silently stopped matching the plainest
            # spelling of all.
            while IFS= read -r line; do
                offenders="$offenders  $name/$(basename "$df"): $line"$'\n'
            done < <(copy_instructions "$df" |
                     grep -E '(^|[[:space:]"[])(\./)?\*\.sh([[:space:]",]|$)' || true)
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

# The matcher above is the part that can fail silently: tightened or loosened, it
# stops reporting and the suite stays green. It gets its own table of spellings —
# written after a "broadening" edit quietly stopped matching `COPY *.sh /`, the
# plainest form of the defect and the one that shipped.
matches_glob() { # dockerfile text, possibly multi-line
    local f="$BATS_TEST_TMPDIR/df"
    printf '%s\n' "$1" > "$f"
    copy_instructions "$f" | grep -qE '(^|[[:space:]"[])(\./)?\*\.sh([[:space:]",]|$)'
}

@test "the glob matcher catches every spelling that would ship the scripts" {
    matches_glob 'COPY *.sh /'
    matches_glob 'COPY --chmod=755 *.sh /'
    matches_glob 'copy *.sh /'
    matches_glob 'ADD *.sh /'
    matches_glob 'COPY entrypoint.sh *.sh /'
    matches_glob 'COPY ["*.sh", "/"]'
    matches_glob 'COPY ./*.sh /'
    matches_glob '    COPY *.sh /'
    # Continued across lines: neither line satisfies the match on its own.
    matches_glob 'COPY --chmod=755 \
    *.sh /'
}

@test "the glob matcher leaves alone what does not ship them" {
    ! matches_glob 'COPY docker-entrypoint.sh /'
    ! matches_glob 'COPY scripts/*.sh /'
    ! matches_glob 'COPY --from=builder /out/x.sh /'
    ! matches_glob 'RUN ls x*.sh'
    ! matches_glob 'RUN echo hi'
    # A build stage is not the directory holding test.sh, so a glob out of one is
    # not this defect.
    ! matches_glob 'COPY --from=builder *.sh /usr/local/bin/'
    ! matches_glob 'COPY --chmod=755 --from=builder *.sh /'
}

# A further check lived here and was removed rather than repaired: "every
# container's declared entrypoint script is one the Dockerfile copies". Deciding
# that from Dockerfile text needs stage-aware source/destination parsing, and the
# grep standing in for it mistook a wrapper entrypoint for the script it wraps,
# read only the canonical Dockerfile while its sibling read every variant, and
# silently skipped whatever it could not parse. A check that skips what it cannot
# read reports success for the cases it is least able to judge. What actually
# proves an image runs is the e2e suite, against a built image.
