#!/bin/zsh
# Restore ~/dev/logic-test/MixPrepTest.logicx from its clean template and open it in Logic.
#
# Refuses to touch any open document other than MixPrepTest: those are closed only when
# they are unmodified, otherwise the script stops so nobody's work is discarded.
#   tools/reset-test-project.sh            close, restore, open
#   tools/reset-test-project.sh --snapshot copy the currently saved MixPrepTest to the clean template
set -euo pipefail

TEST_DIR="$HOME/dev/logic-test"
PROJECT="$TEST_DIR/MixPrepTest.logicx"
CLEAN="$TEST_DIR/MixPrepTest_clean.logicx"

open_documents() {
  osascript -e 'tell application "Logic Pro" to get name of documents' 2>/dev/null | tr ',' '\n' | sed 's/^ *//'
}

close_documents() {
  local name modified
  for name in ${(f)"$(open_documents)"}; do
    [[ -z "$name" ]] && continue
    if [[ "$name" == "MixPrepTest" ]]; then
      osascript -e 'tell application "Logic Pro" to close document "MixPrepTest" saving no'
      continue
    fi
    modified=$(osascript -e "tell application \"Logic Pro\" to get modified of document \"$name\"")
    if [[ "$modified" == "true" ]]; then
      echo "refusing: '$name' is open with unsaved changes" >&2
      exit 1
    fi
    osascript -e "tell application \"Logic Pro\" to close document \"$name\" saving no"
  done
  for _ in {1..40}; do
    [[ -z "$(open_documents)" ]] && return 0
    sleep 0.25
  done
  echo "documents still open: $(open_documents)" >&2
  exit 1
}

if [[ "${1:-}" == "--snapshot" ]]; then
  close_documents
  rm -rf "$CLEAN"
  cp -R "$PROJECT" "$CLEAN"
  echo "snapshot: $CLEAN"
  exit 0
fi

[[ -d "$CLEAN" ]] || { echo "missing clean template $CLEAN" >&2; exit 1; }
close_documents
rm -rf "$PROJECT"
cp -R "$CLEAN" "$PROJECT"
open -a "Logic Pro" "$PROJECT"
for _ in {1..120}; do
  if open_documents | grep -qx "MixPrepTest"; then
    echo "opened: $PROJECT"
    exit 0
  fi
  sleep 0.5
done
echo "MixPrepTest did not open within 60 s" >&2
exit 1
