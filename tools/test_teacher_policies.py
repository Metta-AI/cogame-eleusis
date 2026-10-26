"""Exercise explicit teachers through complete native games and unchanged default play."""

import argparse
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary")
parser.add_argument("--reference")
args = parser.parse_args()
manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"


def episode(binary, profile, probes=True):
    process = subprocess.Popen(
        [binary, str(manifest), "standard", "text"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    )
    trace = []

    def request(payload):
        process.stdin.write(json.dumps(payload) + "\n")
        process.stdin.flush()
        line = process.stdout.readline()
        assert line, "native bridge exited unexpectedly"
        return json.loads(line)

    try:
        observation = request(
            {"kind": "reset", "seed": "teacher-profile-system", "players": 5}
        )
        decisions = 0
        while observation["kind"] == "decision":
            default = request({"kind": "teacher"})
            trace.append((observation, default))
            seat = observation["seat"]
            expected = "openbook" if seat % 2 == 0 else "hoarder"
            if probes:
                before = request({"kind": "encode"})
                for invalid in ["unknown", "", 0, None, {}]:
                    assert (
                        request({"kind": "teacher", "policy": invalid})["kind"]
                        == "error"
                    )
                for policy in ["openbook", "hoarder", "freerider"]:
                    reply = request({"kind": "teacher", "policy": policy})
                    assert (
                        reply["policy"] == policy
                        and reply["decision_id"] == observation["decision_id"]
                    )
                    action = json.loads(reply["response"])
                    assert action["publish"] is (policy == "openbook")
                    if policy == "freerider" and "experiment" in action:
                        assert action["experiment"] == ""
                    if policy == expected:
                        assert reply["response"] == default["response"]
                assert request({"kind": "encode"}) == before
                assert request({"kind": "teacher"}) == default
            chosen = (
                default
                if profile == "mixed"
                else request({"kind": "teacher", "policy": profile})
            )
            result = request(
                {
                    "kind": "step",
                    "decision_id": observation["decision_id"],
                    "response": chosen["response"],
                }
            )
            assert result["kind"] == "accepted", result
            observation = result["observation"]
            decisions += 1
        assert decisions == 140
        assert set(observation["scores"]) == set(map(str, range(5)))
        trace.append(observation)
        print(profile, decisions, "accepted decisions", observation["scores"])
        return trace
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        process.stdout.close()


baseline = episode(args.binary, "mixed")
if args.reference:
    assert baseline == episode(args.reference, "mixed", probes=False)
for profile in ["openbook", "hoarder", "freerider"]:
    episode(args.binary, profile)
