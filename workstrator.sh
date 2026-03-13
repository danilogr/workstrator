#!/usr/bin/env bash
# Workstrator — Planner + Worker Agent Orchestrator
#
# Two-agent model:
#   PLANNER — reads issues, posts plans, revises on feedback, detects approval,
#             adds `plan-approved` label, creates sub-issues. Runs in repo root (read-only).
#   WORKER  — implements approved plans in a git worktree, self-reviews, creates PRs.
#
# Signal model:
#   - Assigned to bot account          → bot should work on it
#   - `agent-waiting` label            → bot posted, needs human input (skip)
#   - `plan-approved` label            → plan approved, ready for worker
#   - `agent-waiting` + human reply    → auto-remove label (next cycle picks up)
#   - Issue closed                     → skip
#
# Routing:
#   - Has `plan-approved`, no `agent-waiting` → WORKER
#   - No `plan-approved`, no `agent-waiting`  → PLANNER
#
# State tracking uses separate fingerprints per role (state/planner-*, state/worker-*)
# to avoid transition conflicts when planner hands off to worker.
#
# Rate budget (GitHub API: 5000 requests/hour):
#   - Poll cost: ~10 calls (1 per repo) + ~1 per assigned issue
#   - At 3-min intervals: 20 polls/hr × ~12 calls = ~240 calls/hr (well under limit)
#
# ── Files ─────────────────────────────────────────────────────────────
#
#   workstrator.sh              This script (outer loop)
#   config.sh                   User configuration (ORG, REPOS, board IDs, etc.)
#   architecture.md             Optional platform architecture (injected into prompts)
#   agent-prompt.md             Agent system prompt (shared conventions)
#   dashboard.py                Split-pane curses dashboard
#   .stream-parser.py           Stream-json → text parser
#   install.sh / uninstall.sh   launchd service management
#   logs/                       workstrator.log + per-agent logs
#   state/                      Fingerprint files (role-prefixed)
#   running.json                Currently running agents (read by dashboard)
#   .lock/                      Single-instance lock (mkdir-based)

set -uo pipefail

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$SCRIPT_DIR/config.sh" ]]; then
  echo "ERROR: config.sh not found. Copy config.example.sh to config.sh and customize it."
  echo "  cp $SCRIPT_DIR/config.example.sh $SCRIPT_DIR/config.sh"
  exit 1
fi

# shellcheck source=config.example.sh
source "$SCRIPT_DIR/config.sh"

# Validate required config
for var in ORG PROJECT_NUMBER BOT_LOGIN REPOS AGENT_MODEL; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var is not set in config.sh"
    exit 1
  fi
done

POLL_INTERVAL="${POLL_INTERVAL:-180}"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTRUCTIONS="$SCRIPT_DIR/agent-prompt.md"
ARCHITECTURE="$SCRIPT_DIR/architecture.md"
PARSER="$SCRIPT_DIR/.stream-parser.py"
LOG_DIR="$SCRIPT_DIR/logs"
STATE_DIR="$SCRIPT_DIR/state"
RUNNING_FILE="$SCRIPT_DIR/running.json"
LOCKDIR="$SCRIPT_DIR/.lock"

mkdir -p "$LOG_DIR" "$STATE_DIR"

# ---------------------------------------------------------------------------
# Agent tracking (simple variables — only 2 slots)
# ---------------------------------------------------------------------------
PLANNER_PID=""
PLANNER_KEY=""
PLANNER_REPO=""
PLANNER_NUM=""
PLANNER_STARTED=""

WORKER_PID=""
WORKER_KEY=""
WORKER_REPO=""
WORKER_NUM=""
WORKER_WORKTREE=""
WORKER_STARTED=""

# ---------------------------------------------------------------------------
# Single-instance lock (mkdir is atomic)
# ---------------------------------------------------------------------------
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [[ -f "$LOCKDIR/pid" ]]; then
    old_pid=$(cat "$LOCKDIR/pid")
    if kill -0 "$old_pid" 2>/dev/null; then
      echo "Workstrator already running (PID $old_pid). Exiting."
      exit 0
    fi
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR"
fi
echo $$ > "$LOCKDIR/pid"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
graphql_remaining() {
  gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null || echo "?"
}

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_DIR/workstrator.log"
}

# ---------------------------------------------------------------------------
# State tracking — separate files per role to avoid transition conflicts
# ---------------------------------------------------------------------------
read_state() {
  local role="$1" key="$2"
  local state_file="$STATE_DIR/${role}-${key}"
  [[ -f "$state_file" ]] && cat "$state_file" || echo ""
}

write_state() {
  local role="$1" key="$2" value="$3"
  echo "$value" > "$STATE_DIR/${role}-${key}"
}

# ---------------------------------------------------------------------------
# Running agents file (read by dashboard)
# ---------------------------------------------------------------------------
update_running_file() {
  local entries=""
  if [[ -n "$PLANNER_PID" ]]; then
    entries+="{\"role\":\"planner\",\"repo\":\"$PLANNER_REPO\",\"num\":$PLANNER_NUM,\"status\":\"running\",\"started\":\"$PLANNER_STARTED\"}"
  fi
  if [[ -n "$WORKER_PID" ]]; then
    [[ -n "$entries" ]] && entries+=","
    entries+="{\"role\":\"worker\",\"repo\":\"$WORKER_REPO\",\"num\":$WORKER_NUM,\"status\":\"running\",\"started\":\"$WORKER_STARTED\",\"worktree\":\"$WORKER_WORKTREE\"}"
  fi
  echo "[$entries]" > "$RUNNING_FILE"
}

clear_running_file() {
  echo "[]" > "$RUNNING_FILE"
}

# ---------------------------------------------------------------------------
# Fetch issue details — SINGLE API call per issue
# Returns: comment_count:assigned_to_bot:agent_waiting:plan_approved:last_author:is_open
# ---------------------------------------------------------------------------
get_issue_info() {
  local repo="$1" num="$2"
  gh issue view "$num" --repo "$ORG/$repo" \
    --json comments,labels,assignees,state \
    --jq '{
      comment_count: (.comments | length),
      assigned_to_bot: ([.assignees[].login] | any(. == "'"$BOT_LOGIN"'")),
      agent_waiting: ([.labels[].name] | any(. == "agent-waiting")),
      plan_approved: ([.labels[].name] | any(. == "plan-approved")),
      last_author: (.comments[-1].author.login // "none"),
      is_open: (.state == "OPEN")
    } | "\(.comment_count):\(.assigned_to_bot):\(.agent_waiting):\(.plan_approved):\(.last_author):\(.is_open)"' 2>/dev/null || echo "error"
}

# ---------------------------------------------------------------------------
# Find bot-assigned issues (1 API call per repo)
# ---------------------------------------------------------------------------
get_bot_assigned_issues() {
  local all_issues=""
  for repo in $REPOS; do
    local result
    result=$(gh issue list --repo "$ORG/$repo" --assignee "$BOT_LOGIN" --state open \
      --json number --jq '.[].number' 2>/dev/null)
    if [[ -n "$result" ]]; then
      while read -r num; do
        all_issues+="${repo}\t${num}\n"
      done <<< "$result"
    fi
  done
  echo -e "$all_issues"
}

# ---------------------------------------------------------------------------
# Look up project board item ID (lazy-loads board data once per poll)
# ---------------------------------------------------------------------------
BOARD_FILE="$SCRIPT_DIR/board-cache.json"

load_board_cache() {
  if [[ -z "${BOARD_CACHE:-}" ]]; then
    BOARD_CACHE=$(gh project item-list "$PROJECT_NUMBER" --owner "$ORG" --limit 200 --format json 2>/dev/null || echo "{}")
    # Write to file so dashboard can read without API calls
    echo "$BOARD_CACHE" > "$BOARD_FILE"
  fi
}

get_item_id() {
  local repo="$1" num="$2"
  load_board_cache
  echo "$BOARD_CACHE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    c = item.get('content', {})
    if str(c.get('number','')) == '$num' and c.get('repository','').endswith('/$repo'):
        print(item['id'])
        break
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Create git worktree for worker
# ---------------------------------------------------------------------------
create_worktree() {
  local repo_dir="$1" num="$2"
  local worktree_dir="$repo_dir/.worktrees/issue-$num"

  mkdir -p "$repo_dir/.worktrees"

  if [[ -d "$worktree_dir" ]]; then
    # Resume existing worktree — sync with main
    (
      cd "$worktree_dir"
      git fetch origin || true
      git merge origin/main --no-edit || true
      git submodule update --init --recursive || true
    ) >/dev/null 2>&1
    echo "$worktree_dir"
    return 0
  fi

  (
    cd "$repo_dir"
    git fetch origin || true

    local branch_name="agent/issue-${num}"

    # Try new branch from origin/main, fall back to existing branch
    if ! git worktree add "$worktree_dir" -b "$branch_name" origin/main 2>/dev/null; then
      git worktree add "$worktree_dir" "$branch_name" 2>/dev/null || return 1
    fi

    cd "$worktree_dir"
    git submodule update --init --recursive || true
  ) >/dev/null 2>&1

  if [[ -d "$worktree_dir" ]]; then
    echo "$worktree_dir"
  fi
}

# ---------------------------------------------------------------------------
# Build system prompt (shared across planner + worker)
# ---------------------------------------------------------------------------
build_system_prompt() {
  local repo_dir="$1"
  local system_prompt
  system_prompt=$(cat "$INSTRUCTIONS")

  # Inject architecture docs if present
  if [[ -f "$ARCHITECTURE" ]]; then
    system_prompt+=$'\n\n'"$(cat "$ARCHITECTURE")"
  fi

  # Inject repo-specific CLAUDE.md if present
  if [[ -f "$repo_dir/CLAUDE.md" ]]; then
    system_prompt+=$'\n\n# Repo-Specific Conventions\n\n'
    system_prompt+=$(cat "$repo_dir/CLAUDE.md")
  fi

  echo "$system_prompt"
}

# ---------------------------------------------------------------------------
# Run planner agent (BACKGROUND)
# ---------------------------------------------------------------------------
run_planner() {
  local repo="$1" num="$2" issue_key="$3" item_id="$4"
  local local_dir
  local_dir=$(repo_to_local "$repo")
  local work_dir="$PROJECT_DIR/$local_dir"
  local log_file="$LOG_DIR/planner-${issue_key}-$(date +%Y%m%d-%H%M%S).log"

  if [[ ! -d "$work_dir" ]]; then
    log "PLANNER ERROR: Directory $work_dir does not exist for repo $repo"
    return 1
  fi

  # Fetch issue context
  local issue_json
  issue_json=$(gh issue view "$num" --repo "$ORG/$repo" \
    --json title,body,comments,labels,author,state,assignees 2>/dev/null)

  if [[ -z "$issue_json" ]]; then
    log "PLANNER ERROR: Failed to fetch issue $ORG/$repo#$num"
    return 1
  fi

  # Build prompt from parts (mixed heredocs avoid escaping hell)
  local prompt_file
  prompt_file=$(mktemp "/tmp/workstrator-planner-XXXXXX")

  # Part 1: header with variables
  cat > "$prompt_file" <<HEADER
You are **Planner Agent #${num}**, responsible for issue \`${ORG}/${repo}#${num}\`.

## Your Role: PLANNER

You read issues, write implementation plans, revise them based on feedback, and prepare work for the Worker agent. You do NOT write code or create PRs.

## Issue Context

\`\`\`json
HEADER

  # Part 2: issue JSON (raw)
  echo "$issue_json" >> "$prompt_file"

  # Part 3: parameters with variables
  cat >> "$prompt_file" <<PARAMS
\`\`\`

## Parameters

- **Org:** ${ORG}
- **Repo:** ${ORG}/${repo}
- **Working directory:** ${work_dir}
- **Bot account:** ${BOT_LOGIN}
- **Comment signature:** 🤖 **Planner #${num}**
- **Project item ID:** ${item_id}

PARAMS

  # Part 4: static instructions (single-quoted heredoc = zero escaping)
  cat >> "$prompt_file" <<'STATIC'
## Your States

### STATE 1: No agent comments yet

Read the issue and the codebase. Post a plan comment with:
- Repos and files changing
- Specific changes per file
- Execution order (if multi-step)
- Sub-issue breakdown (if this is a story/epic)

Then add `agent-waiting` label and exit.

### STATE 2: Agent posted plan, human replied with feedback

Read the feedback. Revise the plan. Post the revised plan as a new comment.
Add `agent-waiting` label and exit.

### STATE 3: Agent posted plan, human approved

Approval signals: "approved", "lgtm", "looks good", "go ahead", "ship it", or a reply that doesn't suggest changes or ask questions.

When you detect approval:
1. Edit the issue body to include the final approved plan.
2. Add the `plan-approved` label — this signals the Worker agent to implement.
3. If this is a story/epic, create sub-issues:
   - Each sub-issue gets: parent link, scope from plan, files to change, acceptance criteria
   - Each sub-issue is assigned to the bot account (see Parameters above)
   - Each sub-issue gets the `plan-approved` label (inherits approval from parent)
   - Edit parent issue body to include a checklist of sub-issues with links
   - For the parent: add `agent-waiting` label (wait for sub-issues to complete)
4. If this is NOT a story (single issue): do NOT add `agent-waiting` — let the worker pick it up immediately.
5. Set board status to "In progress".
6. Post a comment: "Plan approved. Worker agent will begin implementation."
7. Exit.

### STATE 5: Ambiguous

Read full comment history carefully. Either post a clarifying comment + `agent-waiting`, or continue working if you have enough context.

## Rules

- You are **READ-ONLY** on the codebase. Read files to inform your plan, but do NOT modify code.
- Do NOT create branches, worktrees, or PRs.
- Do NOT implement the plan yourself.
- Take ONE action per invocation, then exit.
- Always read the repo's CLAUDE.md before writing a plan.
- For cross-repo work, read CLAUDE.md in ALL affected repos.
STATIC

  # Part 5: board status commands with config variables
  cat >> "$prompt_file" <<BOARD

## Project Board Status

\`\`\`bash
# Set to "In progress"
gh project item-edit --project-id ${PROJECT_ID} --id "${item_id}" --field-id ${STATUS_FIELD_ID} --single-select-option-id ${STATUS_IN_PROGRESS}

# Set to "Todo" (revert if blocked)
gh project item-edit --project-id ${PROJECT_ID} --id "${item_id}" --field-id ${STATUS_FIELD_ID} --single-select-option-id ${STATUS_TODO}
\`\`\`

## Repo Conventions

Before writing any plan, read the CLAUDE.md file in each repo you reference:
- Primary: \`${work_dir}/CLAUDE.md\`
- For cross-repo work, read CLAUDE.md in ALL affected repos

Follow these conventions strictly — they define types, patterns, and structure.

Take ONE action and exit. You will be called again on the next poll cycle.
BOARD

  # Build system prompt
  local system_prompt
  system_prompt=$(build_system_prompt "$work_dir")

  log "PLANNER: Starting for $ORG/$repo#$num"

  # Read prompt content before spawning (avoid race with rm)
  local prompt_content
  prompt_content=$(cat "$prompt_file")
  rm -f "$prompt_file"

  PLANNER_REPO="$repo"
  PLANNER_NUM="$num"
  PLANNER_KEY="$issue_key"
  PLANNER_STARTED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Spawn in background
  (
    unset CLAUDECODE
    cd "$work_dir"
    claude -p "$prompt_content" \
      --model "$AGENT_MODEL" \
      --append-system-prompt "$system_prompt" \
      --dangerously-skip-permissions \
      --verbose \
      --output-format stream-json 2>>"$log_file.err" \
    | python3 -u "$PARSER" >> "$log_file"
  ) &
  PLANNER_PID=$!
  update_running_file

  log "PLANNER: Spawned PID $PLANNER_PID for $issue_key"
}

# ---------------------------------------------------------------------------
# Run worker agent (BACKGROUND)
# ---------------------------------------------------------------------------
run_worker() {
  local repo="$1" num="$2" issue_key="$3" item_id="$4"
  local local_dir
  local_dir=$(repo_to_local "$repo")
  local repo_dir="$PROJECT_DIR/$local_dir"
  local log_file="$LOG_DIR/worker-${issue_key}-$(date +%Y%m%d-%H%M%S).log"

  if [[ ! -d "$repo_dir" ]]; then
    log "WORKER ERROR: Directory $repo_dir does not exist for repo $repo"
    return 1
  fi

  # Create or resume worktree
  local worktree_dir
  worktree_dir=$(create_worktree "$repo_dir" "$num")
  if [[ -z "$worktree_dir" || ! -d "$worktree_dir" ]]; then
    log "WORKER ERROR: Failed to create worktree for $issue_key"
    return 1
  fi

  # Get branch name from worktree
  local branch_name
  branch_name=$(cd "$worktree_dir" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "agent/issue-${num}")

  # Fetch issue context
  local issue_json
  issue_json=$(gh issue view "$num" --repo "$ORG/$repo" \
    --json title,body,comments,labels,author,state,assignees 2>/dev/null)

  if [[ -z "$issue_json" ]]; then
    log "WORKER ERROR: Failed to fetch issue $ORG/$repo#$num"
    return 1
  fi

  # Build prompt from parts
  local prompt_file
  prompt_file=$(mktemp "/tmp/workstrator-worker-XXXXXX")

  # Part 1: header with variables
  cat > "$prompt_file" <<HEADER
You are **Worker Agent #${num}**, responsible for implementing issue \`${ORG}/${repo}#${num}\`.

## Your Role: WORKER

You implement approved plans. The plan has been approved by a human and the Planner has prepared the issue. Your job is to write code, self-review, and create a PR.

## Issue Context

\`\`\`json
HEADER

  # Part 2: issue JSON
  echo "$issue_json" >> "$prompt_file"

  # Part 3: parameters with variables
  cat >> "$prompt_file" <<PARAMS
\`\`\`

## Parameters

- **Org:** ${ORG}
- **Repo:** ${ORG}/${repo}
- **Working directory:** ${worktree_dir} (pre-created git worktree)
- **Branch:** ${branch_name}
- **Bot account:** ${BOT_LOGIN}
- **Comment signature:** 🤖 **Worker #${num}**
- **Project item ID:** ${item_id}

## Your Working Directory

You are running in a **pre-created git worktree** at:
\`\`\`
${worktree_dir}
\`\`\`

This is an isolated copy of the repo on branch \`${branch_name}\`. You can freely modify files here without affecting the main checkout. Do NOT create another worktree — just work in your current directory.

PARAMS

  # Part 4: static instructions (single-quoted = zero escaping)
  cat >> "$prompt_file" <<'STATIC'
## Your States

### STATE 3: Plan approved — implement

1. Read the approved plan from the issue body.
2. Read the repo's CLAUDE.md for conventions.
3. Implement the plan.
4. Commit with co-authorship (see Commit Conventions in system prompt).
5. Self-review: run `git diff main...HEAD`, check against CLAUDE.md standards.
6. Fix any issues found, commit fixes.
7. Push and create a **full PR** (not draft).
8. Comment on the issue with the PR link.
9. Add `agent-waiting` label.
10. Exit.

### STATE 4: Sub-issue work

1. Read the parent issue for full plan context (linked in issue body).
2. Read this sub-issue's specific scope.
3. Read the repo's CLAUDE.md.
4. Implement this sub-issue's scope.
5. Commit, self-review, fix, create PR (same as State 3).
6. Comment on sub-issue with PR link.
7. Add `agent-waiting` label.
8. Exit.

### STATE 6: Blocked

Post a comment with:
- What you were doing
- What went wrong
- What you tried
- Current branch and file state

Add `agent-waiting` label and exit.

## Self-Review Checklist (before creating any PR)

1. Run `git diff main...HEAD` to see all your changes.
2. Review against the repo's CLAUDE.md standards.
3. Check for: bugs, code duplication, missing types, security issues, unused imports.
4. Fix any issues found and commit the fixes.
5. Only then create the PR.

## Safety Rules

1. Never force push.
2. Never commit to main.
3. Never merge your own PRs.
4. Always self-review before creating a PR.
5. Take ONE action per invocation, then exit.
STATIC

  # Part 5: board status + repo conventions with variables
  cat >> "$prompt_file" <<BOARD

## Project Board Status

\`\`\`bash
# Set to "In progress"
gh project item-edit --project-id ${PROJECT_ID} --id "${item_id}" --field-id ${STATUS_FIELD_ID} --single-select-option-id ${STATUS_IN_PROGRESS}

# Set to "Done"
gh project item-edit --project-id ${PROJECT_ID} --id "${item_id}" --field-id ${STATUS_FIELD_ID} --single-select-option-id ${STATUS_DONE}
\`\`\`

## Repo Conventions

Read the CLAUDE.md file before writing any code:
- In worktree: \`${worktree_dir}/CLAUDE.md\`
- For cross-repo references: check CLAUDE.md in other repo roots

Follow these conventions strictly — they define types, patterns, and structure.

Take ONE action and exit. You will be called again on the next poll cycle.
BOARD

  # Build system prompt
  local system_prompt
  system_prompt=$(build_system_prompt "$repo_dir")

  log "WORKER: Starting for $ORG/$repo#$num (worktree: $worktree_dir)"

  # Read prompt content before spawning (avoid race with rm)
  local prompt_content
  prompt_content=$(cat "$prompt_file")
  rm -f "$prompt_file"

  WORKER_REPO="$repo"
  WORKER_NUM="$num"
  WORKER_KEY="$issue_key"
  WORKER_WORKTREE="$worktree_dir"
  WORKER_STARTED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  # Spawn in background
  (
    unset CLAUDECODE
    cd "$worktree_dir"
    claude -p "$prompt_content" \
      --model "$AGENT_MODEL" \
      --append-system-prompt "$system_prompt" \
      --dangerously-skip-permissions \
      --verbose \
      --output-format stream-json 2>>"$log_file.err" \
    | python3 -u "$PARSER" >> "$log_file"
  ) &
  WORKER_PID=$!
  update_running_file

  log "WORKER: Spawned PID $WORKER_PID for $issue_key"
}

# ---------------------------------------------------------------------------
# Reap finished agents
# ---------------------------------------------------------------------------
reap_agents() {
  if [[ -n "$PLANNER_PID" ]]; then
    if ! kill -0 "$PLANNER_PID" 2>/dev/null; then
      wait "$PLANNER_PID" 2>/dev/null || true
      log "PLANNER: $PLANNER_KEY finished"

      # Update planner fingerprint
      local new_info
      new_info=$(get_issue_info "$PLANNER_REPO" "$PLANNER_NUM")
      [[ "$new_info" != "error" ]] && write_state "planner" "$PLANNER_KEY" "$new_info"

      PLANNER_PID=""
      PLANNER_KEY=""
      PLANNER_REPO=""
      PLANNER_NUM=""
      PLANNER_STARTED=""
      update_running_file
    fi
  fi

  if [[ -n "$WORKER_PID" ]]; then
    if ! kill -0 "$WORKER_PID" 2>/dev/null; then
      wait "$WORKER_PID" 2>/dev/null || true
      log "WORKER: $WORKER_KEY finished"

      # Update worker fingerprint
      local new_info
      new_info=$(get_issue_info "$WORKER_REPO" "$WORKER_NUM")
      [[ "$new_info" != "error" ]] && write_state "worker" "$WORKER_KEY" "$new_info"

      WORKER_PID=""
      WORKER_KEY=""
      WORKER_REPO=""
      WORKER_NUM=""
      WORKER_WORKTREE=""
      WORKER_STARTED=""
      update_running_file
    fi
  fi
}

# ---------------------------------------------------------------------------
# Poll and route issues to planner or worker
# ---------------------------------------------------------------------------
poll() {
  local gql_before
  gql_before=$(graphql_remaining)
  log "Polling... (GraphQL remaining: $gql_before)"

  # Reap finished agents first
  reap_agents

  # Reset and refresh board cache each poll (writes to file for dashboard)
  BOARD_CACHE=""
  load_board_cache

  # Find all open issues assigned to the bot
  local issues
  issues=$(get_bot_assigned_issues)

  if [[ -z "$issues" ]]; then
    local gql_after
    gql_after=$(graphql_remaining)
    log "No issues assigned to bot. GraphQL: $gql_before→$gql_after (used $((gql_before - gql_after)))"
    return 0
  fi

  local planner_candidates=()
  local worker_candidates=()
  local checked=0

  while IFS=$'\t' read -r repo num; do
    [[ -z "$repo" || -z "$num" ]] && continue
    local issue_key="${repo}-${num}"
    checked=$((checked + 1))

    # Skip if this issue is already running
    [[ "$issue_key" == "${PLANNER_KEY:-}" ]] && continue
    [[ "$issue_key" == "${WORKER_KEY:-}" ]] && continue

    # Get issue info (1 API call)
    local info
    info=$(get_issue_info "$repo" "$num")
    [[ "$info" == "error" ]] && continue

    # Parse: "count:assigned_to_bot:agent_waiting:plan_approved:last_author:is_open"
    local comment_count assigned_to_bot agent_waiting plan_approved last_author is_open
    IFS=':' read -r comment_count assigned_to_bot agent_waiting plan_approved last_author is_open <<< "$info"

    # Skip closed
    [[ "$is_open" != "true" ]] && continue

    # agent-waiting: check if human replied → auto-remove label
    if [[ "$agent_waiting" == "true" ]]; then
      if [[ "$last_author" != "none" && "$last_author" != "$BOT_LOGIN" ]]; then
        log "Human replied on $issue_key — removing agent-waiting label"
        gh issue edit "$num" --repo "$ORG/$repo" --remove-label "agent-waiting" 2>/dev/null || true
      fi
      # Skip this cycle — pick up next poll with updated fingerprint
      continue
    fi

    # Route based on plan-approved label
    if [[ "$plan_approved" == "true" ]]; then
      # Worker queue — check worker fingerprint
      local prev
      prev=$(read_state "worker" "$issue_key")
      [[ "$info" == "$prev" ]] && continue
      worker_candidates+=("${repo}	${num}	${issue_key}	${info}")
    else
      # Planner queue — check planner fingerprint
      local prev
      prev=$(read_state "planner" "$issue_key")
      [[ "$info" == "$prev" ]] && continue
      planner_candidates+=("${repo}	${num}	${issue_key}	${info}")
    fi

  done <<< "$issues"

  # Spawn planner if idle and candidates exist
  if [[ -z "$PLANNER_PID" && ${#planner_candidates[@]} -gt 0 ]]; then
    local candidate="${planner_candidates[0]}"
    local p_repo p_num p_key p_fingerprint
    IFS=$'\t' read -r p_repo p_num p_key p_fingerprint <<< "$candidate"

    local p_item_id
    p_item_id=$(get_item_id "$p_repo" "$p_num")

    write_state "planner" "$p_key" "$p_fingerprint"
    run_planner "$p_repo" "$p_num" "$p_key" "$p_item_id" || {
      log "PLANNER: Failed to start for $p_key"
      PLANNER_PID=""
    }
  fi

  # Spawn worker if idle and candidates exist
  if [[ -z "$WORKER_PID" && ${#worker_candidates[@]} -gt 0 ]]; then
    local candidate="${worker_candidates[0]}"
    local w_repo w_num w_key w_fingerprint
    IFS=$'\t' read -r w_repo w_num w_key w_fingerprint <<< "$candidate"

    local w_item_id
    w_item_id=$(get_item_id "$w_repo" "$w_num")

    write_state "worker" "$w_key" "$w_fingerprint"
    run_worker "$w_repo" "$w_num" "$w_key" "$w_item_id" || {
      log "WORKER: Failed to start for $w_key"
      WORKER_PID=""
    }
  fi

  local gql_after
  gql_after=$(graphql_remaining)
  local gql_used=$((gql_before - gql_after))
  log "Poll complete. Checked $checked issues. Planner: ${PLANNER_KEY:-idle}. Worker: ${WORKER_KEY:-idle}. GraphQL: $gql_before→$gql_after (used $gql_used)"
}

# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------
shutdown() {
  log "Workstrator shutting down..."

  # Kill running agents
  if [[ -n "$PLANNER_PID" ]]; then
    kill "$PLANNER_PID" 2>/dev/null || true
    wait "$PLANNER_PID" 2>/dev/null || true
    log "Killed planner PID $PLANNER_PID"
  fi
  if [[ -n "$WORKER_PID" ]]; then
    kill "$WORKER_PID" 2>/dev/null || true
    wait "$WORKER_PID" 2>/dev/null || true
    log "Killed worker PID $WORKER_PID"
  fi

  clear_running_file
  rm -rf "$LOCKDIR"
  log "Workstrator stopped."
  exit 0
}

trap shutdown SIGTERM SIGINT

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
log "=========================================="
log "Workstrator starting (planner + worker)"
log "  Org:            $ORG"
log "  Project:        #$PROJECT_NUMBER"
log "  Bot:            $BOT_LOGIN"
log "  Repos:          $REPOS"
log "  Poll interval:  ${POLL_INTERVAL}s"
log "  Agent model:    $AGENT_MODEL"
log "=========================================="

while true; do
  poll || log "Poll cycle failed, will retry next cycle"
  sleep "$POLL_INTERVAL"
done
