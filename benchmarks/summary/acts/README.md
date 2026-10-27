# Speech-act probe fixtures

Gold labels for `scripts/act-probe.py`, which asks a model to label every transcript turn with acts from a closed list (commit, accept, tentative, request, propose, agree, decline, decide, defer, correct, withdraw, challenge, quote, obligation, question), with the turn each act refers to and the person who would act. The definitions and the gold format are in [LABELS.md](LABELS.md). Every meeting, person and figure is invented.

| Path | Content |
|---|---|
| `LABELS.md` | Label definitions, annotation rules and gold file format |
| `gold_dev.py` | Development gold for Atlas (`../synthetic/`) and `d1`, `d2` (`../ledger/dev/`); run it to write `dev/*.acts.json`. The same labels apply to the French, English and mixed versions. |
| `scenarios_test.py` | Source of the two test scenarios, with per-turn gold acts and ledger expectations |
| `generate.py` | Deterministic generator of `test/`; reuses the builders of `../ledger/generate.py` without modifying them |
| `check.py` | Self-check of `test/` against a fresh generation, label vocabulary, targets, agents and naming rules |
| `test/` | Recording JSON, ledger expected JSON and `.acts.json` gold for `t1-community-choir-concert` (23 turns) and `t2-mountain-trail-race` (39 turns), in `fr`, `en` and `mixed` |

The test scenarios were written by a separate agent that had no access to the probe prompt or code. Their hashes were frozen before the first test run. They were run and read once on 2026-10-27 (see `docs/summary-capacity-followup.md`), so they are no longer unseen data: use them for regression, not to claim generalization.

```sh
python3 benchmarks/summary/acts/gold_dev.py
python3 benchmarks/summary/acts/generate.py --force
python3 benchmarks/summary/acts/check.py
```

A gold act may carry `"optional": true` (neither counted as missed nor as false when predicted) and `alt_targets` (other turns accepted as its target).
