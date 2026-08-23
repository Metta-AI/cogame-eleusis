# Eleusis

**A secret law of nature, costly experiments, and the choice to publish or
hoard** — the induction game (Eleusis/Zendo) for the Softmax Coworld
platform, on the [cogame-parley](https://github.com/Metta-AI/cogame-parley)
technology stack (forked from
[cogame-bullwhip](https://github.com/Metta-AI/cogame-bullwhip)).

Five cogs share one sealed machine. The machine holds **one hidden rule** over
**strips** — ordered sequences of exactly four coloured tokens, each `R` red,
`B` blue, `G` green or `Y` yellow, written as four letters (`RBGY`). Feed it a
strip and it stamps **PASS** or **FAIL**. The rule is one entry of a
**68-instance catalogue that every seat can read** (`CONTAINS R`,
`ADJACENT R B`, `PARITY G EVEN`, `MORE Y THAN B`, …), so the game is a search,
not a guess.

Every round each seat pays **$1.00** to run **one experiment** and sees the
verdict **privately**. On its *next* turn it decides what to do with the
result:

- **PUBLISH** — the fact is pinned to the shared corkboard. Every rival reads
  it, and the author can earn citation credit later. Publishing a strip
  somebody already published earns nothing, ever.
- **HOARD** — it slides into a private drawer only spectators can see.

Every **6 rounds** a **prediction test** scores everyone on six strips nobody
has ever tested, exactly half of which pass (so answering all FAIL scores
exactly 50%). A **$20 prize pool** is split in proportion to correct answers —
*every rival you teach takes a slice of your pool*. **Citation credit** pays
the other way: when another seat answers a test strip correctly and one of
your published results differs from that strip in exactly one token, a **$0.50
pot** for that strip is shared between the authors whose results do.

```
score = prize money + citation credit − $1.00 × experiments
```

Higher wins, and a seat that only ever spends finishes negative. **Citation
rings do not pay**: credit needs a *rival* to be actually right about a strip
nobody has tested, self-citation is impossible by construction, and a
duplicate publication has no author.

**The game is LLM-driven and a policy is just a prompt.** Every turn the game
server sends each seat's policy prompt, its own experiment log, the corkboard,
the public scoreboard, the per-test scores and its private notes to Claude —
all five seats as **one parallel batch**, because their decisions are
simultaneous — and Claude answers with the experiment, the publish/hoard
decision, a public hypothesis line and private notes. Player containers exist
only to deliver their prompt over the websocket. Two built-in **scripted
baselines** share one version-space engine and differ only in disclosure —
`openbook` publishes every result, `hoarder` publishes none — so the two
fillers are a live control experiment for the dilemma the game is about. They
play any seat that registers as scripted, and every seat when no LLM
credentials are available, so episodes (and offline certification) always
complete.

Seats play under **anonymous cog aliases** (Sprocket, Gizmo, …): policy
display names never reach the agents' prompts, so nobody can meta-game "that
seat is the champion". The spectator and replay viewers map the aliases back
to policy names; results are reported under policy names.

The episode ends `complete` after the test that follows the final research
round (default 24 rounds, 4..60), or `deadline` when the episode clock stops
play between batches — an unfinished test is discarded unscored and the tests
already settled keep their money.

## Layout

- `src/eleusis.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/eleusis/types.nim` — config, the event vocabulary, the runtime config
- `src/eleusis/sim.nim` — pure rules: the catalogue and the machine, the
  seeded rule pick, turn resolution, disclosure, the balanced test draw, the
  knowledge pool, citation settlement, endings, replay derivation; shared by
  the server, the tests and the wasm viewer
- `src/eleusis/llm.nim` — Claude client (one parallel batch per turn) + the
  version-space scripted baselines
- `src/eleusis/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/eleusis_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
- `client/` — shared canvas renderer + global/player/replay pages (the parley
  broadcast chrome around the lab bench)
- `replay-viewer/` — static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `tools/ci/` — the docker episode smoke, the viewer load test, the policy set
- `scripts/art/` — the nano-banana renders and the split script for
  `cog_violet_front.png` and `bench_surface.png`
- `scripts/build_manifest.py` — regenerates `coworld_manifest_template.json`
- `data/` — cog sprites (the four from
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) via cogame-bullwhip,
  MIT) and the bench art
- `docs/plans/` — the design note this game was built from

## The viewer

The replay is a **static wasm bundle**, never a pod: the same `eleusis/sim`
module the server runs is compiled to WebAssembly, and the browser re-derives
every frame from the recorded events. The bench shows the machine stamping
each strip, the corkboard filling with pinned index cards, the drawer sliding
open on a hoard (tagged `SECRET · SPECTATORS ONLY`), the prediction-test panel
with a pip per seat per strip, and an endcard that reveals the rule and who
got closest.

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the paths
# are machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim            # rules tests
nim r -d:release --path:src tests/test_bot.nim # scripted-baseline tests
nim c -d:release -o:bin/eleusis src/eleusis.nim
nim c -d:release -o:bin/eleusis-player src/eleusis_player.nim
nim c --hints:off -d:emscripten replay-viewer/eleusis_replay.nim  # wasm viewer
# A full containerised episode (game + five players, results and replay in
# dist/smoke/), exactly what CI runs:
docker build --platform=linux/amd64 -t coworld-eleusis:ci .
./tools/ci/docker_smoke.sh coworld-eleusis:ci
# Export ANTHROPIC_API_KEY for real Claude play; omit it and the scripted
# baselines play every seat.
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
uv run coworld secret put eleusis anthropic_api_key <keyfile>   # hosted Claude
```

In the cloud all of that is the `coworld-release.yml` workflow dispatch;
`ci.yml` is the harness (sim tests, an end-to-end docker episode, and the
replay viewer opened in a real browser).

## Fielding a policy

```bash
uv run coworld upload-policy <eleusis image> --name my-eleusis \
  --run /bin/eleusis-player \
  --secret-env PLAYER_PROMPT="Your laboratory strategy here."
```

Or field a scripted baseline: same image, `--env PLAYER_SCRIPTED=openbook` or
`--env PLAYER_SCRIPTED=hoarder`.
