#!/usr/bin/env python3
"""
Antigravity / Gemini automated code review for GitHub Pull Requests.

Fetches the pull request diff, ignores generated files and build artifacts,
applies repository guidelines from AGENTS.md / GEMINI.md, and posts or updates
a structured review comment on the PR.
"""

import datetime
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

# Files to exclude from LLM diff review to save context and avoid reviewing generated code
IGNORED_PATTERNS = [
    "flutter/triage_client/lib/generated/",
    "crates/triaged/dist/",
    "Cargo.lock",
    "pubspec.lock",
    "package-lock.json",
    "third_party/",
    "target/",
    ".wasm",
    ".dylib",
    ".so",
    ".dll",
]

COMMENT_TAG = "<!-- antigravity-code-review -->"


def run_cmd(cmd: list[str]) -> str:
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print(f"Command failed: {' '.join(cmd)}\n{res.stderr}", file=sys.stderr)
        return ""
    return res.stdout.strip()


def should_ignore_file(filepath: str) -> bool:
    for pat in IGNORED_PATTERNS:
        if pat.endswith("/"):
            if pat in filepath:
                return True
        elif filepath.endswith(pat) or pat in filepath:
            return True
    return False


def get_pr_diff(base_ref: str, base_sha: str | None = None) -> str:
    # Ensure origin/base_ref is fetched
    run_cmd(["git", "fetch", "origin", base_ref])

    target = base_sha if base_sha else f"origin/{base_ref}"
    changed_files = run_cmd(["git", "diff", "--name-only", f"{target}...HEAD"]).splitlines()
    reviewable_files = [f for f in changed_files if not should_ignore_file(f)]

    if not reviewable_files:
        return ""

    diff_chunks = []
    for f in reviewable_files:
        diff = run_cmd(["git", "diff", f"{target}...HEAD", "--", f])
        if diff:
            # Cap individual large file diffs if needed
            if len(diff) > 20000:
                diff = diff[:20000] + "\n\n[... diff truncated for length ...]\n"
            diff_chunks.append(diff)

    full_diff = "\n\n".join(diff_chunks)
    # Global safety cap (approx 80k characters)
    if len(full_diff) > 80000:
        full_diff = full_diff[:80000] + "\n\n[... overall diff truncated for context limit ...]\n"
    return full_diff


def get_repo_guidelines() -> str:
    guidelines = []
    for filename in ["AGENTS.md", "GEMINI.md"]:
        if os.path.isfile(filename):
            try:
                with open(filename, "r", encoding="utf-8") as f:
                    guidelines.append(f"--- {filename} ---\n" + f.read(4000))
            except Exception:
                pass
    return "\n\n".join(guidelines)


def call_gemini_api(api_key: str, prompt: str) -> str:
    model = os.getenv("ANTIGRAVITY_MODEL", "gemini-3.7-flash")
    thinking_budget = int(os.getenv("ANTIGRAVITY_THINKING_BUDGET", "8192"))
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
    payload = {
        "contents": [
            {
                "parts": [{"text": prompt}]
            }
        ],
        "generationConfig": {
            "temperature": 0.1,
            "maxOutputTokens": 16384,
            "thinkingConfig": {
                "thinkingBudget": thinking_budget,
            },
        },
    }

    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            candidates = data.get("candidates", [])
            if candidates:
                parts = candidates[0].get("content", {}).get("parts", [])
                text_parts = [
                    p.get("text", "")
                    for p in parts
                    if "text" in p and not p.get("thought", False)
                ]
                if text_parts:
                    return "".join(text_parts).strip()
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"Gemini API model '{model}' HTTPError {e.code}: {body}", file=sys.stderr)
    except Exception as e:
        print(f"Gemini API model '{model}' request failed: {e}", file=sys.stderr)

    return ""


def find_existing_comment_id(github_token: str, repo: str, pr_number: str) -> int | None:
    comments_url = f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments?per_page=100"
    headers = {
        "Authorization": f"token {github_token}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "Antigravity-Code-Review",
    }
    req = urllib.request.Request(comments_url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req) as resp:
            comments = json.loads(resp.read().decode("utf-8"))
            for c in comments:
                if COMMENT_TAG in c.get("body", ""):
                    return c["id"]
    except Exception as e:
        print(f"Error checking existing comments: {e}", file=sys.stderr)
    return None


def post_comment(
    github_token: str,
    repo: str,
    pr_number: str,
    comment_body: str,
    head_sha: str = "",
) -> None:
    short_sha = head_sha[:7] if head_sha else run_cmd(["git", "rev-parse", "--short", "HEAD"])
    commit_link = (
        f"[`{short_sha}`](https://github.com/{repo}/commit/{head_sha})"
        if head_sha
        else f"`{short_sha}`"
    )
    timestamp_utc = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%d %H:%M:%S UTC"
    )

    body_clean = comment_body.strip()
    if body_clean.startswith("## 🪐 Antigravity Code Review"):
        body_clean = body_clean[len("## 🪐 Antigravity Code Review"):].strip()
    elif body_clean.startswith("# Antigravity Code Review"):
        body_clean = body_clean[len("# Antigravity Code Review"):].strip()

    meta_header = (
        f"> *Reviewed commit {commit_link} • {timestamp_utc} • "
        f"Deep Reasoning Audit (Gemini 3.7 Flash)*"
    )
    full_body = f"{COMMENT_TAG}\n## 🪐 Antigravity Code Review\n{meta_header}\n\n{body_clean}"
    headers = {
        "Authorization": f"token {github_token}",
        "Accept": "application/vnd.github.v3+json",
        "User-Agent": "Antigravity-Code-Review",
    }

    existing_id = find_existing_comment_id(github_token, repo, pr_number)
    if existing_id:
        url = f"https://api.github.com/repos/{repo}/issues/comments/{existing_id}"
        method = "PATCH"
        action = f"Updated existing review comment {existing_id}"
    else:
        url = f"https://api.github.com/repos/{repo}/issues/{pr_number}/comments"
        method = "POST"
        action = "Created new review comment"

    req = urllib.request.Request(
        url,
        data=json.dumps({"body": full_body}).encode("utf-8"),
        headers=headers,
        method=method,
    )
    try:
        with urllib.request.urlopen(req):
            print(f"{action} on PR #{pr_number}")
    except Exception as e:
        print(f"Error posting comment: {e}", file=sys.stderr)
        raise


def main():
    is_local = "--local" in sys.argv or "--stdout" in sys.argv
    api_key = os.getenv("ANTIGRAVITY_API_KEY") or os.getenv("GEMINI_API_KEY")
    if not api_key:
        print("ANTIGRAVITY_API_KEY or GEMINI_API_KEY not set; skipping automated code review.", file=sys.stderr)
        sys.exit(0)

    github_token = os.getenv("GITHUB_TOKEN")
    repo = os.getenv("GITHUB_REPOSITORY")
    pr_number = os.getenv("PR_NUMBER")
    base_ref = os.getenv("BASE_REF", "main")
    base_sha = os.getenv("BASE_SHA", "")
    head_sha = os.getenv("HEAD_SHA", "")
    pr_title = os.getenv("PR_TITLE", "")
    pr_body = os.getenv("PR_BODY", "")

    if not is_local and not (github_token and repo and pr_number):
        is_local = True

    diff = get_pr_diff(base_ref, base_sha)
    if not diff:
        # Fall back to working tree diff if branch diff is clean
        diff = run_cmd(["git", "diff", "HEAD"])
    if not diff:
        print("No reviewable diff found.")
        sys.exit(0)

    guidelines = get_repo_guidelines()

    prompt = f"""You are Antigravity, a Senior Principal Systems & Terminal Architecture Specialist conducting a thorough, rigorous, production-grade code review for the Triage repository.

About Triage:
Triage is an attention-routing terminal supervisor: a long-running Rust daemon (`triaged`), a Ratatui local TUI (`triage`), a Flutter remote client (`flutter/triage_client`), and an MCP server (`triage-mcp`), all sharing one unified session API.

Repository Guidelines & Rules:
{guidelines}

Pull Request Context:
- Title: {pr_title}
- Description: {pr_body}

Diff to review:
```diff
{diff}
```

Review Objective & Standard:
Provide a rigorous, deep-dive code review that matches or exceeds the depth, precision, and actionable quality of top-tier reviewers (such as Copilot / Junie / human staff engineers). Do NOT write superficial or generic summaries. Every finding must be specific, backed by exact file paths, line references or code snippets, and include a concrete fix proposal.

Audit Checklist:
1. **Architectural & Cross-Platform Systems Integrity**:
   - Clean abstractions, minimal coupling, and proper crate boundaries across `crates/` workspace and `flutter/`.
   - Cross-platform portability (macOS vs Linux vs Android vs Windows, Unix domain sockets vs Windows named pipes/TCP).
   - Zero-Downtime Daemon Handover Protocol invariants (Phase 1 FD passing, Phase 2 adoption sync, Phase 3 teardown commit).
2. **Concurrency, Threading & Lock Safety**:
   - Mutex ordering: sessions lock must NEVER be held across blocking I/O, actor round-trips, snapshot generation, or handover transfers.
   - Poisoned mutex recovery (`.unwrap_or_else(|p| p.into_inner())` on shared daemon statics).
   - Channel drain loops, atomic ordering (`SeqCst` vs `Acquire`/`Release` vs `Relaxed`), cancellation token safety.
3. **Descriptors, SCM_RIGHTS & Resource Management**:
   - Master PTY close-on-exec (`FD_CLOEXEC`, `dup_cloexec`, `recv_fds`).
   - `cmsghdr` memory alignment (`allocate_control_buffer` allocating `Vec<usize>`).
   - Descriptor leak prevention during handover recovery snapshot compaction and error teardown.
4. **Correctness, Edge Cases & Error Domains**:
   - Strict no-panic in runtime/daemon paths (`bail!`, `ensure!`, `?` error propagation instead of `.unwrap()`/`.expect()`).
   - Signal handling and self-pipe safety in `shutdown.rs` (non-blocking write end, signal mask preservation across exec).
   - Peer authentication & process termination safety (macOS audit tokens, Linux pidfds/proc validation against PID reuse).
5. **Performance & Hot Paths**:
   - Avoid lock contention in snapshot polling, styled rows extraction, or session event fanout.
   - Pipelined session extraction during handover rather than serial blocking waits.
6. **Test Coverage & Regression Prevention**:
   - Proper regression tests for bugs, edge cases, and lifecycles in `handover_tests.rs`, `pty_child_exec.rs`, etc.

Output Structure:
### 1. Executive Summary & Impact Analysis
- Concise technical synthesis of what the PR changes, architectural implications, and readiness for merge.

### 2. 🚨 Critical / Blocking Issues
*(If none, explicitly state "None identified.")*
- Severe bugs, memory/concurrency violations, unhandled panics/exceptions, or breaking regressions.
- Include exact `file_path:line_number`, explanation of the hazard, and a concrete before/after code diff fix.

### 3. ⚠️ Warnings & Correctness Risks
- Edge cases, error handling gaps, resource leaks, cross-platform caveats, or subtle logical flaws.
- Include exact `file_path:line_number`, explanation, and actionable code diff recommendations.

### 4. 💡 Suggestions & Optimization Opportunities
- Non-blocking improvements: cleaner idioms, performance optimizations in hot paths, documentation comments, or refactoring opportunities.
- Include exact `file_path:line_number` and concise code proposals.

### 5. 🧪 Test Coverage & Edge Cases to Consider
- Specific scenarios or test cases that should be verified (e.g. timeout handling, PID recycling, broken pipe during handover).

### 6. 🌟 Architecture Highlights
- Acknowledge well-crafted patterns, elegant abstractions, and robust implementations in the PR.

Be direct, highly technical, actionable, and precise.
"""

    print("Generating thorough deep-reasoning code review with Gemini 3.7 Flash...")
    review = call_gemini_api(api_key, prompt)
    if not review:
        print("Failed to get review from API.", file=sys.stderr)
        sys.exit(1)

    if is_local:
        print("\n" + "=" * 80)
        print("## 🪐 Antigravity Code Review (Local)")
        print("=" * 80 + "\n")
        print(review)
    else:
        print("Posting review comment to GitHub...")
        post_comment(github_token, repo, pr_number, review, head_sha=head_sha)


if __name__ == "__main__":
    main()
