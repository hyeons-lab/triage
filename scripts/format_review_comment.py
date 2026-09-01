#!/usr/bin/env python3
"""Formats and replaces/upserts the Gemini CLI review output as a clean GitHub PR comment."""

from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys

try:
    import zoneinfo
except ImportError:
    zoneinfo = None  # type: ignore

COMMENT_TAG = "<!-- antigravity-code-review -->"
MAX_COMMENT_CHARS = 65000
DEFAULT_SUBPROCESS_TIMEOUT = 60

JSON_ESCAPE_MAP = {
    'n': '\n',
    'r': '\r',
    't': '\t',
    'b': '\b',
    'f': '\f',
}


def is_empty_or_null(val: str | None) -> bool:
    if not val:
        return True
    return val.strip().lower() in ("null", "undefined", "none", "")


def unescape_json_string(s: str) -> str:
    try:
        return json.loads(f'"{s}"', strict=False)
    except Exception:
        pass

    # Single-pass atomic escape replacement (handles both single-char and \\uXXXX escapes)
    def _replace_match(match: re.Match) -> str:
        simple = match.group(1)
        if simple:
            return JSON_ESCAPE_MAP.get(simple, simple)
        hex_code = match.group(2)
        if hex_code:
            try:
                return chr(int(hex_code, 16))
            except Exception:
                return match.group(0)
        return match.group(0)

    s = re.sub(r'\\(?:([\\"/bfnrt])|u([0-9a-fA-F]{4}))', _replace_match, s)
    try:
        # Re-encode and decode with surrogatepass to assemble any UTF-16 surrogate pairs into valid characters
        return s.encode('utf-16', 'surrogatepass').decode('utf-16', errors='replace')
    except Exception:
        return s


def extract_review_text(raw: str) -> str:
    if is_empty_or_null(raw):
        return ""
    raw = raw.strip()

    # Unwrap outer markdown code blocks if the entire response is enclosed in a single wrapper
    if raw.startswith("```") and raw.endswith("```"):
        lines = raw.splitlines()
        if len(lines) >= 2:
            first_line_lower = lines[0].lower().strip()
            inner = "\n".join(lines[1:-1]).strip()
            # Only unwrap if the outer tag explicitly indicates a wrapper fence and inner fences are balanced
            if (
                first_line_lower in ("```json", "```markdown", "```md", "```text")
                and inner.count("```") % 2 == 0
            ):
                raw = inner

    # Strategy 1: json.loads with strict=False (allows unescaped newlines/control chars)
    try:
        data = json.loads(raw, strict=False)
        if isinstance(data, dict):
            text = data.get("response")
            if isinstance(text, str) and text.strip():
                return text.strip()

            candidates = data.get("candidates")
            if isinstance(candidates, list) and candidates:
                first_cand = candidates[0]
                if isinstance(first_cand, dict):
                    content = first_cand.get("content")
                    if isinstance(content, dict):
                        parts = content.get("parts")
                        if isinstance(parts, list):
                            text_parts = [
                                p["text"]
                                for p in parts
                                if isinstance(p, dict)
                                and not p.get("thought", False)
                                and isinstance(p.get("text"), str)
                            ]
                            if text_parts:
                                return "".join(text_parts).strip()

            # If the payload is a Gemini/API envelope with no review content, don't leak raw JSON
            if any(k in data for k in ("response", "candidates", "session_id", "promptFeedback", "error")):
                return ""
        elif isinstance(data, str) and data.strip():
            return data.strip()
    except Exception:
        pass

    # Strategy 2: Regex extraction for JSON object envelopes (starts with {)
    if raw.startswith("{"):
        m = re.search(
            r'"response"\s*:\s*"((?:[^"\\]|\\.)*)"',
            raw,
            re.DOTALL,
        )
        if m:
            extracted = unescape_json_string(m.group(1))
            if extracted.strip():
                return extracted.strip()

    # Strategy 3: Raw markdown output
    return raw


def resolve_head_sha(head_sha_env: str) -> str:
    if not is_empty_or_null(head_sha_env):
        return head_sha_env.strip()
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            timeout=DEFAULT_SUBPROCESS_TIMEOUT,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
    except Exception:
        pass
    return ""


def get_formatted_timestamps(now_utc: datetime.datetime | None = None) -> str:
    if now_utc is None:
        now_utc = datetime.datetime.now(datetime.timezone.utc)
    elif now_utc.tzinfo is None:
        now_utc = now_utc.replace(tzinfo=datetime.timezone.utc)

    if zoneinfo is not None:
        try:
            pt_tz = zoneinfo.ZoneInfo("America/Los_Angeles")
            now_pt = now_utc.astimezone(pt_tz)
            pt_str = now_pt.strftime("%Y-%m-%d %I:%M:%S %p %Z")
            utc_str = now_utc.strftime("%H:%M:%S UTC")
            return f"{pt_str} ({utc_str})"
        except Exception:
            pass

    # Fallback: Deterministic dynamic PT timezone calculation (PST vs PDT)
    year = now_utc.year
    # Second Sunday in March (DST start): March 1st weekday (0=Mon, 6=Sun)
    m1_dow = datetime.datetime(year, 3, 1, tzinfo=datetime.timezone.utc).weekday()
    m_dst_start = 1 + (6 - m1_dow) % 7 + 7
    dst_start = datetime.datetime(year, 3, m_dst_start, 10, 0, tzinfo=datetime.timezone.utc)

    # First Sunday in November (DST end)
    n1_dow = datetime.datetime(year, 11, 1, tzinfo=datetime.timezone.utc).weekday()
    n_dst_end = 1 + (6 - n1_dow) % 7
    dst_end = datetime.datetime(year, 11, n_dst_end, 9, 0, tzinfo=datetime.timezone.utc)

    if dst_start <= now_utc < dst_end:
        offset_hours, tz_name = -7, "PDT"
    else:
        offset_hours, tz_name = -8, "PST"

    pt_tz = datetime.timezone(datetime.timedelta(hours=offset_hours))
    now_pt = now_utc.astimezone(pt_tz)
    return f"{now_pt.strftime('%Y-%m-%d %I:%M:%S %p')} {tz_name} ({now_utc.strftime('%H:%M:%S UTC')})"


def build_comment_body(
    review_text: str,
    effort: str,
    repo: str,
    head_sha: str,
    now_utc: datetime.datetime | None = None,
) -> str:
    review_text = review_text.strip()

    # Robust whole-line header stripping for any heading level and trailing suffixes
    review_text = re.sub(
        r"^#*\s*(?:🪐\s*)?antigravity\s+code\s+review[^\n]*\n*",
        "",
        review_text,
        flags=re.IGNORECASE,
    ).strip()

    short_sha = head_sha[:7] if head_sha else ""
    commit_link = (
        f"[`{short_sha}`](https://github.com/{repo}/commit/{head_sha})"
        if (repo and short_sha)
        else (f"`{short_sha}`" if short_sha else "")
    )
    timestamp_str = get_formatted_timestamps(now_utc)

    meta_parts = []
    if commit_link:
        meta_parts.append(f"Reviewed commit {commit_link}")
    meta_parts.append(timestamp_str)
    meta_parts.append(f"Antigravity Deep Reasoning Audit (Gemini 3.7 Flash • {effort} effort)")

    meta_header = f"> *{' • '.join(meta_parts)}*"
    full_body = f"{COMMENT_TAG}\n## 🪐 Antigravity Code Review\n{meta_header}\n\n{review_text}"

    # Protect against GitHub API's strict 65,536 character comment body limit
    if len(full_body) > MAX_COMMENT_CHARS:
        truncation_warning = "\n\n... *[Review truncated due to GitHub character limit. Read full audit in workflow execution logs]*"
        avail_len = MAX_COMMENT_CHARS - len(truncation_warning)
        truncated = full_body[:avail_len]
        # If truncation cut inside an unclosed code block (odd number of ```), close it cleanly
        if truncated.count("```") % 2 != 0:
            truncated = full_body[: avail_len - 4].rstrip() + "\n```"
        full_body = truncated + truncation_warning

    return full_body


def find_comment_id_in_items(comments: list[dict] | dict) -> str | None:
    items = comments if isinstance(comments, list) else [comments]
    for comment in reversed(items):
        if isinstance(comment, dict):
            body = comment.get("body") or ""
            cid = comment.get("id")
            if isinstance(body, str) and COMMENT_TAG in body and cid is not None and str(cid) != "None":
                return str(cid)
    return None


def find_existing_comment_id(repo: str, pr_number: str) -> str | None:
    try:
        proc = subprocess.run(
            ["gh", "api", f"repos/{repo}/issues/{pr_number}/comments", "--paginate"],
            capture_output=True,
            text=True,
            timeout=DEFAULT_SUBPROCESS_TIMEOUT,
        )
        if proc.returncode == 0:
            decoder = json.JSONDecoder()
            idx = 0
            s = proc.stdout.strip()
            last_matching_id = None
            while idx < len(s):
                s_slice = s[idx:].lstrip()
                if not s_slice:
                    break
                idx = len(s) - len(s_slice)
                obj, end = decoder.raw_decode(s, idx)
                idx = end
                found = find_comment_id_in_items(obj)
                if found:
                    last_matching_id = found
            return last_matching_id
        else:
            print(f"Warning: gh api returned non-zero code {proc.returncode}: {proc.stderr.strip()}", file=sys.stderr)
    except Exception as e:
        print(f"Warning: Failed to search for existing comments: {e}", file=sys.stderr)
    return None


def main() -> None:
    pr_number = os.environ.get("PR_NUMBER", "").lstrip("#").strip()
    if not pr_number:
        print("PR_NUMBER not set; skipping comment posting.", file=sys.stderr)
        return

    raw_response = ""
    response_file = os.environ.get("RESPONSE_FILE", "").strip()
    if response_file and os.path.isfile(response_file):
        try:
            with open(response_file, "r", encoding="utf-8") as f:
                content = f.read().strip()
                if not is_empty_or_null(content):
                    raw_response = content
        except Exception:
            pass

    if is_empty_or_null(raw_response):
        raw_response = os.environ.get("RESPONSE", "").strip()

    # Fallback to output files if RESPONSE environment variable is empty
    if is_empty_or_null(raw_response):
        for artifact_path in [
            "gemini-artifacts/response.md",
            "gemini-artifacts/stdout.log",
        ]:
            if os.path.isfile(artifact_path):
                try:
                    with open(artifact_path, "r", encoding="utf-8") as f:
                        content = f.read().strip()
                        if not is_empty_or_null(content):
                            raw_response = content
                            break
                except Exception:
                    pass

    if is_empty_or_null(raw_response):
        print("Error: No review response content found to post.", file=sys.stderr)
        sys.exit(1)

    review_text = extract_review_text(raw_response)
    if not review_text:
        print("Error: Failed to extract review text.", file=sys.stderr)
        sys.exit(1)

    effort = os.environ.get("EFFORT_LEVEL", "high") or "high"
    repo = os.environ.get("GITHUB_REPOSITORY", "hyeons-lab/triage") or "hyeons-lab/triage"
    head_sha = resolve_head_sha(os.environ.get("HEAD_SHA", "").strip())

    final_body = build_comment_body(review_text, effort, repo, head_sha)

    # Replace/upsert comment: if an existing review comment is found, PATCH/replace it in place
    success = False
    existing_comment_id = find_existing_comment_id(repo, pr_number)
    if existing_comment_id:
        print(f"Replacing existing Antigravity review comment #{existing_comment_id} with latest review for commit {head_sha[:7]}...")
        try:
            proc = subprocess.run(
                ["gh", "api", f"repos/{repo}/issues/comments/{existing_comment_id}", "-X", "PATCH", "--input", "-"],
                input=json.dumps({"body": final_body}),
                text=True,
                capture_output=True,
                timeout=DEFAULT_SUBPROCESS_TIMEOUT,
            )
            if proc.returncode == 0:
                success = True
            else:
                print(f"Warning: Failed to update comment #{existing_comment_id} ({proc.stderr.strip()}). Falling back to posting a new comment...", file=sys.stderr)
        except Exception as e:
            print(f"Warning: Exception updating comment #{existing_comment_id} ({e}). Falling back to posting a new comment...", file=sys.stderr)

    if not success:
        print(f"Posting initial/fallback Antigravity review comment for commit {head_sha[:7]}...")
        try:
            proc = subprocess.run(
                ["gh", "pr", "comment", pr_number, "--repo", repo, "--body-file", "-"],
                input=final_body,
                text=True,
                capture_output=True,
                timeout=DEFAULT_SUBPROCESS_TIMEOUT,
            )
            if proc.returncode != 0:
                print(f"Error submitting PR comment: {proc.stderr}", file=sys.stderr)
                sys.exit(proc.returncode)
        except Exception as e:
            print(f"Error submitting PR comment: {e}", file=sys.stderr)
            sys.exit(1)

    print(f"Successfully updated Antigravity code review comment on PR #{pr_number}")


if __name__ == "__main__":
    main()
