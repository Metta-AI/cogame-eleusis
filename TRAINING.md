# Training

All three certified variants also expose a persistent numeric bridge for
Metta RL and native PufferLib:

```sh
nim c -d:release --path:src -o:/tmp/eleusis-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/eleusis-train-bridge
```

Pass the binary, manifest, and variant to Metta's
`recipes.external.coworld_metta_rl.train` or `recipes.external.coworld.train`.
Use `players=5` and a finite `total_timesteps`. The bridge has 895 numeric
features and eight action heads: publication, one of 256 experiments or skip,
and six test answers. Heads irrelevant to the current phase are masked.
It exposes public facts and each seat's own experiments, without the hidden
rule or test answers. Every seat in a research or test batch observes the
same pre-batch state, matching the hosted simultaneous decision path.

## Episode-stable prompt variants

The game accepts `promptVariant` and `promptSeed` independently of the simulator seed.
The default is `canonical`. Training wordings are `canonical`, `plain`, `numbered`,
`questions`, and `reordered`. `mixed` chooses one using `promptSeed % 5` and
requires an explicit nonnegative seed. Selection stays fixed throughout the episode.
`heldout-briefing` and `heldout-reference` are evaluation-only.

These variants paraphrase the role introduction. The rules, private information,
response schema, scoring, and published budgets remain identical. The canonical
system prompt preserves the original bytes. This tests sensitivity to framing;
it does not establish improved learning or robustness.

The bridge accepts an optional third argument, `text`, for complete JSON actions,
including public hypotheses and private notes. Numeric actions retain their existing
meaning. Text reset requests accept the prompt selectors and `split`; held-out
wordings are rejected for training. Private observations include the bank version,
resolved wording, selection seed, and SHA256 hashes of the exact prompt messages.

## Reviewed post-training candidates

Build once, then export from a clean committed checkout:

```sh
nim c -d:release --path:src -o:/tmp/eleusis-export tools/export_posttrain.nim
for variant in standard open-science closed-shop; do
  /tmp/eleusis-export "/tmp/eleusis-${variant}" 10 1 "$variant" canonical 0
done
```

Each export plays complete published games with five scientists, 24 research rounds,
and four prediction tests. Even seats use `openbook`; odd seats use `hoarder`.
All five observations are frozen before any action in their simultaneous batch.
The actual reply parser and simulator apply every action.

Outputs are private `trajectories.jsonl`, `execution.jsonl`, and `manifest.json` files.
They record the source revision, full messages, prompt hashes, teacher proposals,
normalized actions, applied event intervals, and final scores. Teacher decisions
have no inference request, platform call identifier, or behavior log probabilities.
Execution evidence can contain hidden rule information and must remain private.

Exports are candidates, not automatically admitted training data. Convert trajectories
with Coworld's `export_complete_episodes`, then use Metta's independent source-hash
review gate before label export. Do not split rows independently: keep each
`eleusis-SEED` family together across variants and wordings. Held-out prompt wordings
cannot be exported as teacher training candidates. At least ten complete games are
required per invocation; existing output directories are never overwritten.

## Native provenance and validation

Optional `ELEUSIS_HOST_TRACE_PATH` and `ELEUSIS_ATTEMPT_TRACE_DIR` capture private
host decisions and actual inference attempts. Set `ELEUSIS_SOURCE_REVISION` to the
qualified source revision. Attempt records preserve request bodies, exact messages,
retry hashes, raw responses, parser results, latency, and transport failures.
Host records join proposals to applied actions and replay event intervals, and
identify scripted fallbacks without attributing them to successful model requests.
Do not publish these files as replay artifacts.

```sh
python3 tools/test_train_bridge.py /tmp/eleusis-train-bridge
python3 tools/test_prompt_games.py /tmp/eleusis-train-bridge /tmp/original-eleusis-bridge
python3 tools/test_export_posttrain.py /tmp/eleusis-export
python3 tools/test_native_prompts.py /tmp/eleusis-game /tmp/eleusis-player /tmp/eleusis-native
```

The prompt panel compares 75 complete text games against original numeric runs.
The source-export panel checks 30 complete games. The native panel runs ten complete
published games with five real player processes and a reserved closed inference
endpoint, testing actual retries and fallbacks. `--smoke` runs two native games.
No paid model calls or training-quality claims follow from these deterministic checks.
