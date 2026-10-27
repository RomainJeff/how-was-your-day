#!/usr/bin/env python3
"""No real model, microphone or private recording required. A loopback stub server stands in for LM Studio."""
import http.server
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import threading
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location("act_probe", Path(__file__).with_name("act-probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
GOLD = probe.ROOT / "benchmarks/summary/acts/dev/d1-trade-fair-booth-en.acts.json"


def act(turn, name, target=None, agent=None):
    return {"turn": turn, "act": name, "target": target, "agent": agent, "target_after_turn": False}


class ParseTests(unittest.TestCase):
    IDS, PEOPLE = ["S1", "S2", "S3"], ["Ana", "Bea"]

    def test_valid_acts_are_kept_and_late_targets_are_counted_not_repaired(self):
        content = json.dumps({"acts": [{"turn": "S1", "act": "request", "target": None, "agent": "Bea"},
                                       {"turn": "S2", "act": "accept", "target": "S3", "agent": "Bea"}]})
        acts = probe.parse_acts(content, self.IDS, self.PEOPLE)
        self.assertEqual([entry["target_after_turn"] for entry in acts], [False, True])
        self.assertEqual(acts[1]["target"], "S3")

    def test_unknown_labels_turns_and_agents_are_invalid(self):
        for entry in ({"turn": "S9", "act": "commit", "target": None, "agent": None},
                      {"turn": "S1", "act": "promise", "target": None, "agent": None},
                      {"turn": "S1", "act": "commit", "target": None, "agent": "Zoe"},
                      {"turn": "S1", "act": "commit", "target": None}):
            with self.assertRaises(probe.ledger.InvalidResponse):
                probe.parse_acts(json.dumps({"acts": [entry]}), self.IDS, self.PEOPLE)

    def test_per_turn_version_requires_every_turn_in_order(self):
        good = {"turns": [{"turn": "S1", "acts": [{"act": "request", "target": None, "agent": "Bea"}]},
                          {"turn": "S2", "acts": []}, {"turn": "S3", "acts": [{"act": "accept", "target": "S1", "agent": "Bea"}]}]}
        acts = probe.parse_acts(json.dumps(good), self.IDS, self.PEOPLE, "acts-v2")
        self.assertEqual([(entry["turn"], entry["act"]) for entry in acts], [("S1", "request"), ("S3", "accept")])
        skipped = {"turns": [good["turns"][0], good["turns"][2]]}
        with self.assertRaises(probe.ledger.InvalidResponse):
            probe.parse_acts(json.dumps(skipped), self.IDS, self.PEOPLE, "acts-v2")
        schema = probe.probe_schema(self.IDS, self.PEOPLE, "acts-v2")["properties"]["turns"]
        self.assertEqual((schema["minItems"], schema["maxItems"]), (3, 3))

    def test_acts_v3_names_the_person_field_who_acts(self):
        content = {"turns": [{"turn": "S1", "acts": [{"act": "request", "target": None, "who_acts": "Bea"}]},
                             {"turn": "S2", "acts": []}, {"turn": "S3", "acts": []}]}
        acts = probe.parse_acts(json.dumps(content), self.IDS, self.PEOPLE, "acts-v3")
        self.assertEqual(acts[0]["agent"], "Bea")
        act = probe.probe_schema(self.IDS, self.PEOPLE, "acts-v3")["properties"]["turns"]["items"]["properties"]["acts"]["items"]
        self.assertEqual(act["required"], ["act", "target", "who_acts"])
        for version in probe.SYSTEMS:
            self.assertNotIn("\u2014", probe.SYSTEMS[version])
        self.assertNotIn(" agent", probe.SYSTEM_V3)

    def test_schema_is_closed(self):
        schema = probe.probe_schema(self.IDS, self.PEOPLE)
        item = schema["properties"]["acts"]["items"]
        self.assertEqual(item["properties"]["act"]["enum"], list(probe.ACTS))
        self.assertIn("other", item["properties"]["agent"]["anyOf"][0]["enum"])
        self.assertFalse(item["additionalProperties"])


class ScoreTests(unittest.TestCase):
    GOLD = {"turns": {"S1": [{"act": "request", "target": None, "agent": "Bea"}],
                      "S2": [{"act": "decline", "target": "S1", "agent": None},
                             {"act": "defer", "target": "S1", "agent": None, "optional": True}],
                      "S3": [{"act": "commit", "target": None, "agent": "Ana"}],
                      "S4": [{"act": "challenge", "target": "S3", "agent": None}],
                      "S5": [{"act": "decide", "target": "S2", "agent": None, "alt_targets": ["S1"]}]}}

    def test_perfect_labels_have_no_error(self):
        predicted = [act("S1", "request", agent="Bea"), act("S2", "decline", "S1"), act("S3", "commit", agent="Ana"),
                     act("S4", "challenge", "S3"), act("S5", "decide", "S1")]
        counts, targets, agents, critical, _ = probe.score_case(predicted, self.GOLD)
        self.assertEqual(sum(counts[name]["fp"] + counts[name]["fn"] for name in probe.ACTS), 0)
        self.assertEqual((targets["wrong"], agents["wrong"], sum(critical.values())), (0, 0, 0))

    def test_optional_acts_are_neither_missed_nor_false(self):
        predicted = [act("S2", "decline", "S1"), act("S2", "defer", "S1")]
        counts, *_ = probe.score_case(predicted, self.GOLD)
        self.assertEqual(sum(counts["defer"].values()), 0)

    def test_critical_errors(self):
        predicted = [act("S2", "accept", "S1", "Bea"), act("S4", "withdraw", "S3"), act("S1", "decide"),
                     act("S5", "decide", "S4")]
        _, targets, _, critical, notes = probe.score_case(predicted, self.GOLD)
        self.assertEqual(critical["C1_false_commitment"], 1)
        self.assertEqual(critical["C1_refusal_hedge_or_quote_read_as_commitment"], 1)
        self.assertEqual(critical["C3_false_withdrawal"], 1)
        self.assertEqual(critical["C4_false_decision"], 1)
        self.assertEqual(targets["wrong"], 1)
        self.assertTrue(any("missed commit" in note for note in notes))

    def test_commit_and_accept_are_also_scored_as_one_commitment(self):
        gold = {"turns": {"S2": [{"act": "accept", "target": "S1", "agent": "Bea"}]}}
        counts, *_ = probe.score_case([act("S2", "commit", agent="Bea")], gold)
        self.assertEqual((counts["accept"]["fn"], counts["accept"]["union_found"]), (1, 1))
        self.assertEqual(probe.summary(counts)["commit_or_accept_union_recall"], 1.0)

    def test_wrong_change_target_is_critical(self):
        gold = {"turns": {"S3": [{"act": "withdraw", "target": "S1", "agent": None}]}}
        _, _, _, critical, _ = probe.score_case([act("S3", "withdraw", "S2")], gold)
        self.assertEqual(critical["C5_wrong_change_target"], 1)


class StubServer(http.server.ThreadingHTTPServer):
    def __init__(self, reply):
        self.reply_content, self.requests = reply, []
        super().__init__(("127.0.0.1", 0), StubHandler)


class StubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append(body)
        data = json.dumps({"choices": [{"message": {"content": self.server.reply_content}, "finish_reason": "stop"}],
                           "usage": {"prompt_tokens": 10}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class EndToEndTests(unittest.TestCase):
    def test_run_and_score_one_dev_case_against_a_stub(self):
        gold = json.loads(GOLD.read_text())
        acts = [{"turn": sid, "act": entry["act"], "target": entry["target"], "agent": entry["agent"]}
                for sid, entries in gold["turns"].items() for entry in entries if not entry.get("optional")]
        server = StubServer(json.dumps({"acts": acts}))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        directory = Path(tempfile.mkdtemp(dir=probe.ROOT / "build"))
        try:
            args = SimpleNamespace(endpoint=f"http://127.0.0.1:{server.server_address[1]}/v1", model="stub", reasoning_effort="none",
                                   prompt_version=probe.PROMPT_VERSION, input_characters=24_000, server_pid=[], sample_interval=5,
                                   quantization=None, context_tokens=None)
            report = probe.run_case(GOLD, directory / "case", args, probe.ledger.load_harness())
            self.assertEqual((report["status"], report["calls"]), ("completed", 1))
            body = server.requests[0]
            self.assertEqual((body["temperature"], body["reasoning_effort"]), (0, "none"))
            self.assertEqual(body["response_format"]["json_schema"]["schema"], probe.probe_schema(
                [f"S{index}" for index in range(1, report["turns"] + 1)], gold["participants"]))
            result = probe.score(directory)
            self.assertEqual((result["overall"]["micro_precision"], result["overall"]["micro_recall"]), (1.0, 1.0))
            self.assertEqual(result["cases_with_critical_error"], 0)
        finally:
            server.shutdown()
            shutil.rmtree(directory)


if __name__ == "__main__":
    unittest.main()
