#!/usr/bin/env bash

# Synopsis:
# Run the test runner on a solution.

# Arguments:
# $1: exercise slug
# $2: path to solution folder
# $3: path to output directory

# Output:
# Writes the test results to a results.json file in the passed-in output directory.
# The test results are formatted according to the specifications at
# https://github.com/exercism/docs/blob/main/building/tooling/test-runners/interface.md

# Example:
# ./bin/run.sh two-fer path/to/solution/folder/ path/to/output/directory/

set -uo pipefail

# Byte semantics for gawk, and a stable sort/format everywhere else. A
# solution is free to print arbitrary bytes and we must not choke on them.
export LC_ALL=C

# Set before main so the EXIT trap can still see them.
work=""
results_file=""
build_dir=""

cleanup() {
    [[ -n "$work" ]] && rm -rf "$work"
    [[ -n "$build_dir" ]] && rm -rf "$build_dir"
    return 0
}
trap cleanup EXIT

# Once results_file is known, a fatal error still has to be reported through
# it: the platform reads results.json, and an empty output directory tells it
# nothing.
die() {
    echo "$*" >&2
    if [[ -n "$results_file" ]]; then
        printf '%s\n' "$*" > "${work:-/tmp}/die.$$" 2>/dev/null &&
            write_flat error "${work:-/tmp}/die.$$"
    fi
    exit 1
}

usage() {
    die "usage: $0 exercise-slug path/to/solution/folder/ path/to/output/directory/"
}

# Sather needs SATHER_HOME to find its library and platform configuration.
: "${SATHER_HOME:=/opt/sather}"
export SATHER_HOME

: "${EXERCISM_LIB:=/opt/exercism}"

# Time limits, in seconds.
: "${COMPILE_TIMEOUT:=60}"
: "${RUN_TIMEOUT:=15}"

# Cap what we copy into results.json. The interface has no stated limit, but
# a runaway solution can print without bound.
: "${MAX_MESSAGE_BYTES:=65536}"

# Ceiling on what the solution itself may write, enforced with ulimit so a
# runaway loop cannot fill the tmpfs before the timeout fires.
: "${MAX_OUTPUT_BYTES:=8388608}"

# The compiled tests have to be run, so the build directory must allow
# execution. Under the production settings the container filesystem is
# read-only and /tmp is a tmpfs mounted noexec, which rules out the obvious
# choice; the bind-mounted output and solution directories are the writable,
# executable ones. Probe rather than assume.
can_exec() {
    local dir=$1 probe
    probe=$(mktemp "${dir}/.sather-exec-probe.XXXXXX" 2>/dev/null) || return 1
    printf '#!/bin/sh\nexit 0\n' > "$probe"
    chmod +x "$probe" 2>/dev/null
    if "$probe" 2>/dev/null; then
        rm -f "$probe"
        return 0
    fi
    rm -f "$probe"
    return 1
}

truncated() {
    # Reads stdin, writes at most MAX_MESSAGE_BYTES plus a note if it cut.
    #
    # Deliberately no command substitution: $(...) strips every trailing
    # newline, which both loses the "was it cut?" signal when the cut lands
    # on one and turns an all-newline capture into an empty message.
    local src=$1
    head -c "$MAX_MESSAGE_BYTES" < "$src"
    if (( $(wc -c < "$src") > MAX_MESSAGE_BYTES )); then
        printf '\n... output truncated ...'
    fi
}

# results.json for the cases with no per-test detail to report.
write_flat() {
    local status=$1 message_file=$2
    # A capture of nothing but newlines would otherwise yield an empty
    # message, which says nothing to the student or to us.
    if [[ ! -s $message_file ]] || ! grep -q '[^[:space:]]' "$message_file"; then
        printf 'the tests produced no usable output\n' > "$message_file"
    fi
    # Trim blank lines at both ends: a timeout note appended to an empty
    # capture would otherwise leave the message starting with one.
    jq -n --arg status "$status" --rawfile message "$message_file" \
        '{version: 3, status: $status,
          message: ($message | sub("^\n+"; "") | rtrimstr("\n"))}' \
        > "$results_file"
}

main() {
    [[ -n "${1:-}" && -n "${2:-}" && -n "${3:-}" ]] || usage

    local slug solution_dir output_dir
    slug="$1"
    solution_dir=$(realpath "$2")
    output_dir=$(realpath "$3")

    [[ -d "$solution_dir" && -d "$output_dir" ]] || usage

    local snake_slug
    snake_slug="${slug//-/_}"

    results_file="${output_dir}/results.json"

    # Fail loudly if the runner itself is misinstalled, rather than parsing
    # nothing and blaming the solution for producing no results.
    [[ -f "${EXERCISM_LIB}/parse-records.awk" ]] \
        || die "the record parser is missing from ${EXERCISM_LIB}"

    work=$(mktemp -d)

    local capture="${work}/capture" summary="${work}/summary" records="${work}/records"
    local records_raw="${work}/stderr"
    : > "$capture"; : > "$records_raw"

    # Somewhere to build that we may execute from. Preference order: the
    # output directory, the solution directory, then whatever mktemp gives.
    local build="" candidate_dir
    for candidate_dir in "$output_dir" "$solution_dir" "$work"; do
        if can_exec "$candidate_dir"; then
            # Not "$$": run.sh is the container entrypoint, so $$ is always 1.
            # A fixed name would be reused by a concurrent run and would pick
            # up a build directory left behind by a run that was killed.
            build=$(mktemp -d "${candidate_dir}/.sather-build.XXXXXX" 2>/dev/null) \
                || { build=""; continue; }
            break
        fi
    done
    if [[ -z "$build" ]]; then
        printf 'no directory available that allows both writing and execution;\ntried the output directory, the solution directory and %s\n' \
            "$work" > "$capture"
        write_flat error "$capture"
        echo "${slug}: done"
        return 0
    fi
    build_dir="$build"

    cd "$solution_dir" || die "cannot enter $solution_dir"

    echo "${slug}: testing..."

    # Normally the files are named after the slug, as config.json declares.
    # Fall back to finding them, so a solution assembled by hand still runs
    # and so the runner's own scenario directories can be named freely.
    local tests="${snake_slug}_test.sa"
    if [[ ! -f "$tests" ]]; then
        # exercism_test.sa is the harness and also matches *_test.sa, so it
        # has to be skipped explicitly.
        local candidate
        for candidate in *_test.sa; do
            [[ $candidate == exercism_test.sa ]] && continue
            [[ -f $candidate ]] || continue
            tests="$candidate"
            break
        done
    fi
    if [[ ! -f "$tests" ]]; then
        printf 'no test file found (expected %s_test.sa)\n' "$snake_slug" > "$capture"
        write_flat error "$capture"
        echo "${slug}: done"
        return 0
    fi

    # The main class is named after the test file, not the slug, so that the
    # two always agree.
    local class_name
    class_name="$(basename "$tests" .sa | tr '[:lower:]' '[:upper:]')"

    local solution="${snake_slug}.sa"
    if [[ ! -f "$solution" ]]; then
        local candidate
        for candidate in *.sa; do
            [[ $candidate == "$tests" || $candidate == exercism_test.sa ]] && continue
            solution="$candidate"
            break
        done
    fi
    if [[ ! -f "$solution" ]]; then
        printf 'expected a solution file named %s.sa\n' "$snake_slug" > "$capture"
        write_flat error "$capture"
        echo "${slug}: done"
        return 0
    fi

    # The harness normally ships with the exercise as an editor file; fall
    # back to the copy in the image for a solution assembled without one.
    local harness="exercism_test.sa"
    [[ -f "$harness" ]] || harness="${EXERCISM_LIB}/exercism_test.sa"

    # Build in the work directory rather than in place. sacomp writes its
    # generated C and the executable next to the output name, and the
    # solution directory is a bind mount we should not be writing into --
    # the container filesystem is read-only in production, and even where
    # the mount is writable, leaving build output in a student's solution is
    # not our business. Everything the compile needs is copied across,
    # including any data files the exercise ships, such as grep's fixtures.
    cp -- "$harness" "$build/exercism_test.sa" || die "cannot stage the harness"
    cp -- "$solution" "$build/" || die "cannot stage $solution"
    cp -- "$tests" "$build/" || die "cannot stage $tests"
    # Stage the exercise's own data files -- grep's fixtures, say -- but
    # never anything named like the build product. cp preserves the execute
    # bit, so a solution shipping an executable file called `tests' would
    # otherwise be handed straight to the runner as though it had compiled.
    local data
    for data in *; do
        [[ -f $data ]] || continue
        [[ -e "$build/$data" ]] && continue
        case $data in
            tests|tests.code) continue ;;
        esac
        cp -- "$data" "$build/"
    done

    cd "$build" || die "cannot enter the build directory"

    # Whatever happens next, the only `tests' that can exist afterwards is
    # the one the compiler produced.
    rm -rf ./tests ./tests.code

    # sacomp emits C into <output>.code/ and runs make there, so both Sather
    # and C diagnostics land in the same capture.
    timeout "$COMPILE_TIMEOUT" sacomp \
        exercism_test.sa "$solution" "$tests" \
        -main "$class_name" \
        -o tests > "$capture" 2>&1
    local compile_rc=$?

    # sacomp reports some failures without a non-zero exit status, so the
    # executable is the thing to test rather than the status.
    if [[ ! -x ./tests ]]; then
        if (( compile_rc == 124 )); then
            printf '\ncompilation timed out after %s seconds\n' "$COMPILE_TIMEOUT" >> "$capture"
        fi
        if [[ ! -s "$capture" ]]; then
            printf 'the compiler produced no executable and no diagnostics (exit %s)\n' \
                "$compile_rc" > "$capture"
        fi
        truncated "$capture" > "${capture}.cut"
        write_flat error "${capture}.cut"
        echo "${slug}: done"
        return 0
    fi

    # Keep the two streams apart. The harness writes its records to stderr
    # and its readable report to stdout, and only stderr is parsed, so a
    # solution printing something record-shaped with #OUT cannot manufacture
    # a result. A solution that deliberately writes records to #ERR still
    # can; short of handing the harness a private channel there is no way to
    # prevent that, and it is not something a student does by accident.
    #
    # MAX_OUTPUT_BYTES caps the file the solution can write. Without it a
    # loop printing to stdout fills the tmpfs -- container memory -- long
    # before RUN_TIMEOUT expires.
    (
        ulimit -f "$(( MAX_OUTPUT_BYTES / 512 ))" 2>/dev/null
        timeout "$RUN_TIMEOUT" ./tests > "$capture" 2> "$records_raw"
    )
    local run_rc=$?
    if (( run_rc == 124 )); then
        printf '\nthe tests timed out after %s seconds\n' "$RUN_TIMEOUT" >> "$capture"
    fi

    gawk -v SUMMARY="$summary" -f "${EXERCISM_LIB}/parse-records.awk" \
        < "$records_raw" > "$records"

    # What the student sees is the readable report, plus anything the
    # program wrote to stderr that was not a record.
    grep -v '^##EX' "$records_raw" >> "$capture" 2>/dev/null || true

    local n_tests=0 n_failures=0 saw_done=0
    if [[ -s "$summary" ]]; then
        read -r n_tests n_failures saw_done < "$summary"
    fi

    if (( n_tests == 0 )); then
        # Nothing was reported: the program died before the first test, or
        # never was a test program.
        if [[ ! -s "$capture" ]]; then
            printf 'the tests produced no output\n' > "$capture"
        fi
        truncated "$capture" > "${capture}.cut"
        write_flat error "${capture}.cut"
        echo "${slug}: done"
        return 0
    fi

    local status=pass
    (( n_failures > 0 )) && status=fail

    if (( saw_done == 0 )); then
        # Records arrived but the run stopped early. Report what did run and
        # say so, rather than implying the suite finished.
        status=fail
        truncated "$capture" > "${capture}.cut"
        if ! jq -n --arg status "$status" \
                  --rawfile message "${capture}.cut" \
                  --slurpfile tests "$records" \
              '{version: 3, status: $status,
                message: ("the test program stopped before finishing; the remaining tests did not run\n\n"
                          + ($message | rtrimstr("\n"))),
                tests: $tests}' > "$results_file"
        then
            printf 'could not encode the test results as JSON\n' > "$capture"
            write_flat error "$capture"
        fi
        echo "${slug}: done"
        return 0
    fi

    if ! jq -n --arg status "$status" --slurpfile tests "$records" \
          '{version: 3, status: $status, tests: $tests}' > "$results_file"
    then
        printf 'could not encode the test results as JSON\n' > "$capture"
        write_flat error "$capture"
    fi

    echo "${slug}: done"
}

main "$@"
