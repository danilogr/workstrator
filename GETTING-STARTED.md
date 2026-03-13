# Workstrator — Getting Started

Workstrator is an autonomous agent orchestrator that watches your GitHub project board and dispatches Claude Code agents to work on issues. It runs as a background daemon on macOS, polling every 3 minutes for work.

## How It Works

Two specialized agents run in parallel:

```
                   GitHub Issue
                       │
                 Assigned to bot
                       │
          ┌────────────┴────────────┐
          │                         │
    No plan-approved          Has plan-approved
          │                         │
     ┌────┴────┐              ┌─────┴─────┐
     │ PLANNER │              │  WORKER   │
     └────┬────┘              └─────┬─────┘
          │                         │
  Reads code, posts plan      Implements in
  Revises on feedback         git worktree
  Detects approval            Self-reviews
  Adds plan-approved label    Creates PR
  Creates sub-issues          Posts results
          │                         │
          └────────────┬────────────┘
                       │
               agent-waiting label
              (ball in human's court)
```

**Planner** reads issues and the codebase, writes implementation plans, revises them based on feedback, and when the human approves, adds the `plan-approved` label. It runs in the repo root directory (read-only — never modifies code).

**Worker** picks up issues with `plan-approved`, creates an isolated git worktree, implements the plan, self-reviews against the repo's CLAUDE.md standards, and creates a PR. It runs in the worktree so it never conflicts with your working copy.

### Signal Model

| Signal | Meaning |
|---|---|
| Assign issue to bot account | "Work on this" |
| `agent-waiting` label | Bot posted something, waiting for human |
| `plan-approved` label | Plan approved, worker should implement |
| Human replies (while `agent-waiting`) | Label auto-removed, agent re-engages next cycle |
| Close issue | Done, agent ignores it |

### Lifecycle of an Issue

1. You create an issue and assign it to the bot account
2. **Planner** reads the issue + codebase, posts a plan comment, adds `agent-waiting`
3. You review the plan — approve or give feedback
4. If feedback: **Planner** revises, re-posts, adds `agent-waiting` again
5. If approved: **Planner** adds `plan-approved` label
6. **Worker** creates a git worktree, implements, self-reviews, creates a PR, adds `agent-waiting`
7. You review the PR — merge or request changes
8. If changes needed: **Worker** re-engages when you comment

For stories/epics, the **Planner** decomposes them into sub-issues (each auto-assigned to the bot with `plan-approved`), and the **Worker** implements them one at a time.

---

## Prerequisites

- **macOS** (uses launchd for background daemon)
- **Claude Code CLI** (`claude`) installed and authenticated
- **GitHub CLI** (`gh`) installed and authenticated as the bot account
- **Python 3.10+** (for dashboard and stream parser)
- **Git** with worktree support (any modern version)

### GitHub Setup

1. **Bot account**: Create a GitHub account for the agent (e.g., `my-bot`). Authenticate `gh` as this account:
   ```bash
   gh auth login  # Login as the bot account
   gh auth status  # Verify: should show bot account
   ```

2. **Project board**: Create a GitHub Project (Projects v2) in your org. Add the bot as a member with write access to repos.

3. **Token scopes**: The bot's token needs: `repo`, `project`, `read:org`, `workflow`.

4. **Labels**: Create two labels in each repo the bot monitors:
   - `agent-waiting` — signals the bot posted and is waiting for human input
   - `plan-approved` — signals the plan is approved and the worker should implement

---

## Setup

### 1. Directory Structure

Workstrator expects a workspace directory containing your repo clones as siblings:

```
your-workspace/              # Parent directory
├── repo-a/                  # Your repos (git clones)
├── repo-b/
├── repo-c/
└── workstrator/             # This directory
    ├── workstrator.sh       # Main orchestrator daemon
    ├── agent-prompt.md      # Agent system prompt
    ├── dashboard.py         # Terminal UI
    ├── .stream-parser.py    # Stream-json → text parser
    ├── install.sh           # Install as launchd service
    ├── uninstall.sh         # Remove service
    ├── logs/                # Auto-created: agent + orchestrator logs
    ├── state/               # Auto-created: fingerprint tracking
    ├── running.json         # Auto-created: currently running agents
    └── board-cache.json     # Auto-created: board data for dashboard
```

Clone or copy the `workstrator/` directory into your workspace:

```bash
# Option A: Clone just the workstrator directory
cd ~/Projects/my-workspace
git clone <workstrator-repo-url> workstrator

# Option B: Copy from an existing setup
cp -r /path/to/workstrator ~/Projects/my-workspace/workstrator
```

### 2. Configure `workstrator.sh`

Edit the top of `workstrator.sh`:

```bash
ORG="your-github-org"         # Your GitHub org
PROJECT_NUMBER=1              # Your project board number
BOT_LOGIN="your-bot-account"  # Your bot's GitHub username
POLL_INTERVAL=180             # Seconds between poll cycles (3 min)
AGENT_MODEL="opus"            # Claude model to use
```

Update the `REPOS` variable with all repos the bot should monitor:

```bash
REPOS="repo-a repo-b repo-c"
```

Update `repo_to_local()` if any GitHub repo names differ from local directory names:

```bash
repo_to_local() {
  case "$1" in
    my-github-repo)  echo "my-local-dirname" ;;
    *)               echo "$1" ;;  # Default: same name
  esac
}
```

### 3. Configure `agent-prompt.md`

This is the system prompt injected into every agent invocation. You need to customize:

1. **Platform Architecture** — Replace the architecture diagram and service table with your own. This helps the planner understand how services relate to each other.

2. **Service → Repo Map** — Update the table with your repos, runtimes, and descriptions.

3. **Project Board IDs** — Find and replace all project/field/option IDs:

```bash
# Get project ID
gh project list --owner YOUR_ORG --format json | jq '.projects[] | {title, id}'

# Get field IDs
gh project field-list PROJECT_NUMBER --owner YOUR_ORG --format json \
  | jq '.fields[] | {name, id}'

# Get status option IDs (Todo, In progress, Done)
gh api graphql -f query='
  query {
    organization(login: "YOUR_ORG") {
      projectV2(number: PROJECT_NUMBER) {
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            options { id name }
          }
        }
      }
    }
  }
'
```

Then update the IDs in:
- The **Project Board** section of `agent-prompt.md`
- The planner and worker prompt templates in `workstrator.sh` (search for `project item-edit`)

4. **Firestore / Data Model** — Replace or remove the Firestore section. If your project uses a different database, document its collections and key fields here. If not applicable, delete the section.

5. **Integration Points** — Replace with your own service-to-service integration details. This helps the planner understand cross-repo dependencies.

### 4. Add Per-Repo CLAUDE.md Files

Each repo can have its own `CLAUDE.md` at its root with repo-specific coding conventions. The orchestrator automatically injects the repo's CLAUDE.md into the agent's system prompt alongside `agent-prompt.md`.

Example `CLAUDE.md` for a TypeScript repo:
```markdown
# CLAUDE.md

## Stack
- Node 22, Express, TypeScript
- Tests: vitest

## Conventions
- No `any` types — use `unknown` and narrow
- async/await only — no `.then()` chains
- All function parameters and return types explicit

## Commands
- Build: `npm run build`
- Test: `npm test`
- Lint: `npm run lint`
```

### 5. Install

```bash
cd path/to/workstrator
bash install.sh
```

This registers a macOS LaunchAgent that:
- Starts automatically on login
- Auto-restarts if it crashes (with 60s throttle)
- Captures PATH from your shell so it can find `claude`, `gh`, `git`, `python3`

### Verify

```bash
# Check service status
launchctl print gui/$(id -u)/com.appliedmindai.workstrator

# Check logs
tail -f workstrator/logs/workstrator.log
```

### Stop / Uninstall

```bash
bash workstrator/uninstall.sh
```

### Restart (after code changes)

```bash
bash uninstall.sh && bash install.sh
```

---

## Dashboard

```bash
python3 dashboard.py
```

Split-pane terminal UI:
- **Left pane**: Running agents (Planner/Worker), issue queue, recent orchestrator log
- **Right pane**: Live agent output (streams as the agent works)

### Keybindings

| Key | Action |
|---|---|
| `Up` / `Down` | Select issue in queue |
| `Tab` | Cycle right pane: Auto -> Planner -> Worker -> Auto |
| `PgUp` / `PgDn` | Scroll agent log |
| `r` | Force refresh |
| `q` | Quit |

The dashboard reads all data from local files — it makes **zero GitHub API calls**. Board data comes from `board-cache.json` written by the workstrator each poll cycle.

---

## Usage

### Assigning Work

1. Create an issue in any monitored repo
2. Assign it to your bot account
3. The planner picks it up within 3 minutes

### Approving Plans

When the planner posts a plan, reply with one of:
- "approved", "lgtm", "looks good", "go ahead", "ship it"
- Or any reply that doesn't ask questions or suggest changes

To request revisions, just reply with your feedback. The planner will revise and re-post.

### Skipping the Planning Phase

If you want the worker to implement immediately (e.g., a trivial fix), add the `plan-approved` label manually when creating the issue.

### Stories / Epics

For large issues, the planner will propose a breakdown into sub-issues. When you approve, it creates the sub-issues (each auto-assigned to the bot with `plan-approved`) and the worker processes them sequentially.

---

## Rate Limits

GitHub allows 5,000 GraphQL calls/hour. Key costs:

| Operation | Approximate cost | Frequency |
|---|---|---|
| Board cache refresh | ~100 calls | Once per poll (3 min) |
| Repo scan (issue list) | ~1 per repo | Every poll |
| Issue detail fetch | ~1 per assigned issue | Every poll |
| Agent `gh` commands | Varies | During agent runs |

At 20 polls/hour with ~11 repos, the orchestrator uses ~2,400/hour, leaving headroom for agent work.

The dashboard reads from files only — it contributes zero API cost.

### Monitoring

The orchestrator logs GraphQL usage every poll cycle:

```
Polling... (GraphQL remaining: 4685)
Poll complete. ... GraphQL: 4685→4664 (used 21)
```

If you see the remaining count dropping fast between polls, something external (another tool, CI, etc.) is consuming your quota.

---

## Troubleshooting

### Agent not picking up an issue

1. **Is the repo in the REPOS list?** Check `REPOS=` in `workstrator.sh`.
2. **Is the issue assigned to the bot?** Check `gh issue view NUM --repo ORG/REPO --json assignees`.
3. **Does `agent-waiting` need removal?** If the bot posted and is waiting, reply to trigger auto-removal.
4. **Check the fingerprint**: `cat state/planner-REPO-NUM` or `state/worker-REPO-NUM`. Delete the state file to force reprocessing.

### Worker fails to create worktree

- Check if a stale worktree exists: `git worktree list` in the repo directory
- Clean up: `git worktree remove .worktrees/issue-NUM`
- Check if the branch already exists: `git branch | grep issue-NUM`

### GraphQL rate limit exceeded

- Check: `gh api rate_limit --jq '.resources.graphql'`
- Resets every hour. The orchestrator and dashboard will resume automatically.
- To reduce cost: increase `POLL_INTERVAL` in `workstrator.sh`.

### Service won't start

- Check launchd logs: `cat workstrator/logs/launchd-stderr.log`
- Check if another instance is running: `ls workstrator/.lock/`
- Clean stale lock: `rm -rf workstrator/.lock`
- Verify `claude` is in PATH: `which claude`

### Agent producing bad code

- Add or update the repo's `CLAUDE.md` with stricter conventions
- The agent self-reviews against CLAUDE.md before creating PRs
- Review and reject PRs as you would with any contributor

---

## Files Reference

| File | Purpose |
|---|---|
| `workstrator.sh` | Main daemon — polls, routes, spawns agents |
| `agent-prompt.md` | Agent system prompt — architecture, state machine, conventions |
| `dashboard.py` | Terminal UI — reads local files, zero API cost |
| `.stream-parser.py` | Converts Claude's stream-json output to readable text |
| `install.sh` | Registers macOS LaunchAgent |
| `uninstall.sh` | Removes LaunchAgent |
| `logs/workstrator.log` | Orchestrator log (polls, agent lifecycle) |
| `logs/planner-*.log` | Per-run planner output |
| `logs/worker-*.log` | Per-run worker output |
| `state/planner-*` | Planner fingerprints (prevents re-processing unchanged issues) |
| `state/worker-*` | Worker fingerprints |
| `running.json` | Currently running agents (read by dashboard) |
| `board-cache.json` | Project board snapshot (written by workstrator, read by dashboard) |
| `.lock/` | Single-instance lock (mkdir-based, atomic) |
