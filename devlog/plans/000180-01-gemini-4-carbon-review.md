# Plan: Upgrade CI Code Review Model to Gemini 4 Carbon

## Thinking

The GitHub Actions automated PR code review workflow (`.github/workflows/code-review.yml`) invokes `google-github-actions/run-gemini-cli@v0.1.22` with `gemini_model: 'gemini-3.8-flash'`, and `scripts/format_review_comment.py` formats the posted PR comment banner with `"Antigravity Deep Reasoning Audit (Gemini 3.8 Flash • {effort} effort)"` (previously updated together in commit `1c6f25a`).

Now that Gemini 4 Carbon (`gemini-4-carbon`) is available, both files must be updated in lockstep so CI runs `gemini-4-carbon` and the rendered PR review comment header accurately identifies `Gemini 4 Carbon`.

## Plan

1. Update `.github/workflows/code-review.yml` line 81 from `gemini_model: 'gemini-3.8-flash'` to `gemini_model: 'gemini-4-carbon'`.
2. Update `scripts/format_review_comment.py` line 216 from `Gemini 3.8 Flash` to `Gemini 4 Carbon`.
3. Validate YAML syntax of `.github/workflows/code-review.yml` and Python compilation plus `build_comment_body` output of `scripts/format_review_comment.py`.
4. Update `devlog/000180-ci-gemini-4-carbon-review.md`, commit, push to `refs/heads/ci/gemini-4-carbon-review`, and open a PR.
