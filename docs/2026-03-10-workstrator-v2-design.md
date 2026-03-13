# Workstrator v2 — Design Spec

## Overview

Redesign of the workstrator autonomous issue orchestrator. Simplifies the signal model, adds self-review, story decomposition, explicit approval gates, and a live dashboard.

## Signal Model

Assignment to `appliedmind-agent` is the single opt-in gate. The `agentic work` label is retired.

| Check | Source | Skip if |
|---|---|---|
| Assigned to `appliedmind-agent` | `assignees` | Not assigned |
| `agent-waiting` label | `labels` | Present (unless human replied — auto-remove) |
| Issue state | `state` | Closed |
| Fingerprint | Local state file | Unchanged |

### `agent-waiting` Auto-Remove

Workstrator checks every poll cycle: if an issue has `agent-waiting` AND the last comment is from a non-bot user, the label is automatically removed. The fingerprint changes, and the agent gets dispatched on the next cycle.

```bash
# In poll loop, before skip:
if has_agent_waiting AND last_comment_author != BOT_LOGIN:
    gh issue edit $NUM --repo $ORG/$REPO --remove-label "agent-waiting"
    # fingerprint will change → agent picked up next cycle
```

## Workstrator (Outer Loop)

- **Poll interval**: 3 minutes
- **Blocking**: does NOT poll while an agent is running
- **Serial**: one agent at a time, full codebase ownership
- **Issue selection**: picks the highest-priority assigned issue with a changed fingerprint

### Poll Cycle

```
1. Fetch all project board items (1 API call)
2. For each item:
   a. Skip if not assigned to appliedmind-agent
   b. Skip if issue is closed
   c. If `agent-waiting`: check last comment author
      - If human replied → remove label (fingerprint changes)
      - Skip either way (label still present this cycle, or just removed)
   d. Skip if fingerprint unchanged
   e. Run agent (blocking)
3. After agent exits, update fingerprint, continue to next issue
4. When all issues checked, sleep 3 minutes, repeat
```

## Agent Lifecycle

Each agent invocation handles ONE issue and takes ONE action, then exits. Clean context window per invocation.

### State Machine

```
Agent spawns → reads issue + comments → determines state:

STATE 1: NO PLAN YET (no agent comments, or agent asked questions and human replied)
  ├─ Read issue body + relevant codebase + repo CLAUDE.md
  ├─ If story/epic → propose plan with sub-issue breakdown and execution order
  ├─ If simple issue → propose plan inline
  ├─ Post plan as comment
  ├─ Add `agent-waiting` label
  └─ Exit

STATE 2: PLAN POSTED, HUMAN REPLIED
  ├─ If feedback/suggestions → revise plan, repost, add `agent-waiting`, exit
  ├─ If approved →
  │   ├─ Edit issue body to contain final approved plan
  │   ├─ If story → create sub-issues (see Sub-Issue Creation below)
  │   ├─ Begin implementing (first sub-issue or the issue itself)
  │   ├─ Commit code
  │   ├─ Self-review (see Self-Review below)
  │   ├─ Fix any issues found, re-commit
  │   ├─ Create PR (full PR, not draft)
  │   ├─ Comment on issue with PR link
  │   ├─ Add `agent-waiting` label
  │   └─ Exit
  │
  └─ Next poll: workstrator picks next sub-issue or next issue

STATE 3: SUB-ISSUE WORK (sub-issue assigned to agent, parent has approved plan)
  ├─ Read parent issue for plan context
  ├─ Read sub-issue for specific scope
  ├─ Implement this sub-issue's scope
  ├─ Commit, self-review, fix, create PR
  ├─ Comment on sub-issue with PR link
  ├─ Add `agent-waiting` label on sub-issue
  └─ Exit

STATE 4: AMBIGUOUS (no `agent-waiting` but appears to be waiting)
  ├─ Agent reads full comment history, decides:
  │   ├─ Post clarifying comment + add `agent-waiting`
  │   └─ OR continue working if it has enough context
  └─ Exit

STATE 5: BLOCKED (build failure, unclear architecture, external dependency)
  ├─ Comment with full context (what failed, what was tried, branch state)
  ├─ Add `agent-waiting` label
  └─ Exit
```

### Approval Detection

The agent detects approval by reading the human's reply. Approval signals:
- Explicit: "approved", "lgtm", "looks good", "go ahead", "ship it"
- Implicit: human replies without suggesting changes or asking questions

If ambiguous, the agent asks for explicit confirmation rather than assuming approval.

## Self-Review

Before creating a PR, the agent performs a self-review:

1. Run `git diff main...HEAD` to see all changes
2. Review against the repo's CLAUDE.md standards:
   - No `any` types
   - All function parameters and return types explicit
   - async/await patterns (no `.then()`)
   - No leaked internals in API responses
   - Allowlist serialization (no spread-to-omit)
3. Check for:
   - Bugs and logic errors
   - Code duplication (within the PR and against existing code)
   - Missing error handling at boundaries
   - Security issues (injection, XSS, leaked secrets)
   - Unused imports or dead code introduced
4. Fix any issues found, commit fixes
5. Only then create the PR

## Sub-Issue Creation

When an agent decomposes a story into sub-issues:

1. Each sub-issue includes in its body:
   - Link to parent issue
   - Relevant section of the approved plan
   - Specific files and functions to change
   - Acceptance criteria
   - Execution order (e.g., "Do this after sub-issue #X")
2. Sub-issues are:
   - Auto-assigned to `appliedmind-agent`
   - Added to the project board (auto-add workflow handles this)
   - Linked from the parent issue body
3. Parent issue body is edited to include a checklist of sub-issues with links

### Ordering

Workstrator picks sub-issues by:
1. Most recently changed (fingerprint delta)
2. Among equals, respect execution order if specified in parent plan

## Repo CLAUDE.md Loading

Agents must read and follow repo-specific conventions.

### System prompt injection

```bash
system_prompt="$(cat "$INSTRUCTIONS")"
if [[ -f "$work_dir/CLAUDE.md" ]]; then
  system_prompt+=$'\n\n'"# Repo-Specific Conventions"$'\n\n'"$(cat "$work_dir/CLAUDE.md")"
fi
```

### Agent prompt instruction

```markdown
## Repo Conventions

Before writing any code, read the CLAUDE.md file in each repo you touch:
- Primary: ${work_dir}/CLAUDE.md
- For cross-repo work, read CLAUDE.md in ALL affected repos

Follow these conventions strictly — they define types, patterns, and structure.
```

## Dashboard v2

Split-pane terminal UI:

```
┌─────────────────────────────┬──────────────────────────────────────┐
│ WORKSTRATOR                 │ AGENT OUTPUT (live stdout)           │
│                             │                                      │
│ ● Running  Poll: 3min       │ [rtc#14] Reading issue context...    │
│                             │ [rtc#14] Scanning src/services/...   │
│ Queue:                      │ [rtc#14] Plan: 3 changes needed     │
│  ▸ rtc#14     In progress   │ [rtc#14] Posting plan comment...    │
│    rtc#15     agent-waiting │ [rtc#14] Adding agent-waiting label │
│    dash#8     agent-waiting │ [rtc#14] Done. Exit 0.              │
│    navi#38    Queued        │                                      │
│                             │ ─── idle, waiting for next poll ──── │
│ Recent:                     │                                      │
│  rtc#12  ✓ PR merged        │                                      │
│  dash#5  ✓ PR merged        │                                      │
│                             │                                      │
│ [↑↓] select  [q] quit      │ [PgUp/PgDn] scroll                  │
└─────────────────────────────┴──────────────────────────────────────┘
```

- Left pane: workstrator status, issue queue, recent completions
- Right pane: live tail of the currently running agent's stdout
- `↑/↓` to select an issue on the left, right pane shows that issue's latest agent log
- Real-time updates (2-second refresh on log files)

## Changes from v1

| v1 | v2 |
|---|---|
| `agentic work` label = opt-in | Assignment to bot = opt-in |
| Turn-taking via assignment | `agent-waiting` label for pause, auto-removed on human reply |
| Draft PRs | Full PRs |
| No self-review | Self-review before every PR |
| Manual story decomposition | Agent creates sub-issues from approved plans |
| 15-min poll interval | 3-min poll interval |
| Poll continues while idle | Poll blocked while agent runs (already was) |
| Dashboard: separate views | Dashboard: split-pane with live agent output |
| CLAUDE.md maybe loaded | CLAUDE.md explicitly injected + agent instructed to read |

## Implementation Order

1. Update `workstrator.sh`: new signal model, `agent-waiting` auto-remove, 3-min poll, CLAUDE.md injection
2. Update `GITHUB_CLAUDE_WORKSTRATOR.md`: new state machine, self-review step, sub-issue creation, approval detection
3. Update agent prompt in `workstrator.sh`: new state detection, repo conventions instruction
4. Create `agent-waiting` label across all repos
5. Update `dashboard.py`: split-pane layout with live agent output
6. Test end-to-end on a real issue
