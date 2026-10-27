"""Development gold labels for the speech-act probe (see LABELS.md).

Written from the English version of each dev fixture; French and mixed versions share speakers, turn
order and meaning, so the same labels apply to the three languages. Dev labels may be read while
iterating on the probe. `alt_targets` lists other turns accepted as the target of an act.
Run this file to write dev/<case>.acts.json.
"""
import json
from pathlib import Path


def act(name, target=None, agent=None, optional=False, alt_targets=(), note=None):
    value = {"act": name, "target": target, "agent": agent}
    if optional:
        value["optional"] = True
    if alt_targets:
        value["alt_targets"] = list(alt_targets)
    if note:
        value["note"] = note
    return value


ATLAS = {
    "participants": ["Camille", "Jordan"],
    "turns": {
        "S1": [act("propose")],
        "S2": [act("decline", "S1")],
        "S3": [act("withdraw", "S1"), act("propose", optional=True, note="The pilot is put forward, then settled at S4")],
        "S4": [act("decide", "S3", alt_targets=["S1"])],
        "S5": [act("request", agent="Jordan")],
        "S6": [act("accept", "S5", "Jordan")],
        "S7": [act("commit", agent="Camille"), act("decline", optional=True, note="Refuses customer training nobody asked for")],
        "S8": [act("propose"), act("defer", optional=True, note="'An idea for later'")],
        "S9": [act("question")],
        "S10": [act("obligation")],
        "S11": [act("propose")],
        "S12": [act("defer", "S11"), act("propose", optional=True, note="Counter-preference of seven days")],
        "S13": [act("obligation"), act("defer", "S11", optional=True), act("agree", "S12", optional=True)],
        "S15": [act("correct", "S7", "Camille")],
        "S16": [act("commit", "S6", "Jordan", optional=True, note="Restates an unchanged commitment")],
        "S17": [act("decide"), act("decline", "S8", optional=True)],
        "S18": [act("decide"), act("agree", "S17", optional=True), act("obligation", optional=True)],
    },
}

D1 = {
    "participants": ["Hélène", "Bastien", "Mehdi"],
    "turns": {
        "S2": [act("obligation", optional=True, note="Staffing need, not a task")],
        "S3": [act("commit", agent="Mehdi")],
        "S4": [act("request", agent="Bastien")],
        "S5": [act("decline", "S4"), act("defer", "S4", optional=True), act("question")],
        "S6": [act("propose")],
        "S7": [act("decline", "S6"), act("propose")],
        "S8": [act("agree", "S7", optional=True, note="Conditional feasibility")],
        "S9": [act("decide", "S7", alt_targets=["S8"])],
        "S10": [act("agree", "S9")],
        "S11": [act("agree", "S9")],
        "S12": [act("obligation")],
        "S13": [act("request")],
        "S14": [act("quote", agent="Bastien")],
        "S15": [act("defer", "S13"), act("request")],
        "S16": [act("commit", "S15", "Hélène")],
        "S17": [act("commit")],
        "S18": [act("correct", "S3", "Mehdi")],
        "S19": [act("request", agent="Bastien")],
        "S20": [act("accept", "S19", "Bastien")],
    },
}

D2 = {
    "participants": ["Lucie", "Karim", "Sophie", "Thomas"],
    "turns": {
        "S4": [act("quote", agent="other", optional=True, note="The sign maker installs it")],
        "S5": [act("request", agent="Karim")],
        "S6": [act("accept", "S5", "Karim")],
        "S7": [act("question")],
        "S8": [act("commit", agent="Karim")],
        "S9": [act("quote", agent="Karim")],
        "S10": [act("propose")],
        "S11": [act("agree", "S10")],
        "S12": [act("agree", "S10")],
        "S13": [act("agree", "S10")],
        "S14": [act("decide", "S10"), act("question", optional=True)],
        "S15": [act("commit", agent="Sophie"), act("obligation", optional=True)],
        "S16": [act("obligation")],
        "S17": [act("commit", agent="Thomas"), act("obligation", optional=True)],
        "S18": [act("commit", agent="Karim"), act("obligation", optional=True)],
        "S19": [act("propose")],
        "S20": [act("agree", "S19")],
        "S21": [act("agree", "S19")],
        "S23": [act("decide", "S19"), act("request", agent="Sophie")],
        "S24": [act("accept", "S23", "Sophie")],
        "S25": [act("commit", agent="Thomas")],
        "S26": [act("request"), act("question", optional=True)],
        "S27": [act("tentative", "S26", "Thomas")],
        "S29": [act("request", agent="Karim")],
        "S30": [act("decline", "S29")],
        "S31": [act("question")],
        "S32": [act("quote", agent="other", optional=True, note="The fishmonger agrees to deliver")],
        "S34": [act("propose")],
        "S35": [act("defer", "S34")],
        "S36": [act("request"), act("question", optional=True)],
        "S37": [act("quote", agent="other")],
        "S38": [act("correct", "S8", "Karim")],
        "S39": [act("challenge", "S6")],
        "S40": [act("commit", "S6", "Karim"), act("decline", "S39", optional=True)],
        "S41": [act("request", "S17", "Sophie")],
        "S42": [act("accept", "S41", "Sophie")],
        "S43": [act("commit", "S9", "Karim")],
        "S44": [act("withdraw", "S23")],
        "S45": [act("agree", "S44", optional=True)],
        "S46": [act("request", "S18", "Sophie")],
        "S47": [act("decline", "S46")],
        "S48": [act("withdraw", "S25")],
        "S49": [act("propose", "S14")],
        "S50": [act("agree", "S49")],
        "S51": [act("agree", "S49")],
        "S52": [act("decide", "S49", alt_targets=["S14"]), act("request")],
        "S53": [act("commit", "S52", "Lucie")],
    },
}

CASES = [
    ("atlas-" + language, f"benchmarks/summary/synthetic/{language}.json", ATLAS) for language in ("fr", "en", "mixed")
] + [
    (f"d1-trade-fair-booth-{language}", f"benchmarks/summary/ledger/dev/d1-trade-fair-booth-{language}.json", D1)
    for language in ("fr", "en", "mixed")
] + [
    (f"d2-second-restaurant-opening-{language}", f"benchmarks/summary/ledger/dev/d2-second-restaurant-opening-{language}.json", D2)
    for language in ("fr", "en", "mixed")
]


def main():
    output = Path(__file__).resolve().parent / "dev"
    output.mkdir(exist_ok=True)
    for name, recording, gold in CASES:
        value = {"schema": "hwyd-acts-gold/1", "recording": recording, "participants": gold["participants"], "turns": gold["turns"]}
        (output / f"{name}.acts.json").write_text(json.dumps(value, ensure_ascii=False, indent=1) + "\n")


if __name__ == "__main__":
    main()
