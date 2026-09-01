#!/usr/bin/env bash
# Shared jq validation contracts for GHCR package-version records used by the
# destructive registry pruners.  Callers deliberately choose one of the named
# contracts below; they cannot supply their own field list.

# Decimal values received from a work frame or configuration are never Bash
# arithmetic operands.  Keep their syntax and comparisons here so callers use
# the same overflow-safe rule everywhere.
is_canonical_decimal() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

decimal_string_greater_than() {
  local left="$1" right="$2"

  [[ ${#left} -gt ${#right} ]] \
    || { [[ ${#left} -eq ${#right} ]] && [[ "$left" > "$right" ]]; }
}

decimal_strings_equal() {
  [[ "$1" == "$2" ]]
}

# Result counters arrive from a function boundary, not from the accumulators
# that consume them.  Parse every field here before it is assigned or used in
# arithmetic, and update the paired aggregate in the same checked operation.
# Arguments after `label` are output-name/aggregate-name pairs; use `-` when a
# validated field must not contribute to an aggregate (for an incomplete
# assessment, for example).
parse_result_counters() {
  local _result_counter_record="$1" _result_counter_label="$2"
  local _result_counter_argument_count _result_counter_pair_count _result_counter_index
  local _result_counter_field _result_counter_remaining _result_counter_aggregate
  local _result_counter_output_name _result_counter_total_name
  local _result_counter_output_position _result_counter_total_position
  local -a _result_counter_values=()

  _result_counter_argument_count=$(( $# - 2 ))
  if (( _result_counter_argument_count < 2 || _result_counter_argument_count % 2 != 0 )); then
    printf 'result-counter parser misuse: expected output-name/aggregate-name pairs\n' >&2
    return 64
  fi
  if [[ "$_result_counter_record" == *$'\n'* ]]; then
    printf '%s rejected: result record must contain one line\n' "$_result_counter_label" >&2
    return 1
  fi
  IFS='|' read -r -a _result_counter_values <<< "$_result_counter_record"
  _result_counter_pair_count=$(( _result_counter_argument_count / 2 ))
  if [[ ${#_result_counter_values[@]} -ne $_result_counter_pair_count ]]; then
    printf '%s rejected: expected %s counters\n' "$_result_counter_label" "$_result_counter_pair_count" >&2
    return 1
  fi

  for ((_result_counter_index = 0; _result_counter_index < _result_counter_pair_count; _result_counter_index++)); do
    _result_counter_field="${_result_counter_values[$_result_counter_index]}"
    if ! is_canonical_decimal "$_result_counter_field" \
      || decimal_string_greater_than "$_result_counter_field" 2147483647; then
      printf '%s rejected: counter %s must be a canonical decimal between 0 and 2147483647\n' \
        "$_result_counter_label" "$((_result_counter_index + 1))" >&2
      return 1
    fi
  done

  for ((_result_counter_index = 0; _result_counter_index < _result_counter_pair_count; _result_counter_index++)); do
    _result_counter_field="${_result_counter_values[$_result_counter_index]}"
    _result_counter_output_position=$((3 + _result_counter_index * 2))
    _result_counter_output_name="${!_result_counter_output_position}"
    # shellcheck disable=SC2178 # The caller intentionally supplies scalar destinations.
    local -n _result_counter_output="$_result_counter_output_name"
    _result_counter_output="$_result_counter_field"

    _result_counter_total_position=$((4 + _result_counter_index * 2))
    _result_counter_total_name="${!_result_counter_total_position}"
    [[ "$_result_counter_total_name" == '-' ]] && continue
    # shellcheck disable=SC2178 # The caller intentionally supplies scalar aggregate destinations.
    local -n _result_counter_total="$_result_counter_total_name"
    _result_counter_aggregate="$_result_counter_total"
    if ! is_canonical_decimal "$_result_counter_aggregate" \
      || decimal_string_greater_than "$_result_counter_aggregate" 2147483647; then
      printf '%s rejected: aggregate is outside the executable range\n' "$_result_counter_label" >&2
      return 64
    fi
    printf -v _result_counter_remaining '%d' "$((2147483647 - _result_counter_aggregate))"
    if decimal_string_greater_than "$_result_counter_field" "$_result_counter_remaining"; then
      printf '%s rejected: counter %s would overflow its aggregate\n' \
        "$_result_counter_label" "$((_result_counter_index + 1))" >&2
      return 1
    fi
    _result_counter_total=$((_result_counter_aggregate + _result_counter_field))
  done
}

# Validate the common destructive-cleanup configuration.
validate_cleanup_config() {
  local variable value
  local -r maximum_retention_count=2147483647

  case "${DRY_RUN-}" in
    true|false) ;;
    *)
      printf '%s\n' "cleanup configuration rejected: DRY_RUN must be exactly true or false" >&2
      return 64
      ;;
  esac

  for variable in KEEP_LATEST_COUNT KEEP_MONTHS; do
    value="${!variable-}"
    if ! is_canonical_decimal "$value"; then
      printf 'cleanup configuration rejected: %s must be 0 or [1-9][0-9]*\n' "$variable" >&2
      return 64
    fi
    # This is an executable-domain bound, not a retention policy.  It is far
    # below Bash's signed-integer limit, so every position <= count comparison
    # is representable, while still allowing more than two billion versions or
    # months.  Compare decimal strings so validation cannot overflow either.
    if decimal_string_greater_than "$value" "$maximum_retention_count"; then
      printf 'cleanup configuration rejected: %s must be between 0 and %s\n' "$variable" "$maximum_retention_count" >&2
      return 64
    fi
  done

  # Keep the generated cutoff and its epoch usable by every later consumer;
  # a failed date calculation is a configuration error, not a later runtime
  # failure.  CUTOFF_TS avoids reparsing CUTOFF_DATE in purge_container.
  # shellcheck disable=SC2034 # These values are consumed by cleanup-old-versions.sh.
  if ! CUTOFF_DATE=$(date -u -d "-${KEEP_MONTHS} months" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
    || ! CUTOFF_TS=$(date -u -d "-${KEEP_MONTHS} months" +%s 2>/dev/null); then
    printf '%s\n' 'cleanup configuration rejected: KEEP_MONTHS must produce a representable cutoff' >&2
    return 64
  fi
}

# A work list is a small, line-oriented frame.  The payload is deliberately
# opaque here: callers must prove that the whole frame arrived before they
# decode even its first record.  That makes a truncated list an incomplete
# assessment, rather than an apparently normal EOF after a valid prefix.
#
# The caller supplies the destination array name.  Its records are assigned
# only after the header, terminal marker, and record counts agree.
load_framed_work_list() {
  local _frame_phase="$1" _frame_work_file="$2" _frame_destination_name="$3"
  local -a _frame_lines=() _frame_records=()
  local _frame_terminal _frame_expected_count _frame_terminal_count _frame_consumed_count _frame_index
  local _frame_last_byte

  # Keep the helper's namespace unavailable to callers.  In particular, a
  # destination cannot resolve to `_frame_records` and silently receive the
  # helper's local array rather than the caller's array.
  if [[ ! "$_frame_destination_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ \
    || "$_frame_destination_name" == _frame_* ]]; then
    printf '  ✗ Refused incomplete %s work list: destination name is reserved or invalid\n' "$_frame_phase" >&2
    return 1
  fi

  if [[ ! -r "$_frame_work_file" ]]; then
    printf '  ✗ Refused incomplete %s work list: cannot read frame\n' "$_frame_phase" >&2
    return 1
  fi
  if ! mapfile -t _frame_lines < "$_frame_work_file"; then
    printf '  ✗ Refused incomplete %s work list: cannot read frame\n' "$_frame_phase" >&2
    return 1
  fi
  if [[ ${#_frame_lines[@]} -eq 0 || ! ${_frame_lines[0]} =~ ^work-list\|expected\|([0-9]+)$ ]]; then
    printf '  ✗ Refused incomplete %s work list: header missing or invalid\n' "$_frame_phase" >&2
    return 1
  fi
  _frame_expected_count="${BASH_REMATCH[1]}"

  # A final unterminated line can be a truncated record or marker.  Do not
  # accept it as a terminal marker merely because read/mapfile returned it.
  if ! _frame_last_byte=$(tail -c 1 "$_frame_work_file" | od -An -tx1); then
    printf '  ✗ Refused incomplete %s work list: cannot read frame\n' "$_frame_phase" >&2
    return 1
  fi
  if [[ "$_frame_last_byte" != *"0a"* ]]; then
    # mapfile returns an unterminated final fragment.  It has not been
    # consumed as a record, so exclude it from the diagnostic count.
    _frame_consumed_count=$(( ${#_frame_lines[@]} - 2 ))
    [[ "$_frame_consumed_count" -ge 0 ]] || _frame_consumed_count=0
    printf '  ✗ Refused incomplete %s work list: terminal marker missing (consumed %s of expected %s)\n' "$_frame_phase" "$_frame_consumed_count" "$_frame_expected_count" >&2
    return 1
  fi
  if [[ ${#_frame_lines[@]} -lt 2 ]]; then
    _frame_consumed_count=$(( ${#_frame_lines[@]} - 1 ))
    [[ "$_frame_consumed_count" -ge 0 ]] || _frame_consumed_count=0
    printf '  ✗ Refused incomplete %s work list: terminal marker missing (consumed %s of expected %s)\n' "$_frame_phase" "$_frame_consumed_count" "$_frame_expected_count" >&2
    return 1
  fi
  _frame_terminal="${_frame_lines[${#_frame_lines[@]} - 1]}"
  if [[ "$_frame_terminal" =~ ^work-list\|complete\|([0-9]+)$ ]]; then
    _frame_terminal_count="${BASH_REMATCH[1]}"
  else
    _frame_consumed_count=$(( ${#_frame_lines[@]} - 1 ))
    printf '  ✗ Refused incomplete %s work list: terminal marker missing (consumed %s of expected %s)\n' "$_frame_phase" "$_frame_consumed_count" "$_frame_expected_count" >&2
    return 1
  fi
  _frame_consumed_count=$(( ${#_frame_lines[@]} - 2 ))

  # `consumed_count` is derived only from the trusted in-memory line array;
  # render it canonically and compare all counts as decimal strings.  Header
  # and terminal values remain untrusted strings throughout.
  printf -v _frame_consumed_count '%d' "$_frame_consumed_count"
  if ! is_canonical_decimal "$_frame_expected_count" \
    || ! is_canonical_decimal "$_frame_terminal_count" \
    || ! decimal_strings_equal "$_frame_terminal_count" "$_frame_expected_count" \
    || ! decimal_strings_equal "$_frame_consumed_count" "$_frame_expected_count"; then
    printf '  ✗ Refused incomplete %s work list: count mismatch (consumed %s of expected %s; terminal %s)\n' "$_frame_phase" "$_frame_consumed_count" "$_frame_expected_count" "$_frame_terminal_count" >&2
    return 1
  fi

  for ((_frame_index = 1; _frame_index < ${#_frame_lines[@]} - 1; _frame_index++)); do
    [[ -n "${_frame_lines[$_frame_index]}" ]] || {
      printf '  ✗ Refused incomplete %s work list: empty record (consumed %s of expected %s)\n' "$_frame_phase" "$_frame_consumed_count" "$_frame_expected_count" >&2
      return 1
    }
    _frame_records+=("${_frame_lines[$_frame_index]}")
  done

  # shellcheck disable=SC2178 # _frame_destination_name is intentionally an array reference.
  local -n _frame_destination="$_frame_destination_name"
  # shellcheck disable=SC2034 # _frame_destination is a write-only nameref for the caller.
  _frame_destination=("${_frame_records[@]}")
}

# `created_at` is only checked for RFC3339 string shape here.  #1301 owns
# timestamp parsing and ordering semantics.
# shellcheck disable=SC2016,SC2034,SC2089,SC2090
VERSION_RECORD_VALIDATION_JQ='
def valid_tag:
  # jq ^ is a true start anchor; use \z rather than $ so a final newline is
  # not silently accepted as part of a whole-string check.
  if type == "string" then test("^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}\\z") else false end;

def valid_id:
  if type == "number" then (tostring | test("^[1-9][0-9]*\\z"))
  elif type == "string" then test("^[1-9][0-9]*\\z")
  else false
  end;

def valid_digest:
  if type == "string" then test("^sha256:[0-9a-f]{64}\\z") else false end;

def version_base($index):
  if type != "object" then "versions[\($index)]"
  elif has("id") | not then "versions[\($index)].id is missing"
  elif (.id | valid_id | not) then "versions[\($index)].id is invalid"
  elif has("name") | not then "versions[\($index)].name is missing"
  elif (.name | type) != "string" then "versions[\($index)].name is invalid"
  elif (.name | valid_digest | not) then "versions[\($index)].name is invalid"
  elif has("metadata") | not then "versions[\($index)].metadata is missing"
  elif (.metadata | type) != "object" then "versions[\($index)].metadata is invalid"
  elif (.metadata | has("container") | not) then "versions[\($index)].metadata.container is missing"
  elif (.metadata.container | type) != "object" then "versions[\($index)].metadata.container is invalid"
  elif (.metadata.container | has("tags") | not) then "versions[\($index)].metadata.container.tags is missing"
  elif (.metadata.container.tags | type) != "array" then "versions[\($index)].metadata.container.tags is invalid"
  else
    ([range(0; (.metadata.container.tags | length)) as $tag_index
      | .metadata.container.tags[$tag_index]
      | select(valid_tag | not)
      | "versions[\($index)].metadata.container.tags[\($tag_index)] is invalid"]
     | .[0])
  end;

def version_outdated_tags_contract($index):
  version_base($index);

def version_old_versions_contract($index):
  version_base($index) //
  (if has("created_at") | not then "versions[\($index)].created_at is missing"
   elif (.created_at | type) != "string" or (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})\\z") | not) then "versions[\($index)].created_at is invalid"
   else null
   end);

# A kept version may report an index.  Only direct descriptors that declare a
# plain image manifest are accepted without walking a further level of the graph.
def named_manifest_media_type:
  type == "string" and (
    . == "application/vnd.oci.image.index.v1+json" or
    . == "application/vnd.docker.distribution.manifest.list.v2+json" or
    . == "application/vnd.oci.image.manifest.v1+json" or
    . == "application/vnd.docker.distribution.manifest.v2+json"
  );

# This validates only the metadata each direct descriptor reports; its declared
# media type is not confirmed against the document at its digest.
def manifest_child_error($index):
  if type != "object" then "child descriptor \($index) is not an object"
  elif has("mediaType") | not then "child descriptor \($index) has no mediaType"
  elif has("mediaType") and ((.mediaType | type) != "string") then "child descriptor \($index) has a non-string mediaType"
  elif has("mediaType") and (.mediaType | named_manifest_media_type | not) then "child descriptor \($index) has unsupported mediaType \(.mediaType | @json)"
  elif .mediaType == "application/vnd.oci.image.index.v1+json" then "child descriptor \($index) is a nested OCI index"
  elif .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json" then "child descriptor \($index) is a nested Docker manifest list"
  elif has("digest") | not then "child descriptor \($index) has no digest"
  elif (.digest | valid_digest | not) then "child descriptor \($index) has a malformed digest"
  else null
  end;

# `first` stops evaluating direct descriptors once the first refusal is found.
# The caller reports only that refusal, so later descriptors are not inspected.
def first_manifest_child_error:
  first(
    range(0; (.manifests | length)) as $index
    | .manifests[$index]
    | manifest_child_error($index)
    | select(. != null)
  ) // null;

# This is deliberately a one-level protection contract.  It classifies a
# document from the metadata that document reports: its top-level mediaType,
# the presence and type of its manifests field, and the declared mediaType of
# each direct descriptor.  It does not fetch a child to confirm the media type
# declared by its descriptor.  A top-level subject is refused: adding only its
# digest to children would leave that subject document unfetched, so any child
# references it contains could not be classified.  The transitive walk needed
# to resolve subjects belongs to oorabona/docker-containers#1338.
def manifest_protection_contract:
  if type != "object" then error("top-level manifest is not an object")
  elif has("subject") then error("top-level manifest has an unresolved subject")
  elif has("mediaType") | not then error("top-level manifest has no mediaType")
  elif has("mediaType") and ((.mediaType | type) != "string") then error("top-level manifest has a non-string mediaType")
  elif has("mediaType") and (.mediaType | named_manifest_media_type | not) then error("top-level manifest has unsupported mediaType \(.mediaType | @json)")
  elif .mediaType == "application/vnd.oci.image.index.v1+json" then
    if has("manifests") | not then error("top-level OCI index has no manifests field")
    elif (.manifests | type) != "array" then error("top-level OCI index has a non-array manifests field")
    else first_manifest_child_error as $child_error
    | if $child_error == null then
        {children: [.manifests[].digest]}
      else error($child_error)
      end
    end
  elif .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json" then
    if has("manifests") | not then error("top-level Docker manifest list has no manifests field")
    elif (.manifests | type) != "array" then error("top-level Docker manifest list has a non-array manifests field")
    else first_manifest_child_error as $child_error
    | if $child_error == null then
        {children: [.manifests[].digest]}
      else error($child_error)
      end
    end
  elif .mediaType == "application/vnd.oci.image.manifest.v1+json" then
    if has("manifests") then error("top-level OCI image manifest has a manifests field")
    else {children: []}
    end
  elif .mediaType == "application/vnd.docker.distribution.manifest.v2+json" then
    if has("manifests") then error("top-level Docker image manifest has a manifests field")
    else {children: []}
    end
  end;

def versions_collection_contract:
  if type == "array" then null else "versions must be an array" end;

def duplicate_id_error:
  . as $versions
  | reduce range(0; length) as $index
      ({seen: {}, error: null};
        if .error != null then .
        else ($versions[$index].id | tostring) as $id
        | if .seen[$id] == null then .seen[$id] = $index
          else .error = "versions[\($index)].id duplicates an earlier value at versions[\(.seen[$id])]"
          end
        end)
  | .error;

# The package endpoint supplies a total to compare with a paginated versions
# listing.  This detects cardinality drift, not every omission: with 200
# records, deleting one from page 1 before page 2 shifts an offset so page 2
# skips a live record; the 199 collected records can then agree with a later
# package total of 199.  Duplicate IDs are checked separately.  This entry
# point is intentionally separate from validate_old_versions.
def validate_versions_listing_count($reported_count):
  versions_collection_contract as $collection_error
  | if $collection_error != null then error("validation failed: \($collection_error)")
    elif (($reported_count | type) != "number" or ($reported_count | floor) != $reported_count or $reported_count < 0 or length != $reported_count) then
      error("validation failed: package version_count is invalid or does not match the versions listing")
    else true
    end;

def validate_outdated_tags_versions:
  versions_collection_contract as $collection_error
  | if $collection_error != null then error("validation failed: \($collection_error)")
    else
      ([range(0; length) as $index | .[$index] | version_outdated_tags_contract($index)]
       | map(select(. != null)) | .[0]) as $record_error
      | ($record_error // duplicate_id_error) as $error
      | if $error == null then true else error("validation failed: \($error)") end
    end;

def validate_old_versions:
  versions_collection_contract as $collection_error
  | if $collection_error != null then error("validation failed: \($collection_error)")
    else
      ([range(0; length) as $index | .[$index] | version_old_versions_contract($index)]
       | map(select(. != null)) | .[0]) as $record_error
      | ($record_error // duplicate_id_error) as $error
      | if $error == null then true else error("validation failed: \($error)") end
    end;
'
