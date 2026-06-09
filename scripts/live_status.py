#!/usr/bin/env python3
"""Join authoritative graph JSON with a delivery queue snapshot."""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path
from typing import Any


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


def strings(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    if isinstance(value, list):
        return [item.strip() for item in value if isinstance(item, str) and item.strip()]
    return []


def records(data: Any, key: str) -> dict[str, dict[str, Any]]:
    value = data.get(key) if isinstance(data, dict) else None
    if isinstance(value, dict):
        return {str(name): record for name, record in value.items() if isinstance(record, dict)}
    if isinstance(value, list):
        result: dict[str, dict[str, Any]] = {}
        for record in value:
            if not isinstance(record, dict):
                continue
            name = record.get("name")
            if isinstance(name, str) and name.strip():
                result[name.strip()] = record
        return result
    return {}


def empty_edge(queue: str) -> dict[str, Any]:
    return {"queue": queue, "aliases": {queue}, "producers": set(), "consumers": set()}


def add_edge(edges: dict[str, dict[str, Any]], queue: str) -> dict[str, Any]:
    return edges.setdefault(queue, empty_edge(queue))


def parse_graph(data: Any) -> dict[str, dict[str, Any]]:
    if not isinstance(data, dict):
        raise ValueError("graph JSON must be an object")
    edges: dict[str, dict[str, Any]] = {}
    for name, record in records(data, "department").items():
        endpoint = "dept:" + str(record.get("name") or name).strip()
        for queue in strings(record.get("consumes")):
            add_edge(edges, queue)["consumers"].add(endpoint)
        for queue in strings(record.get("produces")):
            add_edge(edges, queue)["producers"].add(endpoint)
    for name, record in records(data, "raiser").items():
        endpoint = "raiser:" + str(record.get("name") or name).strip()
        for queue in strings(record.get("produces")):
            add_edge(edges, queue)["producers"].add(endpoint)
    for name, record in records(data, "queue").items():
        edge = add_edge(edges, name)
        edge["aliases"].update(strings(record.get("aliases")))
    return edges


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


def pointers(record: dict[str, Any]) -> list[str]:
    result: list[str] = []
    for key in ("events", "pending_events", "leased_events", "retry_events", "dlq_events", "dead_letter_events", "pointers"):
        values = record.get(key)
        if not isinstance(values, list):
            continue
        for value in values:
            pointer = event_pointer(value)
            if pointer is not None and pointer not in result:
                result.append(pointer)
    return result


def delivery_record(record: dict[str, Any], fallback: str | None = None) -> dict[str, Any] | None:
    name = queue_name(record, fallback)
    if name is None:
        return None
    return {
        "queue": name,
        "pending": as_int(record.get("pending", record.get("pending_count", record.get("ready")))),
        "leased": as_int(record.get("leased", record.get("in_flight", record.get("processing")))),
        "retry": as_int(record.get("retry", record.get("retries", record.get("retry_count")))),
        "dlq": as_int(record.get("dlq", record.get("dead_letter", record.get("dead_letters")))),
        "pointers": pointers(record),
    }


def normalize_delivery(data: Any) -> dict[str, dict[str, Any]]:
    if isinstance(data, dict) and isinstance(data.get("queues"), dict):
        raw = [delivery_record(record, str(name)) for name, record in data["queues"].items() if isinstance(record, dict)]
    elif isinstance(data, dict) and isinstance(data.get("queues"), list):
        raw = [delivery_record(record) for record in data["queues"] if isinstance(record, dict)]
    elif isinstance(data, list):
        raw = [delivery_record(record) for record in data if isinstance(record, dict)]
    elif isinstance(data, dict):
        raw = [delivery_record(record, str(name)) for name, record in data.items() if isinstance(record, dict)]
    else:
        raw = []

    result: dict[str, dict[str, Any]] = {}
    for record in raw:
        if record is None:
            continue
        current = result.setdefault(record["queue"], {"pending": 0, "leased": 0, "retry": 0, "dlq": 0, "pointers": []})
        for key in ("pending", "leased", "retry", "dlq"):
            current[key] += record[key]
        for pointer in record["pointers"]:
            if pointer not in current["pointers"]:
                current["pointers"].append(pointer)
    return result


def load_json(path: str) -> Any:
    if path == "-":
        return json.load(sys.stdin)
    with Path(path).resolve().open("r", encoding="utf-8") as handle:
        return json.load(handle)


def merge_delivery(edge: dict[str, Any], deliveries: dict[str, dict[str, Any]]) -> dict[str, Any]:
    merged = {"pending": 0, "leased": 0, "retry": 0, "dlq": 0, "pointers": []}
    for alias in sorted(edge["aliases"] | {edge["queue"]}):
        record = deliveries.get(alias)
        if record is None:
            continue
        for key in ("pending", "leased", "retry", "dlq"):
            merged[key] += record[key]
        for pointer in record["pointers"]:
            if pointer not in merged["pointers"]:
                merged["pointers"].append(pointer)
    return merged


def joined_rows(edges: dict[str, dict[str, Any]], deliveries: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    rows = []
    aliases = set()
    for edge in edges.values():
        aliases.update(edge["aliases"])
        delivery = merge_delivery(edge, deliveries)
        rows.append(
            {
                "queue": edge["queue"],
                **delivery,
                "producers": ",".join(sorted(edge["producers"])) or "external",
                "consumers": ",".join(sorted(edge["consumers"])) or "sink",
            }
        )
    for name, delivery in deliveries.items():
        if name not in aliases:
            rows.append({"queue": name, **delivery, "producers": "unknown", "consumers": "unknown"})
    return sorted(rows, key=lambda row: (sum(row[key] for key in ("pending", "leased", "retry", "dlq")) == 0, row["queue"]))


def format_table(rows: list[dict[str, Any]]) -> str:
    headers = ["queue", "pending", "leased", "retry", "dlq", "producers", "consumers", "pointers"]
    table = [{key: ", ".join(row[key]) if key == "pointers" else str(row[key]) for key in headers} for row in rows]
    widths = {key: max([len(key)] + [len(row[key]) for row in table]) for key in headers}
    lines = ["  ".join(key.ljust(widths[key]) for key in headers)]
    lines.append("  ".join("-" * widths[key] for key in headers))
    lines.extend("  ".join(row[key].ljust(widths[key]) for key in headers) for row in table)
    return "\n".join(lines)


def dot_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def format_dot(rows: list[dict[str, Any]]) -> str:
    lines = ["digraph fkst_live_status {", "  rankdir=LR;"]
    nodes = sorted({node for row in rows for side in ("producers", "consumers") for node in row[side].split(",") if ":" in node})
    for node in nodes:
        shape = "box" if node.startswith("dept:") else "ellipse"
        lines.append(f"  {dot_quote(node)} [shape={shape}];")
    for row in rows:
        label = f"{row['queue']} p={row['pending']} l={row['leased']} r={row['retry']} dlq={row['dlq']}"
        producers = [node for node in row["producers"].split(",") if ":" in node] or ["source:external"]
        consumers = [node for node in row["consumers"].split(",") if ":" in node] or ["sink:external"]
        for producer in producers:
            for consumer in consumers:
                lines.append(f"  {dot_quote(producer)} -> {dot_quote(consumer)} [label={dot_quote(label)}];")
    lines.append("}")
    return "\n".join(lines)


def render(args: argparse.Namespace) -> str:
    rows = joined_rows(parse_graph(load_json(args.graph_json)), normalize_delivery(load_json(args.delivery_json)) if args.delivery_json else {})
    if args.format == "json":
        return json.dumps(rows, indent=2, sort_keys=True)
    if args.format == "dot":
        return format_dot(rows)
    return format_table(rows)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Render fkst live delivery status from authoritative JSON inputs.")
    parser.add_argument("--graph-json", help="Graph JSON exported by authoritative fkst-substrate or host tooling.")
    parser.add_argument("--delivery-json", help="Delivery status JSON snapshot. Use - for stdin.")
    parser.add_argument("--format", choices=("table", "dot", "json"), default="table")
    parser.add_argument("--self-test", action="store_true", help="Run hermetic unit tests.")
    return parser


def write(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data), encoding="utf-8")


def run_self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="fkst-live-status-test.") as tmp:
        root = Path(tmp)
        graph_path = root / "graph.json"
        delivery_path = root / "delivery.json"
        write(
            graph_path,
            {
                "department": {
                    "demo.scan": {"consumes": ["demo.tick"], "produces": ["demo.ready"]},
                    "demo.work": {"consumes": ["demo.ready", "foreign.done"], "produces": []},
                },
                "raiser": {"demo.tick": {"produces": ["demo.tick"]}},
                "queue": {"demo.ready": {"aliases": ["ready"]}, "foreign.done": {}},
            },
        )
        write(
            delivery_path,
            {
                "queues": {
                    "ready": {
                        "pending": 2,
                        "leased": [{"id": "lease-1"}],
                        "retry": 3,
                        "dlq": [{"source_ref": {"kind": "external", "ref": "owner/repo#issue/82"}}],
                        "pending_events": [{"dedup_key": "ready-1"}],
                    },
                    "foreign.done": {"pending_count": "1", "in_flight": 0, "retries": 0, "dead_letter": 0},
                }
            },
        )
        rows = joined_rows(parse_graph(load_json(str(graph_path))), normalize_delivery(load_json(str(delivery_path))))
        ready = next(row for row in rows if row["queue"] == "demo.ready")
        assert ready["pending"] == 2
        assert ready["leased"] == 1
        assert ready["retry"] == 3
        assert ready["dlq"] == 1
        assert "ready-1" in ready["pointers"]
        assert ready["producers"] == "dept:demo.scan"
        assert "dept:demo.work" in format_table(rows)
        assert "demo.ready p=2 l=1 r=3 dlq=1" in format_dot(rows)
    print("OK: live_status self-test")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.self_test:
        run_self_test()
        return 0
    if not args.graph_json:
        parser.error("--graph-json is required unless --self-test is used")
    print(render(args))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
