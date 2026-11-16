## How to test this locally

The agent can't compile iOS code on its Linux runner, so **this change has not been built
or run**. On the Mac, from the repository folder:

```bash
# 1. Get the branch
git fetch origin
git switch <BRANCH>

# 2. Unit tests on the iPhone Duo simulator (a few minutes)
xcodebuild test -project DuoDash.xcodeproj -scheme DuoDash \
  -destination 'platform=iOS Simulator,name=iPhone Duo' -only-testing:DuoDashTests

# 3. Check the app sources build with zero warnings
xcodebuild clean build -project DuoDash.xcodeproj -scheme DuoDash \
  -destination 'platform=iOS Simulator,name=iPhone Duo' 2>&1 \
  | grep -E 'warning:|error:' | grep '/DuoDash/' || echo 'No warnings in app sources'

# 4. UI tests (about 25 minutes; run the ones the agent lists, or all of them)
xcodebuild test -project DuoDash.xcodeproj -scheme DuoDash \
  -destination 'platform=iOS Simulator,name=iPhone Duo' -only-testing:DuoDashUITests

# 5. Try it on the phone (keeps settings and speech models)
scripts/setup.sh --install
```

Check by hand on the device: folded (cover screen), unfolded, half-open and Split View;
touch targets at least 60 pt; text fields have a dictation button; changes persist after
relaunch. `DUODASH_CANVAS=WxH` renders a given window size in the Simulator.

To throw the branch away: `git switch -` then `git branch -D <BRANCH>`, and close the PR.
