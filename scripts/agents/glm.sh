#!/usr/bin/env bash
# Run a headless GLM session (Claude Code with the GLM config).
# Usage: glm.sh <sonnet|haiku> <prompt-file> <workdir> [resume-session-id]
#   sonnet -> glm-5.3, haiku -> glm-5.3-flash (mapping in ~/.claude-glm/settings.json).
#   Never pass a raw model id like glm-5.3: it fails with unrecognized_model.
set -euo pipefail
model="$1"; prompt="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; workdir="$3"; resume="${4:-}"
case "$model" in sonnet|haiku|opus) ;; *) echo "model must be sonnet|haiku|opus" >&2; exit 2;; esac
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
log_dir="$repo_root/.agent-logs"; mkdir -p "$log_dir"
task="$(basename "$prompt" .md)"
log="$log_dir/$task-$(date +%Y%m%d-%H%M%S).json"

bash "$HOME/.claude-glm/sync-from-claude.sh" -q
token="$(grep '^GLM_API_KEY=' "$HOME/.hermes/.env" | cut -d= -f2-)"
args=(-p --model "$model" --dangerously-skip-permissions --output-format json)
[[ -n "$resume" ]] && args+=(--resume "$resume")

cd "$workdir"
CLAUDE_CONFIG_DIR="$HOME/.claude-glm" ANTHROPIC_AUTH_TOKEN="$token" \
  claude "${args[@]}" < "$prompt" > "$log" 2> "$log.err" || true
echo "LOG=$log"
jq -r '"session_id=\(.session_id // "-") is_error=\(.is_error // "-") turns=\(.num_turns // "-") cost=\(.total_cost_usd // "-")"' "$log" 2>/dev/null || tail -n 20 "$log.err"
