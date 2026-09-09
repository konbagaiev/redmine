#!/bin/bash
# Copies the unedited Claude Code session transcripts for this task into ai-workflow/logs/
# and renders them to Markdown and HTML. Run from the repository root, as the last step
# before the final commit. Re-running overwrites the copies with the current state.
#
#   bash ai-workflow/logs/export.sh
#
# Sources: every session that ran in this repository, JSONL as written by Claude Code, plus the
# per-session directory (tool results and subagent transcripts) when it exists. Nothing is edited.
set -euo pipefail

SRC="$HOME/.claude/projects/-Users-kbagaiev-Projects-TaxDome"
DEST="ai-workflow/logs"
mkdir -p "$DEST/sessions" "$DEST/transcripts"

for f in "$SRC"/*.jsonl; do
  id=$(basename "$f" .jsonl)
  cp "$f" "$DEST/sessions/$id.jsonl"
  if [ -d "$SRC/$id" ]; then
    rm -rf "$DEST/sessions/$id"
    cp -R "$SRC/$id" "$DEST/sessions/$id"
  fi
done

# Human-readable renderings of the same files (claude-code-log, https://pypi.org/project/claude-code-log/).
# The JSONL copies above are the record; these are for reading.
if command -v uvx >/dev/null 2>&1; then
  for f in "$DEST"/sessions/*.jsonl; do
    id=$(basename "$f" .jsonl)
    uvx claude-code-log "$f" -o "$DEST/transcripts/$id.md" >/dev/null 2>&1 || echo "render failed: $id"
  done
  uvx claude-code-log "$DEST/sessions" -o "$DEST/transcripts/index.html" >/dev/null 2>&1 || echo "index render failed"
else
  echo "uvx not found: JSONL copied, renderings skipped"
fi

echo "sessions:"
for f in "$DEST"/sessions/*.jsonl; do
  id=$(basename "$f" .jsonl)
  first=$(jq -r 'select(.type=="user" and (.message.content|type)=="string") | .message.content' "$f" 2>/dev/null | head -1 | cut -c1-70)
  printf '  %s  %6s lines  %s\n' "${id:0:8}" "$(wc -l < "$f" | tr -d ' ')" "$first"
done
