#!/usr/bin/env python3
"""Render a static department graph with live delivery queue counters.

The script intentionally treats delivery state as an external snapshot. It does
not read the durable redb store directly; substrate can expose that as JSON via
a CLI, and this tool joins that snapshot with the package graph.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


COUNT_FIELDS = ("pending", "leased", "retry", "dlq")
QUEUE_TABLE_RE = re.compile(r"\b(?P<key>consumes|produces|fanout)\s*=\s*(?P<value>\{[^}]*\}|[\"'][^\"']+[\"'])", re.S)
RAISER_PRODUCES_RE = re.compile(r"\bproduces\s*=\s*(?P<value>\{[^}]*\}|[\"'][^\"']+[\"'])", re.S)
STRING_RE = re.compile(r"[\"']([^\"']+)[\"']")


@dataclass
class Endpoint:
    kind: str
    package: str
    name: str

    @property
    def label(self) -> str:
        return f"{self.kind}:{self.package}/{self.name}"


@dataclass
class QueueEdge:
    queue: str
    aliases: set[str] = field(default_factory=set)
    producers: list[Endpoint] = field(default_factory=list)
    consumers: list[Endpoint] = field(default_factory=list)


@dataclass
class DeliveryQueue:
    queue: str
    pending: int = 0
    leased: int = 0
    retry: int = 0
    dlq: int = 0
    pointers: list[str] = field(default_factory=list)

    @property
    def active(self) -> bool:
        return any(getattr(self, field_name) for field_name in COUNT_FIELDS)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def normalize_queue(package: str, queue: str) -> tuple[str, set[str]]:
    queue = str(queue).strip()
    if "." in queue:
        return queue, {queue}
    canonical = f"{package}.{queue}"
    return canonical, {queue, canonical}


def parse_lua_strings(value: str) -> list[str]:
    return [match.group(1).strip() for match in STRING_RE.finditer(value) if match.group(1).strip()]


def edge_for(edges: dict[str, QueueEdge], package: str, queue: str) -> QueueEdge:
    canonical, aliases = normalize_queue(package, queue)
    edge = edges.setdefault(canonical, QueueEdge(queue=canonical))
    edge.aliases.update(aliases)
    return edge


def scan_department(package: str, path: Path, edges: dict[str, QueueEdge]) -> None:
    text = read_text(path)
    dept = path.parent.name
    endpoint = Endpoint("dept", package, dept)
    for match in QUEUE_TABLE_RE.finditer(text):
        key = match.group("key")
        for queue in parse_lua_strings(match.group("value")):
            edge = edge_for(edges, package, queue)
            if key == "produces":
                edge.producers.append(endpoint)
            elif key == "consumes":
                edge.consumers.append(endpoint)


def scan_raiser(package: str, path: Path, edges: dict[str, QueueEdge]) -> None:
    text = read_text(path)
    endpoint = Endpoint("raiser", package, path.stem)
    for match in RAISER_PRODUCES_RE.finditer(text):
        for queue in parse_lua_strings(match.group("value")):
            edge_for(edges, package, queue).producers.append(endpoint)


def scan_graph(package_roots: list[Path]) -> dict[str, QueueEdge]:
    edges: dict[str, QueueEdge] = {}
    for package_root in package_roots:
        package = package_root.name
        for path in sorted((package_root / "departments").glob("*/main.lua")):
            scan_department(package, path, edges)
        for path in sorted((package_root / "raisers").glob("*.lua")):
            scan_raiser(package, path, edges)
    return edges


def as_int(value: Any) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return max(value, 0)
    if isinstance(value, float):
        return max(int(value), 0)
    if isinstance(value, list):
        return len(value)
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return 0


def queue_name(record: dict[str, Any], fallback: str | None = None) -> str | None:
    for key in ("queue", "name", "queue_name"):
        value = record.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return fallback


def event_pointer(event: Any) -> str | None:
    if isinstance(event, str):
        return event[:120]
    if not isinstance(event, dict):
        return None
    source_ref = event.get("source_ref")
    if isinstance(source_ref, dict):
        ref = source_ref.get("ref")
        kind = source_ref.get("kind")
        if isinstance(ref, str) and ref:
            return f"{kind}:{ref}" if isinstance(kind, str) and kind else ref
    for key in ("ref", "event_ref", "id", "event_id", "dedup_key", "dedup"):
        value = event.get(key)
        if isinstance(value, str) and value:
            return value[:120]
    return None


def record_pointers(record: dict[str, Any]) -> list[str]:
    pointers: list[str] = []
    for key in (
        "events",
        "pending_events",
        "leased_events",
        "retry_events",
        "dlq_events",
        "dead_letter_events",
        "pointers",
    ):
        values = record.get(key)
        if not isinstance(values, list):
            continue
        for value in values:
            pointer = event_pointer(value)
            if pointer is not None and pointer not in pointers:
                pointers.append(pointer)
    return pointers


def normalize_record(record: dict[str, Any], fallback: str | None = None) -> DeliveryQueue | None:
    name = queue_name(record, fallback)
    if name is None:
        return None
    delivery = DeliveryQueue(queue=name)
    delivery.pending = as_int(record.get("pending", record.get("pending_count", record.get("ready"))))
    delivery.leased = as_int(record.get("leased", record.get("in_flight", record.get("processing"))))
    delivery.retry = as_int(record.get("retry", record.get("retries", record.get("retry_count"))))
    delivery.dlq = as_int(record.get("dlq", record.get("dead_letter", record.get("dead_letters"))))
    delivery.pointers = record_pointers(record)
    return delivery


def normalize_delivery_snapshot(data: Any) -> dict[str, DeliveryQueue]:
    records: list[DeliveryQueue] = []
    if isinstance(data, dict) and isinstance(data.get("queues"), dict):
        for name, record in data["queues"].items():
            if isinstance(record, dict):
                delivery = normalize_record(record, str(name))
                if delivery is not None:
                    records.append(delivery)
    elif isinstance(data, dict) and isinstance(data.get("queues"), list):
        for record in data["queues"]:
            if isinstance(record, dict):
                delivery = normalize_record(record)
                if delivery is not None:
                    records.append(delivery)
    elif isinstance(data, list):
        for record in data:
            if isinstance(record, dict):
                delivery = normalize_record(record)
                if delivery is not None:
                    records.append(delivery)
    elif isinstance(data, dict):
        for name, record in data.items():
            if isinstance(record, dict):
                delivery = normalize_record(record, str(name))
                if delivery is not None:
                    records.append(delivery)

    by_queue: dict[str, DeliveryQueue] = {}
    for record in records:
        current = by_queue.setdefault(record.queue, DeliveryQueue(queue=record.queue))
        current.pending += record.pending
        current.leased += record.leased
        current.retry += record.retry
        current.dlq += record.dlq
        for pointer in record.pointers:
            if pointer not in current.pointers:
                current.pointers.append(pointer)
    return by_queue


def load_delivery(path: str | None) -> dict[str, DeliveryQueue]:
    if path is None:
        return {}
    if path == "-":
        return normalize_delivery_snapshot(json.load(sys.stdin))
    with Path(path).resolve().open("r", encoding="utf-8") as handle:
        return normalize_delivery_snapshot(json.load(handle))


def delivery_for(edge: QueueEdge, deliveries: dict[str, DeliveryQueue]) -> DeliveryQueue:
    merged = DeliveryQueue(queue=edge.queue)
    for alias in sorted(edge.aliases | {edge.queue}):
        record = deliveries.get(alias)
        if record is None:
            continue
        merged.pending += record.pending
        merged.leased += record.leased
        merged.retry += record.retry
        merged.dlq += record.dlq
        for pointer in record.pointers:
            if pointer not in merged.pointers:
                merged.pointers.append(pointer)
    return merged


def endpoint_labels(endpoints: list[Endpoint], fallback: str) -> str:
    if not endpoints:
        return fallback
    return ",".join(sorted({endpoint.label for endpoint in endpoints}))


def row_for(edge: QueueEdge, delivery: DeliveryQueue) -> dict[str, Any]:
    return {
        "queue": edge.queue,
        "pending": delivery.pending,
        "leased": delivery.leased,
        "retry": delivery.retry,
        "dlq": delivery.dlq,
        "producers": endpoint_labels(edge.producers, "external"),
        "consumers": endpoint_labels(edge.consumers, "sink"),
        "pointers": delivery.pointers,
    }


def joined_rows(edges: dict[str, QueueEdge], deliveries: dict[str, DeliveryQueue]) -> list[dict[str, Any]]:
    rows = [row_for(edge, delivery_for(edge, deliveries)) for edge in edges.values()]
    known_aliases = set()
    for edge in edges.values():
        known_aliases.update(edge.aliases)
        known_aliases.add(edge.queue)
    for name, delivery in deliveries.items():
        if name in known_aliases:
            continue
        rows.append(
            {
                "queue": name,
                "pending": delivery.pending,
                "leased": delivery.leased,
                "retry": delivery.retry,
                "dlq": delivery.dlq,
                "producers": "unknown",
                "consumers": "unknown",
                "pointers": delivery.pointers,
            }
        )
    return sorted(rows, key=lambda row: (row["pending"] + row["leased"] + row["retry"] + row["dlq"] == 0, row["queue"]))


def format_table(rows: list[dict[str, Any]]) -> str:
    headers = ["queue", "pending", "leased", "retry", "dlq", "producers", "consumers", "pointers"]
    table = []
    for row in rows:
        table.append({key: ", ".join(row[key]) if key == "pointers" else str(row[key]) for key in headers})
    widths = {key: len(key) for key in headers}
    for row in table:
        for key in headers:
            widths[key] = max(widths[key], len(row[key]))
    lines = ["  ".join(key.ljust(widths[key]) for key in headers)]
    lines.append("  ".join("-" * widths[key] for key in headers))
    for row in table:
        lines.append("  ".join(row[key].ljust(widths[key]) for key in headers))
    return "\n".join(lines)


def dot_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def endpoint_node(endpoint: Endpoint) -> str:
    return endpoint.label


def format_dot(edges: dict[str, QueueEdge], deliveries: dict[str, DeliveryQueue]) -> str:
    lines = ["digraph fkst_live_status {", "  rankdir=LR;"]
    nodes: dict[str, str] = {}
    for edge in edges.values():
        for endpoint in edge.producers + edge.consumers:
            nodes[endpoint_node(endpoint)] = "box" if endpoint.kind == "dept" else "ellipse"
    for node, shape in sorted(nodes.items()):
        lines.append(f"  {dot_quote(node)} [shape={shape}];")
    for edge in sorted(edges.values(), key=lambda item: item.queue):
        delivery = delivery_for(edge, deliveries)
        label = f"{edge.queue} p={delivery.pending} l={delivery.leased} r={delivery.retry} dlq={delivery.dlq}"
        producers = edge.producers or [Endpoint("source", "external", edge.queue)]
        consumers = edge.consumers or [Endpoint("sink", "external", edge.queue)]
        for producer in producers:
            for consumer in consumers:
                lines.append(f"  {dot_quote(endpoint_node(producer))} -> {dot_quote(endpoint_node(consumer))} [label={dot_quote(label)}];")
    lines.append("}")
    return "\n".join(lines)


def package_roots(paths: list[str]) -> list[Path]:
    roots = [Path(path).resolve() for path in paths]
    missing = [str(path) for path in roots if not path.is_dir()]
    if missing:
        raise SystemExit("package root not found: " + ", ".join(missing))
    return roots


def render(args: argparse.Namespace) -> str:
    roots = package_roots(args.package_root)
    edges = scan_graph(roots)
    deliveries = load_delivery(args.delivery_json)
    rows = joined_rows(edges, deliveries)
    if args.format == "json":
        return json.dumps(rows, indent=2, sort_keys=True)
    if args.format == "dot":
        return format_dot(edges, deliveries)
    return format_table(rows)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Render fkst package live delivery status.")
    parser.add_argument("--project-root", default=".", help="Repository root; reserved for future substrate joins.")
    parser.add_argument("--package-root", action="append", required=False, default=[], help="Package root to scan. Repeat for composed graphs.")
    parser.add_argument("--delivery-json", help="Delivery status JSON snapshot emitted by substrate. Use - for stdin.")
    parser.add_argument("--format", choices=("table", "dot", "json"), default="table")
    parser.add_argument("--self-test", action="store_true", help="Run hermetic unit tests for parsing and rendering.")
    return parser


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="fkst-live-status-test.") as tmp:
        root = Path(tmp)
        pkg = root / "packages" / "demo"
        write(
            pkg / "raisers" / "tick.lua",
            'return { type = "cron", interval = "1m", produces = "tick" }\n',
        )
        write(
            pkg / "departments" / "scan" / "main.lua",
            'local M = {}\nM.spec = { consumes = { "tick" }, produces = { "ready" } }\nreturn M\n',
        )
        write(
            pkg / "departments" / "work" / "main.lua",
            'local M = {}\nM.spec = { consumes = { "ready", "foreign.done" }, produces = {} }\nreturn M\n',
        )
        delivery_path = root / "delivery.json"
        write(
            delivery_path,
            json.dumps(
                {
                    "queues": {
                        "demo.ready": {
                            "pending": 2,
                            "leased": [{"id": "lease-1"}],
                            "retry": 3,
                            "dlq": [{"source_ref": {"kind": "external", "ref": "owner/repo#issue/82"}}],
                            "pending_events": [{"dedup_key": "ready-1"}],
                        },
                        "foreign.done": {"pending_count": "1", "in_flight": 0, "retries": 0, "dead_letter": 0},
                    }
                }
            ),
        )

        edges = scan_graph([pkg])
        deliveries = load_delivery(delivery_path)
        rows = joined_rows(edges, deliveries)
        ready = next(row for row in rows if row["queue"] == "demo.ready")
        assert ready["pending"] == 2
        assert ready["leased"] == 1
        assert ready["retry"] == 3
        assert ready["dlq"] == 1
        assert "ready-1" in ready["pointers"]
        table = format_table(rows)
        assert "demo.ready" in table
        assert "dept:demo/scan" in table
        dot = format_dot(edges, deliveries)
        assert "dept:demo/scan" in dot
        assert "demo.ready p=2 l=1 r=3 dlq=1" in dot
    print("OK: live_status self-test")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        run_self_test()
        return 0
    if not args.package_root:
        parser.error("--package-root is required unless --self-test is used")
    _ = Path(args.project_root).resolve()
    print(render(args))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
