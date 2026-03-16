# Workstrator

An autonomous agent orchestrator that watches your GitHub project board and dispatches [Claude Code](https://claude.ai/claude-code) agents to work on issues. It runs as a background daemon on macOS, polling every 3 minutes for work.

## How It Works

Multiple **Planner** agents and a single **Worker** agent run in parallel:

```
                   GitHub Issues
                       │
                 Assigned to bot
                       │
          ┌────────────┴────────────┐
          │                         │
    No plan-approved          Has plan-approved
          │                         │
   ┌──────┴──────┐            ┌─────┴─────┐
   │  PLANNERS   │            │  WORKER   │
   │ (up to N)   │            │ (single)  │
   └──────┬──────┘            └─────┬─────┘
          │                         │
  Read code, post plans       Implements in
  Revise on feedback          git worktree
  Detect approval             Self-reviews
  Add plan-approved label     Creates PR
  Create sub-issues           Posts results
          │                         │
          └────────────┬────────────┘
                       │
               agent-waiting label
              (ball in human's court)
```

**Planners** (up to `MAX_PLANNERS` concurrent, default 5) read issues and the codebase, write implementation plans, revise them based on feedback, and when the human approves, add the `plan-approved` label. They run in the repo root directory (read-only — never modify code). Multiple planners can work on different issues simultaneously.

**Worker** picks up issues with `plan-approved`, creates an isolated git worktree, implements the plan, self-reviews against the repo's CLAUDE.md standards, and creates a PR. It runs in the worktree so it never conflicts with your working copy.

### Signal Model

| Signal | Meaning |
|---|---|
| Assign issue to bot account | "Work on this" |
| `agent-waiting` label | Bot posted something, waiting for human |
| `plan-approved` label | Plan approved, worker should implement |
| Human replies (while `agent-waiting`) | Label auto-removed, agent re-engages immediately |
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
    ├── config.sh            # Your config (created from config.example.sh)
    ├── architecture.md      # Your platform architecture (optional)
    ├── agent-prompt.md      # Agent system prompt (state machine + conventions)
    ├── dashboard.py         # Terminal UI
    ├── .stream-parser.py    # Stream-json → text parser
    ├── install.sh           # Install as launchd service
    └── uninstall.sh         # Remove service
```

### 2. Create Your Config

```bash
cp config.example.sh config.sh
```

Edit `config.sh` with your GitHub org, bot account, repos, and project board IDs:

```bash
ORG="your-github-org"
PROJECT_NUMBER=1
BOT_LOGIN="your-bot-account"
REPOS="repo-a repo-b repo-c"
AGENT_MODEL="opus"
MAX_PLANNERS=5       # concurrent planner agents (default: 5)
```

### 3. Find Project Board IDs

```bash
# Get project ID
gh project list --owner $ORG --format json | jq '.projects[] | {title, id, number}'

# Get field IDs
gh project field-list $PROJECT_NUMBER --owner $ORG --format json \
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

Add the IDs to `config.sh`:

```bash
PROJECT_ID="PVT_kwXXXXXX"
STATUS_FIELD_ID="PVTSSF_XXXXXXX"
STATUS_TODO="xxxxxxxx"
STATUS_IN_PROGRESS="xxxxxxxx"
STATUS_DONE="xxxxxxxx"
```

### 4. Document Your Architecture (Optional)

If your platform has multiple services, create `architecture.md` from the example:

```bash
cp architecture.example.md architecture.md
```

Edit it with your service map, database collections, and integration points. This gets injected into every agent's system prompt so the Planner understands cross-repo relationships.

### 5. Add Per-Repo CLAUDE.md Files

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

### 6. Install

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
launchctl print gui/$(id -u)/com.workstrator

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
- **Header**: Poll countdown, GraphQL remaining, service status
- **Left pane**: Running agents (Planners/Worker), issue queue, recent orchestrator log
- **Right pane**: Live agent output (auto-selects most recent planner when multiple are running)

### Keybindings

| Key | Action |
|---|---|
| `Up` / `Down` | Select issue in queue |
| `Tab` | Cycle right pane: Auto → Planner → Worker → Auto |
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

At 20 polls/hour with ~10 repos, the orchestrator uses ~2,400/hour, leaving headroom for agent work.

The dashboard reads from files only — it contributes zero API cost.

### Monitoring

The orchestrator logs GraphQL usage every poll cycle:

```
Polling... (GraphQL remaining: 4685)
Poll complete. Checked 5 issues. Planners: 2 active. Worker: idle. GraphQL: 4685→4664 (used 21)
```

The dashboard also shows a live poll countdown and GraphQL remaining in the header bar.

---

## Troubleshooting

### Agent not picking up an issue

1. **Is the repo in REPOS?** Check `REPOS=` in `config.sh`.
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
- To reduce cost: increase `POLL_INTERVAL` in `config.sh`.

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
| `config.sh` | Your configuration (gitignored) |
| `config.example.sh` | Configuration template |
| `architecture.md` | Your platform architecture (optional, gitignored) |
| `architecture.example.md` | Architecture template |
| `agent-prompt.md` | Agent system prompt — state machine, conventions |
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

## License

MIT
