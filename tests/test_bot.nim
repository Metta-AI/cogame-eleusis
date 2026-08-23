## The scripted baselines must play whole episodes without ever proposing an
## illegal decision — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path.
## The version-space predictor must also actually learn the rule, or it is no
## partner worth beating.

import std/[json, monotimes, options, os, strutils, times, unicode, unittest]
import eleusis/[llm, server, sim]

proc fixture(seed: int, rounds = 24, testEvery = 6): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.testEvery = testEvery
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc checkLegal(sim: Sim, decision: Decision) =
  ## Every decision a baseline emits must be legal BEFORE the sim is asked to
  ## apply it: that is what makes it a safe fallback.
  check decision.hypothesis.runeLen <= MaxHypothesisLen
  check decision.hypothesis.validateUtf8() == -1
  check decision.notes.len == 0
  if sim.phase == phTest:
    check decision.answers.len == sim.config.testStrips
  else:
    if decision.strip.len > 0:
      check decision.strip.len == StripLen
      for letter in decision.strip:
        check letter in Colours
      check indexOfStrip(decision.strip) >= 0

proc playScripted(config: GameConfig, kinds: array[Seats, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    let testing = result.phase == phTest
    for seat in result.pendingSeats():
      let decision = scriptedAction(result, seat, kinds[seat])
      checkLegal(result, decision)
      if testing:
        result.applyAnswers(seat, decision.answers, decision.publish,
          decision.hypothesis, decision.notes, true)
      else:
        result.applyResearch(seat, decision.strip, decision.publish,
          decision.hypothesis, decision.notes, true)

suite "the play clock":
  test "the play deadline is never switched off":
    ## The deadline is what makes the episode settle and score inside 60% of
    ## the platform's timeout. A non-positive value anywhere in the chain must
    ## fall through to the next source, never to "no deadline at all".
    var config = fixture(1)
    check playTimeoutSeconds(config, "600") == 600.0
    check playTimeoutSeconds(config, "  600  ") == 600.0
    ## Env garbage and an absent env fall back to the configured assumption.
    check playTimeoutSeconds(config, "not-a-number") ==
      config.episodeTimeoutSeconds.float
    check playTimeoutSeconds(config, "") == config.episodeTimeoutSeconds.float
    check playTimeoutSeconds(config, "0") == config.episodeTimeoutSeconds.float
    ## And a config whose own timeout is unusable falls through to the
    ## built-in default rather than leaving the episode unbounded.
    config.episodeTimeoutSeconds = 0
    check playTimeoutSeconds(config, "") ==
      defaultGameConfig().episodeTimeoutSeconds.float
    config.episodeTimeoutSeconds = -5
    check playTimeoutSeconds(config, "-1") ==
      defaultGameConfig().episodeTimeoutSeconds.float
    check playTimeoutSeconds(config, "") > 0.0

suite "scripted baselines":
  test "five baseline seats play full, legal episodes":
    for seed in [1, 7, 42, 99, 1234]:
      let config = fixture(seed, rounds = 12, testEvery = 4)
      let started = getMonoTime()
      let sim = playScripted(config,
        [skOpenbook, skHoarder, skOpenbook, skHoarder, skOpenbook])
      let elapsed = (getMonoTime() - started).inMilliseconds
      check sim.done
      check sim.reason == "complete"
      check sim.roundsPlayed == config.rounds
      check sim.testsDone == config.rounds div config.testEvery
      var experiments = 0
      for event in sim.events:
        if event.kind == evExperiment:
          inc experiments
          check event.strip.len == StripLen
      check experiments > 0
      echo "seed ", seed, ": rule ", sim.ruleText(), ", ", experiments,
        " experiments, board ", sim.board.len, ", ", elapsed, " ms"

  test "the version space really learns: >= 70% on the final test":
    ## Five open-book seats pooling their results should have the rule
    ## cornered by the last test; a coin flip would score 50%.
    var total = 0
    var answered = 0
    for seed in 0 ..< 10:
      let sim = playScripted(fixture(seed, rounds = 12, testEvery = 4),
        [skOpenbook, skOpenbook, skOpenbook, skOpenbook, skOpenbook])
      check sim.testCorrect.len > 0
      for correct in sim.testCorrect[^1]:
        total += correct
        answered += sim.config.testStrips
    let rate = total.float / answered.float
    echo "final-test accuracy over 10 seeds: ", rate
    check rate >= 0.70

  test "hoarders publish nothing; open books publish everything they can":
    let sim = playScripted(fixture(5, rounds = 12, testEvery = 4),
      [skOpenbook, skHoarder, skOpenbook, skHoarder, skOpenbook])
    for seat in [1, 3]:
      check sim.seats[seat].published == 0
      check sim.seats[seat].hoarded > 0
      for fact in sim.board:
        check fact.author != seat
      for fact in sim.seats[seat].log:
        check fact.mode in ["hoard", ""]
    for seat in [0, 2, 4]:
      check sim.seats[seat].hoarded == 0
      check sim.seats[seat].published > 0
      ## Every disclosed result was published; only an exact duplicate of a
      ## strip already on the board fails to earn authorship.
      for fact in sim.seats[seat].log:
        check fact.mode in ["publish", "duplicate", ""]

  test "decideAll falls back to scripted with no credentials":
    let config = fixture(3, rounds = 8, testEvery = 4)
    let client = newLlmClient(config)
    check client.disabled
    var sim = initSim(config)
    let seats = sim.pendingSeats()
    let decisions = client.decideAll(sim, seats,
      @["be bold", "", "", "", ""],
      @[skNone, skNone, skHoarder, skNone, skOpenbook])
    check decisions.len == Seats
    for index, seat in seats:
      let kind = if seat == 2: skHoarder else: skOpenbook
      check decisions[index].strip == scriptedAction(sim, seat, kind).strip
      check decisions[index].publish == (seat != 2)
      sim.applyResearch(seat, decisions[index].strip, decisions[index].publish,
        decisions[index].hypothesis, decisions[index].notes, true)
    check sim.round == 2

  test "a slot that never delivered a prompt plays openbook, not an LLM call":
    ## The reference player always delivers a prompt (its own default strategy
    ## when PLAYER_PROMPT is empty), so an empty prompt means the pod never
    ## connected. That seat plays the scripted baseline for the episode
    ## instead of calling Claude with an empty operator block.
    putEnv("ANTHROPIC_API_KEY", "not-a-real-key")
    let config = fixture(17, rounds = 8, testEvery = 4)
    let client = newLlmClient(config)
    check not client.disabled
    var sim = initSim(config)
    let seats = sim.pendingSeats()
    let decisions = client.decideAll(sim, seats,
      @["", "  ", "", "", ""], @[skNone, skNone, skNone, skNone, skNone])
    check decisions.len == Seats
    for index, seat in seats:
      ## No request was ever built, so nothing failed and nothing fell back.
      check not decisions[index].fallback
      check decisions[index] == scriptedAction(sim, seat, skOpenbook)
    delEnv("ANTHROPIC_API_KEY")

  test "model replies parse, and illegal ones are rejected":
    check parseDecision(parseJson("""{"experiment": "rb gy"}"""), 6,
      false).strip == "RBGY"
    check parseDecision(parseJson("""{"experiment": "R-B-G-Y"}"""), 6,
      false).strip == "RBGY"
    check parseDecision(parseJson("""{"experiment": ""}"""), 6,
      false).strip == ""
    let full = parseDecision(parseJson(
      """{"experiment": "RRBG", "publish": "yes", "hypothesis": "ADJACENT R B?",
          "notes": "shortlist: 3"}"""), 6, false)
    check full.strip == "RRBG"
    check full.publish
    check full.hypothesis == "ADJACENT R B?"
    check full.notes == "shortlist: 3"
    check not parseDecision(parseJson("""{"experiment": "RRBG"}"""), 6,
      false).publish
    expect EleusisError:
      discard parseDecision(parseJson("""{"experiment": "RBG"}"""), 6, false)
    expect EleusisError:
      discard parseDecision(parseJson("""{"experiment": "RBGZ"}"""), 6, false)
    expect EleusisError:
      discard parseDecision(parseJson("""{"notes": "no experiment"}"""), 6,
        false)
    expect EleusisError:
      discard parseDecision(parseJson("""[1, 2]"""), 6, false)
    ## Test turns: exactly testStrips entries, PASS/FAIL either case.
    let answered = parseDecision(parseJson(
      """{"answers": ["PASS", "fail", "P", "F", true, false]}"""), 6, true)
    check answered.answers == @[vPass, vFail, vPass, vFail, vPass, vFail]
    expect EleusisError:
      discard parseDecision(parseJson(
        """{"answers": ["PASS", "FAIL", "PASS", "FAIL", "PASS"]}"""), 6, true)
    expect EleusisError:
      discard parseDecision(parseJson(
        """{"answers": ["PASS", "FAIL", "PASS", "FAIL", "PASS", "maybe"]}"""),
        6, true)
    expect EleusisError:
      discard parseDecision(parseJson("""{"experiment": "RBGY"}"""), 6, true)
    ## Rune-safe truncation of everything that lands in the replay.
    var long = ""
    for index in 0 ..< 900:
      long.add("é")
    check cleanText(long, MaxNotesLen).runeLen == MaxNotesLen
    check cleanText(long, MaxHypothesisLen).runeLen == MaxHypothesisLen
    check cleanText(long, MaxNotesLen).validateUtf8() == -1
    check parseScriptKind("1") == skOpenbook
    check parseScriptKind("openbook") == skOpenbook
    check parseScriptKind("hoarder") == skHoarder
    check parseScriptKind("") == skNone
    let extracted = extractJsonObject("prose {\"experiment\": \"RBGY\"} tail")
    check extracted{"experiment"}.getStr() == "RBGY"

  test "prompts carry the seat's own view and nothing hidden":
    var sim = initSim(fixture(7, rounds = 8, testEvery = 4))
    for seat in sim.pendingSeats():
      sim.applyResearch(seat, stripOfIndex(seat * 51), seat == 0,
        "hypothesis " & $seat, "note " & $seat, true)
    for seat in sim.pendingSeats():
      sim.applyResearch(seat, stripOfIndex(seat * 51 + 7), seat == 0,
        "hypothesis " & $seat, "", true)
    let text = sim.userPrompt(0, "operator says hi")
    check "ROUND 3 OF 8" in text
    check "operator says hi" in text
    check "YOUR PENDING RESULT" in text
    check "THE CORKBOARD" in text
    check "SCOREBOARD" in text
    check "note 0" in text
    ## The rule, the other seats' notes and their drawers are never in it.
    check sim.ruleText() notin text
    check "note 1" notin text
    check text.runeLen > 200
    let system = sim.systemPrompt(0)
    check "ELEUSIS laboratory" in system
    check "must begin with the character {" in system
    check sim.ruleText() notin system
