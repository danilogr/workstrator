#!/usr/bin/env bash
# Workstrator configuration
# Copy this file to config.sh and customize for your setup:
#
#   cp config.example.sh config.sh
#   $EDITOR config.sh
#
# config.sh is gitignored — your secrets and IDs stay local.

# ── GitHub ───────────────────────────────────────────────────────────

# Your GitHub organization (or personal account)
ORG="your-org"

# Project board number (from https://github.com/orgs/YOUR_ORG/projects/N)
PROJECT_NUMBER=1

# Bot account username — the GitHub account agents operate as.
# Create a dedicated account, authenticate `gh` as this account,
# and give it write access to all monitored repos.
BOT_LOGIN="your-bot"

# ── Agent ────────────────────────────────────────────────────────────

# Seconds between poll cycles (default: 180 = 3 minutes)
POLL_INTERVAL=180

# Claude model: "opus", "sonnet", or "haiku"
AGENT_MODEL="opus"

# Max concurrent planner agents (default: 5)
MAX_PLANNERS=5

# ── Repos ────────────────────────────────────────────────────────────

# Space-separated list of GitHub repo names to monitor.
# These must be cloned as sibling directories next to workstrator/.
REPOS="repo-a repo-b repo-c"

# Map GitHub repo name → local directory name.
# Override only when they differ. Default: same name.
repo_to_local() {
  case "$1" in
    # github-repo-name)  echo "local-dir-name" ;;
    *)  echo "$1" ;;
  esac
}

# ── Project Board IDs ────────────────────────────────────────────────
# Run these commands to find your IDs (see README.md for details):
#
#   gh project list --owner $ORG --format json | jq '.projects[] | {title, id, number}'
#   gh project field-list $PROJECT_NUMBER --owner $ORG --format json | jq '.fields[] | {name, id}'
#   gh api graphql -f query='query { organization(login: "YOUR_ORG") {
#     projectV2(number: N) { field(name: "Status") {
#       ... on ProjectV2SingleSelectField { options { id name } } } } } }'

# Project
PROJECT_ID=""                # e.g., PVT_kwXXXXXX

# Field IDs (single-select fields on your project board)
STATUS_FIELD_ID=""           # Status field
PRIORITY_FIELD_ID=""         # Priority field (optional)
SIZE_FIELD_ID=""             # Size field (optional)
CATEGORY_FIELD_ID=""         # Category field (optional)

# Status option IDs (required — used for board updates)
STATUS_TODO=""               # e.g., f75ad846
STATUS_IN_PROGRESS=""        # e.g., 47fc9ee4
STATUS_DONE=""               # e.g., 98236657

# Priority option IDs (optional — included in agent prompt for reference)
PRIORITY_P0=""
PRIORITY_P1=""
PRIORITY_P2=""

# Size option IDs (optional)
SIZE_XS=""
SIZE_S=""
SIZE_M=""
SIZE_L=""
SIZE_XL=""

# Category option IDs (optional)
CATEGORY_BUG=""
CATEGORY_FEATURE=""
CATEGORY_IDEA=""
CATEGORY_CHORE=""
CATEGORY_TECH_DEBT=""

# ── macOS LaunchAgent ────────────────────────────────────────────────

# launchd service label — must be unique on this machine.
# Convention: com.<your-org>.workstrator
LAUNCHD_LABEL="com.workstrator"
