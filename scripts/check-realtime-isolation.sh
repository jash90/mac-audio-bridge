#!/bin/bash
# Static regression guard for realtime/queue callback isolation.
#
# Swift 6 inserts a dynamic executor check into closures that inherit main-actor
# isolation. When a system framework invokes such a closure on its own queue
# (CoreAudio IOProc, AVAudioSourceNode render block, dispatch timer handler),
# that check traps: EXC_BREAKPOINT in _dispatch_assert_queue_fail.
#
# Heuristic: fail when AudioDeviceCreateIOProcIDWithBlock, AVAudioSourceNode( or
# setEventHandler is called with an INLINE closure literal ('{') inside a type
# explicitly annotated @MainActor. Calls that pass a block produced by a
# `nonisolated` factory function (no inline '{') pass.
#
# Known limits (deliberate, keep it a simple grep/awk heuristic):
#   - only explicitly @MainActor-annotated types are scanned (SwiftUI's implicit
#     MainActor views are not detected);
#   - brace/paren counting is line-based.
set -euo pipefail
cd "$(dirname "$0")/.."

failed=0
while IFS= read -r file; do
    output=$(awk -v file="$file" '
        {
            lines[NR] = $0
        }
        function count_char(s, c,    k, total) {
            total = 0
            for (k = 1; k <= length(s); k++)
                if (substr(s, k, 1) == c) total++
            return total
        }
        function scan_for_api_calls(start, end,    i, j, depth, saw_brace) {
            for (i = start; i <= end; i++) {
                if (lines[i] ~ /AudioDeviceCreateIOProcIDWithBlock|AVAudioSourceNode\(|setEventHandler/) {
                    saw_brace = (lines[i] ~ /\{/)
                    depth = count_char(lines[i], "(") - count_char(lines[i], ")")
                    j = i
                    while (depth > 0 && j < end) {
                        j++
                        if (lines[j] ~ /\{/) saw_brace = 1
                        depth += count_char(lines[j], "(") - count_char(lines[j], ")")
                    }
                    if (saw_brace) {
                        printf("%s:%d: framework callback created as an inline closure inside a @MainActor type; build it in a nonisolated factory function instead\n", file, i)
                        bad = 1
                    }
                }
            }
        }
        END {
            total_lines = NR
            for (i = 1; i <= total_lines; i++) {
                if (lines[i] ~ /^[ \t]*@MainActor/) {
                    decl = 0
                    for (d = 0; d <= 3 && (i + d) <= total_lines; d++) {
                        if (lines[i + d] ~ /[ \t](class|struct|actor|enum|extension)[ \t]/) { decl = i + d; break }
                        if (d > 0 && lines[i + d] ~ /[ \t](func|var|let|init|static)[ \t]/) break
                    }
                    if (decl == 0) continue
                    body_end = total_lines
                    for (j = decl + 1; j <= total_lines; j++)
                        if (lines[j] ~ /^}/) { body_end = j; break }
                    scan_for_api_calls(decl, body_end)
                    i = body_end
                }
            }
            if (bad) exit 1
        }
    ' "$file") || true
    if [ -n "$output" ]; then
        printf '%s\n' "$output"
        failed=1
    fi
done < <(find Apps Packages -type f -name '*.swift')

if [ "$failed" -ne 0 ]; then
    echo "check-realtime-isolation: FAILED"
    exit 1
fi
echo "check-realtime-isolation: OK"
