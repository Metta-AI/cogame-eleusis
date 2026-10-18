## Persistent numeric bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:eleusis-train-bridge tools/train_bridge.nim

import std/[json, options, os]
import eleusis/[llm, sim, observations]

const
  OperatorPrompt = "Choose experiments and predictions that maximize your score over the complete game."
  Variants = ["standard", "open-science", "closed-shop"]
  AnswerFields = ["answer0", "answer1", "answer2", "answer3", "answer4", "answer5"]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc answerChoices(testing: bool): JsonNode =
  if testing: %*["fail", "pass"]
  else: %*["fail", newJNull()]

proc heads(game: Sim): JsonNode =
  let testing = game.phase == phTest
  result = newJArray()
  result.add(%*{"name": "publish", "choices": [false, true]})
  var experiments = newJArray()
  experiments.add(%"")
  for index in 0 ..< StripUniverse:
    experiments.add(if testing: newJNull() else: %stripOfIndex(index))
  result.add(%*{"name": "experiment", "choices": experiments})
  for field in AnswerFields:
    result.add(%*{"name": field, "choices": answerChoices(testing)})

proc action(teacher: Decision, testing: bool): JsonNode =
  result = %*{"publish": teacher.publish,
    "experiment": (if testing: "" else: teacher.strip)}
  for index, field in AnswerFields:
    result[field] = %(if testing: $teacher.answers[index] else: "fail")

proc hostedAction(action: JsonNode, testing: bool): JsonNode =
  result = %*{"publish": action["publish"], "hypothesis": "", "notes": ""}
  if testing:
    result["answers"] = newJArray()
    for field in AnswerFields:
      result["answers"].add(action[field])
  else:
    result["experiment"] = action["experiment"]

proc decision(view: Sim, seat, id: int, selection: PromptSelection, textMode: bool): JsonNode =
  let actions = view.heads()
  var fields = newJObject()
  for head in actions:
    var legal = newJArray()
    for choice in head["choices"]:
      if choice.kind != JNull:
        legal.add(choice)
    fields[head["name"].getStr()] = %*{"enum": legal}
  result = %*{
    "kind": "decision", "game": "eleusis", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": view.round,
    "semantic_view": decisionView(view, seat, textMode),
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(view, seat, selection)},
      {"role": "user", "content": userPrompt(view, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": fields,
      "required": ["publish", "experiment", "answer0", "answer1",
        "answer2", "answer3", "answer4", "answer5"]},
    "typed_question": newJNull()
  }

  if textMode:
    result["semantic_view"]["prompt_template"] = selection.promptMetadata(
      result["messages"][0]["content"].getStr(), result["messages"][1]["content"].getStr())
    let testing = view.phase == phTest
    var properties = %*{"publish": {"type": "boolean"},
      "hypothesis": {"type": "string", "maxLength": MaxHypothesisLen},
      "notes": {"type": "string", "maxLength": MaxNotesLen}}
    var required = %*["publish"]
    if testing:
      properties["answers"] = %*{"type": "array", "minItems": view.config.testStrips,
        "maxItems": view.config.testStrips, "items": {"enum": ["pass", "fail"]}}
      required.add(%"answers")
    else:
      properties["experiment"] = %*{"type": "string", "pattern": "^([RBGY]{4})?$"}
      required.add(%"experiment")
    result["action_schema"] = %*{"type": "object", "properties": properties, "required": required}

proc encoding(view: Sim, seat, id: int, variant: string): JsonNode =
  var values = newJArray()
  for name in Variants:
    values.add(%(if name == variant: 1 else: 0))
  for value in [seat, view.round, view.config.rounds,
      view.config.testEvery, view.config.testStrips, view.testsDone,
      view.board.len, (if view.phase == phTest: 1 else: 0)]:
    values.add(%value)
  for other in 0 ..< Seats:
    let state = view.seats[other]
    for value in [state.score, state.knowledge, state.credit, state.spend]:
      values.add(%value)
    for value in [state.experiments, state.published, state.correct,
        state.answered]:
      values.add(%value)
  let pending = view.seats[seat].pending
  values.add(%(if pending.isSome: indexOfStrip(pending.get().strip) + 1 else: 0))
  values.add(%(if pending.isSome and pending.get().verdict == vPass: 1 else: 0))
  for index in 0 ..< StripUniverse:
    let strip = stripOfIndex(index)
    var own = 0
    var public = 0
    var author = 0
    for fact in view.seats[seat].log:
      if fact.strip == strip:
        own = if fact.verdict == vPass: 1 else: -1
    for fact in view.board:
      if fact.strip == strip:
        public = if fact.verdict == vPass: 1 else: -1
        author = fact.author + 1
    for value in [own, public, author]:
      values.add(%value)
  for index in 0 ..< 6:
    values.add(%(if view.phase == phTest:
      indexOfStrip(view.test.strips[index]) + 1 else: 0))
  let consistent = consistentRules(view.knownFacts(seat))
  for rule in catalogue():
    values.add(%(if rule in consistent: 1 else: 0))
  %*{"decision_id": id, "values": values, "action_heads": view.heads()}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 3:
    quit("usage: eleusis-train-bridge MANIFEST [variant [text]]", 1)
  let textMode = args.len == 3
  if textMode: doAssert args[2] == "text"
  let variant = if args.len >= 2: args[1] else: Variants[0]
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var selection: PromptSelection
  var game, view: Sim
  var batch: array[Seats, Decision]
  var seat = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      selection = if textMode: promptSelection(request) else: PromptSelection()
      let split = if request.hasKey("split"): request["split"].getStr() else: "train"
      doAssert split in ["train", "validation", "test"]
      if split == "train" and selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
        raise newException(ValueError, "held-out wording is evaluation-only")
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = newJArray()
      for other in 0 ..< Seats:
        runtimeConfig["tokens"].add(%("t" & $other))
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      runtimeConfig["minBatchSpacingMs"] = %0
      config.update($runtimeConfig)
      game = initSim(sampleEpisode(config))
      view = game
      seat = 0
      id = 0
      response = view.decision(seat, id, selection, textMode)
    of "encode":
      doAssert not game.done
      response = view.encoding(seat, id, variant)
    of "teacher":
      doAssert not game.done
      let teacher = scriptedAction(view, seat,
        if seat mod 2 == 0: skOpenbook else: skHoarder)
      response = %*{"response": $(if textMode: decisionJson(teacher, view.phase == phTest)
        else: action(teacher, view.phase == phTest))}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let chosen = extractJsonObject(request["response"].getStr())
      let testing = view.phase == phTest
      var payload = chosen
      if not textMode:
        for head in view.heads():
          let name = head["name"].getStr()
          doAssert chosen[name] in head["choices"], "action is masked: " & name
        payload = hostedAction(chosen, testing)
      let parsed = parseDecision(payload, game.config.testStrips, testing)
      batch[seat] = parsed
      let accepted = if textMode: decisionJson(parsed, testing) else: chosen
      inc seat
      if seat == Seats:
        for other in 0 ..< Seats:
          let move = batch[other]
          if testing:
            game.applyAnswers(other, move.answers, move.publish, move.hypothesis, move.notes, false)
          else:
            game.applyResearch(other, move.strip, move.publish, move.hypothesis, move.notes, false)
        view = game
        seat = 0
      inc id
      var observation: JsonNode
      if game.done:
        var scores = newJObject()
        for other in 0 ..< Seats:
          scores[$other] = %game.score(other)
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = view.decision(seat, id, selection, textMode)
      response = %*{"kind": "accepted", "action": accepted,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
