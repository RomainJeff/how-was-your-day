# Closed speech-act labels for commitment probing

This guide defines the gold labels of the speech-act probe. It is shared by the annotators of the development and test sets. It says nothing about how a model is prompted.

Each turn of a transcript gets zero, one or several acts. A turn with no act (facts, context, habits, opinions, thanks, small talk) gets an empty list. Each act has three fields:

- `act`: one label from the closed list below.
- `target`: the earlier turn the act responds to or changes, or `null`. Only the turn that states the targeted thing is valid (the request, the proposal, the commitment, the decision). When a thing was restated, use the most recent statement before the act.
- `agent`: the person who would do the action, for the acts listed as carrying one; otherwise `null`. Use a participant label, `"other"` for a named person who is not a speaking participant, or `null` when nobody is designated.

## Labels

| Act | Meaning | `target` | `agent` |
|---|---|---|---|
| `commit` | The speaker firmly undertakes to do something themself, without being asked in the previous exchange, or volunteers after an open call ("who can...?") that got no answer. | `null`, the open call it answers, or the speaker's own commitment it reaffirms | speaker |
| `accept` | The speaker accepts a request or a handover addressed to them. This implies their commitment; do not add `commit` for the same action. | the request turn | speaker |
| `tentative` | The speaker hedges about doing something themself: "I might", "if I have time", "no guarantees". | the request turn if answering one, else `null` | speaker |
| `request` | The speaker asks a participant to do something, asks who can do it, or asks someone to take over a commitment. | the commitment being handed over, else `null` | addressee, or `null` for an open call |
| `propose` | The speaker suggests an option for the group (a plan, a choice, an idea) without committing to perform it. | the decision or proposal it would replace, else `null` | `null` |
| `agree` | The speaker consents to a proposal or to a decision put to the group. | the proposal or decision turn | `null` |
| `decline` | The speaker refuses or does not take on a request or handover addressed to them, or rejects a proposal. Indirect refusals count ("I won't get ahead of myself on that", "not this week", changing the subject after a request is not a refusal by itself). | the request or proposal turn | `null` |
| `decide` | The speaker states that the group has settled a choice, or settles it ("then we go with X"), including reversing an earlier decision. A question asking for consent while stating the chosen option still counts. | the adopted proposal or the reversed decision, else `null` | `null` |
| `defer` | The speaker explicitly postpones or leaves a subject undecided ("let's not decide today", "for later", "we'll talk about it again"). | the subject turn, else `null` | `null` |
| `correct` | The speaker changes an earlier commitment, request or decision while keeping it alive: new date, smaller deliverable, different scope. Only the person who made the commitment, or the group for a decision, can correct it. | the corrected turn | speaker for a commitment, `null` for a decision |
| `withdraw` | The speaker retracts, without replacement, something they themself put forward: their own commitment, their own request (cancelling it), their own proposal. | the retracted turn | `null` |
| `challenge` | The speaker questions or suggests dropping someone else's commitment, request or decision without being entitled to drop it ("the survey is useless now, isn't it?", "we can skip the test, right?"). | the challenged turn | `null` |
| `quote` | The speaker reports another person's words, promise or intention, or states that another person (present or absent) will do something. The quoted person does not commit by being quoted. | the quoted person's own earlier turn if any, else `null` | the quoted or designated person |
| `obligation` | The speaker states that something has to be done without anyone taking it on ("it will have to be declared", "we need someone to..."). | `null` | `null` |
| `question` | The speaker asks an open question that is not a request for someone to act ("where are we on the menu?", "has it been approved?"). | the turn it asks about, else `null` | `null` |

## Rules

1. Several acts per turn are normal: "I withdraw my proposal; we keep only an internal pilot" is `withdraw` plus `propose` or `decide`; "Not tote bags; I'd rather offer a trial" is `decline` plus `propose`; "Yes, I'll take them over; I'll post them Friday" is one `accept`.
2. A first-person sentence inside reported speech is a `quote`, never a `commit` of the speaker or of the quoted person.
3. The same voice is not the same act. "We will meet next week to finish", an agenda wish, a personal habit, or a fact said by the person who later owns a task are not commitments.
4. A collective "we will do X" is `decide` when the group settles it, `propose` when it is put forward, and nothing personal for any speaker.
5. A refusal does not need a fixed phrase. Judge the meaning: hedging, conditions that are not met, "not now", or redirecting the request are `decline` or `tentative`, never `accept`.
6. When an owner keeps their commitment after a `challenge` ("No, I'm keeping it"), label that turn `correct` only if something changes; otherwise label it `commit` with the challenged commitment as `target`.
7. An unidentified voice can `commit`; its `agent` is `null` because the speaker is unknown.
8. A recap that restates earlier decisions and tasks adds no act unless it changes something.
9. Mark a genuinely ambiguous act with `"optional": true`. Optional acts are neither counted as missed nor as false when predicted. Use this sparingly and explain it in `note`.

## Gold file format

`<case>.acts.json`:

```json
{
  "schema": "hwyd-acts-gold/1",
  "recording": "benchmarks/summary/ledger/dev/d1-trade-fair-booth-fr.json",
  "participants": ["Hélène", "Bastien", "Mehdi"],
  "turns": {
    "S4": [{"act": "request", "target": null, "agent": "Bastien"}],
    "S5": [{"act": "decline", "target": "S4", "agent": null}, {"act": "defer", "target": "S4", "agent": null, "optional": true, "note": "'We'll talk about it again'"}]
  }
}
```

Turns are numbered `S1` to `Sn` in segment order. Turns without acts are omitted.
