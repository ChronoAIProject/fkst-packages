#!/usr/bin/env python3
"""Project trusted github-devloop lifecycle markers into one board fact."""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any


MAX_PROPOSAL_ID_BYTES = 200
MAX_STATE_BYTES = 64
MAX_VERSION_BYTES = 512
MAX_ORDER_KEY_BYTES = 768
TERMINAL_STATES = {"blocked", "impl-failed", "merged", "declined"}

MARKER_RE = re.compile(r"<!--\s*fkst:github-devloop:state:v1\b(.*?)-->")
ATTR_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="([^"]*)"')
UPDATED_AT_RE = re.compile(r"\d\d\d\d-\d\d-\d\dT\d\d[-:]\d\d[-:]\d\dZ")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--origin", required=True, help="Origin proposal id.")
    result.add_argument("--bot-login", required=True, help="Trusted lifecycle marker author login.")
    result.add_argument("--managed-bot-logins", default="", help="Accepted for parity with board fact tools.")
    return result


def safe_attr(value: Any, limit: int) -> str | None:
    if not isinstance(value, str) or value == "":
        return None
    if len(value.encode("utf-8")) > limit:
        return None
    if any(ord(ch) < 32 for ch in value):
        return None
    if any(ch in value for ch in '"<>'):
        return None
    if re.search(r"\s", value):
        return None
    return value


def parse_attrs(raw: str) -> dict[str, str]:
    return {match.group(1): match.group(2) for match in ATTR_RE.finditer(raw)}


def login_for(comment: dict[str, Any]) -> str:
    for key in ("user", "author"):
        raw = comment.get(key)
        if isinstance(raw, dict) and isinstance(raw.get("login"), str):
            return raw["login"]
    return ""


def read_comments() -> tuple[list[Any] | None, str | None]:
    text = sys.stdin.read()
    decoder = json.JSONDecoder()
    comments: list[Any] = []
    index = 0
    try:
        while index < len(text):
            while index < len(text) and text[index].isspace():
                index += 1
            if index >= len(text):
                break
            page, index = decoder.raw_decode(text, index)
            if isinstance(page, list):
                comments.extend(page)
            else:
                return None, "expected comments json array"
    except json.JSONDecodeError as exc:
        return None, f"invalid comments json: {exc}"
    return comments, None


def trusted_comments(comments: list[Any], bot_login: str) -> list[dict[str, Any]]:
    trusted = []
    for comment in comments:
        if not isinstance(comment, dict):
            continue
        if login_for(comment) != bot_login:
            continue
        body = comment.get("body")
        if isinstance(body, str):
            trusted.append({"body": body})
    return trusted


def collect_state_facts(comments: list[dict[str, Any]], origin: str) -> list[dict[str, str]]:
    facts = []
    for comment in comments:
        body = str(comment.get("body") or "")
        for match in MARKER_RE.finditer(body):
            attrs = parse_attrs(match.group(1))
            proposal = safe_attr(attrs.get("proposal"), MAX_PROPOSAL_ID_BYTES)
            state = safe_attr(attrs.get("state"), MAX_STATE_BYTES)
            version = safe_attr(attrs.get("version"), MAX_VERSION_BYTES)
            marker_order_key = safe_attr(attrs.get("marker_order_key"), MAX_ORDER_KEY_BYTES)
            if proposal == origin and state is not None and version is not None and marker_order_key is not None:
                facts.append({
                    "state": state,
                    "version": version,
                    "marker_order_key": marker_order_key,
                })
    return facts


def primary_rank(fact: dict[str, str]) -> int:
    return 1 if UPDATED_AT_RE.search(fact["version"]) else 0


def board_fact(facts: list[dict[str, str]]) -> dict[str, Any] | None:
    if not facts:
        return None
    current = max(facts, key=lambda fact: (primary_rank(fact), fact["marker_order_key"]))
    state = current["state"]
    return {
        "state": state,
        "terminal": state in TERMINAL_STATES,
    }


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    comments, err = read_comments()
    if comments is None:
        print(f"lifecycle-board-fact: {err}", file=sys.stderr)
        return 2

    fact = board_fact(collect_state_facts(trusted_comments(comments, args.bot_login), args.origin))
    if fact is None:
        return 1
    print(json.dumps(fact, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
