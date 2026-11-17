#!/bin/bash
# Sends an announcement to every Duo Dash user who turned Announcements on.
#
#   scripts/notify.sh "Title" "Body" [--bundle com.duodash.app] [--url duodash://open/settings]
#
# Needs two environment variables (keep them out of the repo, e.g. in your shell profile or
# a password manager):
#   DUODASH_NOTIFY_URL          the worker, e.g. https://duodash-notify.<you>.workers.dev
#   DUODASH_NOTIFY_ADMIN_TOKEN  the ADMIN_TOKEN secret set on the worker
# --bundle limits it to one build: com.duodash.app (App Store) or com.duodash.beta (TestFlight).
# See docs/NOTIFICATIONS.md.
set -euo pipefail

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[[ $# -ge 2 ]] || usage 1
TITLE="$1"; BODY="$2"; shift 2
BUNDLE=""; LINK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle) BUNDLE="${2:?--bundle needs a bundle ID}"; shift 2 ;;
    --url) LINK="${2:?--url needs a duodash:// link}"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

: "${DUODASH_NOTIFY_URL:?Set DUODASH_NOTIFY_URL to the worker URL}"
: "${DUODASH_NOTIFY_ADMIN_TOKEN:?Set DUODASH_NOTIFY_ADMIN_TOKEN to the ADMIN_TOKEN secret of the worker}"
BASE="${DUODASH_NOTIFY_URL%/}"
[[ "$BASE" == *"://"* ]] || BASE="https://$BASE"

# Build the JSON safely (quotes, newlines, unicode) without needing jq.
PAYLOAD=$(TITLE="$TITLE" BODY="$BODY" BUNDLE="$BUNDLE" LINK="$LINK" /usr/bin/python3 -c '
import json, os
p = {"title": os.environ["TITLE"], "body": os.environ["BODY"]}
if os.environ["BUNDLE"]: p["bundleId"] = os.environ["BUNDLE"]
if os.environ["LINK"]: p["url"] = os.environ["LINK"]
print(json.dumps(p))')

# The token goes in through a config file on stdin, so it never shows in `ps`.
printf 'header = "Authorization: Bearer %s"\n' "$DUODASH_NOTIFY_ADMIN_TOKEN" |
  curl --silent --show-error --fail-with-body --config - \
    -X POST "$BASE/broadcast" \
    -H "Content-Type: application/json" \
    --data-binary "$PAYLOAD"
echo
