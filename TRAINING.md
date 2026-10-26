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

The v2 bank varies the role introduction, experiment/publication explanation,
and prediction/citation incentives. The rules, private information,
response schema, scoring, and published budgets remain identical. The canonical
system prompt preserves the original bytes. This tests sensitivity to framing;
it does not establish improved learning or robustness.

The bridge accepts an optional third argument, `text`, for complete JSON actions,
including public hypotheses and private notes. Numeric actions retain their existing
meaning. Text reset requests accept the prompt selectors and `split`; held-out
wordings are rejected for training. Private observations include the bank version,
resolved wording, selection seed, and SHA256 hashes of the exact prompt messages.

## Teacher exports

Build once, then export from a clean committed checkout:

```sh
nim c -d:release --path:src -o:/tmp/eleusis-export tools/export_posttrain.nim
for variant in standard open-science closed-shop; do
  /tmp/eleusis-export "/tmp/eleusis-${variant}" 10 1 "$variant" mixed 0
done
```

Each export plays complete published games with five scientists, 24 research rounds,
and four prediction tests. Even seats use `openbook`; odd seats use `hoarder`.
All five observations are frozen before any action in their simultaneous batch.
The actual reply parser and simulator apply every action.

Outputs retain the original `train.jsonl`, `validation.jsonl`, and
`manifest.json` format. Rows include wording metadata and exact message hashes.
Mixed selection cycles the five training wordings separately within each split.
Episode IDs include requested selection, resolved wording, and prompt seed
to distinguish matched collections. Seed families
exclude variant and wording; multiples of five enter validation. Held-out
wordings cannot enter teacher exports. Output directories are private and must
not already exist.

The exporter freezes all five decisions before applying any. Later seats cannot
read publications or hypotheses submitted earlier in the same batch. Every
teacher action must pass the real parser unchanged and is applied by the engine.

## Validation

```sh
python3 tools/test_train_bridge.py /tmp/eleusis-train-bridge
python3 tools/test_prompt_games.py /tmp/eleusis-train-bridge
python3 tools/test_export_posttrain.py /tmp/eleusis-export
```

The wording workflow runs 27 complete games across the three published variants,
including private notes, simultaneous public hypotheses, and normalized actions.
The export workflow runs 30 complete games and checks batch visibility,
seed-family separation, and research/prediction action grammar.
These deterministic checks do not demonstrate improved learning or robustness.

## Hosted canonical capture

When `COGAME_SAVE_TRAJECTORY_URI` is supplied, the native server writes a private
canonical decision trajectory before publishing results. Runtime episode ID,
game version, and source revision are required. The capture uses the shared
bitworld decision-trajectory contract. It includes exact model request/response
bytes, platform call IDs, per-attempt prompt hashes, parser outcomes, retries,
selected actions, scripted/fallback origins, and terminal per-seat scores.
Decoder evidence contains only settings actually sent to the provider.

Every observation comes from the simultaneous pre-batch state. The secret rule
and other seats' private facts never enter a decision observation. Scripted
policies are explicit teacher candidates requiring downstream review; an engine
fallback is not a teacher. External actions without provider evidence have
unknown origin and cannot be admitted as model labels. Deadline endings are
truncated, not completed training games. Private capture is not added to replay.
The existing numeric/text bridge and offline teacher exporter remain separate.

Build game and player with the locked dependencies, then run the no-cost native
provider fixture (OUTPUT must be a new directory):

```sh
python3 tools/test_native_trajectory.py /path/to/eleusis /path/to/eleusis-player /tmp/NEW-eleusis-capture-proof
```

Each fixture plays all 24 research rounds and four prediction tests at standard
scoring, with only pacing disabled. Cases cover exact accepted replies, invalid
responses and repairs, provider errors, and explicitly selected scripted seats.
Fixture responses are plumbing evidence, not qualified teacher demonstrations.
Fresh hosted receipts and a published immutable release are still required for
production data admission.

## Explicit offline teacher queries

The training bridge accepts `{"kind":"teacher","policy":"openbook"}`,
`hoarder`, or `freerider`. An explicit query returns the exact response plus
`policy` and `decision_id`. Omitting `policy` retains the original even-seat
openbook / odd-seat hoarder behavior and response shape. Invalid policy values
return an error without advancing the game. Teacher queries never apply actions;
submit the selected response through the ordinary `step` path.

This lets a collector compare teacher quality for every seat without changing
learner observations, opponent defaults, or historical datasets. Each policy
uses that seat's known facts and the public rule catalogue; it does not read the
hidden rule or undisclosed test answers. Preserve the explicit query, selected
policy, source/binary hashes, replies and complete-game outcomes in any new
collection. A different teacher query is a new collection protocol, not a relabel
of existing targets or an automatic training-data admission.

Run `python3 tools/test_teacher_policies.py BINARY --reference ORIGINAL_BINARY`
to check complete games, state-preserving queries and exact default-play parity.
