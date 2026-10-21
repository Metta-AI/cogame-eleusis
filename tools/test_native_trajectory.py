"""Complete standard native games with exact local provider evidence; no paid calls."""

import hashlib
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME, PLAYER, OUTPUT = (Path(arg).resolve() for arg in sys.argv[1:4])
OUTPUT.mkdir(parents=True, exist_ok=False, mode=0o700)
for mode in ("accepted", "invalid", "provider-error", "scripted"):
    if (
        os.environ.get("ELEUSIS_FIXTURE_MODE")
        and mode != os.environ["ELEUSIS_FIXTURE_MODE"]
    ):
        continue
    calls = {}

    class Provider(http.server.BaseHTTPRequestHandler):
        def do_POST(self, mode=mode, calls=calls):
            assert self.path == "/v1/messages"
            request = json.loads(self.rfile.read(int(self.headers["content-length"])))
            seat = int(self.headers["X-Coworld-Player-Slot"])
            testing = request["messages"][0]["content"].startswith("PREDICTION TEST")
            action = {
                "publish": True,
                "hypothesis": "fixture",
                "notes": "private-fixture-notes",
            }
            action.update({"answers": ["PASS"] * 6} if testing else {"experiment": ""})
            text = "not JSON" if mode == "invalid" and seat == 0 else json.dumps(action)
            body = {
                "model": "fixture/served",
                "content": [{"type": "text", "text": text}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 10, "output_tokens": 5},
            }
            failure = mode == "provider-error" and seat == 0
            if failure:
                body = {"error": {"message": "fixture provider error"}}
            call_id = str(uuid.uuid4())
            raw = json.dumps(body)
            calls[call_id] = (request, raw)
            self.send_response(500 if failure else 200)
            self.send_header("content-type", "application/json")
            self.send_header("x-softmax-llm-call-id", call_id)
            self.send_header("content-length", str(len(raw.encode())))
            self.end_headers()
            self.wfile.write(raw.encode())

        def log_message(self, *_):
            pass

    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    owner = threading.Thread(target=provider.serve_forever)
    owner.start()
    output = OUTPUT / mode
    output.mkdir(mode=0o700)
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    config = {
        "tokens": [f"t{s}" for s in range(5)],
        "players": [{"name": f"p{s}"} for s in range(5)],
        "seed": 7,
        "rounds": 24,
        "testEvery": 6,
        "testStrips": 6,
        "promptVariant": "mixed",
        "promptSeed": 4,
        "minBatchSpacingMs": 0,
        "player_connect_timeout_seconds": 5,
        "llmTimeoutSeconds": 5,
    }
    (output / "config.json").write_text(json.dumps(config))
    env = {
        **os.environ,
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(port),
        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
        "COGAME_SAVE_TRAJECTORY_URI": (output / "trajectory.jsonl").as_uri(),
        "COWORLD_EPISODE_ID": str(uuid.uuid4()),
        "COWORLD_GAME_VERSION": "native-fixture",
        "COWORLD_SOURCE_REVISION": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{provider.server_port}",
        "COWORLD_LLM_MODEL": "fixture/requested",
        "PLAYER_PROMPT": "fixture strategy",
        "PLAYER_SCRIPTED": "openbook" if mode == "scripted" else "",
    }
    processes = []
    try:
        with (output / "game.log").open("w") as log:
            processes.append(
                subprocess.Popen([GAME], cwd=ROOT, env=env, stdout=log, stderr=log)
            )
            for _ in range(200):
                assert processes[0].poll() is None, (output / "game.log").read_text()
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.05)
            else:
                raise AssertionError("game failed to listen")
            for seat in range(5):
                player_env = {
                    **env,
                    "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                }
                processes.append(
                    subprocess.Popen(
                        [PLAYER], cwd=ROOT, env=player_env, stdout=log, stderr=log
                    )
                )
            for process in processes:
                assert process.wait(timeout=90) == 0, (output / "game.log").read_text()
        events = [
            json.loads(line)
            for line in (output / "trajectory.jsonl").read_text().splitlines()
        ]
        assert len(events) == 141 and events[-1]["status"] == "completed"
        assert (
            events[-1]["outcome"]["rounds"] == 24
            and events[-1]["outcome"]["tests"] == 4
        )
        for start in range(0, 140, 5):
            batch = events[start : start + 5]
            for key in ("board", "seats", "test_strips"):
                assert all(
                    event["observation"][key] == batch[0]["observation"][key]
                    for event in batch
                )
        joined = set()
        for event in events[:-1]:
            assert event["visibility"] == "private"
            assert (
                "rule" not in event["observation"]
                and "ruleId" not in event["observation"]
            )
            for attempt in event["attempts"]:
                if mode == "scripted":
                    assert (
                        attempt["origin"] == "teacher"
                        and attempt["policy"] == "openbook"
                    )
                    assert (
                        attempt["platform_call_id"] is None
                        and attempt["request"] is None
                    )
                    assert attempt["parsed_action"] == event["executed_action"]
                    continue
                call_id = attempt["platform_call_id"]
                request, raw = calls[call_id]
                joined.add(call_id)
                assert attempt["request"] == request and attempt["raw_response"] == raw
                assert attempt["decoder"] == {"max_tokens": request["max_tokens"]}
                metadata = next(
                    item["prompt_template"]
                    for item in event["observation"]["prompt_attempts"]
                    if item["attempt_id"] == attempt["attempt_id"]
                )
                assert metadata["variant"] == "reordered"
                assert (
                    metadata["system_sha256"]
                    == hashlib.sha256(request["system"].encode()).hexdigest()
                )
                assert (
                    metadata["user_sha256"]
                    == hashlib.sha256(
                        request["messages"][0]["content"].encode()
                    ).hexdigest()
                )
                if attempt["accepted"]:
                    assert attempt["parsed_action"] == event["executed_action"]
                else:
                    assert attempt["rejection_reason"]
            if mode in {"invalid", "provider-error"} and event["seat"] == "0":
                assert (
                    event["action_status"] == "fallback"
                    and event["selected_attempt_id"] is None
                )
                assert len(event["attempts"]) == 2
            else:
                assert event["action_status"] == "accepted"
        assert joined == set(calls)
        replay = (output / "replay.json").read_text()
        assert "platform_call_id" not in replay and "prompt_attempts" not in replay
        print(mode, "140 decisions", len(joined), "exact provider joins", flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        provider.shutdown()
        owner.join(timeout=5)
        provider.server_close()
