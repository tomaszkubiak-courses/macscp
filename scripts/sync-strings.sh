#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
args=()
while IFS= read -r f; do args+=(--stringsdata "$f"); done < <(find DerivedData -name '*.stringsdata' -path '*MacSCP.build/Objects*')
xcrun xcstringstool sync App/Resources/Localizable.xcstrings "${args[@]}"
