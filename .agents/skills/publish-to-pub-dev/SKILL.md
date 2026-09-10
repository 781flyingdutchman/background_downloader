---
name: publish-to-pub-dev
description: >-
  Publishes the background_downloader package to pub.dev. Use this skill whenever the user asks
  to publish, release, deploy, or push a new version of background_downloader to pub.dev,
  including executing integration tests across iOS, Android, and macOS with flaky test retries,
  verifying version bumps, updating CHANGELOG.md, verifying static analysis and code formatting,
  committing to dev, waiting for GitHub Actions CI to pass, dry-running and publishing to pub.dev,
  fast-forwarding main, tagging with V<version>, and pushing to origin.
---

# Publishing background_downloader to pub.dev

This skill guides the full release process of the `background_downloader` package to [pub.dev](https://pub.dev/packages/background_downloader).

## Release Workflow Overview

The release consists of 11 sequential steps:
1. **Run Integration Tests with Flaky Test Handling** (iOS emulator, Android emulator, macOS)
2. **Check pub.dev Version & Determine Version Bump** (respect manual bumps; otherwise patch/minor)
3. **Verify and Update CHANGELOG.md** (ensure all changes since previous release are documented)
4. **Pre-Commit Quality Verification** (ensure 0 analyzer issues and clean `dart format`)
5. **Commit to `dev` Branch and Push to Trigger CI** (stage release files, commit on `dev`, push to `origin/dev`)
6. **Wait for GitHub Action CI to Pass** (monitor `.github/workflows/build.yml` until completion with 0 errors)
7. **Run `pub publish --dry-run`** (ensure 0 errors and 0 warnings)
8. **Execute `pub publish`** (request user confirmation, confirm version, and publish to pub.dev)
9. **Fast-forward `main` Branch** (bring `main` to the release commit)
10. **Add Git Tag** (`V<version>`, e.g. `V9.6.1`)
11. **Push `main` and Tags to Origin** (push `main` and release tags to `origin`)

---

## Step 1: Run Integration Tests Across All Platforms

Run the full integration test suite across all three supported local platforms: **Android emulator**, **iOS simulator/emulator**, and **macOS**.

### Execution

Use the automated test runner script that handles initial execution and flaky test retries:

```bash
./.agents/skills/publish-to-pub-dev/scripts/test_runner_with_retry.sh
```

Alternatively, to run manually:
```bash
./example/run_tests.sh
```

### Flaky Test Handling

The script `example/run_tests.sh` outputs a summary of failed test files and devices:
```text
Summary: X failed, Y passed.
Failed tests:
  - <test_file> on <device_label> (<device_id>)
```

Along with the failure details and specific failing test case description (marked with `[E]`):
```text
---FAILED--- Test: <test_file> on device: <device_id> (Duration: Xs)
00:15 +1 -1: <specific_test_name> [E]
```

- **If all tests pass initially**: Proceed immediately to Step 2.
- **If any test fails initially**:
  - **Do NOT rerun using `run_tests.sh`**. Re-running the entire test file takes a long time and may introduce new flaky test results from unrelated tests in that file.
  - Instead, identify the failing test file, target device, and the **specific test name** (within the test file) that failed from the log or failure output (`example/integration_test/logs/<timestamp>.log`).
  - Use `flutter test` directly with `--plain-name` to retry **only** that specific test on that specific device:
    ```bash
    flutter test example/integration_test/<test_file> -d "<device_id>" --plain-name "<specific_test_name>"
    ```
    *(For example: `flutter test example/integration_test/uidt_test.dart -d emulator-5554 --plain-name "Enqueue and wait for completion"` or `flutter test example/integration_test/database_test.dart -d 8715BE69-FDE4-4A44-A205-D9F3258EA31C --plain-name "records without path or with relative path have default path"`)*

    > [!IMPORTANT]
    > **Ensure `test_server.py` is running in its venv prior to retrying tests.**
    > Since `example/run_tests.sh` automatically shuts down the test server upon exiting, check and restart it if needed using its virtual environment:
    > ```bash
    > SERVER_URL="http://127.0.0.1:8080"
    > if ! curl --output /dev/null --silent --head --fail "$SERVER_URL"; then
    >   if [ -d ".venv" ]; then
    >     PYTHON_EXEC=".venv/bin/python3"
    >   elif [ -d "example/.venv" ]; then
    >     PYTHON_EXEC="example/.venv/bin/python3"
    >   else
    >     PYTHON_EXEC="python3"
    >   fi
    >   $PYTHON_EXEC test_server/test_server.py > /dev/null 2>&1 &
    >   for i in {1..10}; do
    >     sleep 1
    >     curl --output /dev/null --silent --head --fail "$SERVER_URL" && break
    >   done
    > fi
    > ```
    > When test retries are finished, shut down the server:
    > ```bash
    > curl -X POST "http://127.0.0.1:8080/shutdown" > /dev/null 2>&1
    > ```

  - **Passed on Retry**: Confirm that the failure was caused by flakiness. Log the flaky test in the release notes or output and continue.
  - **Failed on Retry**: **STOP IMMEDIATELY**. This is a persistent test failure. Report the failure to the user and do not proceed with the release until fixed.

---

## Step 2: Check pub.dev Version & Determine Version Bump

### 1. Run the Version Check Helper

```bash
./.agents/skills/publish-to-pub-dev/scripts/check_pub_version.sh
```

Or query pub.dev directly:
```bash
curl -s https://pub.dev/api/packages/background_downloader | grep -o '"version":"[^"]*"' | head -n 1
```

### 2. Manual Version Override Rule (CRITICAL)

> [!IMPORTANT]
> If the `version:` in [pubspec.yaml](../../../pubspec.yaml) is **already different from the latest version on pub.dev** (for example, `pubspec.yaml` already has `9.6.1` while pub.dev is at `9.6.0`), **assume the user has already manually updated the version number to the intended release version. DO NOT modify or overwrite it.**

### 3. Automatic Version Bump (When `pubspec.yaml` matches pub.dev)

If `pubspec.yaml` still matches the version on pub.dev, analyze commits between `origin/main` and `dev`:
```bash
git log --oneline origin/main..dev
```

Apply Semantic Versioning:
- **Patch (`X.Y.Z + 1`)** (*Default / Most Common*): Maintenance releases, bug fixes, dependency updates (e.g. `connectivity_plus` constraint expansion), performance improvements, CI or internal fixes.
- **Minor (`X.Y + 1.0`)**: Only when new features, new public APIs, or major capabilities have been added.
- **Major (`X + 1.0.0`)**: Breaking public API changes (rare).

Update `version: <new_version>` in [pubspec.yaml](../../../pubspec.yaml).

---

## Step 3: Verify and Update CHANGELOG.md

Inspect [CHANGELOG.md](../../../CHANGELOG.md):
```bash
head -n 40 CHANGELOG.md
```

### Verification Checklist:
1. Ensure there is a top section header matching the target version: `## <version>`.
2. Inspect commits since the previous release:
   ```bash
   git log --oneline origin/main..dev
   ```
3. Confirm that all notable changes, fixes, and enhancements are captured under `## <version>`.
4. Follow existing project conventions for changelog entries:
   - Prefix platform-specific changes with `[Android]`, `[iOS]`, `[macOS]`, `[Windows]`, `[Linux]`, or `[Documentation]`.
   - Include issue or PR references in parentheses, e.g. `(fixes #717)`, `(#724)`.
   - Bold major feature titles if applicable.
5. If changes are missing or if the header does not match the target version, edit `CHANGELOG.md` before proceeding.

---

## Step 4: Pre-Commit Quality Verification

Before committing, verify that the codebase is completely clean of formatting and analysis issues:

### Execution

Run the helper script:
```bash
./.agents/skills/publish-to-pub-dev/scripts/pre_commit_checks.sh
```

Or execute directly:
1. **Verify Formatting**:
   ```bash
   dart format --set-exit-if-changed .
   ```
   If formatting changes are needed, run `dart format .` and review modified files.
2. **Verify Static Analysis (Root & Example)**:
   ```bash
   flutter analyze
   cd example && flutter analyze && cd ..
   ```
   Must return **0 issues found**. If any warnings, infos, or errors are reported, fix them before proceeding.

---

## Step 5: Commit on `dev` Branch and Push to Trigger CI

1. Verify that the current branch is `dev`:
   ```bash
   git checkout dev
   ```
2. Check git status to confirm only intended release files are modified:
   ```bash
   git status
   git diff
   ```
3. Stage and commit:
   ```bash
   git add pubspec.yaml CHANGELOG.md
   git commit -m "Release <version>"
   ```
4. Push `dev` to `origin` to trigger the GitHub Action CI build:
   ```bash
   git push origin dev
   ```

---

## Step 6: Wait for GitHub Actions CI Build to Complete Without Errors

Pushing to `dev` triggers the GitHub Actions workflow `.github/workflows/build.yml` ("Build the package"), which runs:
- Formatting check (`dart format --set-exit-if-changed .`)
- Linting check (`flutter analyze` for root and example)
- Android builds (minimum, stable, and beta Flutter SDKs)
- iOS builds (minimum, stable, and beta Flutter SDKs)
- Linux builds (stable and beta Flutter SDKs)

### Execution

Run the automated watcher:
```bash
./.agents/skills/publish-to-pub-dev/scripts/wait_for_gh_action.sh
```

Alternatively, watch with GitHub CLI:
```bash
gh run watch --exit-status
```

> [!CAUTION]
> Proceed to publishing **ONLY** if the GitHub Actions run completes with **success (0 errors)**. If any job fails, inspect the failure with `gh run view <run-id> --log-failed` or on GitHub, fix the underlying issue on `dev`, and push again.

---

## Step 7: Run Dry-Run Validation

Run pub publish in dry-run mode from the workspace root:

```bash
dart pub publish --dry-run
```
*(or `flutter pub publish --dry-run`)*

### Verification:
- Must finish with **0 warnings** and **0 errors**:
  ```text
  Package has 0 warnings.
  ```
- If warnings exist:
  - **False secrets warning** (e.g. test certificates or dummy keys): Ensure the offending test file is listed under `false_secrets:` in [pubspec.yaml](../../../pubspec.yaml).
  - **Formatting issues**: Run `dart format .` across modified files.
  - **Dependency constraints**: Fix any warnings in `pubspec.yaml`.
  - Amend or create a new commit on `dev` and re-run `--dry-run` until clean.

---

## Step 8: Publish to pub.dev

> [!WARNING]
> Publishing to pub.dev is permanent and cannot be undone.

1. Display the target version and confirm:
   - Target version: `<version>`
   - Confirm against `pubspec.yaml` and `CHANGELOG.md`.
2. **Request User Confirmation (MANDATORY)**:
   > [!IMPORTANT]
   > **Always ask for user confirmation before executing the `dart pub publish` command.**
   > State the package name, the target version, and key release notes. You must stop, prompt the user, and wait for explicit approval before running `dart pub publish`.
3. Once user approval is granted, execute publish command:
   ```bash
   dart pub publish
   ```
4. When prompted:
   ```text
   Publishing background_downloader <version> to https://pub.dev:
   ...
   Do you want to publish background_downloader <version> (y/N)?
   ```
   Respond with `y` to confirm publication.
5. Verify that publication completes successfully (HTTP 200 / "Package successfully published").

---

## Step 9: Bring `main` Branch to this Version

The `main` branch tracks official releases on pub.dev. Fast-forward `main` to the release commit:

```bash
git checkout main
git merge --ff-only dev
```

Verify that `main` and `dev` point to the exact same commit:
```bash
[ "$(git rev-parse main)" = "$(git rev-parse dev)" ] && echo "main is aligned with dev"
```

---

## Step 10: Add Git Tag

Add an annotated tag for the release version.
**Important:** The tag name must be preceded by an uppercase **`V`** (matching repository history, e.g. `V9.6.0`):

```bash
git tag -a "V<version>" -m "Release V<version>"
```

*Example:*
```bash
git tag -a V9.6.1 -m "Release V9.6.1"
```

Verify the tag:
```bash
git show "V<version>" --stat
```

---

## Step 11: Push `main` and Tags to Origin

Push updated `main` branch and tags to the remote repository:

```bash
git push origin main
git push origin "V<version>"
```

*(Alternatively: `git push origin main --tags`)*

Verify remote status:
```bash
git status
```

---

## Summary of Helper Scripts

- **`./.agents/skills/publish-to-pub-dev/scripts/check_pub_version.sh`**:
  Queries pub.dev API, inspects `pubspec.yaml`, checks git status between `origin/main` and current branch, detects manual version updates, and suggests version bumps.
- **`./.agents/skills/publish-to-pub-dev/scripts/pre_commit_checks.sh`**:
  Verifies that `dart format` changes 0 files and `flutter analyze` returns 0 issues in both root and example packages.
- **`./.agents/skills/publish-to-pub-dev/scripts/wait_for_gh_action.sh`**:
  Monitors and streams the GitHub Actions CI build (`.github/workflows/build.yml`) for the pushed `dev` commit, ensuring all matrix builds and lint checks pass before publishing.
- **`./.agents/skills/publish-to-pub-dev/scripts/test_runner_with_retry.sh`**:
  Wraps `example/run_tests.sh`, runs the full suite across iOS, Android, and macOS, isolates specific failed test names, retries only those tests using `flutter test --plain-name`, and identifies flaky tests versus persistent failures.
