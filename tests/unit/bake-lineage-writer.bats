#!/usr/bin/env bats

# Execute the strict bake-lineage writer extracted from the workflow against
# local JSON fixtures. The writer reads no registry state in this step.

load "../test_helper"

setup() {
    WORKFLOW="$PROJECT_ROOT/.github/workflows/auto-build.yaml"
    setup_temp_dir
    STEP_BODY=$(yq -r '.jobs."bake-build-amd64".steps[] | select(.id == "write-bake-lineage") | .run' "$WORKFLOW")
    BAKE_SBOM_BODY=$(yq -r '.jobs."bake-build-amd64".steps[] | select(.id == "bake-sbom") | .run' "$WORKFLOW")
    CACHE_MERGE_BODY=$(yq -r '.jobs."cache-lineage".steps[] | select(.id == "merge") | .run' "$WORKFLOW")
    [ -n "$STEP_BODY" ]
    [ -n "$BAKE_SBOM_BODY" ]
    [ -n "$CACHE_MERGE_BODY" ]
    ln -s "$PROJECT_ROOT/helpers" "$TEST_TEMP_DIR/helpers"
    mkdir -p "$TEST_TEMP_DIR/bin"
    PLAN="$TEST_TEMP_DIR/bake-plan.json"
    DESCRIPTORS="$TEST_TEMP_DIR/bake-base-descriptors.json"
    METADATA="$TEST_TEMP_DIR/bake-metadata-amd64.json"
    source "$PROJECT_ROOT/helpers/base-image-utils.sh"
}

teardown() {
    teardown_temp_dir
}

digest() {
    local char=$1
    printf 'sha256:'
    printf "%064d" 0 | tr '0' "$char"
}

cell() {
    local container=$1 tag=$2 target_id=$3 base_identity=$4
    local build_args=${5:-'{"NPROC":"${NPROC}"}'}
    local is_default=${6-true}
    local is_latest_version=${7-true}
    jq -cn \
        --arg container "$container" \
        --arg tag "$tag" \
        --arg target_id "$target_id" \
        --argjson base_identity "$base_identity" \
        --argjson build_args "$build_args" \
        --arg is_default "$is_default" \
        --arg is_latest_version "$is_latest_version" \
        '{container:$container, tag:$tag, target_id:$target_id, version:$tag,
          flavor:"", dockerfile:"Dockerfile", build_args:$build_args, base_identity:$base_identity}
        + (if $is_default == "" then {} else {is_default:($is_default | fromjson)} end)
        + (if $is_latest_version == "" then {} else {is_latest_version:($is_latest_version | fromjson)} end)'
}

write_inputs() {
    local plan=$1 descriptors=$2 metadata=$3
    printf '%s\n' "$plan" > "$PLAN"
    printf '%s\n' "$descriptors" > "$DESCRIPTORS"
    printf '%s\n' "$metadata" > "$METADATA"
}

run_writer() {
    run env \
        BAKE_PLAN_FILE="$PLAN" \
        BAKE_BASE_DESCRIPTORS_FILE="$DESCRIPTORS" \
        BAKE_METADATA_FILE="$METADATA" \
        REMOTE_CR="ghcr.io/example" \
        bash -c 'cd "$1" && bash -c "$2"' _ "$TEST_TEMP_DIR" "$STEP_BODY"
}

run_writer_without_nproc() {
    run env -u NPROC \
        BAKE_PLAN_FILE="$PLAN" \
        BAKE_BASE_DESCRIPTORS_FILE="$DESCRIPTORS" \
        BAKE_METADATA_FILE="$METADATA" \
        REMOTE_CR="ghcr.io/example" \
        bash -c 'cd "$1" && bash -c "$2"' _ "$TEST_TEMP_DIR" "$STEP_BODY"
}

record_path() {
    printf '%s/.build-lineage/%s-%s.json' "$TEST_TEMP_DIR" "$1" "$2"
}

assert_boolean_field() {
    local record=$1 field=$2 expected=$3
    jq -e \
        --arg field "$field" \
        --argjson expected "$expected" \
        '(.[$field] == $expected) and (.[$field] | type == "boolean")' \
        <<< "$record" >/dev/null
}

lineage_record() {
    local container=$1 tag=$2 build_digest=$3
    jq -cn --arg container "$container" --arg tag "$tag" --arg build_digest "$build_digest" \
        '{lineage_schema_version:3,container:$container,version:$tag,tag:$tag,
          flavor:"",dockerfile:"Dockerfile",platform:"linux/amd64",runtime:"docker",
          build_digest:$build_digest,built_at:"2026-09-24T00:00:00Z",
          duration_seconds:1,github_actions:true,images:{dockerhub:"docker.io/example/image",ghcr:"ghcr.io/example/image"},
          build_args:{},base_image_kind:"not_evaluated"}'
}

@test "bake SBOM step removes only a failed cell output before the broad upload glob" {
    local plan call_count
    plan='[{"container":"good","tag":"1","intermediate_ref":"ghcr.io/example/good:1"},{"container":"bad","tag":"2","intermediate_ref":"ghcr.io/example/bad:2"}]'
    printf '%s\n' "$plan" > "$PLAN"
    call_count="$TEST_TEMP_DIR/syft-call-count"
    cat > "$TEST_TEMP_DIR/bin/syft" <<'STUB'
#!/usr/bin/env bash
for argument in "$@"; do
    [[ "$argument" == "--help" ]] && exit 0
done
output_file=""
for argument in "$@"; do
    case "$argument" in spdx-json=*) output_file="${argument#spdx-json=}" ;; esac
done
count=0
[[ -r "$SYFT_CALL_COUNT_FILE" ]] && count=$(cat "$SYFT_CALL_COUNT_FILE")
count=$((count + 1))
printf '%s\n' "$count" > "$SYFT_CALL_COUNT_FILE"
if [[ "$count" -ge 2 ]]; then
    printf '{"incomplete":' > "$output_file"
    exit 1
fi
printf '{"spdxVersion":"SPDX-2.3","SPDXID":"SPDXRef-DOCUMENT","packages":[]}' > "$output_file"
STUB
    chmod +x "$TEST_TEMP_DIR/bin/syft"

    run env PATH="$TEST_TEMP_DIR/bin:$PATH" BAKE_PLAN_FILE="$PLAN" REMOTE_CR="ghcr.io/example" \
        GITHUB_OUTPUT="$TEST_TEMP_DIR/github-output" SYFT_CALL_COUNT_FILE="$call_count" \
        bash -c 'cd "$1" && bash -c "$2"' _ "$TEST_TEMP_DIR" "$BAKE_SBOM_BODY"

    [ "$status" -eq 0 ] || return 1
    [ -f "$TEST_TEMP_DIR/.build-lineage/good-1.sbom.json" ] || return 1
    [ ! -e "$TEST_TEMP_DIR/.build-lineage/bad-2.sbom.json" ] || return 1
}

@test "cache lineage promotes only bake records authorized by receipts after a partial merge" {
    local old_first old_second new_first new_second
    old_first=$(digest a)
    old_second=$(digest b)
    new_first=$(digest c)
    new_second=$(digest d)
    mkdir -p "$TEST_TEMP_DIR/.build-lineage" \
        "$TEST_TEMP_DIR/.build-lineage-artifacts/build-lineage-bake-amd64-test" \
        "$TEST_TEMP_DIR/.bake-merge-receipts-artifacts/bake-merge-receipts-test"
    lineage_record first 1 "$old_first" > "$TEST_TEMP_DIR/.build-lineage/first-1.json"
    lineage_record second 2 "$old_second" > "$TEST_TEMP_DIR/.build-lineage/second-2.json"
    lineage_record first 1 "$new_first" > "$TEST_TEMP_DIR/.build-lineage-artifacts/build-lineage-bake-amd64-test/first-1.json"
    lineage_record second 2 "$new_second" > "$TEST_TEMP_DIR/.build-lineage-artifacts/build-lineage-bake-amd64-test/second-2.json"
    printf '{"container":"first","tag":"1"}\n' > "$TEST_TEMP_DIR/.bake-merge-receipts-artifacts/bake-merge-receipts-test/first.json"

    run env BAKE_MERGE_RESULT=failure GITHUB_OUTPUT="$TEST_TEMP_DIR/github-output" \
        bash -c 'cd "$1" && bash -c "$2"' _ "$TEST_TEMP_DIR" "$CACHE_MERGE_BODY"

    [ "$status" -eq 0 ] || return 1
    [ "$(jq -r '.build_digest' "$TEST_TEMP_DIR/.build-lineage/first-1.json")" = "$new_first" ] || return 1
    [ "$(jq -r '.build_digest' "$TEST_TEMP_DIR/.build-lineage/second-2.json")" = "$old_second" ] || return 1
}

@test "external index descriptor writes a valid schema-v3 record" {
    local build_digest base_digest base_identity plan metadata descriptors record
    build_digest=$(digest a)
    base_digest=$(digest b)
    base_identity='{"kind":"external","ref":"docker.io/library/alpine:3.21"}'
    plan="[$(cell app 1.0 app_1 "$base_identity")]"
    metadata=$(jq -cn --arg digest "$build_digest" '{app_1:{"containerimage.digest":$digest}}')
    descriptors=$(jq -cn --arg digest "$base_digest" '{"docker.io/library/alpine:3.21":{digest:$digest,mediaType:"application/vnd.oci.image.index.v1+json"}}')
    write_inputs "$plan" "$descriptors" "$metadata"

    run_writer
    [ "$status" -eq 0 ]
    record=$(cat "$(record_path app 1.0)")
    lineage_complete_record_valid "$record"
    [ "$(jq -r '.lineage_schema_version' <<< "$record")" = 3 ]
    [ "$(jq -r '.base_image_digest' <<< "$record")" = "$base_digest" ]
}

@test "writer preserves false planned booleans" {
    local build_digest base_identity plan metadata record case_name target_id
    local -a case_names is_default_values is_latest_version_values
    build_digest=$(digest a)
    base_identity='{"kind":"not_evaluated"}'
    case_names=(both-false both-true default-true-latest-false default-false-latest-true)
    is_default_values=(false true true false)
    is_latest_version_values=(false true false true)
    plan='['
    metadata='{}'
    for i in "${!case_names[@]}"; do
        case_name=${case_names[$i]}
        target_id="${case_name//-/_}_1"
        plan+="$(cell "$case_name" 1 "$target_id" "$base_identity" '{"NPROC":"${NPROC}"}' "${is_default_values[$i]}" "${is_latest_version_values[$i]}"),"
        metadata=$(jq -c --arg target_id "$target_id" --arg digest "$build_digest" \
            '. + {($target_id): {"containerimage.digest": $digest}}' <<< "$metadata")
    done
    plan=${plan%,}
    plan+=']'
    write_inputs "$plan" '{}' "$metadata"

    run_writer
    [ "$status" -eq 0 ]
    for i in "${!case_names[@]}"; do
        record=$(cat "$(record_path "${case_names[$i]}" 1)")
        assert_boolean_field "$record" is_default "${is_default_values[$i]}"
        assert_boolean_field "$record" is_latest_version "${is_latest_version_values[$i]}"
    done
}

@test "writer rejects absent and non-boolean planned boolean fields" {
    local build_digest base_identity plan metadata case_name target_id
    local -a case_names is_default_values is_latest_version_values
    build_digest=$(digest a)
    base_identity='{"kind":"not_evaluated"}'
    case_names=(absent-default string-default number-default null-default absent-latest string-latest number-latest null-latest)
    is_default_values=('' '"false"' 0 null true true true true)
    is_latest_version_values=(true true true true '' '"false"' 0 null)
    plan='['
    metadata='{}'
    for i in "${!case_names[@]}"; do
        case_name=${case_names[$i]}
        target_id="${case_name//-/_}_1"
        plan+="$(cell "$case_name" 1 "$target_id" "$base_identity" '{"NPROC":"${NPROC}"}' "${is_default_values[$i]}" "${is_latest_version_values[$i]}"),"
        metadata=$(jq -c --arg target_id "$target_id" --arg digest "$build_digest" \
            '. + {($target_id): {"containerimage.digest": $digest}}' <<< "$metadata")
    done
    plan+="$(cell valid 1 valid_1 "$base_identity")"
    plan+=']'
    metadata=$(jq -c --arg digest "$build_digest" \
        '. + {valid_1: {"containerimage.digest": $digest}}' <<< "$metadata")
    write_inputs "$plan" '{}' "$metadata"

    run_writer
    [ "$status" -eq 1 ]
    for case_name in "${case_names[@]}"; do
        [[ "$output" == *"${case_name}:1: malformed planned build fields"* ]]
        [ ! -e "$(record_path "$case_name" 1)" ]
    done
    [ -e "$(record_path valid 1)" ]
}

@test "bake NPROC reference records its declared default when writer environment unsets NPROC" {
    local build_digest base_identity plan metadata descriptors
    build_digest=$(digest a)
    base_identity='{"kind":"external","ref":"docker.io/library/alpine:3.21"}'
    plan="[$(cell app 1.0 app_1 "$base_identity")]"
    metadata=$(jq -cn --arg digest "$build_digest" '{app_1:{"containerimage.digest":$digest}}')
    descriptors=$(jq -cn --arg digest "$(digest b)" '{"docker.io/library/alpine:3.21":{digest:$digest,mediaType:"application/vnd.oci.image.index.v1+json"}}')
    write_inputs "$plan" "$descriptors" "$metadata"

    run_writer_without_nproc
    [ "$status" -eq 0 ]
    [ "$(jq -r '.build_args.NPROC' "$(record_path app 1.0)")" = 1 ]

    NPROC= run_writer
    [ "$status" -eq 0 ]
    [ "$(jq -r '.build_args.NPROC' "$(record_path app 1.0)")" = 1 ]
}

@test "writer resolves a bake NPROC reference from its environment" {
    local build_digest base_identity plan metadata descriptors
    build_digest=$(digest a)
    base_identity='{"kind":"external","ref":"docker.io/library/alpine:3.21"}'
    plan="[$(cell app 1.0 app_1 "$base_identity")]"
    metadata=$(jq -cn --arg digest "$build_digest" '{app_1:{"containerimage.digest":$digest}}')
    descriptors=$(jq -cn --arg digest "$(digest b)" '{"docker.io/library/alpine:3.21":{digest:$digest,mediaType:"application/vnd.oci.image.index.v1+json"}}')
    write_inputs "$plan" "$descriptors" "$metadata"

    NPROC=8 run_writer
    [ "$status" -eq 0 ]
    [ "$(jq -r '.build_args.NPROC' "$(record_path app 1.0)")" = 8 ]
}

@test "writer leaves embedded and unrelated bake variable references unchanged" {
    local build_digest base_identity plan metadata descriptors no_nproc_args number_args embedded_args other_args
    build_digest=$(digest a)
    base_identity='{"kind":"external","ref":"docker.io/library/alpine:3.21"}'
    no_nproc_args='{}'
    number_args='{"NPROC":4}'
    embedded_args='{"NPROC":"prefix-${NPROC}-suffix"}'
    other_args='{"OTHER":"${OTHER}"}'
    plan="[$(cell no-nproc 1 no_nproc_1 "$base_identity" "$no_nproc_args"),$(cell number 1 number_1 "$base_identity" "$number_args"),$(cell embedded 1 embedded_1 "$base_identity" "$embedded_args"),$(cell other 1 other_1 "$base_identity" "$other_args") ]"
    metadata=$(jq -cn --arg digest "$build_digest" '{no_nproc_1:{"containerimage.digest":$digest},number_1:{"containerimage.digest":$digest},embedded_1:{"containerimage.digest":$digest},other_1:{"containerimage.digest":$digest}}')
    descriptors=$(jq -cn --arg digest "$(digest b)" '{"docker.io/library/alpine:3.21":{digest:$digest,mediaType:"application/vnd.oci.image.index.v1+json"}}')
    write_inputs "$plan" "$descriptors" "$metadata"

    run_writer_without_nproc
    [ "$status" -eq 0 ]
    [ "$(jq -c '.build_args' "$(record_path no-nproc 1)")" = '{}' ]
    [ "$(jq -r '.build_args.NPROC' "$(record_path number 1)")" = 4 ]
    [ "$(jq -r '.build_args.NPROC' "$(record_path embedded 1)")" = 'prefix-${NPROC}-suffix' ]
    [ "$(jq -r '.build_args.OTHER' "$(record_path other 1)")" = '${OTHER}' ]
}

@test "sibling, unresolved, and not_evaluated cells write their markers" {
    local build_digest sibling unresolved not_evaluated plan metadata record
    build_digest=$(digest a)
    sibling='{"kind":"sibling_target","supplier":{"container":"base","version":"1","flavor":"","textual_ref":"target:base","bake_target_id":"base_1"}}'
    unresolved='{"kind":"unresolved","ref":"docker.io/library/missing:1"}'
    not_evaluated='{"kind":"not_evaluated"}'
    plan="[$(cell sibling 1 sibling_1 "$sibling"),$(cell unresolved 1 unresolved_1 "$unresolved"),$(cell pending 1 pending_1 "$not_evaluated")]"
    metadata=$(jq -cn --arg digest "$build_digest" '{sibling_1:{"containerimage.digest":$digest},unresolved_1:{"containerimage.digest":$digest},pending_1:{"containerimage.digest":$digest}}')
    write_inputs "$plan" '{}' "$metadata"

    run_writer
    [ "$status" -eq 0 ]
    record=$(cat "$(record_path sibling 1)")
    [ "$(jq -r '.base_image_kind' <<< "$record")" = sibling_target ]
    [ "$(jq -r '.base_image_sibling.platform' <<< "$record")" = linux/amd64 ]
    [ "$(jq -r '[.base_image_sibling | keys[]] | sort | join(",")' <<< "$record")" = 'bake_target_id,container,flavor,platform,textual_ref,version' ]
    [ "$(jq -r '.base_image_kind' "$(record_path unresolved 1)")" = unresolved_external_base ]
    [ "$(jq -r '.base_image_kind' "$(record_path pending 1)")" = not_evaluated ]
    [ "$(jq 'has("base_image_ref") or has("base_image_digest")' "$(record_path unresolved 1)")" = false ]
    [ "$(jq 'has("base_image_ref") or has("base_image_digest")' "$(record_path pending 1)")" = false ]
}

@test "missing and single-manifest external descriptors fail the writer" {
    local build_digest base_identity plan metadata descriptors
    build_digest=$(digest a)
    base_identity='{"kind":"external","ref":"docker.io/library/alpine:3.21"}'
    plan="[$(cell missing 1 missing_1 '{"kind":"external","ref":"docker.io/library/busybox:1"}'),$(cell single 1 single_1 "$base_identity")]"
    metadata=$(jq -cn --arg digest "$build_digest" '{missing_1:{"containerimage.digest":$digest},single_1:{"containerimage.digest":$digest}}')
    descriptors=$(jq -cn --arg digest "$(digest b)" '{"docker.io/library/alpine:3.21":{digest:$digest,mediaType:"application/vnd.oci.image.manifest.v1+json"}}')
    write_inputs "$plan" "$descriptors" "$metadata"

    run_writer
    [ "$status" -eq 1 ]
    [[ "$output" == *'missing:1'* && "$output" == *'single:1'* ]]
    [ ! -e "$(record_path missing 1)" ]
    [ ! -e "$(record_path single 1)" ]
}

@test "bake-plan rejects failed and non-index concrete external probes" {
    local probe_step bin_dir plan
    probe_step=$(yq -r '.jobs."bake-plan".steps[] | select(.name == "Inspect planned external base indexes") | .run' "$WORKFLOW")
    [ -n "$probe_step" ]
    bin_dir="$TEST_TEMP_DIR/bin"
    mkdir -p "$bin_dir"
    printf '%s\n' '#!/bin/sh' 'case "$MOCK_DOCKER_MODE" in' \
        '  fail) exit 1 ;;' \
        '  single) printf "%s\\n" "{\\\"digest\\\":\\\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\\",\\\"mediaType\\\":\\\"application/vnd.oci.image.manifest.v1+json\\\"}" ;;' \
        'esac' > "$bin_dir/docker"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$bin_dir/sleep"
    chmod +x "$bin_dir/docker" "$bin_dir/sleep"
    plan='[{"base_identity":{"kind":"external","ref":"docker.io/library/alpine:3.21"}}]'
    printf '%s\n' "$plan" > "$TEST_TEMP_DIR/bake-plan.json"

    run env PATH="$bin_dir:$PATH" MOCK_DOCKER_MODE=fail DRY_RUN=false IS_PR=false \
        bash -c 'cd "$1" && bash -c "$2"' _ "$TEST_TEMP_DIR" "$probe_step"
    [ "$status" -eq 1 ]
    [[ "$output" == *'Could not inspect planned external base index docker.io/library/alpine:3.21'* ]]

    run env PATH="$bin_dir:$PATH" MOCK_DOCKER_MODE=single DRY_RUN=false IS_PR=false \
        bash -c 'cd "$1" && bash -c "$2"' _ "$TEST_TEMP_DIR" "$probe_step"
    [ "$status" -eq 1 ]
    [[ "$output" == *'returned no usable index descriptor'* ]]
}

@test "bake-plan compute writes the fixture generator cells array" {
    local compute_step fixture_cells
    compute_step=$(yq -r '.jobs."bake-plan".steps[] | select(.name == "Compute bake lineage plan") | .run' "$WORKFLOW")
    [ -n "$compute_step" ]
    mkdir -p "$TEST_TEMP_DIR/scripts"
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' \
        '[[ "${FIXTURE_GENERATOR_MODE:-success}" != fail ]]' \
        'printf "%s\\n" "$FIXTURE_CELLS"' > "$TEST_TEMP_DIR/scripts/generate-bake-hcl.sh"
    chmod +x "$TEST_TEMP_DIR/scripts/generate-bake-hcl.sh"
    fixture_cells=$(jq -cn '[range(0; 24) | {container:("fixture-" + tostring)}]')

    run env BAKE_CONTAINERS=fixture BAKE_RETAINED_CONTAINERS= BAKE_FINAL_BUILDS='[]' \
        FIXTURE_CELLS="$fixture_cells" \
        bash -c 'cd "$1" && bash -c "$2"' _ "$TEST_TEMP_DIR" "$compute_step"
    [ "$status" -eq 0 ]
    [ "$(jq -r 'type' "$TEST_TEMP_DIR/bake-plan.json")" = array ]
    [ "$(jq -r 'length' "$TEST_TEMP_DIR/bake-plan.json")" -eq 24 ]
    [[ "$output" == *'::notice::Bake lineage plan contains 24 cells'* ]]

    run env BAKE_CONTAINERS=fixture BAKE_RETAINED_CONTAINERS= BAKE_FINAL_BUILDS='[]' \
        FIXTURE_GENERATOR_MODE=fail FIXTURE_CELLS="$fixture_cells" \
        bash -c 'cd "$1" && bash -c "$2"' _ "$TEST_TEMP_DIR" "$compute_step"
    [ "$status" -ne 0 ]
}

@test "bake-plan inspection rejects invalid plans and accepts no external cells" {
    local inspect_step plan
    inspect_step=$(yq -r '.jobs."bake-plan".steps[] | select(.name == "Inspect planned external base indexes") | .run' "$WORKFLOW")
    [ -n "$inspect_step" ]

    for plan in true '{}' '' '[true]'; do
        printf '%s\n' "$plan" > "$TEST_TEMP_DIR/bake-plan.json"
        run env DRY_RUN=false IS_PR=false \
            bash -c 'cd "$1" && bash -c "$2"' _ "$TEST_TEMP_DIR" "$inspect_step"
        [ "$status" -eq 1 ]
        [[ "$output" == *'bake-plan.json'* ]]
    done

    printf '%s\n' '[{"base_identity":{"kind":"not_evaluated"}}]' > "$TEST_TEMP_DIR/bake-plan.json"
    run env DRY_RUN=false IS_PR=false \
        bash -c 'cd "$1" && bash -c "$2"' _ "$TEST_TEMP_DIR" "$inspect_step"
    [ "$status" -eq 0 ]
    [ "$(jq -c . "$TEST_TEMP_DIR/bake-base-descriptors.json")" = '{}' ]
}

@test "missing, malformed, short, nonhex, and uppercase metadata digests fail named cells but write valid cells" {
    local build_digest base_identity plan metadata
    build_digest=$(digest a)
    base_identity='{"kind":"not_evaluated"}'
    plan="[$(cell absent 1 absent_1 "$base_identity"),$(cell malformed 1 malformed_1 "$base_identity"),$(cell short 1 short_1 "$base_identity"),$(cell nonhex 1 nonhex_1 "$base_identity"),$(cell uppercase 1 uppercase_1 "$base_identity"),$(cell valid 1 valid_1 "$base_identity")]"
    metadata=$(jq -cn --arg digest "$build_digest" '{malformed_1:{"containerimage.digest":"not-a-digest"},short_1:{"containerimage.digest":"sha256:111"},nonhex_1:{"containerimage.digest":"sha256:gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg"},uppercase_1:{"containerimage.digest":"sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},valid_1:{"containerimage.digest":$digest}}')
    write_inputs "$plan" '{}' "$metadata"

    run_writer
    [ "$status" -eq 1 ]
    [[ "$output" == *'absent:1'* && "$output" == *'malformed:1'* && "$output" == *'short:1'* && "$output" == *'nonhex:1'* && "$output" == *'uppercase:1'* ]]
    [ -f "$(record_path valid 1)" ]
    [ ! -e "$(record_path absent 1)" ]
    [ ! -e "$(record_path malformed 1)" ]
    [ ! -e "$(record_path short 1)" ]
    [ ! -e "$(record_path nonhex 1)" ]
    [ ! -e "$(record_path uppercase 1)" ]
}

@test "valid image_id is retained while absent and malformed ids are omitted" {
    local build_digest image_id base_identity plan metadata
    build_digest=$(digest a)
    image_id=$(digest c)
    base_identity='{"kind":"not_evaluated"}'
    plan="[$(cell present 1 present_1 "$base_identity"),$(cell absent 1 absent_1 "$base_identity"),$(cell malformed 1 malformed_1 "$base_identity")]"
    metadata=$(jq -cn --arg digest "$build_digest" --arg image_id "$image_id" '{present_1:{"containerimage.digest":$digest,"containerimage.config.digest":$image_id},absent_1:{"containerimage.digest":$digest},malformed_1:{"containerimage.digest":$digest,"containerimage.config.digest":"bad"}}')
    write_inputs "$plan" '{}' "$metadata"

    run_writer
    [ "$status" -eq 0 ]
    [ "$(jq -r '.image_id' "$(record_path present 1)")" = "$image_id" ]
    [ "$(jq 'has("image_id")' "$(record_path absent 1)")" = false ]
    [ "$(jq 'has("image_id")' "$(record_path malformed 1)")" = false ]
}

@test "unreadable plan descriptor and metadata inputs each fail naming the file" {
    local build_digest base_identity plan metadata missing
    build_digest=$(digest a)
    base_identity='{"kind":"not_evaluated"}'
    plan="[$(cell app 1 app_1 "$base_identity")]"
    metadata=$(jq -cn --arg digest "$build_digest" '{app_1:{"containerimage.digest":$digest}}')
    write_inputs "$plan" '{}' "$metadata"

    missing="$TEST_TEMP_DIR/missing-plan.json"
    PLAN="$missing"
    run_writer
    [ "$status" -eq 1 ]
    [[ "$output" == *"$missing"* ]]

    PLAN="$TEST_TEMP_DIR/bake-plan.json"
    DESCRIPTORS="$TEST_TEMP_DIR/missing-descriptors.json"
    missing="$DESCRIPTORS"
    run_writer
    [ "$status" -eq 1 ]
    [[ "$output" == *"$missing"* ]]

    DESCRIPTORS="$TEST_TEMP_DIR/bake-base-descriptors.json"
    METADATA="$TEST_TEMP_DIR/missing-metadata.json"
    missing="$METADATA"
    run_writer
    [ "$status" -eq 1 ]
    [[ "$output" == *"$missing"* ]]
}

@test "workflow wiring keeps the plan and strict writer contract" {
    [ "$(yq -r '.jobs."bake-plan".needs | join(",")' "$WORKFLOW")" = 'detect-containers,build-extensions,merge-extension-manifests,sync-base-images' ]
    [ "$(yq -r '.jobs."bake-plan".permissions.packages' "$WORKFLOW")" = read ]
    [ "$(yq -r '.jobs."bake-build-amd64".needs | join(",")' "$WORKFLOW")" = 'detect-containers,build-extensions,merge-extension-manifests,sync-base-images,bake-plan' ]
    [[ "$(yq -r '.jobs."bake-build-amd64".if' "$WORKFLOW")" == *'needs.bake-plan.result == '\''success'\'''* ]]
    [ "$(yq -r '.jobs."bake-build-arm64".needs | join(",")' "$WORKFLOW")" = 'detect-containers,build-extensions,merge-extension-manifests,sync-base-images,bake-plan' ]
    [[ "$(yq -r '.jobs."bake-build-arm64".if' "$WORKFLOW")" == *'needs.bake-plan.result == '\''success'\'''* ]]
    [ "$(yq -r '.jobs."bake-build-amd64".steps[] | select(.id == "write-bake-lineage") | has("continue-on-error")' "$WORKFLOW")" = false ]
    [ "$(yq -r '.jobs."bake-build-amd64".steps[] | select(.id == "bake-sbom") | ."continue-on-error"' "$WORKFLOW")" = true ]
    [[ "$(yq -r '.jobs."bake-build-amd64".steps[] | select(.id == "upload_build_lineage_bake_amd64") | .if' "$WORKFLOW")" == *'steps.write-bake-lineage.outcome == '\''success'\'''* ]]
    inspect_body=$(yq -r '.jobs."bake-plan".steps[] | select(.name == "Inspect planned external base indexes") | .run' "$WORKFLOW")
    [[ "$inspect_body" == *'retry_with_backoff 2 10 timeout -k 5 30'* && "$inspect_body" == *'DRY_RUN:-false'* && "$inspect_body" == *'IS_PR'* ]]
    [ "$(yq -r '.jobs."bake-plan".steps[] | select(.name == "Upload bake lineage plan") | .with.name' "$WORKFLOW")" = 'bake-plan-${{ github.run_id }}' ]
    [ "$(yq -r '.jobs."cache-lineage".steps[] | select(.id == "merge") | .env.BAKE_MERGE_RESULT' "$WORKFLOW")" = '${{ needs.bake-merge.result }}' ]
    [ "$(yq -r '.jobs."bake-merge".steps[] | select(.name == "Upload bake merge receipts") | .if' "$WORKFLOW")" = 'always()' ]
    [ "$(yq -r '.jobs."bake-merge".steps[] | select(.name == "Upload bake merge receipts") | .with.name' "$WORKFLOW")" = 'bake-merge-receipts-${{ github.run_id }}' ]
    [ "$(yq -r '.jobs."cache-lineage".steps[] | select(.name == "Download bake merge receipts") | .with.pattern' "$WORKFLOW")" = 'bake-merge-receipts-*' ]
    cache_merge_body=$(yq -r '.jobs."cache-lineage".steps[] | select(.id == "merge") | .run' "$WORKFLOW")
    [[ "$cache_merge_body" == *'build-lineage-bake-'* && "$cache_merge_body" == *'BAKE_MERGE_RESULT" != "success"'* && "$cache_merge_body" == *'receipt_matches_lineage'* && "$cache_merge_body" == *'lineage_complete_record_valid'* ]]
}
