## Persistent numeric bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:eleusis-train-bridge tools/train_bridge.nim

import std/[json, options, os]
import eleusis/[llm, sim]

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

proc decision(view: Sim, seat, id: int): JsonNode =
  var board = newJArray()
  for fact in view.board:
    board.add(%*{"strip": fact.strip, "verdict": $fact.verdict,
      "author": fact.author, "round": fact.round,
      "duplicate": fact.duplicate})
  var ownFacts = newJArray()
  for fact in view.seats[seat].log:
    ownFacts.add(%*{"strip": fact.strip, "verdict": $fact.verdict,
      "round": fact.round, "mode": fact.mode})
  var seats = newJArray()
  for other in 0 ..< Seats:
    let state = view.seats[other]
    seats.add(%*{"seat": other, "score": state.score,
      "knowledge": state.knowledge, "credit": state.credit,
      "spend": state.spend, "experiments": state.experiments,
      "published": state.published, "correct": state.correct,
      "answered": state.answered})
  var strips = newJArray()
  if view.phase == phTest:
    for strip in view.test.strips:
      strips.add(%strip)
  let actions = view.heads()
  var fields = newJObject()
  for head in actions:
    fields[head["name"].getStr()] = %*{"enum": head["choices"]}
  %*{
    "kind": "decision", "game": "eleusis", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": view.round,
    "semantic_view": {"round": view.round, "rounds": view.config.rounds,
      "phase": $view.phase, "board": board, "own_facts": ownFacts,
      "seats": seats, "test_strips": strips,
      "pending": (if view.seats[seat].pending.isSome:
        %*{"strip": view.seats[seat].pending.get().strip,
          "verdict": $view.seats[seat].pending.get().verdict}
        else: newJNull())},
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(view, seat)},
      {"role": "user", "content": userPrompt(view, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": fields,
      "required": ["publish", "experiment", "answer0", "answer1",
        "answer2", "answer3", "answer4", "answer5"]},
    "typed_question": newJNull()
  }

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
  if args.len notin 1 .. 2:
    quit("usage: eleusis-train-bridge MANIFEST [variant]", 1)
  let variant = if args.len == 2: args[1] else: Variants[0]
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
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
      response = view.decision(seat, id)
    of "encode":
      doAssert not game.done
      response = view.encoding(seat, id, variant)
    of "teacher":
      doAssert not game.done
      let teacher = scriptedAction(view, seat,
        if seat mod 2 == 0: skOpenbook else: skHoarder)
      response = %*{"response": $action(teacher, view.phase == phTest)}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let chosen = parseJson(request["response"].getStr())
      let heads = view.heads()
      for head in heads:
        let name = head["name"].getStr()
        doAssert chosen[name] in head["choices"], "action is masked: " & name
      let testing = view.phase == phTest
      batch[seat] = parseDecision(hostedAction(chosen, testing),
        game.config.testStrips, testing)
      inc seat
      if seat == Seats:
        for other in 0 ..< Seats:
          let move = batch[other]
          if testing:
            game.applyAnswers(other, move.answers, move.publish, "", "", false)
          else:
            game.applyResearch(other, move.strip, move.publish, "", "", false)
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
        observation = view.decision(seat, id)
      response = %*{"kind": "accepted", "action": chosen,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
