"""Check complete seeded mixed-wording exports for all three published Eleusis variants."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VARIANTS = ("standard", "open-science", "closed-shop")

if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as temp:
        for variant in VARIANTS:
            output = Path(temp) / variant
            subprocess.run(
                [str(binary), str(output), "10", "1", variant, "mixed", "0"],
                cwd=ROOT,
                check=True,
            )
            manifest = json.loads((output / "manifest.json").read_text())
            assert len(manifest["runs"]) == 10
            assert [run["prompt_selection"]["variant"] for run in manifest["runs"]] == [
                "canonical",
                "plain",
                "numbered",
                "questions",
                "reordered",
            ] * 2
            assert all(
                run["decisions"] > 0
                and run["rounds_played"] > 0
                and len(run["scores"]) == 5
                for run in manifest["runs"]
            )
            families, counts, public_batches = {}, {}, {}
            for split in ("train", "validation"):
                rows = [
                    json.loads(line)
                    for line in (output / f"{split}.jsonl").read_text().splitlines()
                ]
                assert len(rows) == manifest[split + "_examples"] > 0
                families[split] = {row["seed"] for row in rows}
                for row in rows:
                    assert row["game"] == "eleusis"
                    assert [message["role"] for message in row["prompt"]] == [
                        "system",
                        "user",
                    ]
                    action = json.loads(row["completion"][0]["content"])
                    assert isinstance(action["publish"], bool)
                    assert (
                        len(action["notes"]) <= 600 and len(action["hypothesis"]) <= 120
                    )
                    if "answers" in action:
                        assert len(action["answers"]) == 6
                        assert set(action["answers"]) <= {"pass", "fail"}
                    else:
                        assert len(action["experiment"]) == 4
                        assert set(action["experiment"]) <= set("RBGY")
                    user = row["prompt"][1]["content"]
                    public = user.split("THE CORKBOARD", 1)[1].split(
                        "YOUR NOTES FROM EARLIER ROUNDS:", 1
                    )[0]
                    batch = (row["episode_id"], row["decision_id"] // 5)
                    assert public_batches.setdefault(batch, public) == public
                    assert row["prompt_template"]["variant"] not in (
                        "heldout-briefing",
                        "heldout-reference",
                    )
                    counts[row["seed"]] = counts.get(row["seed"], 0) + 1
            assert families["train"].isdisjoint(families["validation"])
            assert all(
                counts[f"eleusis-{run['seed']}"] == run["decisions"]
                for run in manifest["runs"]
            )
            print(variant, "10 complete mixed exports PASS", flush=True)
