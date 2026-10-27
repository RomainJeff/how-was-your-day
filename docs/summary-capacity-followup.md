# Follow-up: does a larger model fix the typed ledger?

Status: benchmark-only. The application and the shipped `summary-v7-grounded-writing` workflow are unchanged. This follows [the typed ledger experiment](summary-ledger-experiment.md), whose development and holdout results with Qwen3.5 4B were rejected.

## Question

The 4B failures left on the frozen system (ledger-v2 prompt, final deterministic rules) were local misreadings: an adopted proposal left as a proposal, a refusal read as acceptance, a corrected deliverable rewritten with the wrong content. The plan, written before the holdout, allowed one development pass with Qwen3.5 9B to test whether these errors are a matter of model capacity. No prompt, rule, fixture or budget was changed for this pass, and no new design was tried.

## Setup and provenance

- Same commit and script as the 4B final system: `scripts/ledger-summary.py` sha256 `2a094d46…a180`, prompt `ledger-v2` (hash `b48433b9…`), frozen fixtures and expectations checked before the run, deterministic tests passing.
- `qwen/qwen3.5-9b`, MLX 4-bit, reasoning disabled, temperature 0, one request at a time, parallel 1, the only model loaded. As with the 4B, 32,768 tokens were requested and the server advertised 262,144.
- Shipped bounds: 24,000-character user-prompt ceiling, 12,000-character windows (one window per case), carried ledger of 12 items or 3,000 characters, 4,000-character writer slice, at most 12 calls per case.
- The configured prompt version, budgets and reasoning settings in each case's `benchmark.json` match the 4B reference; the model identifier differs. The 4B reference applies the final rules to cached ledger-v2 responses (`rederive`); the 9B applies them live. Rules and prompt are identical.
- Nine development cases: Atlas, `d1` and `d2`, each in French, English and mixed French/English. 18 expected decisions, 36 expected tasks. The holdout was not run with the 9B, as planned.

Recall and gates come from manual review of every case against its cited turns. A task with a wrong deadline is not counted, as in the 4B review. A gate is any of: unsupported task in next steps, wrong owner, invented or wrong deadline, wrong status (unsupported change applied, or an old state left active), an unowned or hesitant item promoted to a task, a proposal promoted to a decision.

## Results

| | Qwen3.5 4B | Qwen3.5 9B |
|---|---:|---:|
| Calls per case | 2 | 2 |
| Retries, failed cases | 0, 0 | 0, 0 |
| Inference per case | 30.7 to 70.6 s | 40.8 to 91.7 s |
| Inference, nine cases | 411.9 s | 551.5 s (+34%) |
| Largest user prompt | 13,970 characters | 13,997 characters |
| Idle server footprint | 5.70 GiB | 7.30 GiB |
| Sampled server peak | 7.21 to 8.45 GiB | 9.65 to 11.08 GiB |
| Decisions recalled | 13/18 | 16/18 |
| Tasks recalled, right owner and deadline | 34/36 | 33/36 |
| Unsupported tasks listed | 0 | 2 |
| Cases with at least one gate | 1 of 9 | 5 of 9 |

Per case (decisions, tasks, gates):

| Case | 4B | 9B |
|---|---|---|
| Atlas FR | 3/3, 2/2, none | 2/3, 2/2, none |
| Atlas EN | 2/3, 1/2, none | 3/3, 2/2, none |
| Atlas mixed | 3/3, 2/2, none | 3/3, 2/2, none |
| `d1` EN | 1/1, 3/3, none | 1/1, 2/3, corrected date not applied |
| `d1` FR | 1/1, 3/3, none | 1/1, 3/3, unowned obligation listed as a task |
| `d1` mixed | 1/1, 3/3, none | 1/1, 2/3, corrected date not applied |
| `d2` EN | 1/2, 7/7, none | 2/2, 7/7, none |
| `d2` FR | 0/2, 7/7, none | 2/2, 7/7, reversed decision left active; personal habit listed as a task |
| `d2` mixed | 1/2, 6/7, wrong deliverable text | 1/2, 6/7, kept task demoted to "nobody owns it" |

The automatic `score` flags reported 16/18 decisions and 35/36 tasks for the 9B. They do not check the value of a deadline that a cited turn supports, so the two stale dates below counted as recalled.

### What the 9B fixed

- Adopted proposals are recognized as decisions on `d2`: the shared till software in all three languages, and the Monday to Tuesday closing reversal in English and French (the 4B left most of them as proposals).
- Atlas English: the postponed announcement is a decision and the corrected guide draft is a firm task.
- No refusal grounded a task or a handover; the press tasting and the declined hygiene handover never became someone's task.

### Counterexamples

- **Corrected deadline not applied** (`d1` English and mixed). Mehdi first promises the dock address "before November 6", then corrects it to November 9. The 9B cites both turns on one task but keeps "before November 6". The deadline rule accepts it because "6" occurs in the cited turns. Model error; the 4B linked this correction in all three languages.
- **Unowned obligation listed as a task** (`d1` French). "We must declare the badge names before registration closes", said by Mehdi, becomes Mehdi's task. The voice is right, so the rule accepts it.
- **Personal habit listed as a task** (`d2` French). Sophie keeping her own spreadsheet for bank reconciliations becomes her task.
- **Reversed decision left active** (`d2` French). The Tuesday decision points its `replaces` at the turn of the original Monday proposal, which the Monday decision had already replaced, instead of the decision itself. The rules do not follow a replacement chain, as documented, so both decisions are listed. Model linking error.
- **Kept task demoted** (`d2` mixed). Lucie's suggestion to hand the hygiene registrations to Sophie, declined by Sophie, is encoded as an owner-less follow-up that "replaces" Karim's task, which drops to *to confirm, nobody owns it*. The code accepts the change because Lucie is in the item's authority: the model had cited an unrelated Lucie turn as support for Karim's task. This is a model error made possible by a rule weakness, not a code defect against the documented rules: authority is computed from model-chosen support turns, and a demotion to no owner does not require the owner's own turn.

The prose has the same writer defects as before, sometimes in contradiction with correct lists: tote bags translated as "backpacks", the declined price grid described as Bastien's proposal or commitment, and an invented role for Thomas.

## Verdict

Switching to this 9B model with the frozen workflow: **not sufficient in this experiment**. The 9B recovers three decisions net and none of its gates comes from a code bug, but it lists two unsupported tasks, drops a correction the 4B handled, and goes from one to five development cases with a gate, for 34% more inference time and about 2.5 GiB more peak memory. Its failures belong to the classes already seen on the 4B holdout: the right voice with the wrong meaning, a replacement linked to the wrong item, an old value kept next to a cited correction. Rules that only check who speaks do not catch them. Following the plan, neither a 9B holdout nor the 90-minute run was attempted.

## Withdrawal rule, separate arm

`scripts/ledger-summary.py` now accepts `--rules v3|v4` for `run` and `rederive`. `v3` stays the default and keeps the measured behaviour. `v4` changes one rule: a withdrawal raised by someone outside the item counts as confirmed by the owner only if the cited owner turn comes after every turn of the item and is not one of them. This closes the holdout flaw where the owner's original promise was cited as the owner's confirmation of its own withdrawal.

Re-deriving the cached development responses of both models with `v3` and `v4` gives identical results for all 18 cases. The arm costs nothing on development data, but its benefit is not measured: the only known instance is in the holdout, which has been read. A later owner turn that keeps the commitment would still be accepted if the model cited it.

## Closed speech-act probe

Since capacity did not remove the gates, the next hypothesis of the ledger experiment was tested in isolation, before building any pipeline on it: can a model label each turn with a closed list of speech acts and the turn they refer to, so that items could be built by code?

`scripts/act-probe.py` sends one request per case. The model returns, for every turn, a list of acts (commit, accept, tentative, request, propose, agree, decline, decide, defer, correct, withdraw, challenge, quote, obligation, question), each with the earlier turn it refers to and the person who would act. The response schema closes labels, turn identifiers and people. Nothing is built from the labels; they are scored against gold labels.

- Labels and gold format: [benchmarks/summary/acts/LABELS.md](../benchmarks/summary/acts/LABELS.md), written before any probe inference. Several acts per turn are allowed.
- Development gold: Atlas, `d1` and `d2` in three language forms (nine cases).
- Test set: two new scenarios (23 and 39 turns) in French, English and mixed French/English, written by a separate agent without access to the prompt or the probe code, hashes frozen before the first test run, run once per model.
- Critical errors are the label errors that would produce a gate if items were built from them: a commitment on a turn without one (C1), a withdrawal on a turn without one (C3), a decision on a turn without one (C4), a withdrawal or correction aimed at the wrong turn (C5).
- Pass criterion, written before the test run: no critical error on the six test cases, commit or accept recall of at least 0.90, recall of decline, withdraw, correct and challenge of at least 0.80.
- At most two prompt revisions, decided on development errors only, without phrase lists. `acts-v2` returns one entry per turn (`acts-v1` skipped whole turns) and spells out who acts; `acts-v3` renames the person field `who_acts` and states the accept/agree and decline/withdraw contrasts. `acts-v3` was selected on development critical errors before the test. Same runtime settings as above; Qwen3.5 4B first, then the 9B with the frozen `acts-v3`.

| Run | Critical errors | Cases affected | Precision / recall | Commit or accept recall | Decline, withdraw, correct, challenge recall | Target right | Person right |
|---|---:|---:|---|---:|---:|---:|---:|
| 4B dev `acts-v1` | 10 | 4 of 9 | 0.76 / 0.63 | 0.76 | 0.69 | 0.92 | 0.72 |
| 4B dev `acts-v2` | 12 | 6 of 9 | 0.68 / 0.63 | 0.82 | 0.69 | 0.93 | 0.63 |
| 4B dev `acts-v3` | 8 | 3 of 9 | 0.73 / 0.64 | 0.75 | 0.78 | 0.92 | 0.81 |
| 4B test `acts-v3` | 9 | 2 of 6 | 0.72 / 0.70 | 0.91 | 0.53 | 0.77 | 0.69 |
| 9B dev `acts-v3` | 5 | 2 of 9 | 0.83 / 0.74 | 0.98 | 0.92 | 0.95 | 0.74 |
| 9B test `acts-v3` | 18 | 3 of 6 | 0.72 / 0.75 | 0.93 | 0.58 | 0.82 | 0.59 |

Commit or accept recall counts a gold commit or accept as found when the turn carries either predicted label, since both ground the same commitment. Cost per case: 4B 6 to 27 s and a sampled server peak of 6.2 to 8.4 GiB with no retry; 9B 20 to 90 s and 9.3 to 11.1 GiB, with one retry after a response that skipped turns.

Both models fail the criterion. On the test set the critical errors repeat the ledger failure classes under a closed vocabulary: a chair's agenda wish, a personal habit, a practical fact, a preferred date and a suggestion labelled as commitments; an indirect refusal ("we fell out at the last assembly, a letter from you will go over better") labelled as an acceptance or a commitment; a reduced deliverable labelled as a withdrawal. The 9B made more of these than the 4B on the test set while doing better on development data. One counted error is debatable: a cancelled request targeted at the acceptance turn instead of the request turn, which names the same item. Removing it does not change the result. The per-turn schema removed the under-labelling of the first version, and the renamed person field helped on development data without holding on the test set. As with the ledger prompts, each revision moved errors between cases.

## Overall verdict

Neither a larger model nor closed per-turn labels remove the gates of the typed ledger. The blocking errors are readings of meaning (who will act, whether a sentence commits, refuses, reduces or merely describes), which neither speaker-based rules nor a closed label set verify. No pipeline was built on the labels, no new ledger holdout was written, and the 90-minute recording was not run because its precondition, no gate on short development and new holdout cases, was not met.

## Limits

- One pass at temperature 0 on nine synthetic development cases; earlier Atlas reruns were byte-identical, but deterministic decoding does not establish stability across hardware, runtime versions or all inputs.
- The development set was read while tuning the 4B system, so it favours the 4B prompt. The 9B was not tuned; a prompt adapted to the 9B was not tested.
- The 4B reference was re-derived from cached responses, the 9B run was live; prompt, rules and budgets are identical.
- Memory peaks are sampled every 0.5 s and include the LM Studio interface; brief peaks may be missed. The loaded context (262,144 tokens) is larger than any prompt here.
- Gate counting is a single reviewer's judgment against cited turns.
- The probe's development gold was written by the author of the probe prompts. The test gold was written by a different agent from the shared label guide; its author listed nine ambiguous choices, and a few targets admit two readings. The test set has two scenarios: enough to show failure, not to estimate rates. It has now been read and is no longer unseen.
- A probe pass would still have required building items in code and measuring the full pipeline on another unseen set.

## Reproduce

```sh
python3 scripts/test-ledger-summary.py
python3 scripts/test-act-probe.py
python3 benchmarks/summary/acts/check.py
python3 scripts/ledger-summary.py rederive RUN --output build/... --rules v4
python3 scripts/act-probe.py run --gold benchmarks/summary/acts/dev --model MODEL_IDENTIFIER \
  --reasoning-effort none --prompt-version acts-v3 --output build/summary-benchmark/acts-dev-01
python3 scripts/act-probe.py score build/summary-benchmark/acts-dev-01
```
