#!/usr/bin/env python3
"""Self-check of the speech-act test fixtures. Standard library only.

  python3 benchmarks/summary/acts/check.py

Exits non-zero when a check fails.
"""
import sys

sys.dont_write_bytecode = True

import importlib.util  # noqa: E402
import json  # noqa: E402
import re  # noqa: E402
from pathlib import Path  # noqa: E402

ROOT = Path(__file__).resolve().parent
EM_DASH = chr(0x2014)
MAX_CHARACTERS = 11000
LANGUAGES = ("fr", "en", "mixed")

AVOID_NAMES = ("Camille Jordan Hélène Bastien Mehdi Lucie Karim Sophie Thomas Gilles Yannick Odile Farida Théo Rachid "
               "Gaëlle Nora Loïc Pascale Benoît Agnès Garnier").split()
AVOID_DOMAINS = ["portal", "portail", "trade fair", "booth", "salon professionnel", "restaurant", "school trip",
                 "voyage scolaire", "sortie scolaire", "renovation", "rénovation", "chantier", "catalogue", "publisher",
                 "éditeur"]
TURN_RANGES = {"short": (20, 24), "long": (32, 40)}
SECTIONS = {"decision", "task", "to_confirm", "open"}
STATUSES = {"active", "withdrawn", "superseded"}

# Agent rule per label, from the table of LABELS.md.
AGENT_RULE = {
    "commit": "speaker", "accept": "speaker", "tentative": "speaker",
    "request": "addressee_or_null", "propose": "null", "agree": "null", "decline": "null",
    "decide": "null", "defer": "null", "correct": "speaker_or_null", "withdraw": "null",
    "challenge": "null", "quote": "person", "obligation": "null", "question": "null",
}
# Acts that must target a turn carrying one of these acts.
TARGET_ACTS = {
    "accept": {"request"},
    "agree": {"propose", "decide"},
    "decline": {"request", "propose", "decide"},
    "correct": {"commit", "accept", "decide", "propose", "request"},
    "withdraw": {"commit", "accept", "propose", "request"},
    "challenge": {"commit", "accept", "request", "decide"},
    "defer": {"propose", "request", "decide", "question"},
    "decide": {"propose", "decide"},
}

failures = []


def fail(message):
    failures.append(message)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def closed_labels():
    text = (ROOT / "LABELS.md").read_text(encoding="utf-8")
    section = text.split("## Labels", 1)[1].split("## Rules", 1)[0]
    return set(re.findall(r"^\| `([a-z]+)` \|", section, flags=re.M))


def check_generation(generate):
    outputs = generate.build()
    for path, data in outputs.items():
        target = ROOT / path
        if not target.exists():
            fail(f"missing file {path}")
        elif target.read_bytes() != data:
            fail(f"{path} differs from a fresh generation")
    on_disk = {str(p.relative_to(ROOT)) for p in (ROOT / "test").rglob("*") if p.is_file()}
    for extra in sorted(on_disk - set(outputs)):
        fail(f"unexpected file {extra}")
    manifest = json.loads(outputs["test/manifest.json"])
    if manifest["source"]["sha256"] != generate.sha256((ROOT / "scenarios_test.py").read_bytes()):
        fail("manifest source hash is stale")
    return outputs


def check_no_em_dash(outputs):
    paths = [ROOT / "scenarios_test.py", ROOT / "generate.py", ROOT / "check.py"]
    paths += [ROOT / path for path in outputs if (ROOT / path).exists()]
    for path in paths:
        if EM_DASH in path.read_text(encoding="utf-8"):
            fail(f"U+2014 found in {path.relative_to(ROOT)}")


def check_scenario(scenario, labels):
    slug, speakers = scenario["slug"], scenario["speakers"]
    names = {label for _, label, _ in speakers}
    keys = {key for key, _, _ in speakers}
    tags = [turn["tag"] for turn in scenario["turns"]]
    position = {tag: i for i, tag in enumerate(tags)}
    if len(position) != len(tags):
        fail(f"{slug}: duplicate turn tags")
    low, high = TURN_RANGES[scenario["size"]]
    if not low <= len(tags) <= high:
        fail(f"{slug}: {len(tags)} turns outside {low}-{high}")
    unidentified = sum(turn["speaker"] is None for turn in scenario["turns"])
    if scenario["size"] == "short" and (len(speakers) != 3 or unidentified < 1):
        fail(f"{slug}: short case needs 3 identified speakers and an unidentified turn")
    if scenario["size"] == "long" and (len(speakers) != 4 or unidentified):
        fail(f"{slug}: long case needs 4 identified speakers and no unidentified turn")
    if scenario["split"] != "test":
        fail(f"{slug}: split must be test")

    by_tag = {turn["tag"]: turn for turn in scenario["turns"]}
    for i, turn in enumerate(scenario["turns"]):
        if turn["speaker"] is not None and turn["speaker"] not in keys:
            fail(f"{slug}/{turn['tag']}: unknown speaker key")
        speaker = next((label for key, label, _ in speakers if key == turn["speaker"]), None)
        for item in turn["acts"]:
            where = f"{slug}/{turn['tag']}/{item['act']}"
            if item["act"] not in labels:
                fail(f"{where}: label outside the closed list")
                continue
            target = item["target"]
            if target is not None:
                if target not in position:
                    fail(f"{where}: unknown target {target}")
                elif position[target] >= i:
                    fail(f"{where}: target {target} is not an earlier turn")
                elif item["act"] in TARGET_ACTS:
                    target_acts = {a["act"] for a in by_tag[target]["acts"]}
                    if not target_acts & TARGET_ACTS[item["act"]]:
                        fail(f"{where}: target {target} carries none of {sorted(TARGET_ACTS[item['act']])}")
            elif item["act"] in {"accept", "agree", "decline", "correct", "withdraw", "challenge", "defer"}:
                fail(f"{where}: needs a target")
            agent, rule = item["agent"], AGENT_RULE[item["act"]]
            if rule == "null" and agent is not None:
                fail(f"{where}: agent must be null")
            if rule == "speaker":
                expected = speaker
                if agent != expected:
                    fail(f"{where}: agent {agent!r} must be the speaker {expected!r}")
            if rule == "speaker_or_null" and agent not in (None, speaker):
                fail(f"{where}: agent {agent!r} must be the speaker or null")
            if rule == "addressee_or_null" and agent is not None and (agent not in names or agent == speaker):
                fail(f"{where}: addressee {agent!r} must be another speaker or null")
            if rule == "person" and (agent is None or (agent not in names and agent != "other") or agent == speaker):
                fail(f"{where}: quoted agent {agent!r} must be another speaker or 'other'")
            if agent not in names and agent not in (None, "other"):
                fail(f"{where}: agent {agent!r} is not a speaker")
            if agent == "other" and not scenario["mentioned_names"]:
                fail(f"{where}: 'other' used without a mentioned absent name")
            if item.get("optional") and not item.get("note"):
                fail(f"{where}: optional act without a note")
            # Late changes of the long case must sit at least 12 turns after what they change.
            if scenario["size"] == "long" and target is not None and position.get(target) is not None:
                late = item["act"] in {"correct", "withdraw"} or (
                    item["act"] == "decide" and "decide" in {a["act"] for a in by_tag[target]["acts"]})
                if late and i - position[target] < 12:
                    fail(f"{where}: late change only {i - position[target]} turns after {target}")
    for item in scenario["items"]:
        if item["section"] not in SECTIONS or item["status"] not in STATUSES:
            fail(f"{slug}/{item['id']}: bad section or status")
        for tag in item["turns"] + list(item.get("late", ())):
            if tag not in position:
                fail(f"{slug}/{item['id']}: unknown turn {tag}")
    for entry in scenario["forbidden"]:
        for tag in entry["turns"]:
            if tag not in position:
                fail(f"{slug}/{entry['id']}: unknown turn {tag}")


def check_text(scenario):
    slug = scenario["slug"]
    for language in LANGUAGES:
        total = 0
        for turn in scenario["turns"]:
            value = turn[language]
            text = turn[value[1:]] if value in ("=fr", "=en") else value
            total += len(text)
            for name in AVOID_NAMES:
                if re.search(rf"(?<!\w){name}(?!\w)", text):
                    fail(f"{slug}/{turn['tag']}/{language}: avoided name {name}")
            lowered = text.lower()
            for word in AVOID_DOMAINS:
                if word in lowered:
                    fail(f"{slug}/{turn['tag']}/{language}: avoided domain word {word!r}")
        if total >= MAX_CHARACTERS:
            fail(f"{slug}/{language}: {total} characters of turn text, limit {MAX_CHARACTERS}")
    for _, label, _ in scenario["speakers"]:
        if label in AVOID_NAMES:
            fail(f"{slug}: avoided speaker name {label}")
    for name in scenario["mentioned_names"]:
        if name in AVOID_NAMES:
            fail(f"{slug}: avoided mentioned name {name}")


def check_gold_files(scenario, outputs):
    for language in LANGUAGES:
        stem = f"test/{scenario['slug']}-{language}"
        record = json.loads(outputs[f"{stem}.json"])
        gold = json.loads(outputs[f"{stem}.acts.json"])
        if len(record["segments"]) != len(scenario["turns"]):
            fail(f"{stem}: segment count mismatch")
        if gold["recording"] != f"benchmarks/summary/acts/{stem}.json":
            fail(f"{stem}: bad recording path in gold")
        if gold["participants"] != [label for _, label, _ in scenario["speakers"]]:
            fail(f"{stem}: bad participants in gold")
        count = len(record["segments"])
        for key, entries in gold["turns"].items():
            if not re.fullmatch(r"S[1-9][0-9]*", key) or int(key[1:]) > count:
                fail(f"{stem}: bad turn key {key}")
            for entry in entries:
                if entry["target"] is not None and int(entry["target"][1:]) >= int(key[1:]):
                    fail(f"{stem}: {key} targets a later turn")
        if language != "fr":
            french = json.loads(outputs[f"test/{scenario['slug']}-fr.json"])
            starts = [(s["start"], s["end"]) for s in record["segments"]]
            if starts != [(s["start"], s["end"]) for s in french["segments"]]:
                fail(f"{stem}: timestamps differ from the French version")


def main():
    labels = closed_labels()
    expected_labels = {"commit", "accept", "tentative", "request", "propose", "agree", "decline", "decide", "defer",
                       "correct", "withdraw", "challenge", "quote", "obligation", "question"}
    if labels != expected_labels:
        fail(f"labels parsed from LABELS.md differ: {sorted(labels ^ expected_labels)}")
    generate = load("acts_generate", ROOT / "generate.py")
    scenarios = generate.load_scenarios()
    outputs = check_generation(generate)
    check_no_em_dash(outputs)
    for scenario in scenarios:
        check_scenario(scenario, labels)
        check_text(scenario)
        check_gold_files(scenario, outputs)
    if failures:
        print(f"{len(failures)} check(s) failed:")
        for message in failures:
            print(f"  - {message}")
        sys.exit(1)
    print(f"OK: {len(outputs)} generated files verified, {len(scenarios)} scenarios.")


if __name__ == "__main__":
    main()
