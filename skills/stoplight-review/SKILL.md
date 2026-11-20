---
name: stoplight-review
description: Review a GitHub pull request for Stoplight's auto-review and write findings as JSON to $STOPLIGHT_REVIEW_FILE. Use when the prompt says Stoplight requested a review, or $STOPLIGHT_REVIEW_FILE is set.
---

Stoplight runs this when someone requests your review on a PR. You read the PR, write findings to a file, and stop. Stoplight posts them.

## Read the PR

```bash
gh pr view "$STOPLIGHT_PR_URL" --comments
gh pr diff "$STOPLIGHT_PR_URL"
```

Read surrounding code with `gh api` when the diff alone can't tell you whether something is a bug.

## What counts as a finding

- Bugs: wrong logic, unhandled errors, races, off-by-one, broken edge cases.
- Security: injection, missing auth checks, secrets, unsafe input handling.
- Missing tests for logic that changed.
- Code a reader would misunderstand.

Skip style, naming and formatting nits. Skip anything a linter would catch.

## Confidence

- `high`: you are sure it is a real problem and can say how it fails. Stoplight posts these as your comments right away.
- `medium`: likely a problem, but it depends on context you couldn't check.
- `low`: worth a look.

Medium and low become a pending review the user edits before submitting. When unsure, go lower.

## Output

Write exactly this JSON to `$STOPLIGHT_REVIEW_FILE`, and nothing else:

```json
{
  "summary": "One or two sentences on the PR overall.",
  "findings": [
    {"path": "src/app.ts", "line": 42, "confidence": "high", "body": "What is wrong, how it fails, and the fix."}
  ]
}
```

- `line` is the line number in the new version of the file, and must be a line the diff adds or shows as context. Otherwise GitHub rejects the inline comment and Stoplight folds it into the review body.
- No findings: `"findings": []`.

## Never

- Post to GitHub (`gh pr review`, `gh pr comment`, `gh api` writes).
- Approve or request changes.
- Edit code, commit or push.
