# Contributing to Duo Dash

Thanks for your interest. Duo Dash is a personal, source-available project (see
[LICENSE](LICENSE)): you can build it for your own use, and bug reports and ideas are very
welcome. Code contributions are accepted at the maintainer's discretion; section 4 of the
licence covers how they're licensed.

## Issues
Use the templates (blank issues are off):
- **Bug report**: device, iOS version, Duo Dash version and commit
  (`git rev-parse --short HEAD`), folded / unfolded / half-open, steps, screenshots.
- **Feature request**: the problem in the car, and what you'd like it to do.
- **Support question**: install and setup help. Read [docs/INSTALL.md](docs/INSTALL.md)
  first; its Troubleshooting table answers most questions.

Never post personal details: Team IDs, bundle IDs with your name, device IDs, API keys,
Spotify client IDs or secrets, addresses, contacts. Security problems go through
[SECURITY.md](SECURITY.md).

### What happens after you open one
An automated assistant (Claude, running in GitHub Actions) reads new issues. It may add a
label (`bug`, `feature`, `support`, `duplicate`, `needs-info`), point you to the right part
of the docs, or ask for missing details. It can't change code or close issues. The
maintainer reads every issue and decides what happens next. If you're asked for more
information, **edit your issue** to add it; that re-runs the check.

For some issues the maintainer may ask the build agent to draft a pull request. Those PRs
are drafts, are reviewed and tested by the maintainer on a real device, and only reach
users when he merges them. How it all works: [docs/AGENT_PIPELINE.md](docs/AGENT_PIPELINE.md).

## Pull requests
1. Open or comment on an issue first, so we can agree it's wanted.
2. Read [AGENTS.md](AGENTS.md) ("Working on the code"). The same conventions apply to
   people:
   - Swift 5 language mode, `@MainActor @Observable` models, **zero compiler warnings**
     in app sources.
   - Touch targets of at least 60 pt; use `Theme` and the shared components.
   - Every text field gets a `DictationButton`.
   - Layout is size-driven, never orientation-driven: check the cover screen, inner
     screen, half-open and Split View.
   - Everything the user changes must persist.
   - Don't move the speech model folder or rename model IDs or the bundle ID.
3. Run the tests locally (there's no cloud CI for the app):
   ```bash
   xcodebuild test -project DuoDash.xcodeproj -scheme DuoDash \
     -destination 'platform=iOS Simulator,name=iPhone Duo' -only-testing:DuoDashTests
   ```
   UI tests (`-only-testing:DuoDashUITests`) take about 25 minutes; run the ones related
   to your change.
4. Don't commit `Config/Local.xcconfig`, `Config/Secrets.xcconfig` or anything personal.
   Changes to `.github/` (workflows, templates, agent prompts) are reviewed with extra
   care and may be declined.
5. Say in the PR what you changed, why, and how you tested it (device and postures).

## Maintainers
- Ask the agent to draft a fix: add the label `agent:build` to an issue, or comment
  `/agent build` (needs write access).
- Ask for an agent review of any same-repository PR: add the label `agent`.
- Turn all agents off: set the repository variable `AGENT_PIPELINE` to `off`.
