"""Complete published Eleusis games with matched wording and simultaneous private views."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = Path(sys.argv[1]).resolve()
ORIGINAL = Path(sys.argv[2]).resolve()
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(
    variant, seed, wording="canonical", prompt_seed=0, normalize=False, original=False
):
    command = [
        str(ORIGINAL if original else BRIDGE),
        str(ROOT / "coworld_manifest_template.json"),
        variant,
    ]
    if not original:
        command.append("text")
    with subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "players": 5,
                "seed": seed,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test",
            }
        )
        trace, systems, phases = [], {}, set()
        batch_public = None
        while observation["kind"] == "decision":
            seat = observation["seat"]
            assert seat == len(trace) % 5 and observation["decision_id"] == len(trace)
            view = observation["semantic_view"].copy()
            testing = view["phase"] == "test"
            phases.add(view["phase"])
            messages = observation["messages"]
            assert not (
                {"truth", "rule", "ruleId", "ruleText", "seed", "secrets"} & set(view)
            )
            assert all(
                not ({"log", "pending", "notes", "secrets", "answers"} & set(other))
                for other in view["seats"]
            )
            public = (view["board"], view["seats"], view["test_strips"])
            if seat == 0:
                batch_public = public
            else:
                assert public == batch_public
            if not original:
                metadata = view.pop("prompt_template")
                selected = WORDINGS[prompt_seed] if wording == "mixed" else wording
                assert (metadata["bank"], metadata["variant"]) == (
                    "eleusis-rules-v1",
                    selected,
                )
                for message in messages:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                if normalize:
                    marker = ("雪", "森", "海", "山", "月")[seat]
                    assert all(
                        other not in messages[1]["content"]
                        for other in ("雪", "森", "海", "山", "月")
                        if other != marker
                    )
                    if len(trace) >= 5:
                        assert view["notes"] == marker * 599 + "…"
                        for other in range(5):
                            assert (
                                view["seats"][other]["hypothesis"]
                                == f"public-{other}-" + "x" * 110 + "…"
                            )
            assert (
                systems.setdefault(seat, messages[0]["content"])
                == messages[0]["content"]
            )
            proposal = json.loads(request({"kind": "teacher"})["response"])
            if normalize:
                proposal["notes"] = marker * 650
                proposal["hypothesis"] = f"public-{seat}-" + "x" * 150
                proposal["publish"] = str(proposal["publish"]).lower()
                if testing:
                    proposal["answers"] = [
                        answer.upper() for answer in proposal["answers"]
                    ]
                else:
                    proposal["experiment"] = proposal["experiment"].lower()
            accepted = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": json.dumps(proposal),
                }
            )
            assert accepted["kind"] == "accepted"
            action = accepted["action"]
            if normalize:
                assert action["notes"] == marker * 599 + "…"
                assert action["hypothesis"] == f"public-{seat}-" + "x" * 110 + "…"
                assert isinstance(action["publish"], bool)
                if testing:
                    assert action["answers"] == [
                        answer.lower() for answer in proposal["answers"]
                    ]
                else:
                    assert action["experiment"] == proposal["experiment"].upper()
            else:
                assert action == proposal
            projection = {"publish": action["publish"]}
            if testing:
                projection["answers"] = (
                    [action[f"answer{i}"] for i in range(6)]
                    if original
                    else action["answers"]
                )
            else:
                projection["experiment"] = action["experiment"]
            trace.append((view, messages, projection))
            observation = accepted["observation"]
            assert len(trace) <= 300
        process.stdin.close()
        assert process.wait(timeout=30) == 0
        assert observation["kind"] == "terminal" and phases == {"research", "test"}
        assert len(trace) == 140 and set(observation["scores"]) == {
            str(seat) for seat in range(5)
        }
        return trace, observation, systems


for variant in ("standard", "open-science", "closed-shop"):
    for seed in ("17", "946001"):
        original, original_outcome, original_systems = play(
            variant, seed, original=True
        )
        canonical = None
        introductions, selected_systems = set(), {}
        for wording, prompt_seed in [
            *((name, 0) for name in WORDINGS),
            *(("mixed", i) for i in range(5)),
        ]:
            trace, outcome, systems = play(variant, seed, wording, prompt_seed)
            selected = WORDINGS[prompt_seed] if wording == "mixed" else wording
            assert selected_systems.setdefault(selected, systems) == systems
            introductions.add(systems[0].split("\n", 1)[0])
            stripped = [
                (view, messages[0]["content"].split("\n", 1)[1], messages[1], action)
                for view, messages, action in trace
            ]
            if canonical is None:
                canonical = stripped, outcome
                assert systems == original_systems and outcome == original_outcome
                for (view, _, action), (old_view, _, old_action) in zip(
                    trace, original, strict=True
                ):
                    comparable = json.loads(json.dumps(view))
                    comparable.pop("notes")
                    for other in comparable["seats"]:
                        other.pop("hypothesis")
                    assert comparable == old_view and action == old_action
            else:
                assert (stripped, outcome) == canonical
        assert len(introductions) == 7
        print(
            variant,
            seed,
            "12 full matched games and original numeric trajectory PASS",
            flush=True,
        )
    _, normalized_result, _ = play(variant, "17", normalize=True)
    _, baseline_result, _ = play(variant, "17", original=True)
    assert normalized_result == baseline_result
    for wording in WORDINGS[5:]:
        rejected = subprocess.run(
            [
                str(BRIDGE),
                str(ROOT / "coworld_manifest_template.json"),
                variant,
                "text",
            ],
            input=json.dumps(
                {
                    "kind": "reset",
                    "players": 5,
                    "seed": "17",
                    "promptVariant": wording,
                    "split": "train",
                }
            )
            + "\n",
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert rejected.returncode != 0 and "evaluation-only" in rejected.stderr
    print(
        variant,
        "complete private-note, simultaneous-hypothesis, and normalization game PASS",
        flush=True,
    )
