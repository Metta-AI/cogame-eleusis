"""Play every certified Eleusis variant through the numeric bridge."""

import json
import random
import subprocess
import sys
from pathlib import Path


def play(binary: Path, variant: str, teacher: bool) -> None:
    manifest = Path(__file__).resolve().parent.parent / "coworld_manifest_template.json"
    process = subprocess.Popen(
        [str(binary), str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert process.stdin is not None and process.stdout is not None
    rng = random.Random(17)

    def request(payload: dict) -> dict:
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    try:
        observation = request({"kind": "reset", "seed": f"eleusis-{variant}-{teacher}", "players": 5})
        widths = set()
        phases = set()
        batch_board = None
        batch_strips = None
        decisions = 0
        while observation["kind"] == "decision":
            encoding = request({"kind": "encode"})
            widths.add(len(encoding["values"]))
            assert encoding["decision_id"] == observation["decision_id"]
            heads = encoding["action_heads"]
            assert [head["name"] for head in heads] == [
                "publish", "experiment", *(f"answer{i}" for i in range(6))
            ]
            assert [len(head["choices"]) for head in heads] == [2, 257, 2, 2, 2, 2, 2, 2]
            for head in heads:
                assert observation["action_schema"]["properties"][head["name"]]["enum"] == [
                    choice for choice in head["choices"] if choice is not None
                ]
            view = observation["semantic_view"]
            phases.add(view["phase"])
            assert "truth" not in view and "rule" not in view
            if observation["seat"] == 0:
                batch_board = view["board"]
                batch_strips = view["test_strips"]
            else:
                assert view["board"] == batch_board
                assert view["test_strips"] == batch_strips
            if teacher:
                action = json.loads(request({"kind": "teacher"})["response"])
            else:
                action = {
                    head["name"]: rng.choice([choice for choice in head["choices"] if choice is not None])
                    for head in heads
                }
            assert all(action[head["name"]] in head["choices"] for head in heads)
            result = request(
                {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
            assert decisions <= 300
        assert observation["kind"] == "terminal"
        assert set(observation["scores"]) == {"0", "1", "2", "3", "4"}
        assert phases == {"research", "test"}
        assert len(widths) == 1
        print(variant, "teacher" if teacher else "random", decisions, widths.pop(), "features")
    finally:
        process.stdin.close()
        process.stdout.close()
        assert process.wait(timeout=5) == 0


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    for variant in ("standard", "open-science", "closed-shop"):
        for teacher in (True, False):
            play(binary, variant, teacher)
