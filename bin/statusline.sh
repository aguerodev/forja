#!/usr/bin/env bash
# forja statusline — minimal style. Installed to ~/.claude/statusline.sh by the
# /forja:statusline command (Claude Code cannot reference a plugin-bundled path
# from the statusLine command, so the script is copied into ~/.claude/).
#
# Segments: dir | git branch | model | context% | git status | behind upstream
# Only reliable data: nothing estimated about subscription usage.
# Requires: jq (the SessionStart hook and /forja:doctor warn if it is missing).

input="$(cat)"

# --- ANSI colors ---
C_DIR=$'\033[36m'      # cyan
C_BRANCH=$'\033[32m'   # green
C_MODEL=$'\033[35m'    # magenta
C_CTX=$'\033[33m'      # yellow
C_DIRTY=$'\033[33m'    # yellow (uncommitted changes)
C_CLEAN=$'\033[2;37m'  # dim grey (clean tree)
C_BEHIND=$'\033[31m'   # red (commits behind upstream)
C_SEP=$'\033[2;37m'    # dim grey
RESET=$'\033[0m'
SEP=" ${C_SEP}│${RESET} "

# --- Parse payload ---
dir=$(printf '%s' "$input"        | jq -r '.workspace.current_dir // .cwd // "."')
model_name=$(printf '%s' "$input" | jq -r '.model.display_name // "?"')
model_id=$(printf '%s' "$input"   | jq -r '.model.id // ""')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""')

# --- Folder name ---
folder="${dir##*/}"
[ -z "$folder" ] && folder="$dir"

# --- Git branch ---
branch="$(git -C "$dir" branch --show-current 2>/dev/null)"
[ -z "$branch" ] && branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ "$branch" = "HEAD" ] && branch="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"

# --- Git working tree status (only inside a repo) ---
gitstat=""
if [ -n "$branch" ]; then
  changes="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$changes" -gt 0 ] 2>/dev/null; then
    gitstat="${C_DIRTY}${changes}${RESET}"
  else
    gitstat="${C_CLEAN}clean${RESET}"
  fi
fi

# --- Behind upstream (commits to pull) ---
# NOTE: this only reflects the last `git fetch` this repo saw (manual, or run
# by some other tool/IDE) — it never fetches here, so it can be stale vs. the
# real state on GitHub. It will NOT show new remote commits until something
# triggers a fetch.
behind=""
if [ -n "$branch" ]; then
  upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  if [ -n "$upstream" ]; then
    behind_count="$(git -C "$dir" rev-list --count HEAD.."@{u}" 2>/dev/null)"
    if [ -n "$behind_count" ] && [ "$behind_count" -gt 0 ] 2>/dev/null; then
      behind="${C_BEHIND}⇩${behind_count}${RESET}"
    fi
  fi
fi

# --- Context window usage ---
ctx=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  case "$model_id" in
    *1m*) limit=1000000 ;;
    *)    limit=200000  ;;
  esac
  tokens="$(tail -n 300 "$transcript" 2>/dev/null | jq -rs '
    [ .[] | select(.message.usage) ] | last
    | (.message.usage // {})
    | ( (.input_tokens // 0)
      + (.cache_read_input_tokens // 0)
      + (.cache_creation_input_tokens // 0) )
  ' 2>/dev/null)"
  if [ -n "$tokens" ] && [ "$tokens" -gt 0 ] 2>/dev/null; then
    pct=$(( tokens * 100 / limit ))
    ctx="ctx ${pct}%"
  fi
fi

# --- Assemble ---
out="${C_DIR}${folder}${RESET}"
[ -n "$branch" ] && out="${out}${SEP}${C_BRANCH} ${branch}${RESET}"
out="${out}${SEP}${C_MODEL}${model_name}${RESET}"
[ -n "$ctx" ]     && out="${out}${SEP}${C_CTX}${ctx}${RESET}"
[ -n "$gitstat" ] && out="${out}${SEP} ${gitstat}"
[ -n "$behind" ]  && out="${out}${SEP}${behind}"

printf '%b' "$out"
