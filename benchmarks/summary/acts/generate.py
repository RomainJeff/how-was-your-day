#!/usr/bin/env python3
"""Generate the test fixtures of the speech-act probe.

Standard library only and deterministic. Reuses the Recording and expected
builders of ../ledger/generate.py without modifying them. Existing files are
never overwritten unless --force is given.

  python3 benchmarks/summary/acts/generate.py          # refuses to overwrite
  python3 benchmarks/summary/acts/generate.py --force  # rewrites every output

Source: scenarios_test.py. Outputs: test/<slug>-<lang>.json, .expected.json,
.acts.json and test/manifest.json. Run check.py afterwards.
"""
import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import hashlib  # noqa: E402
import importlib.util  # noqa: E402
import json  # noqa: E402
import types  # noqa: E402
import uuid  # noqa: E402
from pathlib import Path  # noqa: E402

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
LEDGER_GENERATE = ROOT.parent / "ledger" / "generate.py"
NAMESPACE_NAME = "hwyd:benchmarks/summary/acts"
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, NAMESPACE_NAME)
CREATED_AT = "2026-10-27T09:00:00Z"
LANGUAGES = ("fr", "en", "mixed")
GOLD_SCHEMA = "hwyd-acts-gold/1"
MANIFEST_SCHEMA = "hwyd-acts-manifest/1"
SOURCE = ROOT / "scenarios_test.py"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_ledger():
    """Import ledger/generate.py with its own scenario modules stubbed out."""
    for name in ("scenarios_dev", "scenarios_holdout"):
        sys.modules[name] = types.SimpleNamespace(SCENARIOS=[])
    try:
        module = load_module("ledger_generate", LEDGER_GENERATE)
    finally:
        for name in ("scenarios_dev", "scenarios_holdout"):
            sys.modules.pop(name, None)
    module.NAMESPACE = NAMESPACE
    return module


def load_scenarios():
    return load_module("scenarios_test", SOURCE).SCENARIOS


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def gold(scenario, language, ledger):
    index = ledger.turn_index(scenario)
    numbers = {tag: f"S{position + 1}" for tag, position in index.items()}
    turns = {}
    for position, turn in enumerate(scenario["turns"]):
        entries = []
        for item in turn["acts"]:
            entry = {"act": item["act"], "target": numbers[item["target"]] if item["target"] else None, "agent": item["agent"]}
            if item.get("optional"):
                entry["optional"] = True
                entry["note"] = item["note"]
            entries.append(entry)
        if entries:
            turns[f"S{position + 1}"] = entries
    stem = f"{scenario['split']}/{scenario['slug']}-{language}"
    return {
        "schema": GOLD_SCHEMA,
        "recording": f"benchmarks/summary/acts/{stem}.json",
        "participants": [label for _, label, _ in scenario["speakers"]],
        "turns": turns,
    }


def build():
    """Return {path relative to ROOT: bytes} for every generated file."""
    ledger = load_ledger()
    outputs, entries = {}, []
    for scenario in load_scenarios():
        split, slug = scenario["split"], scenario["slug"]
        for language in LANGUAGES:
            stem = f"{split}/{slug}-{language}"
            record = ledger.recording(scenario, language)
            files = {
                "recording": (f"{stem}.json", record),
                "expected": (f"{stem}.expected.json", ledger.expected(scenario, language, record)),
                "acts": (f"{stem}.acts.json", gold(scenario, language, ledger)),
            }
            for kind, (path, value) in files.items():
                outputs[path] = ledger.dump(value)
                entry = {"path": path, "kind": kind, "split": split, "scenario": slug, "language": language, "sha256": sha256(outputs[path])}
                if kind == "recording":
                    entry.update({
                        "segments": len(record["segments"]),
                        "text_characters": sum(len(segment["text"]) for segment in record["segments"]),
                        "speakers": len(record["speakers"]),
                        "unidentified_segments": sum(segment["speakerID"] is None for segment in record["segments"]),
                        "duration_seconds": record["duration"],
                    })
                else:
                    entry["recording"] = f"{stem}.json"
                entries.append(entry)
    outputs["test/manifest.json"] = ledger.dump({
        "schema": MANIFEST_SCHEMA,
        "created_at": CREATED_AT,
        "root": "benchmarks/summary/acts",
        "uuid_namespace": str(NAMESPACE).upper(),
        "uuid_namespace_derivation": f"uuid5(NAMESPACE_URL, \"{NAMESPACE_NAME}\")",
        "source": {"path": "benchmarks/summary/acts/scenarios_test.py", "sha256": sha256(SOURCE.read_bytes())},
        "files": entries,
    })
    return outputs


def main():
    parser = argparse.ArgumentParser(description="Generate the speech-act test fixtures.")
    parser.add_argument("--force", action="store_true", help="overwrite existing generated files")
    args = parser.parse_args()
    outputs = build()
    existing = sorted(path for path in outputs if (ROOT / path).exists())
    if existing and not args.force:
        parser.error(f"{len(existing)} generated file(s) already exist (first: {existing[0]}); pass --force to overwrite")
    for path, data in outputs.items():
        target = ROOT / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    print(f"Wrote {len(outputs)} files under {ROOT}")


if __name__ == "__main__":
    main()
