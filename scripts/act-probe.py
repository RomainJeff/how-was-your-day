#!/usr/bin/env python3
"""Closed speech-act probe: one model call labels every turn of a short recording with acts from the
closed list of benchmarks/summary/acts/LABELS.md, then the labels are scored against gold files.

Benchmark-only. It never loads or unloads models and only talks to an already loaded loopback server.
It does not build ledger items: it measures whether per-turn labels are reliable enough to build them.

  python3 scripts/act-probe.py run --gold benchmarks/summary/acts/dev --model ID --reasoning-effort none --output build/...
  python3 scripts/act-probe.py score build/...
"""
import argparse
import collections
import hashlib
import importlib.util
import json
from pathlib import Path
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ledger_summary", Path(__file__).with_name("ledger-summary.py"))
ledger = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ledger)

ACTS = ("commit", "accept", "tentative", "request", "propose", "agree", "decline", "decide", "defer",
        "correct", "withdraw", "challenge", "quote", "obligation", "question")
TARGETED = ("accept", "agree", "decline", "decide", "defer", "correct", "withdraw", "challenge")
WITH_AGENT = ("commit", "accept", "tentative", "request", "quote", "correct")
COMMITMENTS = ("commit", "accept")
CHANGES = ("decline", "withdraw", "correct", "challenge")
OUTSIDE = "other"
PROBE_TOKENS = 8_000
MAXIMUM_ACTS_PER_TURN = 4

SYSTEM_V1 = """Tu étiquettes une réunion tour par tour avec des actes de parole d'une liste fermée. Tu ne résumes pas.

Pour chaque tour qui contient au moins un acte, donne un élément par acte : turn (le tour), act, target, agent. Un tour peut contenir plusieurs actes ; un tour sans acte (fait, contexte, avis, habitude personnelle, remerciement) n'apparaît pas.

Actes :
- commit : la personne qui parle s'engage fermement à faire elle-même quelque chose, de sa propre initiative ou après un appel resté sans réponse. agent = la personne qui parle.
- accept : la personne qui parle accepte une demande ou une reprise qui lui est adressée. target = le tour de la demande ; agent = la personne qui parle. Ne pas ajouter commit pour la même action.
- tentative : la personne qui parle envisage de faire quelque chose sans s'engager (peut-être, si j'ai le temps, sans garantie). agent = la personne qui parle.
- request : la personne qui parle demande à quelqu'un de faire quelque chose, demande qui peut le faire, ou demande à quelqu'un de reprendre un engagement. agent = la personne sollicitée, ou null pour un appel ouvert ; target = l'engagement à reprendre, sinon null.
- propose : suggestion d'une option pour le groupe, sans engagement à l'exécuter. target = la décision ou proposition qu'elle remplacerait, sinon null.
- agree : consentement à une proposition ou à une décision soumise au groupe. target = ce tour-là.
- decline : refus, ou non-prise en charge, d'une demande ou d'une reprise adressée à la personne qui parle, ou rejet d'une proposition. Un refus n'a pas de formule fixe : réserve, condition non remplie, « pas maintenant », renvoi à plus tard comptent. target = le tour refusé.
- decide : la personne qui parle constate ou tranche un choix du groupe, y compris l'annulation d'une décision antérieure. target = la proposition adoptée ou la décision renversée, sinon null.
- defer : report explicite d'un sujet, laissé non tranché. target = le tour du sujet, sinon null.
- correct : la personne qui parle modifie un engagement, une demande ou une décision antérieure qui reste valable sous une autre forme (date, livrable, périmètre). target = le tour modifié ; agent = la personne qui parle pour un engagement, null pour une décision.
- withdraw : la personne qui parle retire, sans remplacement, ce qu'elle avait elle-même avancé : son engagement, sa demande (annulation), sa proposition. target = le tour retiré.
- challenge : la personne qui parle met en doute ou suggère d'abandonner l'engagement, la demande ou la décision de quelqu'un d'autre. target = ce tour-là.
- quote : la personne qui parle rapporte les paroles, la promesse ou l'intention d'une autre personne, ou annonce qu'une autre personne, présente ou absente, fera quelque chose. agent = la personne citée ou désignée (« other » si elle ne parle pas dans la réunion).
- obligation : quelque chose doit être fait, sans que personne ne s'en charge dans ce tour.
- question : question ouverte qui n'est pas une demande d'action. target = le tour visé, sinon null.

Règles :
- Une phrase à la première personne à l'intérieur d'une citation est un quote, jamais un engagement de la personne qui parle ni de la personne citée.
- Ce n'est pas parce que la même personne parle qu'il y a engagement : un souhait d'ordre du jour, un « on se revoit » collectif, une habitude personnelle ou un fait ne sont pas des engagements.
- Un « nous ferons » collectif est decide s'il est tranché, propose s'il est suggéré, jamais un engagement personnel.
- Juge le sens d'un refus, pas sa formulation : une réponse évasive ou conditionnelle à une demande n'est jamais accept.
- Seule la personne qui a pris un engagement peut le corriger ou le retirer ; un tiers qui le met en doute fait un challenge.
- Un récapitulatif qui ne change rien n'ajoute aucun acte.
- target désigne toujours un tour antérieur. agent est un participant listé, « other », ou null.

FORMAT DE SORTIE OBLIGATOIRE : un objet JSON {"acts": [...]}, sans texte autour, éléments dans l'ordre des tours. Chaque élément contient les clés turn, act, target, agent."""

# acts-v2, decided on acts-v1 development errors only: one entry for every turn (whole turns were skipped),
# and the meaning of agent, accept, quote, decide and challenge made explicit (each confusion seen on two or more cases).
SYSTEM_V2 = """Tu étiquettes une réunion tour par tour avec des actes de parole d'une liste fermée. Tu ne résumes pas.

Tu examines chaque tour, du premier au dernier, et tu rends un élément par tour : turn (le tour) et acts, la liste de ses actes (act, target, agent). Un tour peut contenir plusieurs actes. Un tour sans acte (fait, contexte, avis, mise en garde, habitude personnelle, remerciement) a une liste vide.

Actes :
- commit : la personne qui parle s'engage fermement à faire elle-même quelque chose, sans qu'on le lui ait demandé, ou après un appel ouvert resté sans réponse, ou en maintenant son propre engagement. target = l'appel ouvert ou son propre engagement maintenu, sinon null.
- accept : la personne qui parle accepte une demande ou une reprise qui lui est adressée nommément. target = le tour de la demande. Une réponse positive à une demande est accept, pas commit ; ne mets pas les deux pour la même action.
- tentative : la personne qui parle envisage de faire quelque chose sans s'engager (peut-être, si j'ai le temps, sans garantie).
- request : la personne qui parle demande à quelqu'un de faire quelque chose, demande qui peut le faire, ou demande à quelqu'un de reprendre un engagement. target = l'engagement à reprendre, sinon null.
- propose : suggestion d'une option pour le groupe, sans engagement à l'exécuter. target = la décision ou proposition qu'elle remplacerait, sinon null.
- agree : consentement à une proposition ou à une décision soumise au groupe. target = ce tour-là.
- decline : refus, ou non-prise en charge, d'une demande ou d'une reprise adressée à la personne qui parle, ou rejet d'une proposition. Un refus n'a pas de formule fixe : réserve, condition non remplie, « pas maintenant », renvoi à plus tard comptent. target = le tour refusé.
- decide : la personne qui parle constate ou tranche un choix collectif du groupe, y compris l'annulation d'une décision collective antérieure. Une personne qui maintient ou modifie son propre engagement ne décide pas pour le groupe. target = la proposition adoptée ou la décision renversée, sinon null.
- defer : report explicite d'un sujet, laissé non tranché. target = le tour du sujet, sinon null.
- correct : la personne qui parle modifie un engagement, une demande ou une décision antérieure qui reste valable sous une autre forme (date, livrable, périmètre). target = le tour modifié.
- withdraw : la personne qui parle retire, sans remplacement, ce qu'elle avait elle-même avancé : son engagement, sa demande (annulation), sa proposition. target = le tour retiré.
- challenge : la personne qui parle met en doute ou suggère d'abandonner un engagement, une demande ou une décision déjà posée par quelqu'un d'autre. Refuser ce qu'on vous demande est decline ; une simple mise en garde n'est pas un acte. target = l'engagement, la demande ou la décision visée.
- quote : la personne qui parle rapporte les paroles, la promesse ou l'intention d'une autre personne, ou annonce qu'une autre personne ou organisation fera quelque chose. target = la parole antérieure de cette personne s'il y en a une, sinon null.
- obligation : quelque chose doit être fait, sans que personne ne s'en charge dans ce tour.
- question : question ouverte qui n'est pas une demande d'action. Une affirmation n'est pas une question. target = le tour visé, sinon null.

agent désigne toujours la personne qui fera l'action, jamais celle qui parle pour demander : pour commit, accept, tentative et correct, la personne qui parle ; pour request, la personne sollicitée (null pour un appel ouvert) ; pour quote, la personne ou l'organisation citée ou désignée (« other » si elle ne parle pas dans la réunion). Pour les autres actes, agent = null.

Règles :
- Il n'y a commit, accept ou tentative que si la personne qui parle fera elle-même l'action. Si l'action sera faite par quelqu'un d'autre (fournisseur, collègue absent, personne citée), c'est quote.
- Une phrase à la première personne à l'intérieur d'une citation est un quote, jamais un engagement de la personne qui parle ni de la personne citée.
- Ce n'est pas parce que la même personne parle qu'il y a engagement : un souhait d'ordre du jour, un « on se revoit » collectif, une habitude personnelle ou un fait ne sont pas des engagements.
- Un « nous ferons » collectif est decide s'il est tranché, propose s'il est suggéré, jamais un engagement personnel.
- Juge le sens d'un refus, pas sa formulation : une réponse évasive ou conditionnelle à une demande n'est jamais accept.
- Seule la personne qui a pris un engagement peut le corriger ou le retirer ; un tiers qui le met en doute fait un challenge.
- Un récapitulatif qui ne change rien n'ajoute aucun acte.
- target désigne toujours un tour antérieur. agent est un participant listé, « other », ou null.

FORMAT DE SORTIE OBLIGATOIRE : un objet JSON {"turns": [...]}, sans texte autour, avec exactement un élément par tour dans l'ordre. Chaque élément contient les clés turn et acts ; chaque acte contient les clés act, target, agent."""

# acts-v3, the last iteration, decided on acts-v2 development errors only: the person field is renamed
# who_acts in the response schema (agent stayed the speaker in all cases), and the two contrasts that
# produced critical errors on d1 in two or more languages are stated: accept versus agree, decline versus withdraw.
SYSTEM_V3 = (SYSTEM_V2
             .replace("(act, target, agent)", "(act, target, who_acts)")
             .replace("agent désigne toujours la personne qui fera l'action, jamais celle qui parle pour demander",
                      "who_acts désigne toujours la personne qui fera l'action, jamais celle qui parle pour demander ou pour citer")
             .replace("Pour les autres actes, agent = null.", "Pour les autres actes, who_acts = null.")
             .replace("target désigne toujours un tour antérieur. agent est un participant listé, « other », ou null.",
                      "accept répond à une demande adressée nommément à la personne qui parle ; agree répond à une proposition ou "
                      "une décision soumise à tout le groupe, même si la personne qui parle participera ensuite à sa mise en œuvre.\n"
                      "- withdraw ne porte que sur ce que la personne qui parle avait elle-même avancé ; ne pas prendre une demande "
                      "qu'on vous adresse est decline, jamais withdraw.\n"
                      "- target désigne toujours un tour antérieur. who_acts est un participant listé, « other », ou null.")
             .replace("chaque acte contient les clés act, target, agent.", "chaque acte contient les clés act, target, who_acts."))
SYSTEMS = {"acts-v1": SYSTEM_V1, "acts-v2": SYSTEM_V2, "acts-v3": SYSTEM_V3}
PER_TURN = ("acts-v2", "acts-v3")
PERSON_FIELD = {"acts-v3": "who_acts"}
PROMPT_VERSION = "acts-v1"


def prompt_hash(version):
    return hashlib.sha256(SYSTEMS[version].encode()).hexdigest()


def probe_schema(turn_ids, people, version=PROMPT_VERSION):
    turn = {"type": "string", "enum": list(turn_ids)}
    fields = {"act": {"type": "string", "enum": list(ACTS)}, "target": ledger.nullable(turn),
              PERSON_FIELD.get(version, "agent"): ledger.nullable({"type": "string", "enum": list(people) + [OUTSIDE]})}
    if version in PER_TURN:
        act = {"type": "object", "additionalProperties": False, "properties": fields, "required": list(fields)}
        entry = {"type": "object", "additionalProperties": False, "properties": {
            "turn": turn, "acts": {"type": "array", "items": act, "maxItems": MAXIMUM_ACTS_PER_TURN}}, "required": ["turn", "acts"]}
        return {"type": "object", "additionalProperties": False,
                "properties": {"turns": {"type": "array", "items": entry, "minItems": len(turn_ids), "maxItems": len(turn_ids)}},
                "required": ["turns"]}
    entry = {"type": "object", "additionalProperties": False, "properties": dict(turn=turn, **fields),
             "required": ["turn", "act", "target", "agent"]}
    return {"type": "object", "additionalProperties": False,
            "properties": {"acts": {"type": "array", "items": entry, "maxItems": MAXIMUM_ACTS_PER_TURN * len(turn_ids)}},
            "required": ["acts"]}


def probe_prompt(people, turns):
    return (f"Participants identifiés : {', '.join(people)}. Une voix non identifiée a le locuteur « {ledger.UNIDENTIFIED} ».\n"
            "Tours :\n" + ledger.compact(ledger.source_rows(turns)))


def parse_acts(content, turn_ids, people, version=PROMPT_VERSION):
    """Strict shape; targets that do not point to an earlier turn are kept but counted, never repaired."""
    value = ledger.load_content(content)
    if version in PER_TURN:
        if not isinstance(value, dict) or not isinstance(value.get("turns"), list):
            raise ledger.InvalidResponse("missing turns list")
        if [entry.get("turn") if isinstance(entry, dict) else None for entry in value["turns"]] != list(turn_ids):
            raise ledger.InvalidResponse("turns must list every turn exactly once, in order")
        flat = []
        for entry in value["turns"]:
            if set(entry) != {"turn", "acts"} or not isinstance(entry["acts"], list):
                raise ledger.InvalidResponse("turn entry with wrong keys")
            person = PERSON_FIELD.get(version, "agent")
            for raw in entry["acts"]:
                if isinstance(raw, dict) and person != "agent":
                    raw = {("agent" if key == person else key): value for key, value in raw.items()}
                flat.append(dict(raw, turn=entry["turn"]) if isinstance(raw, dict) else raw)
        value = {"acts": flat}
    if not isinstance(value, dict) or not isinstance(value.get("acts"), list):
        raise ledger.InvalidResponse("missing acts list")
    position = {sid: index for index, sid in enumerate(turn_ids)}
    acts = []
    for raw in value["acts"]:
        if not isinstance(raw, dict) or set(raw) != {"turn", "act", "target", "agent"}:
            raise ledger.InvalidResponse("act entry with wrong keys")
        if raw["turn"] not in position or raw["act"] not in ACTS:
            raise ledger.InvalidResponse(f"unknown turn or act {raw.get('turn')} {raw.get('act')}")
        if raw["target"] is not None and raw["target"] not in position:
            raise ledger.InvalidResponse(f"unknown target {raw['target']}")
        if raw["agent"] is not None and raw["agent"] not in list(people) + [OUTSIDE]:
            raise ledger.InvalidResponse(f"unknown agent {raw['agent']}")
        acts.append(dict(raw, target_after_turn=raw["target"] is not None and position[raw["target"]] >= position[raw["turn"]]))
    return acts


def gold_files(paths):
    files = []
    for path in paths:
        files += sorted(path.glob("*.acts.json")) if path.is_dir() else [path]
    if not files:
        raise SystemExit("no gold files")
    return files


def run_case(gold_path, output, args, harness):
    gold = json.loads(gold_path.read_text())
    recording_path = ROOT / gold["recording"]
    recording, input_sha = ledger.load_recording(recording_path)
    turns = ledger.build_turns(recording)
    people = ledger.participants(turns)
    limit = ledger.prompt_limit(args.input_characters)
    output.mkdir(parents=True, exist_ok=False)
    cache = output / "cache"
    cache.mkdir(mode=0o700)
    system = SYSTEMS[args.prompt_version]
    identity = {"endpoint": args.endpoint, "model": args.model, "reasoning_effort": args.reasoning_effort,
                "prompt_version": args.prompt_version, "prompt_hash": prompt_hash(args.prompt_version), "input_sha256": input_sha}
    runner = ledger.Runner(ledger.Client(args.endpoint, args.model, args.reasoning_effort), cache, ledger.compact(identity),
                           output / "calls.jsonl", max_calls=2, version=args.prompt_version)
    sampler = ledger.MemorySampler(harness, output / "memory.jsonl", args.sample_interval, args.server_pid)
    sampler.start()
    ids = [turn["sid"] for turn in turns]
    status, error, acts = "failed", None, []
    try:
        version = args.prompt_version
        acts = runner.call("acts", "all turns", system, probe_prompt(people, turns), probe_schema(ids, people, version), PROBE_TOKENS,
                           lambda content: parse_acts(content, ids, people, version), limit)
        status = "completed"
    except Exception as exception:  # A failed case is reported, not hidden.
        error = f"{type(exception).__name__}: {exception}"
    finally:
        sampler.stop()
    calls = [record for record in runner.records if not record["cached"]]
    report = {"workflow": "act-probe", "prompt_version": args.prompt_version, "prompt_hash": prompt_hash(args.prompt_version),
              "model": args.model, "reasoning_effort": args.reasoning_effort, "quantization": args.quantization,
              "context_tokens": args.context_tokens, "gold": str(gold_path.relative_to(ROOT)), "input_path": str(recording_path),
              "input_sha256": input_sha, "turns": len(turns), "status": status, "error": error,
              "calls": len(calls), "retries": sum(1 for record in calls if record["attempt"] > 1),
              "inference_seconds": round(sum(record["seconds"] for record in calls), 1),
              "max_user_characters": max((record["user_characters"] for record in calls), default=0),
              "max_prompt_tokens": max(((record.get("usage") or {}).get("prompt_tokens") or 0 for record in calls), default=0),
              "memory_peaks": sampler.peaks}
    ledger.write_json(output / "benchmark.json", report)
    ledger.write_json(output / "acts.json", acts)
    return report


def gold_index(gold):
    return {sid: entries for sid, entries in gold["turns"].items()}


def score_case(predicted, gold):
    """Match per turn and act label. Optional gold acts are ignored either way."""
    gold_turns = gold_index(gold)
    counts = {name: collections.Counter() for name in ACTS}
    targets, agents = collections.Counter(), collections.Counter()
    critical, notes = collections.Counter(), []
    by_turn = collections.defaultdict(list)
    for act in predicted:
        by_turn[act["turn"]].append(act)
    # Union view: a required commit or accept counts as found when the turn has either label predicted,
    # because both ground the same commitment downstream.
    for sid, entries in gold_turns.items():
        for entry in entries:
            if entry["act"] in COMMITMENTS and not entry.get("optional"):
                found = any(act["act"] in COMMITMENTS for act in by_turn.get(sid, []))
                counts[entry["act"]]["union_found" if found else "union_missed"] += 1
    for sid in sorted(set(by_turn) | set(gold_turns), key=lambda value: int(value[1:])):
        expected = gold_turns.get(sid, [])
        labels_all = {entry["act"] for entry in expected}
        required = [entry for entry in expected if not entry.get("optional")]
        optional = {entry["act"] for entry in expected if entry.get("optional")}
        remaining = list(required)
        for act in by_turn.get(sid, []):
            match = next((entry for entry in remaining if entry["act"] == act["act"]), None)
            if match is None:
                if act["act"] not in optional:
                    counts[act["act"]]["fp"] += 1
                    notes.append(f"{sid} extra {act['act']} target={act['target']} agent={act['agent']}")
                if act["act"] in COMMITMENTS and not labels_all & set(COMMITMENTS):
                    critical["C1_false_commitment"] += 1
                    if labels_all & {"decline", "tentative", "challenge", "quote"}:
                        critical["C1_refusal_hedge_or_quote_read_as_commitment"] += 1
                    notes.append(f"{sid} CRITICAL C1 false {act['act']} (gold {sorted(labels_all) or 'none'})")
                if act["act"] == "withdraw" and "withdraw" not in labels_all:
                    critical["C3_false_withdrawal"] += 1
                    notes.append(f"{sid} CRITICAL C3 false withdraw (gold {sorted(labels_all) or 'none'})")
                if act["act"] == "decide" and "decide" not in labels_all:
                    critical["C4_false_decision"] += 1
                    notes.append(f"{sid} CRITICAL C4 false decide (gold {sorted(labels_all) or 'none'})")
                continue
            remaining.remove(match)
            counts[act["act"]]["tp"] += 1
            if act["act"] in TARGETED:
                good = act["target"] == match["target"] or act["target"] in match.get("alt_targets", [])
                targets["correct" if good else "wrong"] += 1
                if not good:
                    notes.append(f"{sid} {act['act']} target {act['target']} expected {match['target']}")
                    if act["act"] in ("withdraw", "correct"):
                        critical["C5_wrong_change_target"] += 1
                        notes.append(f"{sid} CRITICAL C5 {act['act']} on wrong target")
            if act["act"] in WITH_AGENT:
                good = act["agent"] == match["agent"]
                agents["correct" if good else "wrong"] += 1
                if not good:
                    notes.append(f"{sid} {act['act']} agent {act['agent']} expected {match['agent']}")
        for entry in remaining:
            counts[entry["act"]]["fn"] += 1
            notes.append(f"{sid} missed {entry['act']} target={entry['target']} agent={entry['agent']}")
    return counts, targets, agents, critical, notes


def rate(numerator, denominator):
    return round(numerator / denominator, 3) if denominator else None


def summary(counts):
    totals = collections.Counter()
    for counter in counts.values():
        totals.update(counter)
    groups = {"commit+accept": COMMITMENTS, "decline+withdraw+correct+challenge": CHANGES}
    value = {"micro_precision": rate(totals["tp"], totals["tp"] + totals["fp"]), "micro_recall": rate(totals["tp"], totals["tp"] + totals["fn"]),
             "commit_or_accept_union_recall": rate(totals["union_found"], totals["union_found"] + totals["union_missed"])}
    for name, members in groups.items():
        tp = sum(counts[act]["tp"] for act in members)
        value[f"{name}_recall"] = rate(tp, tp + sum(counts[act]["fn"] for act in members))
        value[f"{name}_precision"] = rate(tp, tp + sum(counts[act]["fp"] for act in members))
    value["per_act"] = {act: dict({key: count for key, count in counts[act].items() if not key.startswith("union")}, precision=rate(counts[act]["tp"], counts[act]["tp"] + counts[act]["fp"]),
                                  recall=rate(counts[act]["tp"], counts[act]["tp"] + counts[act]["fn"]))
                        for act in ACTS if sum(counts[act].values())}
    return value


def score(run_directory):
    overall = {name: collections.Counter() for name in ACTS}
    targets, agents, critical = collections.Counter(), collections.Counter(), collections.Counter()
    cases = []
    for case in sorted(path for path in run_directory.iterdir() if (path / "benchmark.json").exists()):
        report = json.loads((case / "benchmark.json").read_text())
        gold = json.loads((ROOT / report["gold"]).read_text())
        if report["status"] != "completed":
            print(case.name, report["status"], report["error"])
            cases.append({"case": case.name, "status": report["status"]})
            critical["failed_cases"] += 1
            continue
        predicted = json.loads((case / "acts.json").read_text())
        counts, case_targets, case_agents, case_critical, notes = score_case(predicted, gold)
        for name in ACTS:
            overall[name].update(counts[name])
        targets.update(case_targets)
        agents.update(case_agents)
        critical.update(case_critical)
        late_targets = sum(1 for act in predicted if act["target_after_turn"])
        row = {"case": case.name, "status": "completed", "critical": dict(case_critical), "late_targets": late_targets,
               "inference_seconds": report["inference_seconds"], "max_user_characters": report["max_user_characters"],
               "server_peak_GiB": round((report["memory_peaks"]["server_physical_footprint_bytes"] or 0) / 2**30, 2),
               "retries": report["retries"], **{key: value for key, value in summary(counts).items() if key != "per_act"}}
        cases.append(row)
        (case / "score.txt").write_text("\n".join(notes) + "\n")
        print(case.name, json.dumps({key: value for key, value in row.items() if key != "case"}, ensure_ascii=False))
    result = {"cases": cases, "overall": summary(overall), "target_accuracy": rate(targets["correct"], sum(targets.values())),
              "agent_accuracy": rate(agents["correct"], sum(agents.values())), "critical": dict(critical),
              "cases_with_critical_error": sum(1 for row in cases if row.get("critical") or row["status"] != "completed")}
    ledger.write_json(run_directory / "score.json", result)
    print(json.dumps({key: value for key, value in result.items() if key != "cases"}, ensure_ascii=False, indent=1))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="Label every gold case once with an already loaded model")
    run.add_argument("--gold", type=Path, action="append", required=True, help="Gold file or directory of *.acts.json")
    run.add_argument("--model", required=True)
    run.add_argument("--endpoint", default="http://127.0.0.1:1234/v1")
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--reasoning-effort")
    run.add_argument("--prompt-version", choices=sorted(SYSTEMS), default=PROMPT_VERSION)
    run.add_argument("--input-characters", type=int, default=ledger.MAXIMUM_PROMPT_CHARACTERS)
    run.add_argument("--server-pid", type=int, action="append", default=[])
    run.add_argument("--sample-interval", type=float, default=0.5)
    run.add_argument("--quantization", help="User-supplied label, not inferred")
    run.add_argument("--context-tokens", type=int, help="Loaded server context label; does not configure the server")
    scoring = commands.add_parser("score", help="Score a run directory against its gold files, without inference")
    scoring.add_argument("run_directory", type=Path)
    args = parser.parse_args()
    if args.command == "score":
        score(args.run_directory.resolve())
        return
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / "build") or output.exists():
        parser.error("Output must be a new directory under build/")
    harness = ledger.load_harness()
    started = time.monotonic()
    for gold_path in gold_files([path.resolve() for path in args.gold]):
        report = run_case(gold_path, output / gold_path.name.removesuffix(".acts.json"), args, harness)
        print(f"{gold_path.name}: {report['status']}; calls {report['calls']} (retries {report['retries']}); "
              f"{report['inference_seconds']}s inference; max prompt {report['max_user_characters']} characters; "
              f"server footprint peak {(report['memory_peaks']['server_physical_footprint_bytes'] or 0) / 2**30:.2f} GiB"
              + (f"; {report['error']}" if report["error"] else ""), flush=True)
    print(f"total wall time {time.monotonic() - started:.1f}s")


if __name__ == "__main__":
    main()
