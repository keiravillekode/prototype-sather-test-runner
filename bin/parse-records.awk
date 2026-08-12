# Turn the Sather harness's record stream into JSON Lines, one object per
# test, for jq to assemble into results.json.
#
# The harness in exercism_test.sa writes one record per test to stderr:
#
#     ##EX|<name>|<pass|fail>|<expected>|<actual>|##
#     ##EXDONE|<total>|<failures>|##
#
# Every field is escaped so a record occupies exactly one line and the '|'
# separator is unambiguous:
#
#     \  ->  \\        |  ->  \p        LF ->  \n        CR ->  \r
#
# Because '|' is always written as '\p', a raw '|' in a record can only ever
# be a separator, so splitting on it is safe.
#
# Reads the captured run output on stdin. Writes JSON Lines on stdout, and
# the number of tests and failures to the file named by SUMMARY so the
# caller can tell "no records at all" from "records but no terminator".

BEGIN {
    # gawk has no ord(); build the table once.
    for (byte = 0; byte < 256; byte++) ORD[sprintf("%c", byte)] = byte
    tests = 0
    failures = 0
    saw_done = 0
    # Concatenating with "" initialises SUMMARY without disturbing a value
    # passed by -v, which keeps --lint quiet about referencing it below.
    SUMMARY = SUMMARY ""
}

# Reverse the harness's escaping in a single left-to-right pass. Doing it as
# a sequence of substitutions would be wrong: an escaped backslash followed
# by 'p' ("\\p") must stay a backslash then 'p', not become a separator.
function unescape(s,    out, i, n, c, nxt) {
    out = ""
    n = length(s)
    i = 1
    while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) {
            nxt = substr(s, i + 1, 1)
            if (nxt == "\\")      out = out "\\"
            else if (nxt == "p")  out = out "|"
            else if (nxt == "n")  out = out "\n"
            else if (nxt == "r")  out = out "\r"
            else                  out = out c nxt   # unknown escape: keep both
            i += 2
        } else {
            out = out c
            i++
        }
    }
    return out
}

function json_escape(s,    out, i, n, c, o) {
    out = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\")      out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "\n") out = out "\\n"
        else if (c == "\r") out = out "\\r"
        else if (c == "\t") out = out "\\t"
        else {
            o = ORD[c]
            if (o < 32) out = out sprintf("\\u%04x", o)
            else        out = out c
        }
    }
    return out
}

/^##EXDONE\|/ {
    saw_done = 1
    next
}

/^##EX\|/ {
    line = $0
    # Records are written with a trailing "|##"; anything else is not one.
    if (substr(line, length(line) - 2) != "|##") next

    payload = substr(line, 6, length(line) - 8)
    nf = split(payload, f, "|")
    if (nf < 4) next

    name     = unescape(f[1])
    status   = unescape(f[2])
    expected = unescape(f[3])
    actual   = unescape(f[4])

    tests++
    printf "{\"name\":\"%s\"", json_escape(name)
    if (status == "pass") {
        printf ",\"status\":\"pass\"}\n"
    } else {
        failures++
        printf ",\"status\":\"fail\",\"message\":\"%s\"}\n",
               json_escape("expected: " expected "\nactual:   " actual)
    }
    next
}

END {
    if (SUMMARY != "") printf "%d %d %d\n", tests, failures, saw_done > SUMMARY
}
