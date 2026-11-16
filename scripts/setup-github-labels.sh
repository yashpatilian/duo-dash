#!/bin/bash
# Creates (or updates) the GitHub labels the issue templates and agent workflows use.
#
#   scripts/setup-github-labels.sh                         # the repo of the current folder
#   scripts/setup-github-labels.sh --repo owner/name       # a specific repo
#
# Needs the GitHub CLI signed in with write access (`gh auth status`). Safe to re-run:
# existing labels are updated, nothing is deleted.
set -euo pipefail

REPO_ARGS=()
case "${1:-}" in
  --repo) [ -n "${2:-}" ] || { echo "usage: $0 [--repo owner/name]"; exit 2; }; REPO_ARGS=(--repo "$2") ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--repo owner/name]"; exit 2 ;;
esac

command -v gh >/dev/null || { echo "Install the GitHub CLI first: https://cli.github.com"; exit 1; }

label() { # name colour description
  gh label create "$1" --color "$2" --description "$3" --force "${REPO_ARGS[@]+"${REPO_ARGS[@]}"}"
}

label "bug"          "d73a4a" "Something isn't working"
label "feature"      "a2eeef" "New feature or change request"
label "support"      "0e8a16" "Help with installing, setup or use"
label "duplicate"    "cfd3d7" "Same as another issue"
label "needs-info"   "fbca04" "Waiting for more details from the reporter"
label "needs-human"  "b60205" "Flagged by an agent for the maintainer to look at"
label "agent"        "5319e7" "Pull request written or reviewed by the Claude agent"
label "agent:build"  "1d76db" "Maintainers: ask the agent to draft a PR for this issue"

echo "Labels ready."
