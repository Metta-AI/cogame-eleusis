"""Reject malformed native actions without changing a complete standard game."""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT.joinpath('coworld_manifest_template.json')
name = json.loads(GAME.read_text())['game']['name']
players = 4 if name == 'hanabi' else 5
mode = '--language' if name == 'hanabi' else 'text'
process = subprocess.Popen([sys.argv[1], str(GAME), 'standard', mode],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
assert process.stdin is not None and process.stdout is not None

def request(value):
    process.stdin.write(json.dumps(value) + '\n')
    process.stdin.flush()
    line = process.stdout.readline()
    assert line, 'bridge exited instead of returning a rejection'
    return json.loads(line)

try:
    observation = request({'kind': 'reset', 'seed': 'bridge-rejection-system', 'players': players})
    decisions = 0
    while observation['kind'] == 'decision':
        teacher = request({'kind': 'teacher'})['response']
        for invalid in ['not JSON', '{}', '[]', '{"experiment":"INVALID","move":"invalid"}']:
            rejected = request({'kind': 'step', 'decision_id': observation['decision_id'], 'response': invalid})
            assert rejected['kind'] == 'rejected' and rejected['reason']
            assert rejected['observation'] == observation
            assert request({'kind': 'teacher'})['response'] == teacher
        result = request({'kind': 'step', 'decision_id': observation['decision_id'], 'response': teacher})
        assert result['kind'] == 'accepted'
        observation = result['observation']
        decisions += 1
    assert set(observation['scores']) == {str(s) for s in range(players)}
    assert decisions == 140 if name == 'eleusis' else 1 <= decisions <= 80
    print(name, decisions, 'completed decisions,', decisions * 4, 'state-preserving rejections')
finally:
    process.stdin.close()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
    process.stdout.close()
