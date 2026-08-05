"""Deterministic Lua lexical spans for repository checkers."""

from __future__ import annotations

import re
from collections.abc import Callable, Collection
from dataclasses import dataclass, replace


SHORT_STRING = "short_string"
LONG_STRING = "long_string"
LINE_COMMENT = "line_comment"
LONG_COMMENT = "long_comment"

LITERAL_KINDS = frozenset({SHORT_STRING, LONG_STRING})
COMMENT_KINDS = frozenset({LINE_COMMENT, LONG_COMMENT})
MASKED_KINDS = LITERAL_KINDS | COMMENT_KINDS

LUA_WORD_RE = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\b")


@dataclass(frozen=True, order=True)
class LuaSpan:
    kind: str
    start: int
    end: int
    body_start: int
    body_end: int
    line: int
    body_line: int
    end_line: int
    terminated: bool
    delimiter_level: int | None = None

    @property
    def is_literal(self) -> bool:
        return self.kind in LITERAL_KINDS

    @property
    def is_comment(self) -> bool:
        return self.kind in COMMENT_KINDS

    def content(self, text: str) -> str:
        return text[self.body_start : self.body_end]


def _line_number(text: str, index: int) -> int:
    return text.count("\n", 0, max(0, min(index, len(text)))) + 1


def _span(
    text: str,
    *,
    kind: str,
    start: int,
    end: int,
    body_start: int,
    body_end: int,
    terminated: bool,
    delimiter_level: int | None = None,
    include_line_metadata: bool = True,
) -> LuaSpan:
    if not include_line_metadata:
        line = body_line = end_line = 0
    else:
        last_index = start if end <= start else end - 1
        line = _line_number(text, start)
        body_line = _line_number(text, body_start)
        end_line = _line_number(text, last_index)
    return LuaSpan(
        kind=kind,
        start=start,
        end=end,
        body_start=body_start,
        body_end=body_end,
        line=line,
        body_line=body_line,
        end_line=end_line,
        terminated=terminated,
        delimiter_level=delimiter_level,
    )


def _long_bracket_opener(text: str, start: int) -> tuple[int, int, str] | None:
    if start >= len(text) or text[start] != "[":
        return None
    cursor = start + 1
    while cursor < len(text) and text[cursor] == "=":
        cursor += 1
    if cursor >= len(text) or text[cursor] != "[":
        return None
    level = cursor - start - 1
    opener_length = cursor - start + 1
    return opener_length, level, "]" + ("=" * level) + "]"


def _long_bracket_span(
    text: str,
    start: int,
    kind: str,
    *,
    include_line_metadata: bool = True,
) -> LuaSpan | None:
    opener = _long_bracket_opener(text, start)
    if opener is None:
        return None
    opener_length, level, closer = opener
    body_start = start + opener_length
    close_start = text.find(closer, body_start)
    terminated = close_start != -1
    body_end = len(text) if not terminated else close_start
    end = len(text) if not terminated else close_start + len(closer)
    return _span(
        text,
        kind=kind,
        start=start,
        end=end,
        body_start=body_start,
        body_end=body_end,
        terminated=terminated,
        delimiter_level=level,
        include_line_metadata=include_line_metadata,
    )


def _short_string_span(text: str, start: int, *, include_line_metadata: bool = True) -> LuaSpan | None:
    if start >= len(text) or text[start] not in {"'", '"'}:
        return None
    quote = text[start]
    cursor = start + 1
    terminated = False
    while cursor < len(text):
        if text[cursor] == "\\":
            cursor = min(cursor + 2, len(text))
            continue
        if text[cursor] == quote:
            cursor += 1
            terminated = True
            break
        cursor += 1
    body_end = cursor - 1 if terminated else len(text)
    return _span(
        text,
        kind=SHORT_STRING,
        start=start,
        end=cursor,
        body_start=start + 1,
        body_end=body_end,
        terminated=terminated,
        include_line_metadata=include_line_metadata,
    )


def literal_span_at(
    text: str,
    start: int,
    *,
    recognize_long_brackets: bool = True,
    include_line_metadata: bool = True,
) -> LuaSpan | None:
    short = _short_string_span(text, start, include_line_metadata=include_line_metadata)
    if short is not None:
        return short
    if not recognize_long_brackets:
        return None
    return _long_bracket_span(
        text,
        start,
        LONG_STRING,
        include_line_metadata=include_line_metadata,
    )


def comment_span_at(
    text: str,
    start: int,
    *,
    recognize_long_brackets: bool = True,
    include_line_metadata: bool = True,
) -> LuaSpan | None:
    if not text.startswith("--", start):
        return None
    long_comment = (
        _long_bracket_span(
            text,
            start + 2,
            LONG_COMMENT,
            include_line_metadata=include_line_metadata,
        )
        if recognize_long_brackets
        else None
    )
    if long_comment is not None:
        return _span(
            text,
            kind=LONG_COMMENT,
            start=start,
            end=long_comment.end,
            body_start=long_comment.body_start,
            body_end=long_comment.body_end,
            terminated=long_comment.terminated,
            delimiter_level=long_comment.delimiter_level,
            include_line_metadata=include_line_metadata,
        )
    newline = text.find("\n", start)
    end = len(text) if newline == -1 else newline
    return _span(
        text,
        kind=LINE_COMMENT,
        start=start,
        end=end,
        body_start=start + 2,
        body_end=end,
        terminated=True,
        include_line_metadata=include_line_metadata,
    )


def lex(
    text: str,
    *,
    recognize_long_brackets: bool = True,
    recognize_comments: bool = True,
) -> tuple[LuaSpan, ...]:
    spans: list[LuaSpan] = []
    cursor = 0
    current_line = 1
    while cursor < len(text):
        comment = (
            comment_span_at(
                text,
                cursor,
                recognize_long_brackets=recognize_long_brackets,
                include_line_metadata=False,
            )
            if recognize_comments
            and text[cursor] == "-"
            and cursor + 1 < len(text)
            and text[cursor + 1] == "-"
            else None
        )
        if comment is not None:
            comment = replace(
                comment,
                line=current_line,
                body_line=current_line + text.count("\n", comment.start, comment.body_start),
                end_line=current_line + text.count("\n", comment.start, max(comment.start, comment.end - 1)),
            )
            spans.append(comment)
            current_line += text.count("\n", comment.start, comment.end)
            cursor = comment.end
            continue
        char = text[cursor]
        if char in {"'", '"'}:
            literal = _short_string_span(text, cursor, include_line_metadata=False)
        elif recognize_long_brackets and char == "[":
            literal = _long_bracket_span(
                text,
                cursor,
                LONG_STRING,
                include_line_metadata=False,
            )
        else:
            literal = None
        if literal is not None:
            literal = replace(
                literal,
                line=current_line,
                body_line=current_line + text.count("\n", literal.start, literal.body_start),
                end_line=current_line + text.count("\n", literal.start, max(literal.start, literal.end - 1)),
            )
            spans.append(literal)
            current_line += text.count("\n", literal.start, literal.end)
            cursor = literal.end
            continue
        if char == "\n":
            current_line += 1
        cursor += 1
    return tuple(spans)


def literal_spans(
    text: str,
    *,
    recognize_long_brackets: bool = True,
    recognize_comments: bool = True,
) -> tuple[LuaSpan, ...]:
    return tuple(
        span
        for span in lex(
            text,
            recognize_long_brackets=recognize_long_brackets,
            recognize_comments=recognize_comments,
        )
        if span.is_literal
    )


def comment_spans(text: str, *, recognize_long_brackets: bool = True) -> tuple[LuaSpan, ...]:
    return tuple(
        span
        for span in lex(text, recognize_long_brackets=recognize_long_brackets)
        if span.is_comment
    )


def code_mask(
    text: str,
    *,
    kinds: Collection[str] = MASKED_KINDS,
    preserve: Callable[[LuaSpan], bool] | None = None,
    recognize_long_brackets: bool = True,
    recognize_comments: bool = True,
) -> str:
    selected = set(kinds)
    chars = list(text)
    for span in lex(
        text,
        recognize_long_brackets=recognize_long_brackets,
        recognize_comments=recognize_comments,
    ):
        if span.kind not in selected or (preserve is not None and preserve(span)):
            continue
        for index in range(span.start, span.end):
            if chars[index] != "\n":
                chars[index] = " "
    return "".join(chars)


def block_delta(line: str, *, count_header_keywords: bool = False) -> int:
    tokens = LUA_WORD_RE.findall(line)
    delta = 0
    loop_do_tokens = 0
    if count_header_keywords:
        for token in tokens:
            if token in {"function", "if", "repeat"}:
                delta += 1
            elif token in {"for", "while"}:
                delta += 1
                loop_do_tokens += 1
            elif token == "do":
                if loop_do_tokens > 0:
                    loop_do_tokens -= 1
                else:
                    delta += 1
            elif token in {"end", "until"}:
                delta -= 1
        return delta
    for index, token in enumerate(tokens):
        if token in {"function", "do", "repeat"}:
            delta += 1
        elif token == "then" and (index == 0 or tokens[index - 1] != "elseif"):
            delta += 1
        elif token in {"end", "until"}:
            delta -= 1
    return delta
