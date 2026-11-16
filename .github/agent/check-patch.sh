#!/bin/bash
# Checks a patch written by the build agent before the workflow commits it.
#
#   .github/agent/check-patch.sh <patch-file> <flags-out-file>
#
# Exit 0: patch may be published. Warnings for the owner are written to <flags-out-file>
#         (one Markdown bullet per line; empty when there is nothing to flag).
# Exit 1: patch touches a protected path, contains something that looks like a secret,
#         or is too large. The reason is printed and also written to <flags-out-file>.
# Exit 2: usage error or unreadable patch.
#
# Runs from the default branch's copy of this file, before the patch is applied, so the
# patch can't change the rules it is checked against.
set -euo pipefail

PATCH=${1:-}; FLAGS=${2:-}
[ -n "$PATCH" ] && [ -n "$FLAGS" ] && [ -r "$PATCH" ] || { echo "usage: $0 <patch> <flags-out>" >&2; exit 2; }
: > "$FLAGS"

MAX_FILES=60
MAX_LINES=4000

block() { echo "BLOCKED: $*"; echo "- **Blocked:** $*" >> "$FLAGS"; BLOCKED=1; }
flag()  { echo "flag: $*";    echo "- $*" >> "$FLAGS"; }
BLOCKED=0

# Paths and line counts. The patch is made with --no-renames, so every path is literal.
NUMSTAT=$(git apply --numstat -z "$PATCH" | tr '\0' '\n') || { echo "patch does not parse" >&2; exit 2; }
files=0; lines=0
while IFS=$'\t' read -r added deleted path; do
  [ -n "${path:-}" ] || continue
  files=$((files + 1))
  if [ "$added" = "-" ]; then
    flag "Binary file: \`$path\`"
  else
    lines=$((lines + added + deleted))
  fi
  case "$path" in
    .github/*|.claude/*|.claude-pr/*|.husky/*|.mcp.json|.claude.json|CLAUDE.md|CLAUDE.local.md|.gitmodules|.gitignore|.ripgreprc)
      block "changes agent/CI configuration \`$path\`" ;;
    *.xcconfig|LICENSE|SECURITY.md)
      block "changes protected file \`$path\`" ;;
    *Package.swift|*Package.resolved|Podfile*|Cartfile*|*.xcworkspace/*)
      flag "**New or changed dependency** in \`$path\`" ;;
    *.pbxproj)
      flag "Xcode project file changed: \`$path\` (check for new packages, targets or build settings)" ;;
    *.entitlements)
      flag "**Entitlements changed:** \`$path\`" ;;
    *Info.plist)
      flag "**Info.plist changed:** \`$path\` (new permission prompts or keys?)" ;;
    scripts/*|ci/*)
      flag "Script changed: \`$path\` (runs on the owner's Mac)" ;;
    AGENTS.md)
      flag "\`AGENTS.md\` changed (instructions other agents follow)" ;;
  esac
done <<< "$NUMSTAT"

[ "$files" -le "$MAX_FILES" ] || block "too many files ($files > $MAX_FILES)"
[ "$lines" -le "$MAX_LINES" ] || block "too many changed lines ($lines > $MAX_LINES)"

# Secrets and personal details in added lines.
ADDED=$(grep -E '^\+' "$PATCH" | grep -vE '^\+\+\+ ' || true)
check() { # <label> <extended regex>
  if printf '%s\n' "$ADDED" | grep -Eq -- "$2"; then block "added lines contain $1"; fi
}
check "an Anthropic API key"       'sk-ant-[A-Za-z0-9_-]{10,}'
check "a GitHub token"             '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
check "a private key"              '-----BEGIN [A-Z ]*PRIVATE KEY-----'
check "an AWS key"                 'AKIA[0-9A-Z]{16}'
check "a Team ID"                  'DEVELOPMENT_TEAM *= *[A-Z0-9]{10}'
check "a Spotify client secret"    '[Cc]lient_?[Ss]ecret *[:=] *"?[0-9a-f]{32}'
if printf '%s\n' "$ADDED" | grep -Eq 'https?://' ; then
  urls=$(printf '%s\n' "$ADDED" | grep -Eo 'https?://[^ )"'"'"'>]+' | sort -u | head -20 | sed 's/^/`/; s/$/`/' | paste -sd ',' - | sed 's/,/, /g')
  flag "Adds URLs: $urls"
fi

if [ "$BLOCKED" -ne 0 ]; then exit 1; fi
echo "patch ok: $files files, $lines changed lines"
