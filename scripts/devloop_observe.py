#!/usr/bin/env python3
"""Render a live-oriented department graph for github-devloop."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


COUNT_KEYS = ("pending", "leased", "retry", "dlq")


@dataclass
class DeliveryQueue:
    pending: int = 0
    leased: int = 0
    retry: int = 0
    dlq: int = 0
    refs: list[str] = field(default_factory=list)

    def active(self) -> int:
        return self.pending + self.leased + self.retry + self.dlq

    def label(self) -> str:
        return f"p={self.pending} l={self.leased} r={self.retry} d={self.dlq}"


@dataclass
class Department:
    package: str
    name: str
    path: Path
    consumes: list[str]
    produces: list[str]
    fanout: list[str]
    stall_window: str | None
    retry: str | None

    def node(self) -> str:
        return f"{self.package}.{self.name}"


@dataclass
class Raiser:
    package: str
    name: str
    path: Path
    produces: list[str]
    kind: str | None
    interval: str | None

    def node(self) -> str:
        return f"{self.package}.raiser:{self.name}"


@dataclass
class Graph:
    departments: list[Department]
    raisers: list[Raiser]
    queues: list[str]
    producers: dict[str, list[str]]
    consumers: dict[str, list[str]]
    delivery: dict[str, DeliveryQueue]


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def package_dir(root: Path, package: str) -> Path:
    path = root / "packages" / package
    if not path.is_dir():
        die(f"package not found: {package}")
    return path


def read_deps(path: Path) -> list[str]:
    deps = path / "composed.deps"
    if not deps.exists():
        return []
    result: list[str] = []
    for line in deps.read_text(encoding="utf-8").splitlines():
        clean = line.split("#", 1)[0].strip()
        if clean:
            result.append(clean)
    return result


def collect_packages(root: Path, package: str, include_deps: bool) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []

    def visit(name: str) -> None:
        if name in seen:
            return
        seen.add(name)
        ordered.append(name)
        if include_deps:
            for dep in read_deps(package_dir(root, name)):
                visit(dep)

    visit(package)
    return ordered


def line_index(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def skip_line_comment(text: str, index: int) -> int:
    newline = text.find("\n", index)
    return len(text) if newline == -1 else newline + 1


def long_bracket(text: str, index: int) -> tuple[int, str] | None:
    if index >= len(text) or text[index] != "[":
        return None
    cursor = index + 1
    while cursor < len(text) and text[cursor] == "=":
        cursor += 1
    if cursor >= len(text) or text[cursor] != "[":
        return None
    closer = "]" + ("=" * (cursor - index - 1)) + "]"
    return cursor - index + 1, closer


def skip_quoted(text: str, index: int) -> int:
    quote = text[index]
    cursor = index + 1
    while cursor < len(text):
        if text[cursor] == "\\":
            cursor += 2
            continue
        if text[cursor] == quote:
            return cursor + 1
        cursor += 1
    return len(text)


def skip_long_bracket(text: str, index: int) -> int:
    bracket = long_bracket(text, index)
    if bracket is None:
        return index + 1
    opener_len, closer = bracket
    close = text.find(closer, index + opener_len)
    return len(text) if close == -1 else close + len(closer)


def find_matching_brace(text: str, start: int, path: Path) -> int:
    depth = 0
    cursor = start
    while cursor < len(text):
        if text.startswith("--", cursor):
            bracket = long_bracket(text, cursor + 2)
            cursor = skip_long_bracket(text, cursor + 2) if bracket else skip_line_comment(text, cursor)
            continue
        char = text[cursor]
        if char in ("'", '"'):
            cursor = skip_quoted(text, cursor)
            continue
        if char == "[" and long_bracket(text, cursor) is not None:
            cursor = skip_long_bracket(text, cursor)
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return cursor
        cursor += 1
    die(f"unterminated Lua table in {path}:{line_index(text, start)}")
    return len(text)


def table_after_cursor(text: str, cursor: int, path: Path) -> str:
    while cursor < len(text) and text[cursor].isspace():
        cursor += 1
    if cursor >= len(text) or text[cursor] != "{":
        die(f"expected a static table in {path}:{line_index(text, cursor)}")
    end = find_matching_brace(text, cursor, path)
    return text[cursor : end + 1]


def find_table_after_assignment(text: str, name: str, path: Path) -> str | None:
    match = re.search(rf"\b{name}\s*=", text)
    if match is None:
        return None
    return table_after_cursor(text, match.end(), path)


def find_return_table(text: str, path: Path) -> str | None:
    match = re.search(r"\breturn\b", text)
    if match is None:
        return None
    return table_after_cursor(text, match.end(), path)


def field_expression(table: str, field_name: str, path: Path) -> str | None:
    match = re.search(rf"\b{re.escape(field_name)}\s*=", table)
    if match is None:
        return None
    cursor = match.end()
    while cursor < len(table) and table[cursor].isspace():
        cursor += 1
    if cursor >= len(table):
        return None
    if table[cursor] == "{":
        end = find_matching_brace(table, cursor, path)
        return table[cursor : end + 1]
    if table[cursor] in ("'", '"'):
        end = skip_quoted(table, cursor)
        return table[cursor:end]
    end = cursor
    while end < len(table) and table[end] not in ",\n}":
        end += 1
    return table[cursor:end].strip()


def unquote(value: str) -> str | None:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return bytes(value[1:-1], "utf-8").decode("unicode_escape")
    return None


def string_values(expr: str | None) -> list[str]:
    if expr is None:
        return []
    quoted = unquote(expr)
    if quoted is not None:
        return [quoted]
    return [
        bytes(match.group(2), "utf-8").decode("unicode_escape")
        for match in re.finditer(r"([\"'])(.*?)\1", expr, flags=re.DOTALL)
    ]


def scalar_string(table: str, field_name: str, path: Path) -> str | None:
    return unquote(field_expression(table, field_name, path) or "")


def compact_expr(expr: str | None) -> str | None:
    if expr is None:
        return None
    return " ".join(expr.split())


def canonical_queue(package: str, queue: str) -> str:
    if "." in queue:
        return queue
    return f"{package}.{queue}"


def parse_department(path: Path, package: str, root: Path) -> Department:
    text = path.read_text(encoding="utf-8")
    table = find_table_after_assignment(text, "M\\.spec", path)
    if table is None:
        die(f"missing M.spec in {path}")
    name = path.parent.name
    consumes = [canonical_queue(package, q) for q in string_values(field_expression(table, "consumes", path))]
    produces = [canonical_queue(package, q) for q in string_values(field_expression(table, "produces", path))]
    fanout = [canonical_queue(package, q) for q in string_values(field_expression(table, "fanout", path))]
    retry = compact_expr(field_expression(table, "retry", path))
    return Department(
        package=package,
        name=name,
        path=path.relative_to(root),
        consumes=consumes,
        produces=produces,
        fanout=fanout,
        stall_window=scalar_string(table, "stall_window", path),
        retry=retry,
    )


def parse_raiser(path: Path, package: str, root: Path) -> Raiser:
    text = path.read_text(encoding="utf-8")
    table = find_return_table(text, path)
    if table is None:
        die(f"missing static return table in {path}")
    produces = [canonical_queue(package, q) for q in string_values(field_expression(table, "produces", path))]
    return Raiser(
        package=package,
        name=path.stem,
        path=path.relative_to(root),
        produces=produces,
        kind=scalar_string(table, "type", path),
        interval=scalar_string(table, "interval", path),
    )


def scan_package(root: Path, package: str) -> tuple[list[Department], list[Raiser]]:
    pkg = package_dir(root, package)
    departments: list[Department] = []
    for main in sorted((pkg / "departments").glob("*/main.lua")):
        departments.append(parse_department(main, package, root))
    raisers: list[Raiser] = []
    raiser_dir = pkg / "raisers"
    if raiser_dir.exists():
        for raiser in sorted(raiser_dir.glob("*.lua")):
            raisers.append(parse_raiser(raiser, package, root))
    return departments, raisers


def event_ref(value: Any) -> str | None:
    if not isinstance(value, dict):
        return None
    source_ref = value.get("source_ref")
    if isinstance(source_ref, dict) and source_ref.get("ref") is not None:
        return str(source_ref["ref"])
    for key in ("dedup_key", "id", "ref", "event_ref"):
        if value.get(key) is not None:
            return str(value[key])
    payload = value.get("payload")
    if isinstance(payload, dict):
        return event_ref(payload)
    return None


def int_count(value: Any) -> int:
    if value is None:
        return 0
    if isinstance(value, bool):
        return int(value)
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return 0


def merge_delivery(target: DeliveryQueue, item: dict[str, Any]) -> None:
    for key in COUNT_KEYS:
        setattr(target, key, getattr(target, key) + int_count(item.get(key)))
    events = item.get("events", item.get("pointers", []))
    if isinstance(events, list):
        for event in events:
            ref = event_ref(event)
            if ref:
                target.refs.append(ref)


def normalize_delivery(raw: Any) -> dict[str, DeliveryQueue]:
    queues = raw.get("queues", raw) if isinstance(raw, dict) else raw
    result: dict[str, DeliveryQueue] = {}
    if isinstance(queues, dict):
        for name, value in queues.items():
            if not isinstance(value, dict):
                continue
            target = result.setdefault(str(name), DeliveryQueue())
            merge_delivery(target, value)
    elif isinstance(queues, list):
        for value in queues:
            if not isinstance(value, dict) or value.get("queue") is None:
                continue
            target = result.setdefault(str(value["queue"]), DeliveryQueue())
            merge_delivery(target, value)
    return result


def load_delivery(path: Path | None) -> dict[str, DeliveryQueue]:
    if path is None:
        return {}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        die(f"invalid delivery JSON at {path}:{exc.lineno}:{exc.colno}: {exc.msg}")
    return normalize_delivery(raw)


def delivery_for(delivery: dict[str, DeliveryQueue], queue: str) -> DeliveryQueue:
    if queue in delivery:
        return delivery[queue]
    short = queue.split(".", 1)[1] if "." in queue else queue
    return delivery.get(short, DeliveryQueue())


def build_graph(root: Path, packages: list[str], delivery: dict[str, DeliveryQueue]) -> Graph:
    departments: list[Department] = []
    raisers: list[Raiser] = []
    for package in packages:
        pkg_departments, pkg_raisers = scan_package(root, package)
        departments.extend(pkg_departments)
        raisers.extend(pkg_raisers)

    producers: dict[str, list[str]] = {}
    consumers: dict[str, list[str]] = {}
    queue_set: set[str] = set()
    for dept in departments:
        for queue in dept.produces:
            producers.setdefault(queue, []).append(dept.node())
            queue_set.add(queue)
        for queue in dept.consumes:
            consumers.setdefault(queue, []).append(dept.node())
            queue_set.add(queue)
    for raiser in raisers:
        for queue in raiser.produces:
            producers.setdefault(queue, []).append(raiser.node())
            queue_set.add(queue)
    for queue in delivery:
        queue_set.add(queue)
    return Graph(
        departments=departments,
        raisers=raisers,
        queues=sorted(queue_set),
        producers=producers,
        consumers=consumers,
        delivery=delivery,
    )


def compact_list(values: list[str], limit: int = 3) -> str:
    if not values:
        return "-"
    if len(values) <= limit:
        return ", ".join(values)
    return ", ".join(values[:limit]) + f", +{len(values) - limit}"


def render_table(graph: Graph, packages: list[str], has_delivery: bool) -> str:
    lines: list[str] = []
    lines.append("github-devloop live graph")
    lines.append(f"packages: {', '.join(packages)}")
    lines.append(f"delivery: {'attached' if has_delivery else 'not attached'}")
    lines.append("")
    lines.append("departments")
    for dept in graph.departments:
        retry = f" retry={dept.retry}" if dept.retry else ""
        lines.append(
            f"  {dept.node()} consumes={compact_list(dept.consumes)} "
            f"produces={compact_list(dept.produces)} stall={dept.stall_window or '-'}{retry}"
        )
    if graph.raisers:
        lines.append("")
        lines.append("raisers")
        for raiser in graph.raisers:
            detail = f" type={raiser.kind or '-'} interval={raiser.interval or '-'}"
            lines.append(f"  {raiser.node()} produces={compact_list(raiser.produces)}{detail}")
    lines.append("")
    lines.append("queues")
    header = ("queue", "from", "to", "pending", "leased", "retry", "dlq", "refs")
    rows = [header]
    for queue in graph.queues:
        status = delivery_for(graph.delivery, queue)
        rows.append(
            (
                queue,
                compact_list(graph.producers.get(queue, []), 2),
                compact_list(graph.consumers.get(queue, []), 2),
                str(status.pending),
                str(status.leased),
                str(status.retry),
                str(status.dlq),
                compact_list(status.refs, 2),
            )
        )
    widths = [max(len(row[index]) for row in rows) for index in range(len(header))]
    for index, row in enumerate(rows):
        line = "  " + "  ".join(cell.ljust(widths[col]) for col, cell in enumerate(row))
        lines.append(line)
        if index == 0:
            lines.append("  " + "  ".join("-" * width for width in widths))
    return "\n".join(lines)


def dot_id(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_]", "_", value)


def render_dot(graph: Graph) -> str:
    lines = ["digraph github_devloop {", "  rankdir=LR;"]
    for dept in graph.departments:
        lines.append(f'  {dot_id(dept.node())} [label="{dept.node()}", shape=box];')
    for raiser in graph.raisers:
        lines.append(f'  {dot_id(raiser.node())} [label="{raiser.node()}", shape=oval];')
    for queue in graph.queues:
        status = delivery_for(graph.delivery, queue)
        label = queue if status.active() == 0 else f"{queue}\\n{status.label()}"
        producers = graph.producers.get(queue) or [f"external:{queue}"]
        consumers = graph.consumers.get(queue) or [f"sink:{queue}"]
        for endpoint in producers + consumers:
            shape = "point" if endpoint.startswith("sink:") else "oval"
            if endpoint.startswith("external:") or endpoint.startswith("sink:"):
                lines.append(f'  {dot_id(endpoint)} [label="{endpoint}", shape={shape}];')
        color = "red" if status.dlq else ("orange" if status.retry or status.leased else "black")
        for producer in producers:
            for consumer in consumers:
                lines.append(
                    f'  {dot_id(producer)} -> {dot_id(consumer)} '
                    f'[label="{label}", color={color}];'
                )
    lines.append("}")
    return "\n".join(lines)


def graph_as_json(graph: Graph, packages: list[str]) -> str:
    payload = {
        "packages": packages,
        "departments": [
            {
                "node": dept.node(),
                "consumes": dept.consumes,
                "produces": dept.produces,
                "fanout": dept.fanout,
                "stall_window": dept.stall_window,
                "retry": dept.retry,
                "path": dept.path.as_posix(),
            }
            for dept in graph.departments
        ],
        "raisers": [
            {
                "node": raiser.node(),
                "produces": raiser.produces,
                "type": raiser.kind,
                "interval": raiser.interval,
                "path": raiser.path.as_posix(),
            }
            for raiser in graph.raisers
        ],
        "queues": [
            {
                "queue": queue,
                "producers": graph.producers.get(queue, []),
                "consumers": graph.consumers.get(queue, []),
                "delivery": delivery_for(graph.delivery, queue).__dict__,
            }
            for queue in graph.queues
        ],
    }
    return json.dumps(payload, indent=2, sort_keys=True)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render package department DAGs with optional delivery queue counts."
    )
    parser.add_argument("--project-root", default=str(repo_root()), help="Repository root.")
    parser.add_argument("--package", default="github-devloop", help="Package to inspect.")
    parser.add_argument(
        "--no-deps",
        action="store_true",
        help="Only scan the selected package, not composed.deps.",
    )
    parser.add_argument(
        "--delivery-json",
        type=Path,
        help="JSON dump with queue pending/leased/retry/dlq counts.",
    )
    parser.add_argument(
        "--format",
        choices=("table", "dot", "json"),
        default="table",
        help="Output format.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = Path(args.project_root).resolve()
    packages = collect_packages(root, args.package, not args.no_deps)
    delivery = load_delivery(args.delivery_json)
    graph = build_graph(root, packages, delivery)
    if args.format == "dot":
        print(render_dot(graph))
    elif args.format == "json":
        print(graph_as_json(graph, packages))
    else:
        print(render_table(graph, packages, args.delivery_json is not None))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
