## Export complete Eleusis games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import eleusis/[llm, sim]

const OperatorPrompt = "Choose experiments and predictions that maximize your score over the complete game."
const Variants = ["standard", "open-science", "closed-shop"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit source before generating a pinned corpus"
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  setFilePermissions(output, {fpUserRead, fpUserWrite, fpUserExec})
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
    wordingCounts: array[2, int]
  for seed in firstSeed ..< firstSeed + games:
    var wording = selection
    let partition = ord(seed mod 5 == 0)
    if wording.variant == pvMixed:
      wording.seed += wordingCounts[partition]
    inc wordingCounts[partition]
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = newJArray()
    for seat in 0 ..< Seats:
      runtimeConfig["tokens"].add(%("t" & $seat))
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    var rows: seq[string]
    while not sim.done:
      let testing = sim.phase == phTest
      let seats = sim.pendingSeats()
      var decisions: array[Seats, Decision]
      for seat in seats:
        let teacher = scriptedAction(sim, seat,
          if seat mod 2 == 0: skOpenbook else: skHoarder)
        var completion = %*{
          "publish": teacher.publish,
          "hypothesis": teacher.hypothesis,
          "notes": teacher.notes
        }
        if testing:
          completion["answers"] = newJArray()
          for answer in teacher.answers:
            completion["answers"].add(%($answer))
        else:
          completion["experiment"] = %teacher.strip
        let parsed = parseDecision(completion, config.testStrips, testing)
        doAssert parsed == teacher
        decisions[seat] = parsed
        let system = systemPrompt(sim, seat, wording)
        let user = userPrompt(sim, seat, OperatorPrompt)
        rows.add($(%*{
          "episode_id": "eleusis-" & variant & "-" & $seed & "-" & $wording.selectedVariant,
          "seed": "eleusis-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": system},
            {"role": "user", "content": user}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "eleusis",
          "prompt_template": wording.promptMetadata(system, user),
          "action_schema_revision": "eleusis-decision-v1"
        }))
      for seat in seats:
        let parsed = decisions[seat]
        if testing:
          sim.applyAnswers(seat, parsed.answers, parsed.publish,
            parsed.hypothesis, parsed.notes, true)
        else:
          sim.applyResearch(seat, parsed.strip, parsed.publish,
            parsed.hypothesis, parsed.notes, true)
    doAssert sim.reason == "complete" and rows.len > 0
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "rounds_played": sim.roundsPlayed,
      "prompt_selection": wording.selectionMetadata()})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "eleusis",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-openbook-and-hoarder",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
