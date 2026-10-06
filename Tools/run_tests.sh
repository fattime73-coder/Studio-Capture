#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
result_dir="${1:-${TMPDIR:-/tmp}/StudioCapture-tests-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$result_dir"
xcrun swiftc -O -module-cache-path "$result_dir/module-cache" "$project_dir/StudioCapture/MediaWriter.swift" "$project_dir/Tests/MediaTests.swift" -o "$result_dir/media-tests"
"$result_dir/media-tests" "$result_dir/videos" | tee "$result_dir/media-results.txt"
