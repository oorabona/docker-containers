#!/usr/bin/env bats

# Hermetic promotion tests. Registry commands are function stubs; no network or
# containers are used. The call log distinguishes reads from canonical writes.

load "../test_helper"

setup() {
    setup_temp_dir
    export OWNER="testowner"
    export GITHUB_REPOSITORY_OWNER="$OWNER"
    export EXTENSION_REGISTRY="ghcr.io"
    export CALLS_FILE="$TEST_TEMP_DIR/registry-calls"
    export AMD64_DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    export ARM64_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    export RAW_MANIFEST="{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[{\"digest\":\"$AMD64_DIGEST\",\"platform\":{\"os\":\"linux\",\"architecture\":\"amd64\"}},{\"digest\":\"$ARM64_DIGEST\",\"platform\":{\"os\":\"linux\",\"architecture\":\"arm64\"}}]}"
    export BASELINE_DIGEST="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    export BASELINE_MODE="digest"
    export CANONICAL_DIGEST="$BASELINE_DIGEST"
    export SOURCE_AMD64_DIGEST="$AMD64_DIGEST"
    export SOURCE_ARM64_DIGEST="$ARM64_DIGEST"
    export DESTINATION_AMD64_DIGEST="$AMD64_DIGEST"
    export DESTINATION_ARM64_DIGEST="$ARM64_DIGEST"
    export DOCKER_MODE="success"
    unset STATE_FILE
    : > "$CALLS_FILE"
}

teardown() {
    teardown_temp_dir
    unset OWNER GITHUB_REPOSITORY_OWNER EXTENSION_REGISTRY CALLS_FILE RAW_MANIFEST AMD64_DIGEST ARM64_DIGEST BASELINE_DIGEST BASELINE_MODE
    unset CANONICAL_DIGEST SOURCE_AMD64_DIGEST SOURCE_ARM64_DIGEST DESTINATION_AMD64_DIGEST DESTINATION_ARM64_DIGEST
    unset SKOPEO_MODE DOCKER_MODE STATE_FILE
}

published_digest() {
    printf 'sha256:%s' "$(printf '%s' "$RAW_MANIFEST" | sha256sum | awk '{print $1}')"
}

run_promotion() {
    run env \
        OWNER="$OWNER" \
        GITHUB_REPOSITORY_OWNER="$GITHUB_REPOSITORY_OWNER" \
        EXTENSION_REGISTRY="$EXTENSION_REGISTRY" \
        CALLS_FILE="$CALLS_FILE" \
        RAW_MANIFEST="$RAW_MANIFEST" \
        AMD64_DIGEST="$AMD64_DIGEST" \
        ARM64_DIGEST="$ARM64_DIGEST" \
        BASELINE_DIGEST="$BASELINE_DIGEST" \
        BASELINE_MODE="$BASELINE_MODE" \
        CANONICAL_DIGEST="$CANONICAL_DIGEST" \
        SOURCE_AMD64_DIGEST="$SOURCE_AMD64_DIGEST" \
        SOURCE_ARM64_DIGEST="$SOURCE_ARM64_DIGEST" \
        DESTINATION_AMD64_DIGEST="$DESTINATION_AMD64_DIGEST" \
        DESTINATION_ARM64_DIGEST="$DESTINATION_ARM64_DIGEST" \
        STATE_FILE="${STATE_FILE:-}" \
        SKOPEO_MODE="${SKOPEO_MODE:-success}" \
        DOCKER_MODE="${DOCKER_MODE:-success}" \
        bash -c '
            skopeo() {
                local ref="${!#}"
                if [[ "$1" == "copy" ]]; then
                    printf "COPY %s\\n" "$*" >> "$CALLS_FILE"
                    [[ "$SKOPEO_MODE" != "copy-fails" ]] || return 23
                    return 0
                fi
                if [[ "$1" == "list-tags" ]]; then
                    printf "LIST %s\\n" "$ref" >> "$CALLS_FILE"
                    [[ "$SKOPEO_MODE" != "canonical-unknown-auth" && "$SKOPEO_MODE" != "canonical-inspect-fails" ]] || return 24
                    cat <<EOF
{"Tags":[]}
EOF
                    return 0
                fi
                printf "INSPECT %s\\n" "$ref" >> "$CALLS_FILE"
                if [[ "$1" == "inspect" && "$2" == "--raw" ]]; then
                    if [[ "$SKOPEO_MODE" == "amd64-index" && "$ref" == *"-staging@${AMD64_DIGEST}" ]]; then
                        cat <<EOF
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]}
EOF
                    else
                        cat <<EOF
{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json"}
EOF
                    fi
                    return 0
                fi
                if [[ "$1" == "inspect" && "$2" == "--config" ]]; then
                    if [[ "$SKOPEO_MODE" == "amd64-wrong-platform" && "$ref" == *"-staging@${AMD64_DIGEST}" ]]; then
                        cat <<EOF
{"os":"linux","architecture":"arm64"}
EOF
                    elif [[ "$ref" == *"-staging@${AMD64_DIGEST}" ]]; then
                        cat <<EOF
{"os":"linux","architecture":"amd64"}
EOF
                    else
                        cat <<EOF
{"os":"linux","architecture":"arm64"}
EOF
                    fi
                    return 0
                fi
                [[ "$SKOPEO_MODE" != "inspect-fails" ]] || return 24
                if [[ "$SKOPEO_MODE" == "amd64-inspect-fails" && "$ref" == *"-staging@${AMD64_DIGEST}" ]]; then
                    return 24
                fi
                if [[ "$SKOPEO_MODE" == "amd64-absent" && "$ref" == *"-staging@${AMD64_DIGEST}" ]]; then
                    printf "manifest unknown" >&2
                    return 1
                fi
                if [[ "$SKOPEO_MODE" == "canonical-inspect-fails" && "$ref" != *"-staging@"* ]]; then
                    return 24
                fi
                if [[ "$SKOPEO_MODE" == "canonical-unknown-auth" && "$ref" == *":pg17-0.8.6" ]]; then
                    printf denied:\ upstream\ MANIFEST_UNKNOWN\ while\ auth\ unavailable >&2
                    return 1
                fi
                if [[ "$SKOPEO_MODE" == "canonical-absent" && "$ref" == *":pg17-0.8.6" ]]; then
                    printf "manifest unknown" >&2
                    return 1
                fi
                if [[ "$SKOPEO_MODE" == "destination-amd64-absent" && "$ref" == *":pg17-0.8.6-amd64" ]]; then
                    printf "manifest unknown" >&2
                    return 1
                fi
                case "$ref" in
                    *"-staging@${AMD64_DIGEST}") printf "%s" "$SOURCE_AMD64_DIGEST" ;;
                    *"-staging@${ARM64_DIGEST}") printf "%s" "$SOURCE_ARM64_DIGEST" ;;
                    *":pg17-0.8.6-amd64") printf "%s" "$DESTINATION_AMD64_DIGEST" ;;
                    *":pg17-0.8.6-arm64") printf "%s" "$DESTINATION_ARM64_DIGEST" ;;
                    *":pg17-0.8.6")
                        if [[ -n "$STATE_FILE" && -s "$STATE_FILE" ]]; then
                            cat "$STATE_FILE"
                        else
                            printf "%s" "$CANONICAL_DIGEST"
                        fi
                        ;;
                    *) return 98 ;;
                esac
            }
            docker() {
                if [[ "$1 $2 $3" == "buildx imagetools create" ]]; then
                    printf "CREATE %s\\n" "$*" >> "$CALLS_FILE"
                    [[ "$DOCKER_MODE" != "create-fails" ]] || return 79
                    if [[ "$DOCKER_MODE" == "commit-then-read-fails" ]]; then
                        printf "sha256:%s" "$(printf "%s" "$RAW_MANIFEST" | sha256sum | awk "{print \$1}")" > "$STATE_FILE"
                    fi
                    return 0
                fi
                if [[ "$1 $2 $3" == "buildx imagetools inspect" ]]; then
                    [[ "$DOCKER_MODE" != "index-read-fails" && "$DOCKER_MODE" != "commit-then-read-fails" ]] || return 77
                    printf "%s" "$RAW_MANIFEST"
                    return 0
                fi
                return 99
            }
            export -f skopeo docker
            baseline_args=()
            if [[ "$BASELINE_MODE" == "absent" ]]; then
                baseline_args=(--no-canonical-index)
            else
                baseline_args=(--baseline-digest "$BASELINE_DIGEST")
            fi
            exec "$PROJECT_ROOT/scripts/rotation-promote.sh" \
                --extension pgvector --pg-major 17 --version 0.8.6 \
                "${baseline_args[@]}" \
                --amd64-digest "$AMD64_DIGEST" --arm64-digest "$ARM64_DIGEST"
        '
}

@test "promotion copies frozen staging digests, verifies destinations, and creates a digest-pinned index" {
    run_promotion

    [ "$status" -eq 0 ]
    [[ "$output" == *"Promoted pgvector pg17 0.8.6: $(published_digest)"* ]]
    grep -Fqx "COPY copy --all --preserve-digests docker://ghcr.io/testowner/ext-pgvector-staging@${AMD64_DIGEST} docker://ghcr.io/testowner/ext-pgvector:pg17-0.8.6-amd64" "$CALLS_FILE" || {
        echo "FAIL ASSERTION: staging copies must preserve the tested digest"
        false
    }
    grep -Fqx "COPY copy --all --preserve-digests docker://ghcr.io/testowner/ext-pgvector-staging@${ARM64_DIGEST} docker://ghcr.io/testowner/ext-pgvector:pg17-0.8.6-arm64" "$CALLS_FILE"
    grep -Fq "CREATE buildx imagetools create -t ghcr.io/testowner/ext-pgvector:pg17-0.8.6 ghcr.io/testowner/ext-pgvector@${AMD64_DIGEST} ghcr.io/testowner/ext-pgvector@${ARM64_DIGEST}" "$CALLS_FILE"
}

@test "a canonical index changed during testing refuses before any canonical write" {
    export CANONICAL_DIGEST="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    export DOCKER_MODE="index-read-fails"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: changed canonical index must refuse before any copy"
        false
    }
    [[ "$output" == *"Canonical index changed since testing"* ]]
    [[ ! -s "$CALLS_FILE" || "$(grep -cE '^(COPY|CREATE) ' "$CALLS_FILE" || true)" -eq 0 ]] || {
        echo "ASSERTION: changed canonical index must refuse before any copy"
        false
    }
}

@test "a declared absent canonical index that remains absent permits first publication" {
    export BASELINE_MODE="absent"
    export SKOPEO_MODE="canonical-absent"

    run_promotion

    [ "$status" -eq 0 ] || {
        echo "FAIL ASSERTION: a canonical index that remains absent must permit first publication"
        false
    }
    [ "$(grep -c '^COPY ' "$CALLS_FILE")" -eq 2 ]
    [ "$(grep -c '^CREATE ' "$CALLS_FILE")" -eq 1 ]
}

@test "a canonical index appearing after the caller declared it absent refuses before any copy" {
    export BASELINE_MODE="absent"
    export DOCKER_MODE="index-read-fails"

    run_promotion

    [[ "$(grep -cE '^(COPY|CREATE) ' "$CALLS_FILE" || true)" -eq 0 ]] || {
        echo "FAIL ASSERTION: an appeared canonical index must refuse before any copy"
        false
    }
    [[ "$output" == *"Canonical index appeared since testing"* ]]
    [ "$status" -ne 0 ] || {
        echo "FAIL ASSERTION: an appeared canonical index must refuse"
        false
    }
}

@test "an unreadable canonical index after the caller declared it absent refuses before any copy" {
    export BASELINE_MODE="absent"
    export SKOPEO_MODE="canonical-inspect-fails"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: an unreadable canonical index must refuse before any copy"
        false
    }
    [[ "$output" == *"Could not read the canonical index under the promotion lock"* ]]
    [[ "$(grep -cE '^(COPY|CREATE) ' "$CALLS_FILE" || true)" -eq 0 ]] || {
        echo "ASSERTION: an unreadable canonical index must refuse before any copy"
        false
    }
}

@test "an ambiguous canonical error containing a not-found phrase refuses before any copy" {
    export BASELINE_MODE="absent"
    export SKOPEO_MODE="canonical-unknown-auth"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "FAIL ASSERTION: an ambiguous canonical error must refuse before any copy"
        false
    }
    [[ "$output" == *"Could not read the canonical index under the promotion lock"* ]]
    [[ "$(grep -cE '^(COPY|CREATE) ' "$CALLS_FILE" || true)" -eq 0 ]] || {
        echo "ASSERTION: an ambiguous canonical error must stop before any copy"
        false
    }
}

@test "an identical post-publication index is reported as a failed rotation without rollback" {
    export BASELINE_DIGEST="$(published_digest)"
    export CANONICAL_DIGEST="$BASELINE_DIGEST"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: identical published index must be reported as a failed rotation"
        false
    }
    [[ "$output" == *"identical to the pre-test baseline; reporting failed rotation without rollback"* ]]
    [ "$(grep -c '^COPY ' "$CALLS_FILE")" -eq 2 ]
    [ "$(grep -c '^CREATE ' "$CALLS_FILE")" -eq 1 ]
}

@test "a malformed supplied digest stops before any registry write" {
    local malformed="sha256:not-a-digest"

    run env \
        OWNER="$OWNER" GITHUB_REPOSITORY_OWNER="$GITHUB_REPOSITORY_OWNER" EXTENSION_REGISTRY="$EXTENSION_REGISTRY" CALLS_FILE="$CALLS_FILE" \
        bash -c '
            skopeo() { printf "WRITE %s\\n" "$*" >> "$CALLS_FILE"; return 0; }
            docker() { printf "WRITE %s\\n" "$*" >> "$CALLS_FILE"; return 0; }
            export -f skopeo docker
            exec "$PROJECT_ROOT/scripts/rotation-promote.sh" \
                --extension pgvector --pg-major 17 --version 0.8.6 \
                --baseline-digest "$0" --amd64-digest "$0" --arm64-digest "$0"
        ' "$malformed"

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: malformed digest must fail before any registry write"
        false
    }
    [[ "$output" == *"Promotion requires a valid baseline, amd64, and arm64 OCI digest"* ]]
    [[ ! -s "$CALLS_FILE" ]] || {
        echo "ASSERTION: malformed digest must stop before any registry write"
        false
    }
}

@test "identical architecture digests stop before any registry write" {
    export ARM64_DIGEST="$AMD64_DIGEST"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: identical architecture digests must stop before any registry write"
        false
    }
    [[ "$output" == *"requires distinct amd64 and arm64 OCI digests"* ]]
    [[ ! -s "$CALLS_FILE" ]] || {
        echo "ASSERTION: identical architecture digests must stop before any registry write"
        false
    }
}

@test "an index passed as an amd64 input stops before any canonical write" {
    export SKOPEO_MODE="amd64-index"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "FAIL ASSERTION: an index passed as amd64 must stop before any canonical write"
        false
    }
    [[ "$output" == *"not a single linux/amd64 manifest"* ]]
    [[ "$(grep -cE '^(COPY|CREATE) ' "$CALLS_FILE" || true)" -eq 0 ]] || {
        echo "ASSERTION: an index passed as amd64 must stop before any canonical write"
        false
    }
}

@test "a wrong-platform amd64 input stops before any canonical write" {
    export SKOPEO_MODE="amd64-wrong-platform"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: a wrong-platform amd64 input must stop before any canonical write"
        false
    }
    [[ "$output" == *"not a single linux/amd64 manifest"* ]]
    [[ "$(grep -cE '^(COPY|CREATE) ' "$CALLS_FILE" || true)" -eq 0 ]] || {
        echo "ASSERTION: a wrong-platform amd64 input must stop before any canonical write"
        false
    }
}

@test "swapped architecture inputs stop before any canonical write" {
    export SKOPEO_MODE="amd64-wrong-platform"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: swapped architecture inputs must stop before any canonical write"
        false
    }
    [[ "$output" == *"not a single linux/amd64 manifest"* ]]
    [[ "$(grep -cE '^(COPY|CREATE) ' "$CALLS_FILE" || true)" -eq 0 ]] || {
        echo "ASSERTION: swapped architecture inputs must stop before any canonical write"
        false
    }
}

@test "an unavailable frozen source stops before any canonical write" {
    export SKOPEO_MODE="amd64-inspect-fails"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: unavailable source probe must stop before any canonical write"
        false
    }
    [[ "$output" == *"Could not verify the frozen staging amd64 manifest"* ]]
    [[ "$(grep -cE '^(COPY|CREATE) ' "$CALLS_FILE" || true)" -eq 0 ]] || {
        echo "ASSERTION: unavailable source probe must stop before any canonical write"
        false
    }
}

@test "an absent frozen source stops before any canonical write" {
    export SKOPEO_MODE="amd64-absent"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: an absent frozen source must stop before any canonical write"
        false
    }
    [[ "$output" == *"Could not verify the frozen staging amd64 manifest"* ]]
    [[ "$(grep -cE '^(COPY|CREATE) ' "$CALLS_FILE" || true)" -eq 0 ]] || {
        echo "ASSERTION: an absent frozen source must stop before any canonical write"
        false
    }
}

@test "a mismatched canonical architecture destination stops before index publication" {
    export DESTINATION_AMD64_DIGEST="sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

    run_promotion

    [ "$status" -ne 0 ]
    [[ "$output" == *"integrity tripwire"* ]]
    [ "$(grep -c '^COPY ' "$CALLS_FILE")" -eq 1 ]
    [ "$(grep -c '^CREATE ' "$CALLS_FILE" || true)" -eq 0 ]
}

@test "an absent canonical destination after copy stops before index publication" {
    export SKOPEO_MODE="destination-amd64-absent"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: an absent canonical destination must stop before index publication"
        false
    }
    [[ "$output" == *"integrity tripwire"* ]]
    [ "$(grep -c '^COPY ' "$CALLS_FILE")" -eq 1 ]
    [ "$(grep -c '^CREATE ' "$CALLS_FILE" || true)" -eq 0 ]
}

@test "an empty read-back index is rejected after publication" {
    export RAW_MANIFEST='{"schemaVersion":2,"manifests":[]}'

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "FAIL ASSERTION: an empty read-back index must be rejected after publication"
        false
    }
    [[ "$output" == *"did not contain exactly the requested linux/amd64 and linux/arm64 digests"* ]]
    [[ "$output" == *"was published but could not be verified"* ]]
    [ "$(grep -c '^CREATE ' "$CALLS_FILE")" -eq 1 ]
}

@test "a duplicate amd64 index without arm64 is rejected after publication" {
    export RAW_MANIFEST="{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[{\"digest\":\"$AMD64_DIGEST\",\"platform\":{\"os\":\"linux\",\"architecture\":\"amd64\"}},{\"digest\":\"$AMD64_DIGEST\",\"platform\":{\"os\":\"linux\",\"architecture\":\"amd64\"}}]}"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "FAIL ASSERTION: an index with duplicate amd64 and no arm64 must be rejected"
        false
    }
    [[ "$output" == *"did not contain exactly the requested linux/amd64 and linux/arm64 digests"* ]] || {
        echo "FAIL ASSERTION: duplicate amd64 must fail the exact-descriptor validator"
        false
    }
    [ "$(grep -c '^CREATE ' "$CALLS_FILE")" -eq 1 ]
}

@test "a failed read after index creation says the index was published but could not be verified" {
    export DOCKER_MODE="index-read-fails"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: a failed post-write read must report publication with unverified state"
        false
    }
    [[ "$output" == *"Canonical extension index was published but could not be verified"* ]]
    [[ "$output" != *"Canonical extension index was not published"* ]]
    [ "$(grep -c '^CREATE ' "$CALLS_FILE")" -eq 1 ]
}

@test "a failed create reports an unknown canonical outcome rather than no publication" {
    export DOCKER_MODE="create-fails"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: a failed create must stop promotion"
        false
    }
    [[ "$output" == *"publication outcome is unknown; canonical state may have changed"* ]]
    [[ "$output" != *"Canonical extension index was not published" ]]
    [ "$(grep -c '^CREATE ' "$CALLS_FILE")" -eq 1 ]
}

@test "a retry recovers a committed index without a further write" {
    export STATE_FILE="$TEST_TEMP_DIR/canonical-state"
    export DOCKER_MODE="commit-then-read-fails"

    run_promotion

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: the simulated crash interval must leave the first invocation unverified"
        false
    }
    [[ "$output" == *"was published but could not be verified"* ]]
    [ -s "$STATE_FILE" ]
    local writes_before
    writes_before="$(grep -cE '^(COPY|CREATE) ' "$CALLS_FILE")"

    export DOCKER_MODE="success"
    run_promotion

    [ "$status" -eq 0 ] || {
        echo "FAIL ASSERTION: a retry whose canonical index already has both requested digests must recover"
        false
    }
    [[ "$output" == *"Recovered promotion: canonical index already contains the requested digests"* ]]
    [ "$(grep -cE '^(COPY|CREATE) ' "$CALLS_FILE")" -eq "$writes_before" ] || {
        echo "ASSERTION: recovery must attempt no further canonical write"
        false
    }
}

@test "a constructed tag over 128 characters fails before any registry call" {
    local too_long_version
    too_long_version="$(printf 'a%.0s' {1..124})"

    run env \
        GITHUB_REPOSITORY_OWNER="$GITHUB_REPOSITORY_OWNER" EXTENSION_REGISTRY="$EXTENSION_REGISTRY" CALLS_FILE="$CALLS_FILE" \
        bash -c '
            skopeo() { printf "REGISTRY %s\\n" "$*" >> "$CALLS_FILE"; }
            docker() { printf "REGISTRY %s\\n" "$*" >> "$CALLS_FILE"; }
            export -f skopeo docker
            exec "$PROJECT_ROOT/scripts/rotation-promote.sh" \
                --extension pgvector --pg-major 17 --version "$0" \
                --baseline-digest "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" \
                --amd64-digest "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
                --arm64-digest "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        ' "$too_long_version"

    [ "$status" -ne 0 ] || {
        echo "FAIL ASSERTION: an overlong constructed OCI tag must fail"
        false
    }
    [[ "$output" == *"Constructed canonical OCI tag exceeds the grammar or 128-character limit"* ]] || {
        echo "FAIL ASSERTION: constructed tag guard must reject before registry calls"
        false
    }
    [[ ! -s "$CALLS_FILE" ]] || {
        echo "ASSERTION: an overlong tag must stop before any registry call"
        false
    }
}

@test "an argument cannot inject a GitHub Actions workflow command into logs" {
    local malicious_argument=$'--bad\n::add-mask::secret'

    run env GITHUB_REPOSITORY_OWNER="$GITHUB_REPOSITORY_OWNER" EXTENSION_REGISTRY="$EXTENSION_REGISTRY" \
        "$PROJECT_ROOT/scripts/rotation-promote.sh" "$malicious_argument"

    [ "$status" -ne 0 ] || {
        echo "ASSERTION: the malicious argument must remain an invalid argument"
        false
    }
    [[ "$output" == *"%0A::add-mask::secret"* ]] || {
        echo "FAIL ASSERTION: workflow command newline must be percent-escaped"
        false
    }
    while IFS= read -r output_line; do
        [[ "$output_line" != ::* ]] || {
            echo "FAIL ASSERTION: no logged output line may begin with an unescaped workflow command"
            false
        }
    done <<< "$output"
}

@test "DRY_RUN never invokes overridden registry clients" {
    local sentinel="$TEST_TEMP_DIR/registry-client-sentinel"
    local sentinel_calls="$TEST_TEMP_DIR/registry-client-sentinel-calls"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "SENTINEL %s\\n" "$*" >> "$SENTINEL_CALLS"' \
        'exit 97' > "$sentinel"
    chmod +x "$sentinel"
    : > "$sentinel_calls"

    run env \
        DRY_RUN=true SKOPEO="$sentinel" DOCKER="$sentinel" SENTINEL_CALLS="$sentinel_calls" \
        GITHUB_REPOSITORY_OWNER=$'testowner\n::add-mask::owner' EXTENSION_REGISTRY=$'ghcr.io\n::notice::registry' \
        "$PROJECT_ROOT/scripts/rotation-promote.sh" \
        --extension pgvector --pg-major 17 --version 0.8.6 \
        --baseline-digest "$BASELINE_DIGEST" \
        --amd64-digest "$AMD64_DIGEST" --arm64-digest "$ARM64_DIGEST"

    [[ ! -s "$sentinel_calls" ]] || {
        echo "FAIL ASSERTION: DRY_RUN must never invoke overridden registry clients" >&3
        false
    }
    [ "$status" -eq 0 ] || {
        echo "FAIL ASSERTION: DRY_RUN must complete without invoking overridden registry clients" >&3
        false
    }
    [[ "$output" == *"skopeo inspect --format {{.Digest}}"* ]]
    [[ "$output" == *"docker buildx imagetools create"* ]]
    [[ "$output" == *"Dry run completed promotion"* ]]
    [[ "$output" == *"ghcr.io%0A::notice::registry"* ]]
    [[ "$output" == *"testowner%0A::add-mask::owner"* ]]
    while IFS= read -r output_line; do
        [[ "$output_line" != ::* ]] || {
            echo "ASSERTION: DRY_RUN output must not contain an active workflow command"
            false
        }
    done <<< "$output"
}

@test "DRY_RUN completes when SKOPEO is false" {
    local sentinel="$TEST_TEMP_DIR/docker-client-sentinel"
    local sentinel_calls="$TEST_TEMP_DIR/docker-client-sentinel-calls"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "SENTINEL %s\\n" "$*" >> "$SENTINEL_CALLS"' \
        'exit 97' > "$sentinel"
    chmod +x "$sentinel"
    : > "$sentinel_calls"

    run env \
        DRY_RUN=true SKOPEO=false DOCKER="$sentinel" SENTINEL_CALLS="$sentinel_calls" \
        GITHUB_REPOSITORY_OWNER="$GITHUB_REPOSITORY_OWNER" EXTENSION_REGISTRY="$EXTENSION_REGISTRY" \
        "$PROJECT_ROOT/scripts/rotation-promote.sh" \
        --extension pgvector --pg-major 17 --version 0.8.6 \
        --baseline-digest "$BASELINE_DIGEST" \
        --amd64-digest "$AMD64_DIGEST" --arm64-digest "$ARM64_DIGEST"

    [[ ! -s "$sentinel_calls" ]] || {
        echo "FAIL ASSERTION: DRY_RUN must not invoke DOCKER when SKOPEO=false" >&3
        false
    }
    [ "$status" -eq 0 ] || {
        echo "FAIL ASSERTION: DRY_RUN must complete when SKOPEO=false" >&3
        false
    }
}
