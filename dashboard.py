#!/usr/bin/env python3
"""Workstrator v3 Dashboard — split-pane terminal UI with planner + worker agents."""

import curses
import json
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
LOG_DIR = SCRIPT_DIR / "logs"
STATE_DIR = SCRIPT_DIR / "state"
RUNNING_FILE = SCRIPT_DIR / "running.json"
BOARD_FILE = SCRIPT_DIR / "board-cache.json"

ORG = "appliedmindai"
PROJECT_NUMBER = "1"

# Refresh intervals
BOARD_REFRESH = 10  # seconds between board file reads (free — reads file written by workstrator)
LOG_REFRESH = 1     # seconds between log file reads


def run(cmd: str, timeout: int = 15) -> str:
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, Exception):
        return ""


def is_workstrator_running() -> bool:
    result = run("launchctl print gui/$(id -u)/com.appliedmindai.workstrator 2>&1")
    return "state = running" in result


def get_running_agents() -> list[dict]:
    """Read running.json — returns list of running agent dicts."""
    if RUNNING_FILE.exists():
        try:
            data = json.loads(RUNNING_FILE.read_text())
            if isinstance(data, list):
                return [a for a in data if a.get("status") == "running"]
        except (json.JSONDecodeError, ValueError):
            pass
    return []


def get_processed_issues() -> set[str]:
    if not STATE_DIR.exists():
        return set()
    return {f.name for f in STATE_DIR.iterdir() if f.is_file()}


def get_workstrator_log(n: int = 50) -> list[str]:
    log_file = LOG_DIR / "workstrator.log"
    if not log_file.exists():
        return []
    lines = log_file.read_text().strip().split("\n")
    return lines[-n:]


def get_agent_logs(role: str, issue_key: str) -> list[str]:
    """Get logs for a specific role + issue key."""
    logs = sorted(LOG_DIR.glob(f"{role}-{issue_key}-*.log"), reverse=True)
    if not logs:
        return [f"  (no {role} logs for this issue)"]
    content = logs[0].read_text().strip()
    if not content:
        return [f"  ({role} running — output buffered)"]
    return content.split("\n")


def get_most_recent_log() -> tuple[str, list[str]]:
    """Get the most recent agent log file regardless of role."""
    all_logs = sorted(
        LOG_DIR.glob("*-*-*.log"),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    all_logs = [l for l in all_logs if not l.name.endswith(".err")]
    if not all_logs:
        return "No Agents", ["  (no agent logs yet)"]
    content = all_logs[0].read_text().strip()
    if not content:
        return f"Last: {all_logs[0].name}", [f"  ({all_logs[0].name} — empty)"]
    header = [f"  Last run: {all_logs[0].name}", ""]
    return f"Last: {all_logs[0].stem}", header + content.split("\n")


def get_project_board_issues() -> list[dict]:
    """Read board data from file cache written by workstrator (zero API cost)."""
    if not BOARD_FILE.exists():
        return []
    try:
        data = json.loads(BOARD_FILE.read_text())
    except (json.JSONDecodeError, ValueError):
        return []

    issues = []
    for item in data.get("items", []):
        content = item.get("content", {})
        if content.get("type") != "Issue":
            continue
        repo_url = content.get("repository", "")
        repo = repo_url.split("/")[-1] if repo_url else ""
        num = content.get("number", "")
        if not repo or not num:
            continue
        issues.append({
            "repo": repo,
            "num": num,
            "title": content.get("title", ""),
            "status": item.get("status", ""),
            "key": f"{repo}-{num}",
        })
    return issues


# ──────────────────────────────────────────────────────────────────────
# Curses UI — Split Pane
# ──────────────────────────────────────────────────────────────────────

class Dashboard:
    def __init__(self, stdscr: curses.window):
        self.stdscr = stdscr
        self.issues: list[dict] = []
        self.non_done: list[dict] = []  # cached filtered list
        self.running_agents: list[dict] = []
        self.processed: set[str] = set()
        self.selected_idx = 0
        self.log_scroll = 0
        self.last_board_fetch = 0.0
        self.last_log_fetch = 0.0
        self.cached_agent_log: list[str] = []
        self.cached_agent_label: str = ""
        self.cached_workstrator_log: list[str] = []
        self.workstrator_running = False
        self.active_log_role: str | None = None  # None = auto, "planner"/"worker" = pinned
        self.setup_colors()

    def setup_colors(self):
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_GREEN, -1)     # running / done
        curses.init_pair(2, curses.COLOR_YELLOW, -1)     # waiting / warning
        curses.init_pair(3, curses.COLOR_RED, -1)        # error
        curses.init_pair(4, curses.COLOR_CYAN, -1)       # info
        curses.init_pair(5, curses.COLOR_MAGENTA, -1)    # agent active
        curses.init_pair(6, curses.COLOR_BLUE, -1)       # in progress
        curses.init_pair(7, curses.COLOR_BLACK, curses.COLOR_CYAN)   # selected row
        curses.init_pair(8, curses.COLOR_BLACK, curses.COLOR_GREEN)  # header
        curses.init_pair(9, curses.COLOR_WHITE, curses.COLOR_BLUE)   # status bar
        curses.init_pair(10, curses.COLOR_BLACK, curses.COLOR_YELLOW)  # planner
        curses.init_pair(11, curses.COLOR_BLACK, curses.COLOR_MAGENTA)  # worker

    def _rebuild_non_done(self):
        """Rebuild the filtered + sorted issue list and clamp selection."""
        running_keys = set()
        for agent in self.running_agents:
            running_keys.add(f"{agent.get('repo')}-{agent.get('num')}")

        self.non_done = [i for i in self.issues if i["status"] != "Done"]

        def sort_key(issue):
            if issue["key"] in running_keys:
                return 0
            if issue["status"] == "In progress":
                return 1
            return 2

        self.non_done.sort(key=sort_key)

        # Clamp selection to valid range
        if self.non_done:
            self.selected_idx = min(self.selected_idx, len(self.non_done) - 1)
        else:
            self.selected_idx = 0

    def _get_log_for_display(self) -> tuple[str, list[str]]:
        """Determine which log to show in the right pane based on state + role filter."""
        role = self.active_log_role  # None, "planner", or "worker"

        # If agents are running, show the running agent's log
        if self.running_agents:
            if role:
                # User pinned a specific role — find that agent
                for agent in self.running_agents:
                    if agent.get("role") == role:
                        key = f"{agent.get('repo')}-{agent.get('num')}"
                        label = f"{role.title()}: {agent.get('repo')}#{agent.get('num')}"
                        return label, get_agent_logs(role, key)
                # Pinned role not running — show the pinned role's most recent log anyway
                # (fall through to idle logic below)
            else:
                # Auto: prefer worker, then planner
                for preferred in ("worker", "planner"):
                    for agent in self.running_agents:
                        if agent.get("role") == preferred:
                            key = f"{agent.get('repo')}-{agent.get('num')}"
                            r = agent.get("role", "agent")
                            label = f"{r.title()}: {agent.get('repo')}#{agent.get('num')}"
                            return label, get_agent_logs(r, key)

        # Idle or pinned role not running — show log for selected issue
        if self.non_done and self.selected_idx < len(self.non_done):
            issue = self.non_done[self.selected_idx]

            if role:
                # User pinned a role — show that role's log for the selected issue
                logs = get_agent_logs(role, issue["key"])
                label = f"{role.title()}: {issue['key']}"
                return label, logs
            else:
                # Auto: try worker first, then planner, then most recent overall
                worker_logs = get_agent_logs("worker", issue["key"])
                if "(no worker logs" not in worker_logs[0]:
                    return f"Worker: {issue['key']}", worker_logs

                planner_logs = get_agent_logs("planner", issue["key"])
                if "(no planner logs" not in planner_logs[0]:
                    return f"Planner: {issue['key']}", planner_logs

        return get_most_recent_log()

    def refresh_data(self):
        now = time.time()

        # Board data — refresh every BOARD_REFRESH seconds
        if now - self.last_board_fetch > BOARD_REFRESH:
            new_issues = get_project_board_issues()
            if new_issues:  # Keep stale data on API failure instead of showing empty
                self.issues = new_issues
            self.processed = get_processed_issues()
            self.workstrator_running = is_workstrator_running()
            self.last_board_fetch = now

        # Running agents — check frequently (file read)
        self.running_agents = get_running_agents()

        # Rebuild filtered list (depends on both issues and running_agents)
        self._rebuild_non_done()

        # Logs — refresh frequently
        if now - self.last_log_fetch > LOG_REFRESH:
            self.cached_agent_label, self.cached_agent_log = self._get_log_for_display()
            self.cached_workstrator_log = get_workstrator_log(15)
            self.last_log_fetch = now

    def safe_addstr(self, y: int, x: int, text: str, attr: int = 0):
        h, w = self.stdscr.getmaxyx()
        if y < 0 or y >= h or x >= w:
            return
        try:
            self.stdscr.addnstr(y, x, text, w - x, attr)
        except curses.error:
            pass

    def draw_header(self):
        h, w = self.stdscr.getmaxyx()
        status = "RUNNING" if self.workstrator_running else "STOPPED"
        status_color = curses.color_pair(1) if self.workstrator_running else curses.color_pair(3)

        self.safe_addstr(0, 0, " " * w, curses.color_pair(8) | curses.A_BOLD)
        self.safe_addstr(0, 1, "Workstrator v3", curses.color_pair(8) | curses.A_BOLD)

        # Show agent count
        if self.running_agents:
            roles = "/".join(a.get("role", "?")[0].upper() for a in self.running_agents)
            agent_info = f" [{roles}] "
            self.safe_addstr(0, 16, agent_info, curses.color_pair(8))

        self.safe_addstr(0, w - len(status) - 3, f" {status} ", status_color | curses.A_BOLD)

    def draw_left_pane(self):
        h, w = self.stdscr.getmaxyx()
        left_w = w // 2 - 1
        y = 2

        # Running agents status
        if self.running_agents:
            for agent in self.running_agents:
                role = agent.get("role", "?")
                repo = agent.get("repo", "?")
                num = agent.get("num", "?")
                started = agent.get("started", "")

                if role == "planner":
                    icon = "P"
                    color = curses.color_pair(10) | curses.A_BOLD
                    label_color = curses.color_pair(2) | curses.A_BOLD
                else:
                    icon = "W"
                    color = curses.color_pair(11) | curses.A_BOLD
                    label_color = curses.color_pair(5) | curses.A_BOLD

                self.safe_addstr(y, 1, f" {icon} ", color)
                self.safe_addstr(y, 5, f"{role.title()}: {repo}#{num}", label_color)
                if started:
                    self.safe_addstr(y + 1, 5, f"since {started}", curses.A_DIM)
                y += 2
        else:
            self.safe_addstr(y, 1, "Idle — waiting for next poll", curses.A_DIM)
            y += 1

        y += 1

        # Issue queue
        self.safe_addstr(y, 1, "Queue", curses.A_BOLD | curses.A_UNDERLINE)
        y += 1

        # Build running agent keys for highlighting
        running_keys = set()
        for agent in self.running_agents:
            running_keys.add(f"{agent.get('repo')}-{agent.get('num')}")

        # Calculate available rows for queue (leave 7 lines for log section + 1 gap)
        queue_rows = max(0, (h - 8) - y)

        if queue_rows > 0 and self.non_done:
            # Scroll window to keep selected visible
            visible_start = max(0, min(
                self.selected_idx - queue_rows + 1,
                len(self.non_done) - queue_rows,
            ))
            visible_start = max(0, visible_start)
            visible_end = min(len(self.non_done), visible_start + queue_rows)

            for idx in range(visible_start, visible_end):
                if y >= h - 8:
                    break
                issue = self.non_done[idx]
                is_selected = idx == self.selected_idx
                is_running = issue["key"] in running_keys

                # Find which role is working on it
                role_marker = "  "
                if is_running:
                    for agent in self.running_agents:
                        if f"{agent.get('repo')}-{agent.get('num')}" == issue["key"]:
                            role_marker = f" {agent.get('role', '?')[0].upper()}>"
                            break

                status_str = issue["status"][:11]
                line = f"{role_marker} #{issue['num']:<5} {issue['repo']:<20} {status_str:<11}"
                line = line[:left_w - 1]

                if is_selected:
                    line = line.ljust(left_w - 1)
                    self.safe_addstr(y, 1, line, curses.color_pair(7) | curses.A_BOLD)
                elif is_running:
                    self.safe_addstr(y, 1, line, curses.color_pair(5) | curses.A_BOLD)
                elif issue["status"] == "In progress":
                    self.safe_addstr(y, 1, line, curses.color_pair(6))
                else:
                    self.safe_addstr(y, 1, line, curses.A_NORMAL)
                y += 1
        elif not self.non_done:
            self.safe_addstr(y, 2, "(no active issues)", curses.A_DIM)

        # Recent workstrator log — fixed at bottom
        y = h - 7
        self.safe_addstr(y, 1, "Recent Log", curses.A_BOLD | curses.A_UNDERLINE)
        y += 1

        for line in self.cached_workstrator_log[-5:]:
            if y >= h - 1:
                break
            attr = curses.A_DIM
            if "ERROR" in line:
                attr = curses.color_pair(3)
            elif "PLANNER:" in line:
                attr = curses.color_pair(2)
            elif "WORKER:" in line:
                attr = curses.color_pair(5)
            elif "finished" in line:
                attr = curses.color_pair(1)
            elif "Poll complete" in line:
                attr = curses.A_BOLD
            self.safe_addstr(y, 2, line[:left_w - 3], attr)
            y += 1

    def draw_right_pane(self):
        h, w = self.stdscr.getmaxyx()
        left_w = w // 2
        right_w = w - left_w - 1
        right_x = left_w + 1

        # Draw vertical separator
        for row in range(1, h - 1):
            self.safe_addstr(row, left_w, "\u2502", curses.A_DIM)

        y = 2

        # Header: label + role filter indicator
        label = self.cached_agent_label
        if self.active_log_role:
            label += f"  [{self.active_log_role[0].upper()} pinned]"
        self.safe_addstr(y, right_x + 1, label, curses.color_pair(4) | curses.A_BOLD)

        # Tab hint (always visible)
        self.safe_addstr(y, right_x + right_w - 12, "[Tab switch]", curses.A_DIM)

        y += 1
        self.safe_addstr(y, right_x + 1, "\u2500" * min(right_w - 2, 50), curses.A_DIM)
        y += 1

        # Log content
        log_area_height = h - y - 2
        if log_area_height <= 0:
            return

        total_lines = len(self.cached_agent_log)
        max_scroll = max(0, total_lines - log_area_height)
        if self.log_scroll > max_scroll:
            self.log_scroll = max_scroll

        start_line = max(0, total_lines - log_area_height - self.log_scroll)
        end_line = min(total_lines, start_line + log_area_height)

        for i in range(start_line, end_line):
            if y >= h - 1:
                break
            line = self.cached_agent_log[i]
            self.safe_addstr(y, right_x + 1, line[:right_w - 2], curses.A_NORMAL)
            y += 1

        # Scroll indicator
        if total_lines > log_area_height:
            pct = int(((total_lines - self.log_scroll) / total_lines) * 100)
            self.safe_addstr(h - 2, w - 8, f" {pct:>3}% ", curses.A_DIM)

    def draw_footer(self):
        h, w = self.stdscr.getmaxyx()
        now = datetime.now(timezone.utc).strftime("%H:%M:%S UTC")
        keys = " \u2191/\u2193 select \u2502 PgUp/PgDn scroll \u2502 Tab switch \u2502 r refresh \u2502 q quit "
        footer = f"{keys}\u2502 {now} "
        footer = footer.ljust(w)
        self.safe_addstr(h - 1, 0, footer[:w - 1], curses.color_pair(9))

    def handle_input(self):
        self.stdscr.timeout(500)
        try:
            key = self.stdscr.getch()
        except curses.error:
            return True

        if key == ord("q") or key == ord("Q"):
            return False

        elif key == curses.KEY_UP:
            if self.non_done:
                self.selected_idx = max(0, self.selected_idx - 1)
                self.log_scroll = 0
                self.last_log_fetch = 0

        elif key == curses.KEY_DOWN:
            if self.non_done:
                self.selected_idx = min(len(self.non_done) - 1, self.selected_idx + 1)
                self.log_scroll = 0
                self.last_log_fetch = 0

        elif key == curses.KEY_PPAGE:
            h, _ = self.stdscr.getmaxyx()
            self.log_scroll = min(
                self.log_scroll + (h // 2),
                max(0, len(self.cached_agent_log) - 5)
            )

        elif key == curses.KEY_NPAGE:
            h, _ = self.stdscr.getmaxyx()
            self.log_scroll = max(0, self.log_scroll - (h // 2))

        elif key == ord("\t"):
            # Tab: cycle through None → planner → worker → None
            if self.active_log_role is None:
                self.active_log_role = "planner"
            elif self.active_log_role == "planner":
                self.active_log_role = "worker"
            else:
                self.active_log_role = None  # back to auto
            self.log_scroll = 0
            self.last_log_fetch = 0

        elif key == ord("r") or key == ord("R"):
            self.last_board_fetch = 0
            self.last_log_fetch = 0
            self.active_log_role = None  # Reset to auto

        return True

    def run(self):
        curses.curs_set(0)
        self.stdscr.clear()

        while True:
            self.refresh_data()
            self.stdscr.erase()
            self.draw_header()
            self.draw_left_pane()
            self.draw_right_pane()
            self.draw_footer()
            self.stdscr.refresh()

            if not self.handle_input():
                break


def main(stdscr):
    dashboard = Dashboard(stdscr)
    dashboard.run()


if __name__ == "__main__":
    curses.wrapper(main)
