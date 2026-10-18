"""Export complete Eleusis games and verify frozen private views against applied events."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
OUTPUT = Path(tempfile.mkdtemp(prefix="eleusis-source-export-"))
revision = subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
).strip()
for variant in ("standard", "open-science", "closed-shop"):
    output = OUTPUT / variant
    subprocess.run(
        [str(EXPORTER), str(output), "10", "1", variant],
        cwd=ROOT,
        check=True,
        timeout=600,
    )
    manifest = json.loads((output / "manifest.json").read_text())
    assert manifest["source_revision"] == revision and len(manifest["runs"]) == 10
    assert (
        not (output / "train.jsonl").exists()
        and not (output / "validation.jsonl").exists()
    )
    episodes, decisions, executions = {}, {}, {}
    for filename in ("manifest.json", "trajectories.jsonl", "execution.jsonl"):
        assert (output / filename).stat().st_mode & 0o777 == 0o600
    with (output / "trajectories.jsonl").open() as stream:
        for line in stream:
            row = json.loads(line)
            assert row["source_revision"] == revision
            episode = row["episode_id"]
            if row["event_type"] == "episode":
                episodes[episode] = row
                continue
            decisions.setdefault(episode, []).append(row)
            assert row["visibility"] == "private" and row["action_status"] == "accepted"
            assert row["fallback_origin"] is None
            (attempt,) = row["attempts"]
            assert row["selected_attempt_id"] == attempt["attempt_id"]
            assert attempt["origin"] == "teacher" and attempt["request"] is None
            assert (
                attempt["platform_call_id"] is None
                and attempt["behavior_logprobs"] is None
            )
            assert (
                attempt["parsed_action"]
                == json.loads(attempt["response"])
                == row["executed_action"]
            )
            view = row["observation"]
            metadata = view["prompt_template"]
            assert (
                metadata["bank"] == "eleusis-rules-v1"
                and metadata["variant"] == "canonical"
            )
            assert row["prompt"] == attempt["prompt"]
            for message in row["prompt"]:
                assert (
                    metadata[message["role"] + "_sha256"].lower()
                    == hashlib.sha256(message["content"].encode()).hexdigest()
                )
            assert not (
                {"rule", "ruleId", "ruleText", "truth", "seed", "secrets"} & set(view)
            )
            assert all(
                not ({"log", "pending", "notes", "secrets", "answers"} & set(other))
                for other in view["seats"]
            )
    with (output / "execution.jsonl").open() as stream:
        for line in stream:
            row = json.loads(line)
            executions.setdefault(row["episode_id"], []).append(row)
            assert row["visibility"] == "private" and row["source_revision"] == revision
    assert len(episodes) == 10 and set(episodes) == set(decisions) == set(executions)
    for episode, outcome in episodes.items():
        rows, applied = decisions[episode], executions[episode]
        assert (
            outcome["status"] == "completed"
            and outcome["outcome"]["reason"] == "complete"
        )
        assert outcome["outcome"]["rounds"] == 24 and outcome["outcome"]["tests"] == 4
        assert len(rows) == len(applied) == 140
        assert sum(row["terminal"] for row in rows) == 1 and rows[-1]["terminal"]
        assert {row["observation"]["phase"] for row in rows} == {"research", "test"}
        batch_public = None
        last_event_end = applied[0]["event_start"]
        for index, (row, execution) in enumerate(zip(rows, applied, strict=True)):
            seat = index % 5
            assert row["decision_id"] == execution["decision_id"] == str(index)
            assert row["seat"] == str(seat) and execution["seat"] == seat
            assert execution["event_start"] == last_event_end
            assert execution["event_end"] - execution["event_start"] == len(
                execution["events"]
            )
            last_event_end = execution["event_end"]
            view, action = row["observation"], row["executed_action"]
            public = (view["board"], view["seats"], view["test_strips"])
            if seat == 0:
                batch_public = public
            else:
                assert public == batch_public
            assert (
                execution["phase"] == view["phase"]
                and execution["round"] == view["round"]
            )
            assert execution["stored_hypothesis"] == action["hypothesis"]
            assert execution["stored_notes"] == action["notes"] == ""
            events = [
                event
                for event in execution["events"]
                if event["kind"] in ("experiment", "skip", "answer")
            ]
            (event,) = events
            assert event["seat"] == seat and event["scripted"] and not event["fallback"]
            if view["phase"] == "test":
                assert (
                    event["kind"] == "answer" and event["answers"] == action["answers"]
                )
            else:
                assert (
                    event["kind"] == "experiment"
                    and event["strip"] == action["experiment"]
                )
            disclosures = [
                event for event in execution["events"] if event["kind"] == "disclose"
            ]
            if view["pending"] is None:
                assert not disclosures
            else:
                (disclosure,) = disclosures
                assert disclosure["strip"] == view["pending"]["strip"]
                assert disclosure["verdict"] == view["pending"]["verdict"]
                assert disclosure["mode"] in (
                    ("publish", "duplicate") if action["publish"] else ("hoard",)
                )
        for seat in range(5):
            assert (
                outcome["participant_outcomes"][str(seat)]["score"]
                == outcome["outcome"]["scores"][seat]
            )
    assert {row["seed_family"] for row in episodes.values()} == {
        f"eleusis-{seed}" for seed in range(1, 11)
    }
    print(
        variant,
        "10 complete exports; frozen observations, prompt hashes, applied events and outcomes PASS",
        flush=True,
    )
print("Evidence:", OUTPUT)
