# Security policy

## Reporting a vulnerability
Please **don't open a public issue** for security problems.

Use GitHub's private reporting instead: open the repository's **Security** tab and choose
**Report a vulnerability**. Only the maintainer can see the report. If that button isn't
there, open a public issue titled "Security contact request" with **no details**, and the
maintainer will reply with a private way to send them.

Please include what's affected (file, feature, or workflow), how to reproduce it, and the
impact you expect. You'll get a reply when the maintainer has read it; this is a personal
project, so please allow a few days.

## What's in scope
- The app's handling of user data on the phone: contacts, messages, location, places,
  dashcam recordings, and the Claude API key and Spotify tokens kept in the Keychain.
- Anything that sends data off the device unexpectedly.
- `scripts/` (they run on the user's Mac) and the setup instructions.
- The GitHub automation in `.github/`: prompt injection that makes the agents leak
  secrets, publish unexpected changes, act outside their stated permissions, or post
  harmful content. See [docs/AGENT_PIPELINE.md](docs/AGENT_PIPELINE.md).

## Out of scope
- Problems that need a jailbroken or already-compromised device or Mac.
- Apple, Spotify or Anthropic services themselves (report those to them).
- The automated triage reply being unhelpful or wrong. That's a normal bug report.

## Supported versions
Only the latest commit on the default branch. There are no release builds: users update
with `git pull && scripts/setup.sh --install`.

## Secrets
Never post API keys, Team IDs, Spotify client IDs or secrets, device IDs or addresses in
issues, pull requests or reports. If you posted one by mistake, revoke or rotate it first,
then edit it out.
