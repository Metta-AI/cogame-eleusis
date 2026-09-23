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

## Metta post-training data

The native simulator and published `openbook` and `hoarder` policies export
supervised examples for all three certified Eleusis variants:

```sh
nimby sync nimby.lock
for variant in standard open-science closed-shop; do
  nim r -d:release --path:src tools/export_posttrain.nim \
    "/tmp/eleusis-${variant}" 10 1 "$variant"
done
```

Each run reads the variant configuration from the Coworld manifest, adds the
per-seat tokens supplied by the hosted platform, and plays complete seeded
games. At each research or prediction phase, it records every seat's hosted
system and user prompts and a scripted decision accepted by the game's reply
parser. Parsed decisions advance the simulator together. Even seats use the
publishing `openbook` policy; odd seats use `hoarder`. Whole games stay in one
split. The output manifest records source revision, variant, scores, rounds,
and row counts. Existing output directories are never overwritten.

Train an output with Metta post-training:

```sh
nix develop -c uv run --package metta-posttrain --extra train \
  python -m metta_posttrain.train --dataset /tmp/eleusis-standard \
  --output /tmp/eleusis-adapter --model Qwen/Qwen3-0.6B \
  --max-steps 100 --max-length 4096
```

Ten complete games per variant yielded 1,120 training and 280 validation
examples each. All 4,200 examples fit the Qwen2.5-0.5B-Instruct tokenizer in
4,096 tokens; the maximum was 2,430. These examples distill scripted
teachers; they do not establish stronger league play.
One CPU optimizer step per variant with a local tiny model included every
example and reduced heldout loss, verifying the Metta post-training path.
