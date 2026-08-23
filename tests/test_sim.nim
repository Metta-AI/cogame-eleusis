## Rules tests for Eleusis: the catalogue and the machine, the seeded rule
## pick, turn resolution, disclosure, the balanced test draw, the knowledge
## pool, citation credit (the anti-collusion pin), scoring, endings, replay
## re-derivation, and rune-safe truncation.

import std/[json, math, options, sets, strutils, unicode, unittest]
import eleusis/sim

proc fixtureConfig(rounds = 24, seed = 0, testEvery = 6,
    testStrips = 6): GameConfig =
  result = defaultGameConfig()
  result.rounds = rounds
  result.seed = seed
  result.testEvery = testEvery
  result.testStrips = testStrips
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc close(a, b: float): bool =
  abs(a - b) < 1e-6

proc ruleOf(kind: RuleKind, a = -1, b = -1, flag = 0): Rule =
  Rule(kind: kind, a: a, b: b, flag: flag)

proc researchAll(sim: var Sim, publish = false, offset = 0) =
  ## Every pending seat runs a distinct experiment, so a round resolves.
  for seat in sim.pendingSeats():
    sim.applyResearch(seat, stripOfIndex((offset + seat * 37 + 11) mod
      StripUniverse), publish, "h" & $seat, "", true)

proc answerWith(sim: Sim, correctCount: int): seq[Verdict] =
  ## An answer vector with exactly `correctCount` right answers.
  for index, truth in sim.test.truth:
    if index < correctCount:
      result.add(truth)
    else:
      result.add(if truth == vPass: vFail else: vPass)

suite "catalogue and machine":
  test "the catalogue is 68 instances in a stable order":
    let all = catalogue()
    check all.len == RuleCount
    check all[0].kind == rkContains
    check all[0].a == 0
    check all[3].kind == rkContains
    check all[3].a == 3
    check all[4].kind == rkAtLeastTwo
    check all[8].kind == rkParity
    check all[8].flag == 0
    check all[9].flag == 1
    check all[16].kind == rkAdjacent
    check all[16].a == 0
    check all[16].b == 0
    check all[32].kind == rkBefore
    check all[44].kind == rkStartsWith
    check all[48].kind == rkEndsWith
    check all[52].kind == rkEndsSame
    check all[54].kind == rkRepeat
    check all[56].kind == rkMoreThan
    check all[67].kind == rkMoreThan
    ## describeRule identifies the instance: the endcard reveal is unique.
    var seen = initHashSet[string]()
    for rule in all:
      seen.incl(describeRule(rule))
    check seen.len == RuleCount

  test "strips enumerate lexicographically over R < B < G < Y":
    check stripOfIndex(0) == "RRRR"
    check stripOfIndex(255) == "YYYY"
    check stripOfIndex(1) == "RRRB"
    check indexOfStrip("RRRR") == 0
    check indexOfStrip("YYYY") == 255
    for index in 0 ..< StripUniverse:
      check indexOfStrip(stripOfIndex(index)) == index

  test "the machine's truth table, family by family":
    ## CONTAINS
    check evaluate(ruleOf(rkContains, 0), "RBGY") == vPass
    check evaluate(ruleOf(rkContains, 0), "BGYB") == vFail
    check evaluate(ruleOf(rkContains, 3), "BGYB") == vPass
    ## AT-LEAST-2
    check evaluate(ruleOf(rkAtLeastTwo, 0), "RRBG") == vPass
    check evaluate(ruleOf(rkAtLeastTwo, 0), "RBGY") == vFail
    check evaluate(ruleOf(rkAtLeastTwo, 1), "BBBB") == vPass
    ## PARITY — zero counts as even.
    check evaluate(ruleOf(rkParity, 0, flag = 0), "BGYB") == vPass
    check evaluate(ruleOf(rkParity, 0, flag = 0), "RBGY") == vFail
    check evaluate(ruleOf(rkParity, 0, flag = 0), "RRBG") == vPass
    check evaluate(ruleOf(rkParity, 0, flag = 1), "RBGY") == vPass
    check evaluate(ruleOf(rkParity, 0, flag = 1), "BGYB") == vFail
    ## ADJACENT, including c = d
    check evaluate(ruleOf(rkAdjacent, 0, 1), "RBGY") == vPass
    check evaluate(ruleOf(rkAdjacent, 0, 1), "BRGY") == vFail
    check evaluate(ruleOf(rkAdjacent, 0, 0), "RRBG") == vPass
    check evaluate(ruleOf(rkAdjacent, 0, 0), "RBRG") == vFail
    ## BEFORE — both colours must be present
    check evaluate(ruleOf(rkBefore, 0, 1), "RBGY") == vPass
    check evaluate(ruleOf(rkBefore, 0, 1), "BRGY") == vFail
    check evaluate(ruleOf(rkBefore, 0, 1), "RGYG") == vFail
    ## STARTS / ENDS
    check evaluate(ruleOf(rkStartsWith, 0), "RBGY") == vPass
    check evaluate(ruleOf(rkStartsWith, 0), "BRGY") == vFail
    check evaluate(ruleOf(rkEndsWith, 3), "RBGY") == vPass
    check evaluate(ruleOf(rkEndsWith, 3), "RBGR") == vFail
    ## ENDS-SAME / ENDS-DIFFER
    check evaluate(ruleOf(rkEndsSame, flag = 0), "RBGR") == vPass
    check evaluate(ruleOf(rkEndsSame, flag = 0), "RBGY") == vFail
    check evaluate(ruleOf(rkEndsSame, flag = 1), "RBGY") == vPass
    ## NO-REPEAT / HAS-REPEAT
    check evaluate(ruleOf(rkRepeat, flag = 0), "RBGY") == vPass
    check evaluate(ruleOf(rkRepeat, flag = 0), "RRBG") == vFail
    check evaluate(ruleOf(rkRepeat, flag = 1), "RRBG") == vPass
    ## MORE c d — a tie fails
    check evaluate(ruleOf(rkMoreThan, 0, 1), "RRBG") == vPass
    check evaluate(ruleOf(rkMoreThan, 0, 1), "RBGY") == vFail
    check evaluate(ruleOf(rkMoreThan, 0, 1), "BBRG") == vFail

  test "pickRule is deterministic and never degenerate":
    for seed in 0 ..< 200:
      let picked = pickRule(seed)
      let fraction = passFraction(picked.rule)
      check fraction >= MinPassFraction
      check fraction <= MaxPassFraction
      check pickRule(seed).id == picked.id
      check picked.id >= 0
      check picked.id < RuleCount
    ## Different seeds really do move the rule around.
    var rules = initHashSet[int]()
    for seed in 0 ..< 40:
      rules.incl(pickRule(seed).id)
    check rules.len > 1

  test "normaliseStrip is tolerant on shape, strict on legality":
    check normaliseStrip("rb gy") == "RBGY"
    check normaliseStrip("R-B_G,Y") == "RBGY"
    check normaliseStrip("") == ""
    check normaliseStrip("   ") == ""
    expect EleusisError:
      discard normaliseStrip("RBG")
    expect EleusisError:
      discard normaliseStrip("RBGZ")

suite "turn resolution":
  test "an experiment charges once, records the verdict, and is used up":
    var sim = initSim(fixtureConfig(rounds = 12, seed = 4))
    check sim.round == 1
    check sim.phase == phResearch
    check sim.pendingSeats() == @[0, 1, 2, 3, 4]
    sim.applyResearch(0, "RBGY", false, "ADJACENT R B?", "", true)
    check close(sim.seats[0].spend, sim.config.experimentCost)
    check sim.seats[0].experiments == 1
    check "RBGY" in sim.used
    check sim.seats[0].pending.isSome
    check sim.seats[0].pending.get().strip == "RBGY"
    check sim.seats[0].pending.get().verdict == evaluate(sim.rule, "RBGY")
    check sim.seats[0].hypothesis == "ADJACENT R B?"
    ## A second decision in the same turn is illegal.
    expect EleusisError:
      sim.applyResearch(0, "RRRR", false, "", "", true)
    ## A skip costs nothing.
    sim.applyResearch(1, "", false, "", "", true)
    check close(sim.seats[1].spend, 0.0)
    check sim.seats[1].experiments == 0
    check sim.seats[1].pending.isNone
    ## Unknown seats and malformed strips raise and change nothing.
    expect EleusisError:
      sim.applyResearch(9, "RBGY", false, "", "", true)
    expect EleusisError:
      sim.applyResearch(2, "RBG", false, "", "", true)
    check sim.pendingSeats() == @[2, 3, 4]
    check sim.round == 1

  test "disclosure: publish pins, a duplicate pays nobody, a hoard hides":
    var sim = initSim(fixtureConfig(rounds = 12, seed = 4))
    for seat in 0 ..< Seats:
      sim.applyResearch(seat, "RBGY", false, "", "", true)
    check sim.round == 2
    check sim.board.len == 0
    for seat in 0 ..< Seats:
      check sim.seats[seat].pending.isSome
    ## Seat 0 publishes it first and becomes its sole author.
    sim.applyResearch(0, "", true, "", "", true)
    check sim.board.len == 1
    check sim.board[0].author == 0
    check sim.board[0].strip == "RBGY"
    check not sim.board[0].duplicate
    check sim.seats[0].published == 1
    check sim.seats[0].pending.isNone
    check sim.seats[0].log[0].mode == "publish"
    ## Seat 1 publishes the same strip: a confirmation, no authorship.
    sim.applyResearch(1, "", true, "", "", true)
    check sim.board.len == 2
    check sim.board[1].duplicate
    check sim.board[1].author == -1
    check sim.seats[1].published == 0
    check sim.seats[1].log[0].mode == "duplicate"
    ## Seat 2 hoards: the drawer, never the board.
    sim.applyResearch(2, "", false, "", "", true)
    check sim.board.len == 2
    check sim.seats[2].hoarded == 1
    check sim.seats[2].secrets.len == 1
    check sim.seats[2].secrets[0].strip == "RBGY"
    check sim.seats[2].log[0].mode == "hoard"
    var modes: seq[string]
    for event in sim.events:
      if event.kind == evDisclose:
        modes.add(event.mode)
    check modes == @["publish", "duplicate", "hoard"]

  test "the test draw is held out and balanced":
    var sim = initSim(fixtureConfig(rounds = 12, seed = 6, testEvery = 3))
    for round in 1 .. 3:
      sim.researchAll(offset = round * 13)
    check sim.phase == phTest
    check sim.test.index == 1
    check sim.test.round == 3
    check sim.test.strips.len == 6
    check sim.test.truth.len == 6
    var passes = 0
    for verdict in sim.test.truth:
      if verdict == vPass:
        inc passes
    check passes == 3
    for index, strip in sim.test.strips:
      check strip notin sim.used
      check evaluate(sim.rule, strip) == sim.test.truth[index]
    let firstTest = sim.test.strips
    ## Answer it, play on, and the second test holds out the first's strips.
    for seat in 0 ..< Seats:
      sim.applyAnswers(seat, sim.answerWith(3), false, "", "", true)
    check sim.phase == phResearch
    check sim.round == 4
    for round in 4 .. 6:
      sim.researchAll(offset = round * 13)
    check sim.test.index == 2
    for strip in sim.test.strips:
      check strip notin firstTest
      check strip notin sim.used

suite "money":
  test "the knowledge pool splits by correct answers, and pays nothing to nobody":
    var sim = initSim(fixtureConfig(rounds = 4, seed = 8, testEvery = 4))
    for round in 1 .. 4:
      sim.researchAll(offset = round * 5)
    check sim.phase == phTest
    let counts = [6, 3, 0, 0, 0]
    for seat in 0 ..< Seats:
      sim.applyAnswers(seat, sim.answerWith(counts[seat]), false, "", "", true)
    check sim.testsDone == 1
    check close(sim.seats[0].knowledge, 20.0 * 6.0 / 9.0)
    check close(sim.seats[1].knowledge, 20.0 * 3.0 / 9.0)
    check close(sim.seats[2].knowledge, 0.0)
    var total = 0.0
    for seat in 0 ..< Seats:
      total += sim.seats[seat].knowledge
    check close(total, sim.config.knowledgePool)
    check sim.done
    check sim.reason == "complete"

    ## Nobody right: the pool pays out nothing at all.
    var barren = initSim(fixtureConfig(rounds = 4, seed = 8, testEvery = 4))
    for round in 1 .. 4:
      barren.researchAll(offset = round * 5)
    for seat in 0 ..< Seats:
      barren.applyAnswers(seat, barren.answerWith(0), false, "", "", true)
    for seat in 0 ..< Seats:
      check close(barren.seats[seat].knowledge, 0.0)

  test "citation credit: Hamming-1, never self, once per confirmer, split evenly":
    ## A hand-built corkboard and a hand-built test, so every clause of the
    ## settlement rule is exercised on its own.
    var sim = initSim(fixtureConfig(rounds = 12, seed = 2, testEvery = 3))
    sim.board = @[
      Fact(strip: "RRRB", verdict: vPass, author: 1, round: 1, mode: "publish"),
      Fact(strip: "RRRG", verdict: vFail, author: 1, round: 2, mode: "publish"),
      Fact(strip: "RRRY", verdict: vPass, author: 2, round: 2, mode: "publish"),
      Fact(strip: "RRBB", verdict: vPass, author: 3, round: 2, mode: "publish"),
      Fact(strip: "RRRB", verdict: vPass, author: -1, round: 3,
        duplicate: true, mode: "duplicate"),
      Fact(strip: "BBBR", verdict: vPass, author: 0, round: 3, mode: "publish")
    ]
    sim.testBoardCut = sim.board.len
    ## Published AFTER the test opened: pays nothing, ever.
    sim.board.add(Fact(strip: "BBBG", verdict: vPass, author: 4, round: 4,
      mode: "publish"))
    sim.test = TestState(
      index: 1, round: 3,
      strips: @["RRRR", "BBBB"],
      truth: @[vPass, vFail],
      answers: newSeq[seq[Verdict]](Seats),
      answered: newSeq[bool](Seats),
      open: true
    )
    sim.phase = phTest
    ## Seat 0 is right about both; seat 1 about the first only; the rest are
    ## wrong about everything.
    sim.applyAnswers(0, @[vPass, vFail], false, "", "", true)
    sim.applyAnswers(1, @[vPass, vPass], false, "", "", true)
    sim.applyAnswers(2, @[vFail, vPass], false, "", "", true)
    sim.applyAnswers(3, @[vFail, vPass], false, "", "", true)
    sim.applyAnswers(4, @[vFail, vPass], false, "", "", true)
    ## RRRR, confirmed by seat 0: authors 1 (twice over, paid once) and 2
    ## split $0.50. RRRR, confirmed by seat 1: only author 2 qualifies
    ## (seat 1 cannot cite itself), so it takes the whole pot.
    check close(sim.seats[1].credit, 0.25)
    check close(sim.seats[2].credit, 0.75)
    ## Seat 0's own BBBR sits one token from BBBB, but self-citation is
    ## impossible by construction, and nobody else answered BBBB correctly.
    check close(sim.seats[0].credit, 0.0)
    ## RRBB is two tokens from RRRR; BBBG was published after the cut.
    check close(sim.seats[3].credit, 0.0)
    check close(sim.seats[4].credit, 0.0)
    check sim.citations.len == 3
    var settled = 0
    for event in sim.events:
      if event.kind == evSettle:
        inc settled
        check event.citations.len == 3
        check event.correctAll == @[2, 1, 0, 0, 0]
    check settled == 1

  test "score is prizes plus credit minus spend, and may be negative":
    var sim = initSim(fixtureConfig(rounds = 4, seed = 3, testEvery = 4))
    for round in 1 .. 4:
      sim.researchAll(offset = round * 17)
    for seat in 0 ..< Seats:
      sim.applyAnswers(seat, sim.answerWith(0), false, "", "", true)
    check sim.done
    check sim.reason == "complete"
    for seat in 0 ..< Seats:
      check sim.seats[seat].experiments == 4
      check close(sim.seats[seat].spend, 4.0)
      check close(sim.score(seat), sim.seats[seat].knowledge +
        sim.seats[seat].credit - sim.seats[seat].spend)
      ## A seat that only ever spends finishes below zero.
      check sim.score(seat) < 0.0
    let results = sim.resultsJson()
    check results["reason"].getStr() == "complete"
    check results["scores"].len == Seats
    check results["names"].len == Seats
    check results["rounds"].getInt() == 4
    check results["tests"].getInt() == 1
    check results["ruleId"].getInt() == sim.ruleId

suite "endings":
  test "complete after the final test; deadline discards an open test":
    var sim = initSim(fixtureConfig(rounds = 6, seed = 11, testEvery = 3))
    for round in 1 .. 3:
      sim.researchAll(offset = round * 7)
    for seat in 0 ..< Seats:
      sim.applyAnswers(seat, sim.answerWith(4), false, "", "", true)
    check sim.testsDone == 1
    check not sim.done
    ## A test that was actually marked is settled, not discarded.
    check not sim.benchStateJson()["test"]["open"].getBool()
    check not sim.benchStateJson()["test"]["discarded"].getBool()
    for round in 4 .. 6:
      sim.researchAll(offset = round * 7)
    check sim.phase == phTest
    ## Only two seats answer the second test, then the clock stops play.
    sim.applyAnswers(0, sim.answerWith(6), false, "", "", true)
    sim.applyAnswers(1, sim.answerWith(6), false, "", "", true)
    ## The three seats that never answered are still holding a result.
    var holding: seq[int]
    var hoardedBefore: array[Seats, int]
    var held: array[Seats, string]
    for seat in 0 ..< Seats:
      hoardedBefore[seat] = sim.seats[seat].hoarded
      if sim.seats[seat].pending.isSome:
        holding.add(seat)
        held[seat] = sim.seats[seat].pending.get().strip
    check holding == @[2, 3, 4]
    sim.endEarly()
    check sim.done
    check sim.reason == "deadline"
    ## An undisclosed result was never on the board: it stays hoarded.
    for seat in holding:
      check sim.seats[seat].pending.isNone
      check sim.seats[seat].hoarded == hoardedBefore[seat] + 1
      check sim.seats[seat].secrets[^1].strip == held[seat]
      for fact in sim.board:
        check fact.strip != held[seat]
    check sim.testsDone == 1                 ## the open test is unscored
    check sim.testCorrect.len == 1
    for seat in 0 ..< Seats:
      check sim.seats[seat].answered == 6    ## only the settled test counts
    check sim.seats[0].correct == 4
    check sim.resultsJson()["reason"].getStr() == "deadline"
    ## The discarded test is marked as such in the frame the viewer reads, so
    ## its truth stamps and correctness pips stay sealed: it scored nobody.
    let frame = sim.benchStateJson()
    check frame["test"]["index"].getInt() == 2
    check not frame["test"]["open"].getBool()
    check frame["test"]["discarded"].getBool()
    ## Settling twice is a no-op, and the transcript ends with the reveal.
    sim.endEarly()
    check sim.events[^1].kind == evEnd
    check sim.events[^1].text == "deadline"
    check sim.events[^1].rule == sim.ruleText()
    expect EleusisError:
      sim.applyResearch(0, "RBGY", false, "", "", true)

suite "replay":
  test "events round-trip through JSON, all nine kinds":
    var sim = initSim(fixtureConfig(rounds = 4, seed = 9, testEvery = 4))
    for round in 1 .. 3:
      sim.researchAll(publish = true, offset = round * 23)
    ## One skip, so the kind appears in the transcript.
    for seat in sim.pendingSeats():
      sim.applyResearch(seat, (if seat == 0: "" else:
        stripOfIndex((seat * 41 + 5) mod StripUniverse)), true,
        "line " & $seat, "note " & $seat, true)
    for seat in 0 ..< Seats:
      sim.applyAnswers(seat, sim.answerWith(seat), true, "", "", true)
    check sim.done
    var kinds = initHashSet[string]()
    for event in sim.events:
      kinds.incl($event.kind)
      let back = eventFromJson(eventToJson(event))
      check back.kind == event.kind
      check back.round == event.round
      check back.seat == event.seat
      check back.strip == event.strip
      check back.mode == event.mode
      check back.test == event.test
      check back.text == event.text
      check back.hypothesis == event.hypothesis
      check back.scripted == event.scripted
      check back.fallback == event.fallback
      check back.strips == event.strips
      check back.truth == event.truth
      check back.answers == event.answers
      check back.correctAll == event.correctAll
      check back.citations.len == event.citations.len
      if event.kind == evExperiment or event.kind == evDisclose:
        check back.verdict == event.verdict
      if event.kind == evAnswer:
        check back.correct == event.correct
      if event.kind == evEnd:
        check back.rule == event.rule
        check back.ruleId == event.ruleId
        check back.closest == event.closest
    check kinds.len == 9

  test "a scripted fallback is recorded on the event and in the replay":
    ## An LLM seat whose reply never arrived plays the openbook baseline; the
    ## replay has to say so, or phase 60 cannot count the fallbacks.
    var sim = initSim(fixtureConfig(rounds = 6, seed = 13))
    sim.applyResearch(0, "RBGY", false, "", "", true, fallback = true)
    sim.applyResearch(1, "", false, "", "", true, fallback = true)
    sim.applyResearch(2, "RRBG", false, "", "", false)
    var seen = 0
    for event in sim.events:
      case event.kind
      of evExperiment, evSkip:
        let node = event.eventToJson()
        check node["fallback"].getBool() == event.fallback
        case event.seat
        of 0, 1:
          check event.fallback
          check event.scripted
          inc seen
        else:
          check not event.fallback
          inc seen
      else:
        discard
    check seen == 3
    ## The flag survives the round trip the viewer and phase 60 read.
    let frames = replayMatch(sim.config, sim.events)
    var replayed = 0
    for event in frames[^1].events:
      if event.kind in {evExperiment, evSkip} and event.fallback:
        inc replayed
    check replayed == 2

  test "a recorded episode re-derives frame by frame":
    let config = fixtureConfig(rounds = 6, seed = 11, testEvery = 3)
    var live = initSim(config)
    var round = 1
    while not live.done:
      if live.phase == phTest:
        for seat in 0 ..< Seats:
          live.applyAnswers(seat, live.answerWith(seat), seat mod 2 == 0,
            "h" & $seat, "n" & $seat, true)
      else:
        live.researchAll(publish = round mod 2 == 0, offset = round * 29)
        inc round
    let frames = replayMatch(config, live.events)
    check frames.len == live.events.len + 1
    check $frames[^1].benchStateJson() == $live.benchStateJson()
    check frames[^1].done
    check frames[^1].reason == "complete"
    check frames[^1].ruleId == live.ruleId
    ## A recorded deadline stop is honoured.
    var short = initSim(config)
    short.researchAll(offset = 3)
    short.endEarly()
    let shortFrames = replayMatch(config, short.events)
    check shortFrames[^1].done
    check shortFrames[^1].reason == "deadline"
    check shortFrames[^1].roundsPlayed == 1
    ## Including the results the seats were still holding when it stopped.
    check $shortFrames[^1].benchStateJson() == $short.benchStateJson()

  test "a tampered test event is rejected":
    let config = fixtureConfig(rounds = 4, seed = 11, testEvery = 4)
    var live = initSim(config)
    for round in 1 .. 4:
      live.researchAll(offset = round * 31)
    var events = live.events
    var index = -1
    for position, event in events:
      if event.kind == evTest:
        index = position
    check index >= 0
    events[index].strips[0] = (if events[index].strips[0] == "RRRR": "YYYY"
      else: "RRRR")
    expect EleusisError:
      discard replayMatch(config, events)

suite "text safety":
  test "hypothesis and notes are cut on rune boundaries":
    var sim = initSim(fixtureConfig(rounds = 6, seed = 1))
    var longLine = ""
    for index in 0 ..< 200:
      longLine.add("é")
    var longNotes = ""
    for index in 0 ..< 900:
      longNotes.add("é")
    sim.applyResearch(0, "RBGY", false, longLine, longNotes, true)
    check sim.seats[0].hypothesis.runeLen == MaxHypothesisLen
    check sim.seats[0].notes.runeLen == MaxNotesLen
    ## The cut is marked, so a truncated line does not read as a sentence the
    ## seat chose to stop writing.
    check sim.seats[0].hypothesis.endsWith("…")
    check sim.seats[0].notes.endsWith("…")
    ## Text that fits is untouched, marker and all.
    sim.applyResearch(1, "RRBG", false, "short line", "short note", true)
    check sim.seats[1].hypothesis == "short line"
    check sim.seats[1].notes == "short note"
    check sim.seats[0].hypothesis.validateUtf8() == -1
    check sim.seats[0].notes.validateUtf8() == -1
    ## A byte-boundary cut would land invalid UTF-8 in the replay bytes and
    ## fail the platform's strict parse.
    for event in sim.events:
      check event.hypothesis.validateUtf8() == -1
      check event.text.validateUtf8() == -1
    var payload = newJArray()
    for event in sim.events:
      payload.add(event.eventToJson())
    check ($payload).validateUtf8() == -1
    check parseJson($payload).len == sim.events.len
