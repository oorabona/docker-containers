#!/usr/bin/env bats

# Reject a LITERAL workflow command inside a retry-run block.
#
# `retry-run` executes its wrapped script once per attempt, so a workflow command
# printed there is emitted once per failing attempt — including attempts a later
# retry makes moot (#1075) — and a per-attempt `timeout` kills the script before
# it can emit one at all. Annotations, masks and `::group::` belong in a step
# after the retry, which runs once. Ordinary output is fine and belongs in the
# block: a wrapped command's own stdout and stderr are what a reader needs per
# attempt.
#
# WHAT THIS CANNOT DO, and the reason the test is named for the literal form.
# A block such as `kind=stop-commands; printf '::%s::x\n' "$kind"` contains no
# matching literal, passes here, and disables the runner's command processing at
# runtime. No reading of shell source decides what that shell will emit — the
# same goes for a sourced helper, a subprocess, or any assembled string. This
# catches the mistake (someone writes `echo "::error::…"` in the wrong place),
# not a determined author, who controls CI anyway. Claiming otherwise would be
# the defect: a guard whose name overstates it is trusted past what it checks.
#
# It reads the YAML rather than scanning its text. The first version walked lines
# and tracked indentation, and successive reviews each found a legal spelling
# that walked past it: a value on the same line as the key, a `|2` explicit
# indentation indicator, a flow mapping, a here-document line beginning with
# "- " that read as the start of a new step, and a step whose `run:` key precedes
# its `uses:`. Hardening the walker would have invited the next one. yq resolves
# the document, so every spelling of one value arrives as the same string.

load "../test_helper"

setup() {
    setup_temp_dir
}

teardown() {
    teardown_temp_dir
}

_die() {
    printf '%s\n' "$1" >&2
    return 1
}

# Every workflow and action file, NUL-delimited into a file so find's exit status
# is checked. A guard that scans an empty list and reports success is worse than
# no guard: it outlives whatever broke it, silently.
_collect_files() {
    local out="$TEST_TEMP_DIR/files.z"
    find "$PROJECT_ROOT/.github/workflows" "$PROJECT_ROOT/.github/actions" \
        -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 > "$out" || return 1
    [ -s "$out" ] || return 1
    printf '%s' "$out"
}

# Every `run` belonging to a step that uses the local retry-run action, one per
# NUL-delimited record, written to a file so yq's exit status is checked too.
# Reading it through a process substitution discards that status, which is how a
# file the parser choked on would be scanned as zero sites and pass.
_retry_run_scripts() {
    local src="$1" out="$2"
    yq -r -0 '
        [ (.jobs // {} | .[]? | .steps // [] | .[]?),
          (.runs.steps // [] | .[]?) ]
        | .[]
        | select((.uses // "") | test("\.github/actions/retry-run"))
        | (.with.run // .run // "")
    ' "$src" > "$out"
}

# Both forms the runner parses, and it tries the modern one then the legacy one.
# The command NAME is what is matched, followed by either the closing delimiter
# or the space that starts its parameters — so a parameter value containing a
# colon (`::error title=phase:retry::failed`) or a bracket does not evade it, and
# matching the form rather than a list of names covers ::add-mask::,
# ::stop-commands:: and ::group:: as well as the three annotation levels.
# ::stop-commands:: in a retried block changes how the runner reads everything
# after it, which is further from ordinary output than a duplicate annotation is.
_command_form='(::|##\[)[A-Za-z][A-Za-z-]*(::|\]|[[:space:]])'

# Collects every retry-run script in the repository into $TEST_TEMP_DIR/sites.z
# and echoes how many there are, failing closed on any enumeration error.
_all_sites() {
    local list file per="$TEST_TEMP_DIR/per-file.z" all="$TEST_TEMP_DIR/sites.z"
    local n=0 script

    list=$(_collect_files) || return 1
    : > "$all"

    while IFS= read -r -d '' file; do
        _retry_run_scripts "$file" "$per" || return 1
        while IFS= read -r -d '' script; do
            n=$((n + 1))
            printf '%s\0' "$file" >> "$all"
            printf '%s\0' "$script" >> "$all"
        done < "$per"
    done < "$list"

    printf '%s' "$n"
}

@test "no retry-run block contains a literal workflow command" {
    local sites offenders=() file script

    sites=$(_all_sites) || _die "enumeration failed; the guard scanned an unknown subset"

    # Finding zero means the selector stopped matching. A guard that quietly
    # matches nothing outlives whatever broke it.
    [ "$sites" -gt 0 ] \
        || _die "no retry-run steps found; the selector no longer matches this repository"

    while IFS= read -r -d '' file && IFS= read -r -d '' script; do
        [[ "$script" =~ $_command_form ]] && offenders+=("$file")
    done < "$TEST_TEMP_DIR/sites.z"

    if [ "${#offenders[@]}" -gt 0 ]; then
        printf 'literal workflow command inside a retry-run block: %s\n' "${offenders[@]}" >&2
        _die 'It is emitted once per failing attempt. Move it to a step after the retry.'
    fi
}

# The count above is load-bearing for its own assertion, so it is cross-checked
# against an independent reading. The text count anchors on a `uses:` key at the
# start of a line, because a bare substring search also counts the action's name
# inside a comment or a here-document and would block CI on prose.
@test "the yq selector sees the same retry-run sites a text search does" {
    local sites textual

    sites=$(_all_sites) || _die "enumeration failed; the guard scanned an unknown subset"

    textual=$(grep -rhE '^[[:space:]]*uses:[[:space:]]*\.?/?\.github/actions/retry-run[[:space:]]*$' \
        "$PROJECT_ROOT/.github/workflows" "$PROJECT_ROOT/.github/actions" \
        --include='*.yaml' --include='*.yml' 2>/dev/null | wc -l)

    [ "$sites" -gt 0 ] || _die "yq found no retry-run steps at all"
    [ "$sites" -eq "$textual" ] || _die "yq sees $sites retry-run steps, the text search sees $textual"
}
