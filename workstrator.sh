#!/usr/bin/env bash
# Workstrator v4 — Planner + Worker + Reviewer Agent Orchestrator
#
# Three-agent model:
#   PLANNER  (up to MAX_PLANNERS concurrent) — reads issues, posts plans, revises on
#             feedback, detects approval, adds `plan-approved` label, creates sub-issues.
#             Runs in repo root (read-only).
#   WORKER   (single) — implements approved plans in a git worktree, self-reviews, creates PRs.
#   REVIEWER (up to MAX_REVIEWERS concurrent) — reviews worker PRs, pushes deterministic fixes,
#             submits GitHub PR reviews. Triggered on worker completion.
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
# State tracking uses separate fingerprints per role (state/planner-*, state/worker-*,
# state/reviewer-*) to avoid transition conflicts when planner hands off to worker.
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
MAX_PLANNERS="${MAX_PLANNERS:-5}"
MAX_REVIEWERS="${MAX_REVIEWERS:-3}"

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
# Agent tracking — parallel arrays for planners, single slot for worker
# ---------------------------------------------------------------------------
PLANNER_PIDS=()
PLANNER_KEYS=()
PLANNER_REPOS=()
PLANNER_NUMS=()
PLANNER_STARTEDS=()

# Planner array helpers
active_planner_count() {
  echo "${#PLANNER_PIDS[@]}"
}

is_planner_key_running() {
  local key="$1"
  for k in ${PLANNER_KEYS[@]+"${PLANNER_KEYS[@]}"}; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

WORKER_PID=""
WORKER_KEY=""
WORKER_REPO=""
WORKER_NUM=""
WORKER_WORKTREE=""
WORKER_STARTED=""

# Reviewer tracking — parallel arrays (like planners)
REVIEWER_PIDS=()
REVIEWER_KEYS=()            # "repo-pr-NUM"
REVIEWER_REPOS=()
REVIEWER_NUMS=()            # PR numbers (not issue numbers)
REVIEWER_ISSUE_NUMS=()      # linked issue numbers
REVIEWER_WORKTREES=()
REVIEWER_STARTEDS=()

# Reviewer array helpers
active_reviewer_count() {
  echo "${#REVIEWER_PIDS[@]}"
}

is_reviewer_key_running() {
  local key="$1"
  for k in ${REVIEWER_KEYS[@]+"${REVIEWER_KEYS[@]}"}; do
    [[ "$k" == "$key" ]] && return 0
  done
  return 1
}

# Pending reviewer (set by worker reap, consumed by poll)
PENDING_REVIEWER_REPO=""
PENDING_REVIEWER_PR=""
PENDING_REVIEWER_ISSUE=""
PENDING_REVIEWER_KEY=""

# Poll counter for periodic tasks (PR discovery runs every 5th poll = ~15 min)
POLL_COUNT=0
PR_SCAN_INTERVAL=5

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
# PR info for reviewer fingerprinting
# Returns: head_sha:review_count:pr_state
# ---------------------------------------------------------------------------
get_pr_info() {
  local repo="$1" pr_num="$2"
  gh pr view "$pr_num" --repo "$ORG/$repo" \
    --json headRefOid,reviews,state \
    --jq '"\(.headRefOid):\(.reviews | length):\(.state)"' 2>/dev/null || echo "error"
}

# ---------------------------------------------------------------------------
# Reviewer state — three-line format (fingerprint + last-reviewed SHA + issue num)
# ---------------------------------------------------------------------------
write_reviewer_state() {
  local key="$1" fingerprint="$2" reviewed_sha="$3" issue_num="${4:-}"
  printf '%s\n%s\n%s\n' "$fingerprint" "$reviewed_sha" "$issue_num" > "$STATE_DIR/reviewer-$key"
}

read_reviewer_state() {
  # Sets REVIEWER_FINGERPRINT, REVIEWER_LAST_SHA, and REVIEWER_ISSUE_NUM globals
  local file="$STATE_DIR/reviewer-$1"
  REVIEWER_FINGERPRINT=""
  REVIEWER_LAST_SHA=""
  REVIEWER_ISSUE_NUM=""
  [[ -f "$file" ]] || return 1
  REVIEWER_FINGERPRINT=$(sed -n '1p' "$file")
  REVIEWER_LAST_SHA=$(sed -n '2p' "$file")
  REVIEWER_ISSUE_NUM=$(sed -n '3p' "$file")
}

# ---------------------------------------------------------------------------
# Running agents file (read by dashboard)
# ---------------------------------------------------------------------------
update_running_file() {
  local entries=""
  # All active planners
  for i in "${!PLANNER_PIDS[@]}"; do
    [[ -n "$entries" ]] && entries+=","
    entries+="{\"role\":\"planner\",\"repo\":\"${PLANNER_REPOS[$i]}\",\"num\":${PLANNER_NUMS[$i]},\"status\":\"running\",\"started\":\"${PLANNER_STARTEDS[$i]}\"}"
  done
  # Single worker
  if [[ -n "$WORKER_PID" ]]; then
    [[ -n "$entries" ]] && entries+=","
    entries+="{\"role\":\"worker\",\"repo\":\"$WORKER_REPO\",\"num\":$WORKER_NUM,\"status\":\"running\",\"started\":\"$WORKER_STARTED\",\"worktree\":\"$WORKER_WORKTREE\"}"
  fi
  # All active reviewers — num is PR number, issue_num is linked issue, key is for log matching
  for i in "${!REVIEWER_PIDS[@]}"; do
    [[ -n "$entries" ]] && entries+=","
    entries+="{\"role\":\"reviewer\",\"repo\":\"${REVIEWER_REPOS[$i]}\",\"num\":${REVIEWER_NUMS[$i]},\"issue_num\":${REVIEWER_ISSUE_NUMS[$i]},\"key\":\"${REVIEWER_KEYS[$i]}\",\"status\":\"running\",\"started\":\"${REVIEWER_STARTEDS[$i]}\",\"worktree\":\"${REVIEWER_WORKTREES[$i]}\"}"
  done
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

# ---------------------------------------------------------------------------
# Resolve current iteration ID (cached per poll alongside board data)
# ---------------------------------------------------------------------------
CURRENT_ITERATION_ID=""

load_current_iteration() {
  if [[ -z "$CURRENT_ITERATION_ID" && -n "${ITERATION_FIELD_ID:-}" ]]; then
    CURRENT_ITERATION_ID=$(gh api graphql -f query='
      query {
        organization(login: "'"$ORG"'") {
          projectV2(number: '"$PROJECT_NUMBER"') {
            field(name: "Iteration") {
              ... on ProjectV2IterationField {
                configuration {
                  iterations { id }
                }
              }
            }
          }
        }
      }
    ' --jq '.data.organization.projectV2.field.configuration.iterations[0].id' 2>/dev/null || echo "")
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
      git fetch origin --recurse-submodules || true
      git merge origin/main --no-edit || true
      git submodule sync --recursive || true
      git submodule update --init --recursive || true
    ) >/dev/null 2>&1
    echo "$worktree_dir"
    return 0
  fi

  (
    cd "$repo_dir"
    git fetch origin --recurse-submodules || true

    local branch_name="agent/issue-${num}"

    # Try new branch from origin/main, fall back to existing branch
    if ! git worktree add "$worktree_dir" -b "$branch_name" origin/main 2>/dev/null; then
      git worktree add "$worktree_dir" "$branch_name" 2>/dev/null || return 1
    fi

    cd "$worktree_dir"
    git submodule sync --recursive || true
    git submodule update --init --recursive || true
  ) >/dev/null 2>&1

  if [[ -d "$worktree_dir" ]]; then
    echo "$worktree_dir"
  fi
}

# ---------------------------------------------------------------------------
# Create git worktree for reviewer (checks out PR branch)
# ---------------------------------------------------------------------------
create_review_worktree() {
  local repo_dir="$1" pr_num="$2" repo="$3"
  local worktree_dir="$repo_dir/.worktrees/review-pr-$pr_num"

  mkdir -p "$repo_dir/.worktrees"

  if [[ -d "$worktree_dir" ]]; then
    # Resume existing worktree — fetch latest and update to current PR state
    (
      cd "$worktree_dir"
      git fetch origin
      gh pr checkout "$pr_num" --repo "$ORG/$repo" --force
    ) >/dev/null 2>&1
    echo "$worktree_dir"
    return 0
  fi

  # New worktree — create detached, then checkout PR
  (
    cd "$repo_dir"
    git fetch origin
    git worktree add "$worktree_dir" --detach HEAD
    cd "$worktree_dir"
    gh pr checkout "$pr_num" --repo "$ORG/$repo"
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
  local repo="$1" num="$2" issue_key="$3" item_id="$4" iteration_id="${5:-}"
  local local_dir
  local_dir=$(repo_to_local "$repo")
  local work_dir="$PROJECT_DIR/$local_dir"
  local log_file="$LOG_DIR/planner-${issue_key}-$(date +%Y%m%d-%H%M%S).log"

  if [[ ! -d "$work_dir" ]]; then
    log "PLANNER ERROR: Directory $work_dir does not exist for repo $repo"
    return 1
  fi

  # Ensure planner reads latest main — checkout main, pull, update submodules
  log "PLANNER: Syncing $repo to origin/main"
  (
    cd "$work_dir"
    git fetch origin 2>/dev/null || true
    git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
    git merge origin/main --ff-only 2>/dev/null || git merge origin/master --ff-only 2>/dev/null || true
    git submodule update --init --recursive 2>/dev/null || true
  ) >/dev/null 2>&1

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

## Adding Sub-Issues to the Project Board

When creating sub-issues, you MUST add them to the project board:

\`\`\`bash
ITEM_ID=\$(gh project item-add ${PROJECT_NUMBER} --owner ${ORG} --url <issue-url> --format json | jq -r '.id')
\`\`\`
BOARD

  # Part 5b: iteration commands (only if an active iteration exists)
  if [[ -n "$iteration_id" && -n "${ITERATION_FIELD_ID:-}" ]]; then
    cat >> "$prompt_file" <<ITER

Then set the iteration field on the new item:
\`\`\`bash
gh project item-edit --project-id ${PROJECT_ID} --id "\$ITEM_ID" --field-id ${ITERATION_FIELD_ID} --iteration-id ${iteration_id}
\`\`\`

Also set the iteration on the current issue if it is not already set:
\`\`\`bash
gh project item-edit --project-id ${PROJECT_ID} --id "${item_id}" --field-id ${ITERATION_FIELD_ID} --iteration-id ${iteration_id}
\`\`\`
ITER
  fi

  # Part 5c: repo conventions + closing
  cat >> "$prompt_file" <<CONVENTIONS

## Repo Conventions

Before writing any plan, read the CLAUDE.md file in each repo you reference:
- Primary: \`${work_dir}/CLAUDE.md\`
- For cross-repo work, read CLAUDE.md in ALL affected repos

Follow these conventions strictly — they define types, patterns, and structure.

Take ONE action and exit. You will be called again on the next poll cycle.
CONVENTIONS

  # Build system prompt
  local system_prompt
  system_prompt=$(build_system_prompt "$work_dir")

  log "PLANNER: Starting for $ORG/$repo#$num"

  # Read prompt content before spawning (avoid race with rm)
  local prompt_content
  prompt_content=$(cat "$prompt_file")
  rm -f "$prompt_file"

  local started
  started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

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

  # Track in parallel arrays
  PLANNER_PIDS+=($!)
  PLANNER_KEYS+=("$issue_key")
  PLANNER_REPOS+=("$repo")
  PLANNER_NUMS+=("$num")
  PLANNER_STARTEDS+=("$started")
  update_running_file

  log "PLANNER: Spawned PID $! for $issue_key ($(active_planner_count)/$MAX_PLANNERS)"
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

1. Set board status to "In progress" (ok to fail silently).
2. Read the approved plan from the issue body.
3. Read the repo's CLAUDE.md for conventions.
4. Implement the plan.
5. Commit with co-authorship (see Commit Conventions in system prompt).
6. Self-review: run `git diff main...HEAD`, check against CLAUDE.md standards.
7. Fix any issues found, commit fixes.
8. Push and create a **full PR** (not draft).
9. Comment on the issue with the PR link.
10. Add `agent-waiting` label.
11. Exit.

### STATE 4: Sub-issue work

1. Set board status to "In progress" (ok to fail silently).
2. Read the parent issue for full plan context (linked in issue body).
3. Read this sub-issue's specific scope.
4. Read the repo's CLAUDE.md.
5. Implement this sub-issue's scope.
6. Commit, self-review, fix, create PR (same as State 3).
7. Comment on sub-issue with PR link.
8. Add `agent-waiting` label.
9. Exit.

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
# Run reviewer agent (BACKGROUND)
# ---------------------------------------------------------------------------
run_reviewer() {
  local repo="$1" pr_num="$2" issue_num="$3" reviewer_key="$4"
  local local_dir
  local_dir=$(repo_to_local "$repo")
  local repo_dir="$PROJECT_DIR/$local_dir"
  local log_file="$LOG_DIR/reviewer-${reviewer_key}-$(date +%Y%m%d-%H%M%S).log"

  if [[ ! -d "$repo_dir" ]]; then
    log "REVIEWER ERROR: Directory $repo_dir does not exist for repo $repo"
    return 1
  fi

  # Create or resume worktree
  local worktree_dir
  worktree_dir=$(create_review_worktree "$repo_dir" "$pr_num" "$repo")
  if [[ -z "$worktree_dir" || ! -d "$worktree_dir" ]]; then
    log "REVIEWER ERROR: Failed to create worktree for $reviewer_key"
    return 1
  fi

  # Determine R1 vs R2
  local review_mode="R1"
  local last_reviewed_sha=""
  if read_reviewer_state "$reviewer_key" 2>/dev/null; then
    if [[ -n "$REVIEWER_LAST_SHA" ]]; then
      review_mode="R2"
      last_reviewed_sha="$REVIEWER_LAST_SHA"
    fi
  fi

  # Fetch PR diff — omit from prompt if over 3000 lines to preserve subagent context
  local pr_diff diff_line_count diff_omitted="false"
  if [[ "$review_mode" == "R1" ]]; then
    pr_diff=$(gh pr diff "$pr_num" --repo "$ORG/$repo" 2>/dev/null || echo "(failed to fetch diff)")
  else
    pr_diff=$(cd "$worktree_dir" && git diff "$last_reviewed_sha"..HEAD 2>/dev/null || gh pr diff "$pr_num" --repo "$ORG/$repo" 2>/dev/null || echo "(failed to fetch diff)")
  fi

  diff_line_count=$(echo "$pr_diff" | wc -l | tr -d ' ')
  local changed_files=""
  if [[ "$diff_line_count" -gt 3000 ]]; then
    diff_omitted="true"
    changed_files=$(gh pr diff "$pr_num" --repo "$ORG/$repo" --name-only 2>/dev/null || echo "(failed to list files)")
    pr_diff="(diff omitted — $diff_line_count lines, exceeds 3000-line limit)

Changed files:
$changed_files

IMPORTANT: The diff was too large to include in this prompt. Your subagents MUST read the changed files directly from the worktree at $worktree_dir instead of relying on a diff in this prompt. Use the file list above to know which files to review."
    log "REVIEWER: PR#$pr_num diff is $diff_line_count lines — omitted from prompt, subagents will read files directly"
  fi

  # Fetch linked issue context
  local issue_json=""
  if [[ -n "$issue_num" ]]; then
    issue_json=$(gh issue view "$issue_num" --repo "$ORG/$repo" \
      --json title,body,comments,labels,author,state,assignees 2>/dev/null || echo "{}")
  fi

  # Build prompt from parts
  local prompt_file
  prompt_file=$(mktemp "/tmp/workstrator-reviewer-XXXXXX")

  # Part 1: header with variables
  cat > "$prompt_file" <<HEADER
You are **Reviewer Agent**, responsible for reviewing PR #${pr_num} in \`${ORG}/${repo}\`.

## Your Role: REVIEWER

You review PRs for plan alignment and code quality. You push deterministic fixes and submit GitHub PR reviews. Unlike planners and workers, you run a FULL review cycle in a single invocation — do NOT follow the "one action per invocation" rule.

## Review Mode: ${review_mode}

HEADER

  if [[ "$review_mode" == "R2" ]]; then
    cat >> "$prompt_file" <<DELTA
This is a **re-review**. A previous review was submitted. Only review changes since the last review.

**Last reviewed SHA:** \`${last_reviewed_sha}\`

To see only new changes: \`git diff ${last_reviewed_sha}..HEAD\`

DELTA
  fi

  # Part 2: PR details
  cat >> "$prompt_file" <<PR_DETAILS
## PR Details

- **PR number:** ${pr_num}
- **Repository:** ${ORG}/${repo}
- **Working directory:** ${worktree_dir} (pre-created git worktree on PR branch)
- **Linked issue:** ${ORG}/${repo}#${issue_num}
- **Bot account:** ${BOT_LOGIN}

## PR Diff

\`\`\`diff
PR_DETAILS

  echo "$pr_diff" >> "$prompt_file"

  # Part 3: linked issue context
  cat >> "$prompt_file" <<ISSUE_CTX
\`\`\`

## Linked Issue Context

\`\`\`json
ISSUE_CTX

  echo "$issue_json" >> "$prompt_file"

  # Part 4: static instructions (single-quoted = zero escaping)
  cat >> "$prompt_file" <<'STATIC'
```

## Review Process

You MUST run two review passes **in parallel** using Claude Code's Agent tool:

### Pass 1: Semantic Review (subagent)

Spawn an Agent subagent with this task:
- Read the linked issue (body + comments + approved plan) provided above
- Read the PR diff provided above
- Check:
  - Does the PR address what the issue asked for?
  - Are there changes unrelated to the issue (scope creep)?
  - Are there parts of the plan that the PR missed?
- Return structured findings: what passed, what failed, whether fixes are needed

### Pass 2: Engineering Review (subagent)

Spawn an Agent subagent with this task:
- Read the repo's CLAUDE.md for conventions
- Review the changed files (in the worktree) for:
  - Type safety (no `any`, explicit return types, explicit parameter types)
  - Async patterns (no `.then()` chains, error handling at boundaries only)
  - API serialization (allowlist transforms, no spread-to-omit)
  - File organization (one concern per file, import conventions)
  - Code conciseness and modularization
- Return structured findings: what passed, what failed, whether fixes are needed

### After Both Passes

1. Collect findings from both subagents.
2. Push fix commits for auto-fixable issues ONLY (see Auto-Fix Boundary below).
3. Submit a GitHub PR review.

## Auto-Fix Boundary

Only push fix commits when the fix is **deterministic** — exactly one correct change, no judgment required.

**Auto-fix (push commit):**
- Adding missing explicit return types
- Adding missing parameter types
- Replacing `.then()` chains with `async/await`
- Removing `any` when the correct type is unambiguous from context
- Adding `node:` prefix to Node builtin imports
- Adding `.js` extension to relative imports

**Comment only (Request Changes):**
- Converting spread-to-omit to allowlist serialization (requires choosing fields)
- Restructuring file organization (judgment call)
- Scope creep or missing plan steps (semantic issue)
- Error handling placement (requires understanding boundaries)
- API response shaping (requires knowing what to expose)

**Rule:** If you need to choose *what* the fix is, comment. If you only need to apply a known transformation, commit.

## Submitting the Review

**If all issues were auto-fixed or no issues found:**

```bash
gh api repos/OWNER/REPO/pulls/PR_NUM/reviews --method POST \
  -f event=APPROVE \
  -f body="$(cat <<'REVIEW'
## PR Review

### Semantic Check
- ✓ <findings>

### Engineering Check
- ✓ <findings>

### Commits Pushed
- <list of fix commits, or "None needed">
REVIEW
)"
```

**If there are issues you couldn't auto-fix:**

```bash
gh api repos/OWNER/REPO/pulls/PR_NUM/reviews --method POST \
  -f event=REQUEST_CHANGES \
  -f body="<review body with findings>"
```

## Commit Conventions

Fix commits must follow:
```
fix: <description>

Ref #ISSUE_NUM

Co-Authored-By: $BOT_LOGIN <$BOT_LOGIN@users.noreply.github.com>
```

## Pre-Submit Checks

Before submitting your review:
1. Check PR state: `gh pr view PR_NUM --repo ORG/REPO --json state,isDraft`
2. If PR is draft, closed, or merged — exit without review.
3. Only modify files that are part of the PR diff (no drive-by changes).

## Safety Rules

1. Never merge PRs.
2. Never close PRs.
3. Never force push.
4. Only modify files in the PR diff.
5. Always submit a review or log why you skipped (draft/closed/merged) — never exit silently.
6. Never approve a PR with unresolved concerns you couldn't auto-fix.
STATIC

  # Part 5: repo conventions with variables
  cat >> "$prompt_file" <<CONVENTIONS

## Repo Conventions

Read the CLAUDE.md file in the worktree for repo-specific standards:
- In worktree: \`${worktree_dir}/CLAUDE.md\`
CONVENTIONS

  # Build system prompt
  local system_prompt
  system_prompt=$(build_system_prompt "$repo_dir")

  log "REVIEWER: Starting for $ORG/$repo PR#$pr_num (mode: $review_mode, worktree: $worktree_dir)"

  # Read prompt content before spawning
  local prompt_content
  prompt_content=$(cat "$prompt_file")
  rm -f "$prompt_file"

  local started
  started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

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

  # Track in parallel arrays
  REVIEWER_PIDS+=($!)
  REVIEWER_KEYS+=("$reviewer_key")
  REVIEWER_REPOS+=("$repo")
  REVIEWER_NUMS+=("$pr_num")
  REVIEWER_ISSUE_NUMS+=("$issue_num")
  REVIEWER_WORKTREES+=("$worktree_dir")
  REVIEWER_STARTEDS+=("$started")
  update_running_file

  log "REVIEWER: Spawned PID $! for $reviewer_key ($(active_reviewer_count)/$MAX_REVIEWERS)"
}

# ---------------------------------------------------------------------------
# Reap finished agents
# ---------------------------------------------------------------------------
reap_agents() {
  # Reap finished planners — rebuild arrays without finished entries
  local new_pids=() new_keys=() new_repos=() new_nums=() new_starteds=()
  local planners_reaped=false
  for i in "${!PLANNER_PIDS[@]}"; do
    if kill -0 "${PLANNER_PIDS[$i]}" 2>/dev/null; then
      # Still running — keep
      new_pids+=("${PLANNER_PIDS[$i]}")
      new_keys+=("${PLANNER_KEYS[$i]}")
      new_repos+=("${PLANNER_REPOS[$i]}")
      new_nums+=("${PLANNER_NUMS[$i]}")
      new_starteds+=("${PLANNER_STARTEDS[$i]}")
    else
      # Finished — reap and update fingerprint
      wait "${PLANNER_PIDS[$i]}" 2>/dev/null || true
      log "PLANNER: ${PLANNER_KEYS[$i]} finished"
      local new_info
      new_info=$(get_issue_info "${PLANNER_REPOS[$i]}" "${PLANNER_NUMS[$i]}")
      [[ "$new_info" != "error" ]] && write_state "planner" "${PLANNER_KEYS[$i]}" "$new_info"
      planners_reaped=true
    fi
  done
  PLANNER_PIDS=(${new_pids[@]+"${new_pids[@]}"})
  PLANNER_KEYS=(${new_keys[@]+"${new_keys[@]}"})
  PLANNER_REPOS=(${new_repos[@]+"${new_repos[@]}"})
  PLANNER_NUMS=(${new_nums[@]+"${new_nums[@]}"})
  PLANNER_STARTEDS=(${new_starteds[@]+"${new_starteds[@]}"})
  $planners_reaped && update_running_file

  if [[ -n "$WORKER_PID" ]]; then
    if ! kill -0 "$WORKER_PID" 2>/dev/null; then
      wait "$WORKER_PID" 2>/dev/null || true
      log "WORKER: $WORKER_KEY finished"

      # Update worker fingerprint
      local new_info
      new_info=$(get_issue_info "$WORKER_REPO" "$WORKER_NUM")
      [[ "$new_info" != "error" ]] && write_state "worker" "$WORKER_KEY" "$new_info"

      # Check if worker created a PR — queue for reviewer
      local pr_num
      pr_num=$(gh pr list --repo "$ORG/$WORKER_REPO" --head "agent/issue-$WORKER_NUM" --state open --json number,isDraft --jq '[.[] | select(.isDraft | not)][0].number // empty' 2>/dev/null)
      if [[ -n "$pr_num" ]]; then
        local reviewer_key="${WORKER_REPO}-pr-${pr_num}"
        if ! is_reviewer_key_running "$reviewer_key"; then
          # Check fingerprint — only queue if changed or new
          local pr_info
          pr_info=$(get_pr_info "$WORKER_REPO" "$pr_num")
          if [[ "$pr_info" != "error" ]]; then
            read_reviewer_state "$reviewer_key" 2>/dev/null || true
            if [[ "$pr_info" != "$REVIEWER_FINGERPRINT" ]]; then
              PENDING_REVIEWER_REPO="$WORKER_REPO"
              PENDING_REVIEWER_PR="$pr_num"
              PENDING_REVIEWER_ISSUE="$WORKER_NUM"
              PENDING_REVIEWER_KEY="$reviewer_key"
              log "REVIEWER: Worker created PR#$pr_num for $WORKER_KEY — queued for review"
            fi
          fi
        fi
      fi

      WORKER_PID=""
      WORKER_KEY=""
      WORKER_REPO=""
      WORKER_NUM=""
      WORKER_WORKTREE=""
      WORKER_STARTED=""
      update_running_file
    fi
  fi

  # Reap finished reviewers — rebuild arrays without finished entries
  local new_r_pids=() new_r_keys=() new_r_repos=() new_r_nums=() new_r_issue_nums=() new_r_worktrees=() new_r_starteds=()
  local reviewers_reaped=false
  for i in "${!REVIEWER_PIDS[@]}"; do
    if kill -0 "${REVIEWER_PIDS[$i]}" 2>/dev/null; then
      # Still running — keep
      new_r_pids+=("${REVIEWER_PIDS[$i]}")
      new_r_keys+=("${REVIEWER_KEYS[$i]}")
      new_r_repos+=("${REVIEWER_REPOS[$i]}")
      new_r_nums+=("${REVIEWER_NUMS[$i]}")
      new_r_issue_nums+=("${REVIEWER_ISSUE_NUMS[$i]}")
      new_r_worktrees+=("${REVIEWER_WORKTREES[$i]}")
      new_r_starteds+=("${REVIEWER_STARTEDS[$i]}")
    else
      # Finished — reap and update fingerprint
      wait "${REVIEWER_PIDS[$i]}" 2>/dev/null || true
      log "REVIEWER: ${REVIEWER_KEYS[$i]} finished"

      # Fetch new PR state for fingerprint
      local pr_info
      pr_info=$(get_pr_info "${REVIEWER_REPOS[$i]}" "${REVIEWER_NUMS[$i]}")
      if [[ "$pr_info" != "error" ]]; then
        local head_sha
        head_sha=$(echo "$pr_info" | cut -d: -f1)
        local pr_state
        pr_state=$(echo "$pr_info" | cut -d: -f3)

        if [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]]; then
          # PR done — clean up worktree and state
          local r_repo_dir="$PROJECT_DIR/$(repo_to_local "${REVIEWER_REPOS[$i]}")"
          git -C "$r_repo_dir" worktree remove "${REVIEWER_WORKTREES[$i]}" --force 2>/dev/null || true
          rm -f "$STATE_DIR/reviewer-${REVIEWER_KEYS[$i]}"
          log "REVIEWER: Cleaned up worktree and state for ${REVIEWER_KEYS[$i]} (PR $pr_state)"
        else
          # PR still open — write state with reviewed SHA and issue number
          write_reviewer_state "${REVIEWER_KEYS[$i]}" "$pr_info" "$head_sha" "${REVIEWER_ISSUE_NUMS[$i]}"
        fi
      fi
      reviewers_reaped=true
    fi
  done
  REVIEWER_PIDS=(${new_r_pids[@]+"${new_r_pids[@]}"})
  REVIEWER_KEYS=(${new_r_keys[@]+"${new_r_keys[@]}"})
  REVIEWER_REPOS=(${new_r_repos[@]+"${new_r_repos[@]}"})
  REVIEWER_NUMS=(${new_r_nums[@]+"${new_r_nums[@]}"})
  REVIEWER_ISSUE_NUMS=(${new_r_issue_nums[@]+"${new_r_issue_nums[@]}"})
  REVIEWER_WORKTREES=(${new_r_worktrees[@]+"${new_r_worktrees[@]}"})
  REVIEWER_STARTEDS=(${new_r_starteds[@]+"${new_r_starteds[@]}"})
  $reviewers_reaped && update_running_file
}

# ---------------------------------------------------------------------------
# Discover open PRs by bot that have no reviewer state (runs every Nth poll)
# ---------------------------------------------------------------------------
scan_open_prs() {
  local discovered=0
  for repo in $REPOS; do
    # List open, non-draft PRs authored by the bot
    local prs
    prs=$(gh pr list --repo "$ORG/$repo" --author "$BOT_LOGIN" --state open \
      --json number,isDraft,headRefName \
      --jq '[.[] | select(.isDraft | not)] | .[].number' 2>/dev/null) || continue
    [[ -z "$prs" ]] && continue

    while read -r pr_num; do
      [[ -z "$pr_num" ]] && continue
      local reviewer_key="${repo}-pr-${pr_num}"

      # Skip if already tracked, running, or pending
      [[ -f "$STATE_DIR/reviewer-$reviewer_key" ]] && continue
      is_reviewer_key_running "$reviewer_key" && continue
      [[ "$reviewer_key" == "$PENDING_REVIEWER_KEY" ]] && continue

      # Try to find the linked issue number from the PR body
      local issue_num
      issue_num=$(gh pr view "$pr_num" --repo "$ORG/$repo" \
        --json body --jq '.body' 2>/dev/null \
        | grep -oE '(closes|fixes|resolves|ref) #[0-9]+' \
        | head -1 | grep -oE '[0-9]+') || true
      [[ -z "$issue_num" ]] && issue_num="0"

      local reviewer_slots=$(( MAX_REVIEWERS - $(active_reviewer_count) ))
      if [[ $reviewer_slots -gt 0 ]]; then
        log "PR-SCAN: Discovered unreviewed PR $ORG/$repo#$pr_num — spawning reviewer"
        run_reviewer "$repo" "$pr_num" "$issue_num" "$reviewer_key" || \
          log "PR-SCAN: Failed to start reviewer for $reviewer_key"
        discovered=$((discovered + 1))
      else
        # Queue for next cycle if no slots
        if [[ -z "$PENDING_REVIEWER_KEY" ]]; then
          PENDING_REVIEWER_REPO="$repo"
          PENDING_REVIEWER_PR="$pr_num"
          PENDING_REVIEWER_ISSUE="$issue_num"
          PENDING_REVIEWER_KEY="$reviewer_key"
          log "PR-SCAN: Discovered unreviewed PR $ORG/$repo#$pr_num — queued (no slots)"
        fi
        discovered=$((discovered + 1))
      fi
    done <<< "$prs"
  done
  [[ $discovered -gt 0 ]] && log "PR-SCAN: Discovered $discovered unreviewed PR(s)"
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

  # Reset and refresh caches each poll
  BOARD_CACHE=""
  CURRENT_ITERATION_ID=""
  load_board_cache
  load_current_iteration

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
    is_planner_key_running "$issue_key" && continue
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

    # agent-waiting: check if human replied → auto-remove label and route immediately
    if [[ "$agent_waiting" == "true" ]]; then
      if [[ "$last_author" != "none" && "$last_author" != "$BOT_LOGIN" ]]; then
        log "Human replied on $issue_key — removing agent-waiting label, routing now"
        gh issue edit "$num" --repo "$ORG/$repo" --remove-label "agent-waiting" 2>/dev/null || true
        # Update fingerprint to reflect removed label, then fall through to routing
        agent_waiting="false"
        info="${comment_count}:${assigned_to_bot}:${agent_waiting}:${plan_approved}:${last_author}:${is_open}"
      else
        # Still waiting for human reply — skip
        continue
      fi
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

  # Spawn planners for all candidates (up to available slots)
  local planner_slots=$(( MAX_PLANNERS - $(active_planner_count) ))
  local planners_spawned=0
  for candidate in ${planner_candidates[@]+"${planner_candidates[@]}"}; do
    [[ $planners_spawned -ge $planner_slots ]] && break

    local p_repo p_num p_key p_fingerprint
    IFS=$'\t' read -r p_repo p_num p_key p_fingerprint <<< "$candidate"

    local p_item_id
    p_item_id=$(get_item_id "$p_repo" "$p_num")

    if run_planner "$p_repo" "$p_num" "$p_key" "$p_item_id" "$CURRENT_ITERATION_ID"; then
      write_state "planner" "$p_key" "$p_fingerprint"
      planners_spawned=$((planners_spawned + 1))
    else
      log "PLANNER: Failed to start for $p_key"
    fi
  done

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

  # Spawn reviewer if worker reap queued one (or a previous poll couldn't due to full slots)
  if [[ -n "$PENDING_REVIEWER_KEY" ]]; then
    local reviewer_slots=$(( MAX_REVIEWERS - $(active_reviewer_count) ))
    if [[ $reviewer_slots -gt 0 ]]; then
      if run_reviewer "$PENDING_REVIEWER_REPO" "$PENDING_REVIEWER_PR" "$PENDING_REVIEWER_ISSUE" "$PENDING_REVIEWER_KEY"; then
        # Successfully spawned — clear pending
        PENDING_REVIEWER_REPO=""
        PENDING_REVIEWER_PR=""
        PENDING_REVIEWER_ISSUE=""
        PENDING_REVIEWER_KEY=""
      else
        log "REVIEWER: Failed to start for $PENDING_REVIEWER_KEY — will retry next poll"
      fi
    else
      log "REVIEWER: No slots available for $PENDING_REVIEWER_KEY — will retry next poll ($MAX_REVIEWERS/$MAX_REVIEWERS active)"
    fi
  fi

  # Re-review scan: check existing reviewer state files for fingerprint changes
  # This catches PRs that received new commits or comments after a previous review
  for state_file in "$STATE_DIR"/reviewer-*; do
    [[ -f "$state_file" ]] || continue
    local r_key
    r_key=$(basename "$state_file" | sed 's/^reviewer-//')

    # Skip if already running or pending
    is_reviewer_key_running "$r_key" && continue
    [[ "$r_key" == "$PENDING_REVIEWER_KEY" ]] && continue

    # Parse repo and PR number from key (format: repo-pr-NUM)
    local r_repo r_pr_num
    r_repo=$(echo "$r_key" | sed 's/-pr-[0-9]*$//')
    r_pr_num=$(echo "$r_key" | grep -o '[0-9]*$')
    [[ -z "$r_pr_num" ]] && continue

    # Read stored fingerprint and check current
    read_reviewer_state "$r_key" 2>/dev/null || continue
    local current_pr_info
    current_pr_info=$(get_pr_info "$r_repo" "$r_pr_num")
    [[ "$current_pr_info" == "error" ]] && continue

    # Check if PR is now merged/closed — clean up
    local current_state
    current_state=$(echo "$current_pr_info" | cut -d: -f3)
    if [[ "$current_state" == "MERGED" || "$current_state" == "CLOSED" ]]; then
      local r_repo_dir="$PROJECT_DIR/$(repo_to_local "$r_repo")"
      git -C "$r_repo_dir" worktree remove ".worktrees/review-pr-$r_pr_num" --force 2>/dev/null || true
      rm -f "$state_file"
      log "REVIEWER: Cleaned up stale state for $r_key (PR $current_state)"
      continue
    fi

    # Fingerprint changed — queue re-review
    if [[ "$current_pr_info" != "$REVIEWER_FINGERPRINT" ]]; then
      local reviewer_slots=$(( MAX_REVIEWERS - $(active_reviewer_count) ))
      if [[ $reviewer_slots -gt 0 ]]; then
        # Issue number is stored as line 3 of reviewer state file
        if [[ -n "$REVIEWER_ISSUE_NUM" ]]; then
          log "REVIEWER: PR $r_key fingerprint changed — spawning re-review (R2)"
          run_reviewer "$r_repo" "$r_pr_num" "$REVIEWER_ISSUE_NUM" "$r_key" || \
            log "REVIEWER: Failed to start re-review for $r_key"
        fi
      fi
    fi
  done

  local gql_after
  gql_after=$(graphql_remaining)
  local gql_used=$((gql_before - gql_after))
  local planner_summary
  if [[ $(active_planner_count) -gt 0 ]]; then
    planner_summary="$(active_planner_count) active"
  else
    planner_summary="idle"
  fi
  local reviewer_summary
  if [[ $(active_reviewer_count) -gt 0 ]]; then
    reviewer_summary="$(active_reviewer_count) active"
  else
    reviewer_summary="idle"
  fi
  log "Poll complete. Checked $checked issues. Planners: $planner_summary. Worker: ${WORKER_KEY:-idle}. Reviewers: $reviewer_summary. GraphQL: $gql_before→$gql_after (used $gql_used)"
}

# ---------------------------------------------------------------------------
# Graceful shutdown
# ---------------------------------------------------------------------------
shutdown() {
  log "Workstrator shutting down..."

  # Kill running agents
  for i in "${!PLANNER_PIDS[@]}"; do
    kill "${PLANNER_PIDS[$i]}" 2>/dev/null || true
    wait "${PLANNER_PIDS[$i]}" 2>/dev/null || true
    log "Killed planner PID ${PLANNER_PIDS[$i]} (${PLANNER_KEYS[$i]})"
  done
  if [[ -n "$WORKER_PID" ]]; then
    kill "$WORKER_PID" 2>/dev/null || true
    wait "$WORKER_PID" 2>/dev/null || true
    log "Killed worker PID $WORKER_PID"
  fi
  for i in "${!REVIEWER_PIDS[@]}"; do
    kill "${REVIEWER_PIDS[$i]}" 2>/dev/null || true
    wait "${REVIEWER_PIDS[$i]}" 2>/dev/null || true
    log "Killed reviewer PID ${REVIEWER_PIDS[$i]} (${REVIEWER_KEYS[$i]})"
  done

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
log "Workstrator v4 starting (planner + worker + reviewer)"
log "  Org:            $ORG"
log "  Project:        #$PROJECT_NUMBER"
log "  Bot:            $BOT_LOGIN"
log "  Repos:          $REPOS"
log "  Poll interval:  ${POLL_INTERVAL}s"
log "  Agent model:    $AGENT_MODEL"
log "  Max planners:   $MAX_PLANNERS"
log "  Max reviewers:  $MAX_REVIEWERS"
log "=========================================="

while true; do
  poll || log "Poll cycle failed, will retry next cycle"

  # Periodic PR discovery scan (every Nth poll, and on first poll)
  POLL_COUNT=$((POLL_COUNT + 1))
  if [[ $POLL_COUNT -eq 1 || $((POLL_COUNT % PR_SCAN_INTERVAL)) -eq 0 ]]; then
    scan_open_prs || log "PR scan failed, will retry next cycle"
  fi

  sleep "$POLL_INTERVAL"
done
