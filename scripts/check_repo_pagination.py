#!/usr/bin/env python3
"""GraphQL pagination structure helpers for repository checks."""

from __future__ import annotations

import re


GRAPHQL_FIRST_CONNECTION_RE = re.compile(
    r"\b[A-Za-z_][A-Za-z0-9_]*\s*"
    r"\([^(){}]*\bfirst\s*:\s*\d+\b[^(){}]*\)\s*\{",
    re.DOTALL,
)


def matching_graphql_brace(text: str, open_index: int) -> int | None:
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    return None


def graphql_top_level_text(text: str) -> str:
    chars: list[str] = []
    depth = 0
    for char in text:
        if char == "{":
            depth += 1
            chars.append(" ")
        elif char == "}":
            depth = max(0, depth - 1)
            chars.append(" ")
        elif depth == 0:
            chars.append(char)
        elif char == "\n":
            chars.append("\n")
        else:
            chars.append(" ")
    return "".join(chars)


def graphql_depth_at(text: str, index: int) -> int:
    depth = 0
    for char in text[:index]:
        if char == "{":
            depth += 1
        elif char == "}":
            depth = max(0, depth - 1)
    return depth


def graphql_top_level_field_body(text: str, field_name: str) -> str | None:
    field_re = re.compile(r"\b" + re.escape(field_name) + r"\b\s*\{")
    for match in field_re.finditer(text):
        if graphql_depth_at(text, match.start()) != 0:
            continue
        open_index = match.end() - 1
        close_index = matching_graphql_brace(text, open_index)
        if close_index is not None:
            return text[open_index + 1 : close_index]
    return None


def graphql_connection_has_truncation_guard(selection_body: str) -> bool:
    top_level = graphql_top_level_text(selection_body)
    if re.search(r"\btotalCount\b", top_level):
        return True

    page_info_body = graphql_top_level_field_body(selection_body, "pageInfo")
    if page_info_body is None:
        return False
    return re.search(r"\bhasNextPage\b", graphql_top_level_text(page_info_body)) is not None
