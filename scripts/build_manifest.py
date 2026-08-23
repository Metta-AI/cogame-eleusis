#!/usr/bin/env python3
"""Regenerates coworld_manifest_template.json.

The manifest is long (a real JSON Schema, both protocol texts, and the docs
pages the coworld page renders), and every variant plus the certification
fixture has to agree on num_agents. Keeping the source here means the seat
count, the economy constants and the catalogue table are written once.

    python3 scripts/build_manifest.py
"""

import json
import os

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
IMAGE = "{{ELEUSIS_IMAGE}}"
SOURCE_URL = "https://github.com/Metta-AI/cogame-eleusis/tree/main"
SEATS = 5

CATALOGUE = """| # | kind | parameters | instances | PASS iff |
|---|---|---|---|---|
| 1 | CONTAINS c | c | 4 | colour c appears at least once |
| 2 | AT-LEAST-2 c | c | 4 | colour c appears 2 or more times |
| 3 | PARITY c even/odd | c, even or odd | 8 | the count of c is even (0 counts as even) / odd |
| 4 | ADJACENT c d | c, d (all 16 ordered pairs, c = d allowed) | 16 | some position i in 1..3 has t[i] = c and t[i+1] = d |
| 5 | BEFORE c d | c, d (c != d) | 12 | both appear and the first c is left of the first d |
| 6 | STARTS c | c | 4 | t[1] = c |
| 7 | ENDS c | c | 4 | t[4] = c |
| 8 | ENDS-SAME / ENDS-DIFFER | same or differ | 2 | t[1] = t[4] / t[1] != t[4] |
| 9 | NO-REPEAT / HAS-REPEAT | none or some | 2 | no two adjacent tokens are equal / at least one pair is |
| 10 | MORE c d | c, d (c != d) | 12 | count(c) > count(d) |

68 instances in all, ruleId 0..67, enumerated template by template and, inside
a template, over its parameter grid in the order written; colours iterate
R, B, G, Y."""

RULES_MD = f"""# Eleusis rules

Five cogs share one sealed machine. The machine holds ONE hidden rule over
STRIPS: ordered sequences of exactly 4 coloured tokens, each R (red), B
(blue), G (green) or Y (yellow), written as 4 letters, e.g. `RBGY`. The strip
universe is 4^4 = 256, enumerated lexicographically over R < B < G < Y
(index 0 = RRRR, index 255 = YYYY). Feed the machine a strip and it stamps
PASS (the strip obeys the rule) or FAIL.

## The hypothesis space is public; the instance is not

The rule is drawn from this catalogue, which is printed in every seat's
prompt. That is what makes the game a search rather than a guess.

{CATALOGUE}

Selection is seeded and deterministic, and skips degenerate instances: the
chosen rule's PASS fraction over all 256 strips always lies in [0.10, 0.90].

## Resolution order — research round r

1. **Open the round.** The sim emits a `round` event and marks all five seats
   pending. Each seat's observation is composed from the state at this
   instant.
2. **Collect decisions.** All five seats' requests go out as ONE parallel LLM
   batch. A reply is `{{"experiment", "publish", "hypothesis", "notes"}}`. A
   reply that times out, fails to parse, or is illegal is retried once with a
   hint, then replaced by the `openbook` scripted decision for that seat.
3. **Disclosure of the pending result**, per seat in seat order. Disclosure is
   pipelined by one turn — you pay, you look at your private verdict, and you
   decide what to do with it on your NEXT turn, by which time the corkboard
   has moved:
   - no pending result: `publish` is ignored and nothing is recorded;
   - `publish` true and the strip is NOT already on the corkboard: the fact
     (strip, verdict, author, round) is pinned and the seat becomes its sole
     author (`disclose` with mode `publish`);
   - `publish` true and the strip IS already on the corkboard: recorded as a
     confirmation with no authorship and no credit ever (mode `duplicate`);
   - `publish` false: the result goes to the seat's private drawer, which
     only spectators can see (mode `hoard`).
4. **Experiments**, per seat in seat order. `experiment` is a strip or "":
   - "" — nothing is charged (`skip`);
   - a legal strip — the seat is charged `experimentCost`, the machine is
     consulted, the strip joins the episode's used-strip set (which
     prediction tests hold out), and the result becomes the seat's pending
     result. The verdict is private to that seat.
5. **Advance.** If `round % testEvery == 0`, or the round was the last, the
   next turn is a prediction test; otherwise the next research round opens.

## Resolution order — prediction test k

6. **Draw the test.** `testStrips` strips that no experiment has ever touched
   and no earlier test has used, balanced: half from the rule's PASS set and
   half from its FAIL set, then shuffled. Balance removes the base-rate
   exploit — answering all FAIL scores exactly 50%.
7. **Collect answers.** One parallel batch; the reply is
   `{{"answers", "publish", "hypothesis", "notes"}}`. Step 3's disclosure runs
   first (so the last research round's result always gets a decision), then
   the answers are scored. `answers` must be exactly `testStrips` entries of
   PASS/FAIL.
8. **Knowledge pool.** Seat j earns `knowledgePool * c_j / sum(c)`. This is
   the rivalrous half: every rival you teach takes a slice of your pool.
9. **Citation settlement.** See economy.md.
10. **Advance.** After the test following the final research round the
    episode settles `complete`.

## What a seat sees

Its own alias and seat index, the round and the schedule, the full catalogue,
the economy constants, its own experiment log (strip, verdict, and whether it
published, hoarded or duplicated it), the whole corkboard, the public
scoreboard including every seat's latest stated hypothesis, the per-test
correct counts of every seat, and its own private notes fed back verbatim.

Hidden from every seat: the rule, every other seat's hoarded results and
notes, other seats' choices for the current turn, and the test truth before
settlement. Those are spectator-only — they ride in the replay and on
`/global`, never on a player socket.

## Endings

`complete` (the test after the final research round settled) or `deadline`
(the play clock stopped the episode between batches; an unfinished test is
discarded unscored and the tests already settled keep their money). No other
`results.reason` is legal."""

ECONOMY_MD = """# Eleusis economy

```
score(seat) = knowledge(seat) + credit(seat) - experimentCost x experiments(seat)
```

Higher is better, and a score may be negative: a seat that runs 24
experiments and never answers a test correctly finishes at -24. The league
ranks by mean episode score.

## Knowledge — the rivalrous half

At each prediction test, seat j with c_j correct answers earns
`knowledgePool * c_j / sum(c)` (default pool $20.00 over 6 strips). Nobody
correct pays nobody. Because it is a share, every rival you teach takes a
slice of your own pool — which is exactly why publishing is not free.

## Citation credit — the cooperative half

For each test strip x and each seat j that answered x CORRECTLY, let A(x, j)
be the set of seats a != j that authored a corkboard fact whose strip is at
Hamming distance exactly 1 from x (it differs in exactly one of the four
positions) and that was published BEFORE this test opened. If A(x, j) is
non-empty, a pot of `citePot` (default $0.50) is split equally among its
members. An author is paid at most once per (strip, confirmer) however many
of its facts support x.

**Citation rings do not pay.** Credit accrues only for a published result
that a DIFFERENT seat's passing prediction later confirms, on a strip nobody
has ever tested. Self-citation is impossible by construction, a duplicate
publication has no author, and no arrangement between seats can manufacture a
correct prediction about a strip the machine has never been shown.

## The tuned ratio

With the defaults (experimentCost 1.0, knowledgePool 20.0, citePot 0.5,
testStrips 6, five seats, four tests):

- teaching one rival one extra correct answer costs you roughly
  `20/sum(c) - 20*c_you/sum(c)^2` — about $0.6 to $1.0 of pool share per test;
- one well-placed publication sits one token away from up to 12 strips,
  realistically supports one or two of the six test strips, is confirmed by
  two to four rivals, and pays `0.5 x confirmers / authors` — about $0.5 to
  $2.0 per test.

So publishing pays precisely when your result is informative to others AND
near the frontier. The knife edge is configuration, not code: the
`open-science` variant raises citePot to $1.50 and the `closed-shop` variant
drops it to $0.10, so the league can watch the behaviour flip."""

DESCRIPTION = (
    "Eleusis: science as a game, for five LLM-piloted cogs. A sealed machine "
    "holds ONE hidden rule over STRIPS of four coloured tokens (R, B, G, Y) - "
    "one entry of a 68-instance catalogue that every seat can read, so the "
    "game is a search rather than a guess. Each round every seat pays $1.00 "
    "to feed the machine one strip and sees the PASS/FAIL verdict PRIVATELY; "
    "on its next turn it decides whether to PUBLISH the result to a shared "
    "corkboard (every rival reads it, and the author can earn citation "
    "credit) or HOARD it in a drawer only spectators can see. Every 6 rounds "
    "a PREDICTION TEST scores everyone on strips nobody has ever tested, "
    "exactly half of which pass: a $20 prize pool is split in proportion to "
    "correct answers, so every rival you teach takes a slice of your pool. "
    "Citation credit pays the other way - when a rival answers a test strip "
    "correctly and one of your published results differs from that strip in "
    "exactly one token, a $0.50 pot is shared between the authors whose "
    "results do. Score is prize money + citation credit - $1.00 per "
    "experiment; higher wins, and a seat that only spends finishes negative. "
    "Citation rings cannot pay: credit needs a rival to be actually right "
    "about a strip nobody has tested. The game is LLM-driven - every turn the "
    "server sends each seat's policy prompt plus its own log, the corkboard, "
    "the scoreboard and its private notes to Claude as ONE parallel batch, so "
    "A POLICY IS JUST A PROMPT: build one by reusing the published player "
    "runnable with PLAYER_PROMPT set to your strategy. Two scripted baselines "
    "(openbook publishes everything, hoarder publishes nothing) play any seat "
    "that registers as scripted - and every seat when no LLM credentials are "
    "available, so episodes always complete."
)

README = (
    "Eleusis is the induction game (Eleusis/Zendo) for five LLM-piloted cogs. "
    "A sealed machine holds one hidden rule over 4-token colour strips, drawn "
    "from a 68-instance catalogue that every seat can read. Each round a seat "
    "pays $1.00 to test one strip and sees the verdict privately; on its next "
    "turn it publishes the result to the shared corkboard or hoards it. Every "
    "6 rounds a prediction test on strips nobody has tested splits a $20 pool "
    "by correct answers, and citation credit pays authors whose published "
    "results sit one token away from a strip a RIVAL got right. Score = "
    "prizes + credit - $1.00 per experiment; higher wins. Publish and you arm "
    "your rivals for the pool; hoard and you earn no citations. A policy is "
    "just a prompt: field one by reusing the published eleusis-player "
    "runnable with the PLAYER_PROMPT environment variable set to your "
    "strategy. With no LLM credentials (or for seats that register scripted) "
    "the server plays the openbook or hoarder baseline, so episodes always "
    "complete."
)

PLAYER_PROTOCOL = (
    "eleusis.player.v1 - JSON text frames over the websocket named by "
    "COWORLD_PLAYER_WS_URL (already carrying ?slot=N&token=T). An Eleusis "
    "policy is a prompt: the player container's only job is to deliver it; "
    "the game server makes every decision by sending that prompt plus the "
    "seat's own experiment log, the corkboard, the scoreboard, the test "
    "results and its private notes to Claude once a turn, all five seats as "
    "one parallel batch. game->player frames: "
    "{\"type\":\"welcome\",\"protocol\":\"eleusis.player.v1\",\"slot\":N,"
    "\"name\":str,\"rounds\":int,\"testEvery\":int} on connect; "
    "{\"type\":\"state\",\"slot\":N,\"name\":str,\"round\":int,"
    "\"rounds\":int,\"phase\":\"research|test|done\",\"score\":float,"
    "\"knowledge\":float,\"credit\":float,\"spend\":float,"
    "\"experiments\":int,\"published\":int,\"hoarded\":int,\"correct\":int,"
    "\"answered\":int,\"pending\":{\"strip\":str,\"verdict\":\"pass|fail\"}"
    "|null,\"boardSize\":int,\"started\":bool,\"done\":bool,\"reason\":str} "
    "after every event - REDACTED to the seat's own numbers, because the game "
    "is hidden-information: it never carries the rule, the test truth, "
    "another seat's drawer or another seat's notes (decisions are "
    "server-side, so the redaction loses the policy nothing); "
    "{\"type\":\"final\",\"done\":true,\"scores\":[5],\"names\":[5 aliases],"
    "\"rule\":str,\"closest\":int,\"reason\":str} at episode end, after which "
    "the player should exit. player->game frames: "
    "{\"type\":\"prompt\",\"prompt\":str,\"scripted\":str} - the prompt (max "
    "4000 runes) is the policy, sent right after connecting and again after "
    "welcome; scripted \"openbook\" (or \"1\") plays the built-in "
    "publish-everything baseline for that seat, \"hoarder\" the "
    "publish-nothing one, \"\" means LLM-driven. The reference player reads "
    "PLAYER_PROMPT and PLAYER_SCRIPTED from its environment."
)

GLOBAL_PROTOCOL = (
    "Global spectators connect a websocket to /global and receive the full "
    "bench snapshot as JSON after every event: "
    "{\"type\":\"state\",\"game\":\"eleusis\",\"seats\":[{name,score,"
    "knowledge,credit,spend,experiments,published,hoarded,correct,answered,"
    "hypothesis,notes,pending,last:{strip,verdict,mode}|null,"
    "secrets:[{strip,verdict,round}]} x5 by seat],\"board\":[{strip,verdict,"
    "author,round,cites,duplicate} in publication order],\"machine\":{seat,"
    "round,strip,verdict}|null,\"test\":{index,round,strips,truth,answers,"
    "correct,open,discarded}|null,\"citations\":[{author,by,strip,amount,test}],"
    "\"decided\":int,\"round\":int,\"rounds\":int,\"testEvery\":int,"
    "\"testStrips\":int,\"testsDone\":int,\"experimentCost\":float,"
    "\"knowledgePool\":float,\"citePot\":float,\"phase\":\"research|test|"
    "done\",\"rule\":str,\"ruleId\":int,\"closest\":int,\"gameDone\":bool,"
    "\"reason\":str,\"policyNames\":[...],\"events\":[{kind:start|round|"
    "experiment|skip|disclose|test|answer|settle|end,...}],\"started\":bool,"
    "\"done\":bool,\"connected\":[bool]}. The hidden rule (`rule`, `ruleId`), "
    "the test `truth` and every seat's `secrets` and `notes` are "
    "SPECTATOR-ONLY: they appear here and in the replay, never on a player "
    "socket. The events array is append-only and carries the complete "
    "transcript. The browser page at /client/global renders the lab bench; "
    "/client/replay plays a recorded episode; the static replay viewer bundle "
    "renders replays hosted by the platform (index.html?replay=<url>)."
)


def seat_array(description, item):
    return {
        "description": description,
        "type": "array",
        "minItems": SEATS,
        "maxItems": SEATS,
        "items": item,
    }


CONFIG_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "required": ["tokens", "players"],
    "properties": {
        "tokens": seat_array(
            "One connection token per player slot, indexed by slot. Injected by "
            "the commissioner at dispatch, which is why no variant and no "
            "certification fixture carries it -- the Coworld schema still "
            "requires it to be declared required here, and the game refuses to "
            "start if it arrives with a different length than players.",
            {"type": "string", "minLength": 1},
        ),
        "players": seat_array(
            "One player display-name object per seat, indexed by slot.",
            {
                "type": "object",
                "additionalProperties": False,
                "required": ["name"],
                "properties": {"name": {"type": "string", "minLength": 1}},
            },
        ),
        "num_agents": {
            "description": (
                "Seat count; injected by the commissioner. Eleusis is a "
                "five-player game: citation credit needs an author, a "
                "confirmer and a market."
            ),
            "type": "integer",
            "minimum": SEATS,
            "maximum": SEATS,
        },
        "seed": {
            "description": (
                "Pins the hidden rule, every prediction-test draw and the "
                "seat aliases. Omit for a fresh random seed per episode."
            ),
            "type": "integer",
        },
        "rounds": {
            "description": (
                "Research rounds in the episode. Every seat decides every "
                "round, simultaneously."
            ),
            "type": "integer",
            "minimum": 4,
            "maximum": 60,
            "default": 24,
        },
        "testEvery": {
            "description": "A prediction test after every N research rounds.",
            "type": "integer",
            "minimum": 2,
            "maximum": 20,
            "default": 6,
        },
        "testStrips": {
            "description": (
                "Strips per prediction test, half PASS and half FAIL. Must be "
                "even."
            ),
            "type": "integer",
            "minimum": 2,
            "maximum": 12,
            "default": 6,
        },
        "experimentCost": {
            "description": "Charged against score for every experiment run.",
            "type": "number",
            "minimum": 0,
            "maximum": 10,
            "default": 1.0,
        },
        "knowledgePool": {
            "description": (
                "Prize money each prediction test splits in proportion to "
                "correct answers."
            ),
            "type": "number",
            "minimum": 0,
            "maximum": 200,
            "default": 20.0,
        },
        "citePot": {
            "description": (
                "Per test strip, shared equally by the rival authors whose "
                "published results sit one token away from it."
            ),
            "type": "number",
            "minimum": 0,
            "maximum": 10,
            "default": 0.5,
        },
        "episodeTimeoutSeconds": {
            "description": (
                "Wall-clock the game assumes the platform allows an episode "
                "when COWORLD_TIMEOUT_SECONDS is not in its environment; play "
                "stops between batches at 60% of it so results and the replay "
                "always land."
            ),
            "type": "integer",
            "minimum": 60,
            "maximum": 6000,
            "default": 1200,
        },
        "minBatchSpacingMs": {
            "description": (
                "Wall-clock floor between the STARTS of consecutive LLM "
                "batches. 12s at five seats is 25 requests/minute, under the "
                "hosted Bedrock sidecar's 30/minute per-episode cap."
            ),
            "type": "integer",
            "minimum": 0,
            "maximum": 60000,
            "default": 12000,
        },
        "turnDelayMs": {
            "description": "Extra spectator pacing delay between turns.",
            "type": "integer",
            "minimum": 0,
            "maximum": 10000,
            "default": 0,
        },
        "model": {
            "description": "Claude model that drives every seat.",
            "type": "string",
            "default": "claude-sonnet-5",
        },
        "maxOutputTokens": {
            "type": "integer",
            "minimum": 64,
            "maximum": 2000,
            "default": 900,
        },
        "llmTimeoutSeconds": {
            "type": "integer",
            "minimum": 5,
            "maximum": 300,
            "default": 40,
        },
        "player_connect_timeout_seconds": {
            "type": "number",
            "minimum": 0,
            "default": 180,
        },
    },
}

RESULTS_SCHEMA = {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "type": "object",
    "additionalProperties": False,
    "required": [
        "names", "scores", "knowledge", "credit", "spend", "correct",
        "answered", "accuracy", "published", "hoarded", "rounds", "maxRounds",
        "tests", "ruleId", "rule", "closest", "closestName", "reason",
    ],
    "properties": {
        "names": seat_array(
            "Policy display names, indexed by slot. Seats play under "
            "anonymous cog aliases in-game; results attribute by policy name.",
            {"type": "string"},
        ),
        "scores": seat_array(
            "prizes + citation credit - experimentCost x experiments. Higher "
            "is better and a score may be negative.",
            {"type": "number"},
        ),
        "knowledge": seat_array(
            "Prize money won from the prediction tests.",
            {"type": "number", "minimum": 0},
        ),
        "credit": seat_array(
            "Citation credit earned by published results.",
            {"type": "number", "minimum": 0},
        ),
        "spend": seat_array(
            "Total experiment cost charged.",
            {"type": "number", "minimum": 0},
        ),
        "correct": seat_array(
            "Correct predictions over every settled test.",
            {"type": "integer", "minimum": 0},
        ),
        "answered": seat_array(
            "Predictions answered over every settled test.",
            {"type": "integer", "minimum": 0},
        ),
        "accuracy": seat_array(
            "correct / answered, or 0 when the seat answered nothing.",
            {"type": "number", "minimum": 0, "maximum": 1},
        ),
        "published": seat_array(
            "Results pinned to the corkboard with authorship.",
            {"type": "integer", "minimum": 0},
        ),
        "hoarded": seat_array(
            "Results kept in the seat's private drawer.",
            {"type": "integer", "minimum": 0},
        ),
        "rounds": {
            "description": "Research rounds actually played.",
            "type": "integer",
            "minimum": 0,
        },
        "maxRounds": {
            "description": "The episode's round count after budget fitting.",
            "type": "integer",
            "minimum": 4,
        },
        "tests": {
            "description": "Prediction tests settled.",
            "type": "integer",
            "minimum": 0,
        },
        "ruleId": {
            "description": "The hidden rule's catalogue index, 0..67.",
            "type": "integer",
            "minimum": 0,
            "maximum": 67,
        },
        "rule": {
            "description": "The hidden rule in words, revealed on the endcard.",
            "type": "string",
        },
        "closest": {
            "description": (
                "The seat with the best lifetime test accuracy, or -1 when no "
                "test was scored."
            ),
            "type": "integer",
            "minimum": -1,
            "maximum": SEATS - 1,
        },
        "closestName": {
            "description": "That seat's policy name, or \"\".",
            "type": "string",
        },
        "reason": {
            "description": (
                "How the episode ended: complete (the test after the final "
                "round settled) or deadline (the play clock stopped it "
                "between batches; settled tests keep their money)."
            ),
            "type": "string",
            "enum": ["complete", "deadline"],
        },
    },
}

STANDARD_CONFIG = {
    "players": [{"name": f"Player{index + 1}"} for index in range(SEATS)],
    "num_agents": SEATS,
    "rounds": 24,
    "testEvery": 6,
    "testStrips": 6,
    "experimentCost": 1.0,
    "knowledgePool": 20.0,
    "citePot": 0.5,
    "minBatchSpacingMs": 12000,
    "player_connect_timeout_seconds": 180,
}


def variant(vid, name, description, cite_pot):
    config = dict(STANDARD_CONFIG)
    config["citePot"] = cite_pot
    return {
        "id": vid,
        "name": name,
        "description": description,
        "game_config": config,
    }


def player(pid, name, description, env=None):
    entry = {
        "id": pid,
        "name": name,
        "type": "player",
        "description": description,
        "image": IMAGE,
        "run": ["/bin/eleusis-player"],
    }
    if env:
        entry["env"] = env
    entry["resources"] = {
        "requests": {"cpu": "100m", "memory": "64Mi"},
        "limits": {"cpu": "1"},
    }
    entry["source_url"] = SOURCE_URL
    return entry


MANIFEST = {
    "$schema": (
        "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/"
        "coworld_manifest_schema.json"
    ),
    "tags": [
        "science",
        "hypothesis-discovery",
        "mixed-motive",
        "llm-driven",
        "turn-based",
        "five-player",
        "epistemics",
        "publish-or-hoard",
    ],
    "episode_timeout_minutes": 20,
    "game": {
        "name": "eleusis",
        "replay_viewer": {"bundle": "static-replay-viewer"},
        "description": DESCRIPTION,
        "owner": "daveey@gmail.com",
        "runnable": {
            "type": "game",
            "image": IMAGE,
            "run": ["/bin/eleusis"],
            "env": {
                "ANTHROPIC_API_KEY_URI": (
                    "secret://coworld/eleusis/anthropic_api_key"
                )
            },
            "source_url": SOURCE_URL,
        },
        "config_schema": CONFIG_SCHEMA,
        "results_schema": RESULTS_SCHEMA,
        "protocols": {
            "player": {"type": "text", "value": PLAYER_PROTOCOL},
            "global": {"type": "text", "value": GLOBAL_PROTOCOL},
        },
        "docs": {
            "readme": {"type": "text", "value": README},
            "pages": [
                {
                    "id": "rules.md",
                    "title": "rules.md",
                    "content": {"type": "text", "value": RULES_MD},
                },
                {
                    "id": "economy.md",
                    "title": "economy.md",
                    "content": {"type": "text", "value": ECONOMY_MD},
                },
            ],
        },
    },
    "player": [
        player(
            "eleusis-player",
            "Eleusis Prompt Player",
            "The reference Eleusis policy: delivers its PLAYER_PROMPT (or a "
            "default version-space strategy in words) to the game and "
            "spectates until the final frame. Field your own policy by "
            "uploading this same image with a different PLAYER_PROMPT.",
        ),
        player(
            "eleusis-openbook",
            "Eleusis Open-Book Baseline",
            "The scripted open-science baseline: keeps the version space of "
            "catalogue entries consistent with every fact it knows, spends on "
            "the strip that splits that space closest to in half, and "
            "PUBLISHES every result it holds. No LLM.",
            env={"PLAYER_SCRIPTED": "openbook"},
        ),
        player(
            "eleusis-hoarder",
            "Eleusis Hoarder Baseline",
            "The same version-space engine with the opposite disclosure "
            "policy: it reads the corkboard but never publishes anything of "
            "its own, so it earns no citation credit and teaches no rival. "
            "The control experiment for the publish-or-hoard dilemma.",
            env={"PLAYER_SCRIPTED": "hoarder"},
        ),
    ],
    "variants": [
        variant(
            "standard",
            "Standard laboratory",
            "Five cogs, 24 rounds, a prediction test every 6, citation pot "
            "$0.50.",
            0.5,
        ),
        variant(
            "open-science",
            "Open science",
            "Citation credit tripled to $1.50: publishing should dominate.",
            1.5,
        ),
        variant(
            "closed-shop",
            "Closed shop",
            "Citation credit cut to $0.10: hoarding should dominate.",
            0.1,
        ),
    ],
    "certification": {
        "game_config": {
            "players": [
                {"name": "Sprocket"},
                {"name": "Gizmo"},
                {"name": "Ratchet"},
                {"name": "Widget"},
                {"name": "Bolt"},
            ],
            "num_agents": SEATS,
            "seed": 11,
            "rounds": 6,
            "testEvery": 3,
            "testStrips": 6,
            "turnDelayMs": 0,
            "minBatchSpacingMs": 0,
            "player_connect_timeout_seconds": 180,
        },
        # EVERY declared player runnable occupies at least one slot: a fixture
        # that seats only baselines fails certification's players-run check
        # with players_missing (raid 0.1.2 -> 0.1.3, 2026-08-23).
        "players": [
            {"player_id": "eleusis-player"},
            {"player_id": "eleusis-openbook"},
            {"player_id": "eleusis-player"},
            {"player_id": "eleusis-hoarder"},
            {"player_id": "eleusis-player"},
        ],
    },
}


def main():
    out = os.path.join(REPO, "coworld_manifest_template.json")
    with open(out, "w", encoding="utf-8") as handle:
        json.dump(MANIFEST, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
