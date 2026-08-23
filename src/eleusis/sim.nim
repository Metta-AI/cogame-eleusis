## Pure game rules for Eleusis (the Eleusis/Zendo induction game). No IO, no
## networking, no LLM — the server, the tests and the wasm replay viewer all
## drive this same module.
##
## A `Sim` is one whole episode: the seeded hidden rule, the five seats'
## experiment logs and private drawers, the shared corkboard, the prediction
## tests and their settlements, and the append-only event log. Everything
## random is drawn from the seed at `initSim`, so a replay re-derives the
## episode from the recorded decision events alone.
##
## RESOLUTION ORDER. The design note numbers a research round as: open the
## round, collect all five decisions, apply every seat's DISCLOSURE (seat
## order 0..4), then every seat's EXPERIMENT (seat order 0..4). This module
## applies a seat's disclosure and then its experiment as its decision lands
## (the server applies the batch in seat order 0..4), which is
## state-equivalent: a disclosure reads only that seat's own pending result
## and the corkboard, an experiment writes only that seat's own log and the
## used-strip set, and the duplicate check resolves in seat order either way.
## Doing it per seat is what lets `replayMatch` hand the viewer one frame per
## event instead of one frame per round.

import std/[json, options, random, sets, strutils, unicode], types

export types

const
  Seats* = 5
  StripLen* = 4
  Colours* = ['R', 'B', 'G', 'Y']
  StripUniverse* = 256
  RuleCount* = 68
  MinRounds* = 4
  MaxRounds* = 60
  MinPassFraction* = 0.10
  MaxPassFraction* = 0.90
  MaxHypothesisLen* = 120
  MaxNotesLen* = 600
  ColourNames* = ["RED", "BLUE", "GREEN", "YELLOW"]
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]

type
  RuleKind* = enum
    rkContains = "contains"
    rkAtLeastTwo = "atleast2"
    rkParity = "parity"
    rkAdjacent = "adjacent"
    rkBefore = "before"
    rkStartsWith = "starts"
    rkEndsWith = "ends"
    rkEndsSame = "endssame"
    rkRepeat = "repeat"
    rkMoreThan = "morethan"

  Rule* = object
    kind*: RuleKind
    a*: int     ## first colour index, or -1
    b*: int     ## second colour index, or -1
    flag*: int  ## parity: 0 even / 1 odd; ends: 0 same / 1 differ;
                ## repeat: 0 none / 1 some

  Fact* = object
    ## One machine verdict. On the corkboard `author` is the seat that
    ## published it (-1 for a duplicate confirmation); in a seat's own log or
    ## drawer it is that seat.
    strip*: string
    verdict*: Verdict
    author*: int
    round*: int
    duplicate*: bool
    mode*: string   ## "" while pending, then publish | hoard | duplicate
    cites*: float   ## citation money this published fact has earned

  Pending* = tuple[strip: string, verdict: Verdict]

  MachineState* = object
    ## The strip being stamped right now; spectator dressing only.
    seat*: int
    round*: int
    strip*: string
    verdict*: Verdict

  SeatState* = object
    score*: float
    knowledge*: float
    credit*: float
    spend*: float
    experiments*: int
    published*: int
    hoarded*: int
    correct*: int
    answered*: int
    hypothesis*: string
    notes*: string
    pending*: Option[Pending]
    last*: Option[Fact]      ## the seat's most recent disclosure
    log*: seq[Fact]
    secrets*: seq[Fact]      ## hoarded results; spectator-visible only

  TestState* = object
    index*: int              ## 1-based
    round*: int              ## the research round it follows
    strips*: seq[string]
    truth*: seq[Verdict]     ## spectator-only until settlement
    answers*: seq[seq[Verdict]]
    answered*: seq[bool]
    open*: bool

  Phase* = enum
    phResearch = "research"
    phTest = "test"
    phDone = "done"

  Sim* = object
    config*: GameConfig
    names*: seq[string]            ## anonymous cog aliases per seat
    rule*: Rule
    ruleId*: int
    round*: int                    ## 1-based research round
    phase*: Phase
    seats*: array[Seats, SeatState]
    board*: seq[Fact]              ## the corkboard, in publication order
    used*: HashSet[string]         ## strips any seat has experimented on
    usedTest*: HashSet[string]     ## strips an earlier test used
    testsDone*: int                ## SETTLED tests
    test*: TestState
    testBoardCut*: int             ## board length when the open test opened
    testCorrect*: seq[seq[int]]    ## per settled test, correct per seat
    citations*: seq[Citation]
    machine*: Option[MachineState]
    decided*: array[Seats, bool]   ## decided in the live turn
    roundsPlayed*: int
    done*: bool
    reason*: string                ## "complete" | "deadline"
    events*: seq[GameEvent]
    rng*: Rand

# ---- Strips -----------------------------------------------------------------

proc colourIndex*(letter: char): int =
  for index, colour in Colours:
    if colour == letter:
      return index
  -1

proc stripOfIndex*(index: int): string =
  ## Lexicographic over R < B < G < Y: 0 = "RRRR", 255 = "YYYY".
  var rest = index
  result = newString(StripLen)
  for position in countdown(StripLen - 1, 0):
    result[position] = Colours[rest mod Colours.len]
    rest = rest div Colours.len

proc indexOfStrip*(strip: string): int =
  for letter in strip:
    let colour = colourIndex(letter)
    if colour < 0:
      return -1
    result = result * Colours.len + colour

proc normaliseStrip*(text: string): string =
  ## "" (skip) for an empty or separator-only input; the 4-letter strip
  ## otherwise. Raises on anything that is not a legal strip: uppercased and
  ## stripped of whitespace and separators, the first four characters must
  ## all be colours.
  var cleaned = ""
  for letter in text:
    if letter in {' ', '\t', '\n', '\r', '-', '_', ','}:
      continue
    cleaned.add(toUpperAscii(letter))
  if cleaned.len == 0:
    return ""
  if cleaned.len < StripLen:
    raise newException(EleusisError,
      "a strip is " & $StripLen & " tokens from RBGY: " & text)
  result = cleaned[0 ..< StripLen]
  for letter in result:
    if colourIndex(letter) < 0:
      raise newException(EleusisError,
        "a strip is " & $StripLen & " tokens from RBGY: " & text)

proc countOf(strip: string, colour: int): int =
  for letter in strip:
    if colourIndex(letter) == colour:
      inc result

proc firstAt(strip: string, colour: int): int =
  for index, letter in strip:
    if colourIndex(letter) == colour:
      return index
  -1

proc hamming*(a, b: string): int =
  ## Positions at which two equal-length strips differ.
  if a.len != b.len:
    return high(int)
  for index in 0 ..< a.len:
    if a[index] != b[index]:
      inc result

# ---- The catalogue ----------------------------------------------------------

proc catalogue*(): seq[Rule] =
  ## The 68 instances, in the enumeration order that fixes `ruleId`.
  for colour in 0 ..< Colours.len:
    result.add(Rule(kind: rkContains, a: colour, b: -1))
  for colour in 0 ..< Colours.len:
    result.add(Rule(kind: rkAtLeastTwo, a: colour, b: -1))
  for colour in 0 ..< Colours.len:
    for flag in 0 .. 1:
      result.add(Rule(kind: rkParity, a: colour, b: -1, flag: flag))
  for first in 0 ..< Colours.len:
    for second in 0 ..< Colours.len:
      result.add(Rule(kind: rkAdjacent, a: first, b: second))
  for first in 0 ..< Colours.len:
    for second in 0 ..< Colours.len:
      if first != second:
        result.add(Rule(kind: rkBefore, a: first, b: second))
  for colour in 0 ..< Colours.len:
    result.add(Rule(kind: rkStartsWith, a: colour, b: -1))
  for colour in 0 ..< Colours.len:
    result.add(Rule(kind: rkEndsWith, a: colour, b: -1))
  for flag in 0 .. 1:
    result.add(Rule(kind: rkEndsSame, a: -1, b: -1, flag: flag))
  for flag in 0 .. 1:
    result.add(Rule(kind: rkRepeat, a: -1, b: -1, flag: flag))
  for first in 0 ..< Colours.len:
    for second in 0 ..< Colours.len:
      if first != second:
        result.add(Rule(kind: rkMoreThan, a: first, b: second))

proc passes(rule: Rule, strip: string): bool =
  case rule.kind
  of rkContains:
    countOf(strip, rule.a) >= 1
  of rkAtLeastTwo:
    countOf(strip, rule.a) >= 2
  of rkParity:
    let total = countOf(strip, rule.a)
    if rule.flag == 0: total mod 2 == 0 else: total mod 2 == 1
  of rkAdjacent:
    var found = false
    for index in 0 ..< StripLen - 1:
      if colourIndex(strip[index]) == rule.a and
          colourIndex(strip[index + 1]) == rule.b:
        found = true
    found
  of rkBefore:
    let first = firstAt(strip, rule.a)
    let second = firstAt(strip, rule.b)
    first >= 0 and second >= 0 and first < second
  of rkStartsWith:
    colourIndex(strip[0]) == rule.a
  of rkEndsWith:
    colourIndex(strip[StripLen - 1]) == rule.a
  of rkEndsSame:
    if rule.flag == 0: strip[0] == strip[StripLen - 1]
    else: strip[0] != strip[StripLen - 1]
  of rkRepeat:
    var repeated = false
    for index in 0 ..< StripLen - 1:
      if strip[index] == strip[index + 1]:
        repeated = true
    if rule.flag == 0: not repeated else: repeated
  of rkMoreThan:
    countOf(strip, rule.a) > countOf(strip, rule.b)

proc evaluate*(rule: Rule, strip: string): Verdict =
  ## The sealed machine. The only oracle in the game.
  if passes(rule, strip): vPass else: vFail

proc passFraction*(rule: Rule): float =
  var hits = 0
  for index in 0 ..< StripUniverse:
    if passes(rule, stripOfIndex(index)):
      inc hits
  hits.float / StripUniverse.float

proc describeRule*(rule: Rule): string =
  ## The human line the endcard reveals; unique per instance.
  let first = if rule.a >= 0: ColourNames[rule.a] else: ""
  let second = if rule.b >= 0: ColourNames[rule.b] else: ""
  let firstLetter = if rule.a >= 0: $Colours[rule.a] else: ""
  let secondLetter = if rule.b >= 0: $Colours[rule.b] else: ""
  case rule.kind
  of rkContains:
    "CONTAINS " & firstLetter & " — at least one " & first & " token"
  of rkAtLeastTwo:
    "AT-LEAST-2 " & firstLetter & " — two or more " & first & " tokens"
  of rkParity:
    if rule.flag == 0:
      "PARITY " & firstLetter & " EVEN — an even number of " & first &
        " tokens (zero counts as even)"
    else:
      "PARITY " & firstLetter & " ODD — an odd number of " & first & " tokens"
  of rkAdjacent:
    "ADJACENT " & firstLetter & " " & secondLetter & " — a " & first &
      " token immediately followed by a " & second & " token"
  of rkBefore:
    "BEFORE " & firstLetter & " " & secondLetter & " — both appear, and the " &
      "first " & first & " is left of the first " & second
  of rkStartsWith:
    "STARTS " & firstLetter & " — the first token is " & first
  of rkEndsWith:
    "ENDS " & firstLetter & " — the fourth token is " & first
  of rkEndsSame:
    if rule.flag == 0:
      "ENDS-SAME — the first and fourth tokens are the same colour"
    else:
      "ENDS-DIFFER — the first and fourth tokens are different colours"
  of rkRepeat:
    if rule.flag == 0:
      "NO-REPEAT — no two neighbouring tokens are equal"
    else:
      "HAS-REPEAT — some two neighbouring tokens are equal"
  of rkMoreThan:
    "MORE " & firstLetter & " THAN " & secondLetter & " — more " & first &
      " tokens than " & second & " tokens"

proc pickRuleWith(rng: var Rand): tuple[id: int, rule: Rule] =
  ## Shuffle the catalogue and take the first instance that is neither
  ## almost-always true nor almost-never true.
  let instances = catalogue()
  var order = newSeq[int](instances.len)
  for index in 0 ..< instances.len:
    order[index] = index
  rng.shuffle(order)
  for id in order:
    let fraction = passFraction(instances[id])
    if fraction >= MinPassFraction and fraction <= MaxPassFraction:
      return (id, instances[id])
  (order[0], instances[order[0]])

proc pickRule*(seed: int): tuple[id: int, rule: Rule] =
  ## Deterministic per seed, and always inside the pass-fraction band.
  var rng = initRand(int64(seed) * 7919 + 17)
  pickRuleWith(rng)

proc agrees*(rule: Rule, fact: Fact): bool =
  evaluate(rule, fact.strip) == fact.verdict

proc consistentRules*(facts: seq[Fact]): seq[Rule] =
  ## Every catalogue instance that agrees with every fact given.
  for rule in catalogue():
    var ok = true
    for fact in facts:
      if not agrees(rule, fact):
        ok = false
        break
    if ok:
      result.add(rule)

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the bench: every seat plays under an
  ## anonymous cog alias, drawn deterministically from the seed so replays
  ## and the live view agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the episode to the wall-clock budget: one LLM batch per research
  ## round and one per test, each floored at `minBatchSpacingMs`, all inside
  ## 60% of the platform timeout. Idempotent — a replay's config is untouched.
  result = config
  if result.sampled:
    return
  result.rounds = max(min(config.rounds, MaxRounds), MinRounds)
  let spacing = max(config.minBatchSpacingMs, 1)
  let maxBatches =
    int(config.episodeTimeoutSeconds.float * 0.6 * 1000.0 / spacing.float) - 2
  while result.rounds > MinRounds and
      result.rounds + result.rounds div max(result.testEvery, 1) > maxBatches:
    dec result.rounds
  result.sampled = true

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, round: -1, seat: -1, test: -1, closest: -1, ruleId: -1)

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc openRound(sim: var Sim) =
  sim.phase = phResearch
  for seat in 0 ..< Seats:
    sim.decided[seat] = false
  var event = blankEvent(evRound)
  event.round = sim.round
  sim.addEvent(event)

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(EleusisError,
      "eleusis needs exactly " & $Seats & " players")
  if config.rounds < MinRounds:
    raise newException(EleusisError, "rounds must be at least " & $MinRounds)
  if config.testEvery < 2:
    raise newException(EleusisError, "testEvery must be at least 2")
  if config.testStrips < 2 or config.testStrips mod 2 != 0:
    raise newException(EleusisError, "testStrips must be even and at least 2")
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything the seed decides: the rule, then every test
  ## draw. A replay re-derives both by re-running this from the same seed.
  result.rng = initRand(int64(config.seed) * 7919 + 17)
  let picked = pickRuleWith(result.rng)
  result.ruleId = picked.id
  result.rule = picked.rule
  result.used = initHashSet[string]()
  result.usedTest = initHashSet[string]()
  result.round = 1
  result.addEvent(blankEvent(evStart))
  result.openRound()

# ---- Queries ----------------------------------------------------------------

proc pendingSeats*(sim: Sim): seq[int] =
  ## Seats whose decision for the live turn is still due, in seat order.
  if sim.done:
    return
  for seat in 0 ..< Seats:
    if not sim.decided[seat]:
      result.add(seat)

proc score*(sim: Sim, seat: int): float =
  sim.seats[seat].knowledge + sim.seats[seat].credit - sim.seats[seat].spend

proc refreshScore(sim: var Sim, seat: int) =
  sim.seats[seat].score = sim.score(seat)

proc ruleText*(sim: Sim): string =
  describeRule(sim.rule)

proc knownFacts*(sim: Sim, seat: int): seq[Fact] =
  ## Everything this seat may reason from: its own results and the corkboard.
  result = sim.seats[seat].log
  for fact in sim.board:
    result.add(fact)

proc accuracy*(sim: Sim, seat: int): float =
  if sim.seats[seat].answered == 0: 0.0
  else: sim.seats[seat].correct.float / sim.seats[seat].answered.float

proc closestSeat*(sim: Sim): int =
  ## Highest lifetime test accuracy; ties to the higher score, then the
  ## lower seat index. -1 when no test was scored.
  result = -1
  for seat in 0 ..< Seats:
    if sim.seats[seat].answered == 0:
      continue
    if result < 0:
      result = seat
      continue
    let mine = sim.accuracy(seat)
    let best = sim.accuracy(result)
    if mine > best or (mine == best and sim.score(seat) > sim.score(result)):
      result = seat

# ---- Play -------------------------------------------------------------------

proc clearMachine(sim: var Sim) =
  sim.machine = none(MachineState)

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  sim.clearMachine()
  var event = blankEvent(evEnd)
  event.round = sim.roundsPlayed
  event.text = reason
  event.rule = sim.ruleText()
  event.ruleId = sim.ruleId
  event.closest = sim.closestSeat()
  sim.addEvent(event)

proc drawTest(sim: var Sim): tuple[strips: seq[string], truth: seq[Verdict]] =
  ## `testStrips` strips nobody has ever experimented on and no earlier test
  ## has used, exactly half of which the machine passes — balance removes the
  ## base-rate exploit.
  var passPool, failPool: seq[string]
  for index in 0 ..< StripUniverse:
    let strip = stripOfIndex(index)
    if strip in sim.used or strip in sim.usedTest:
      continue
    if evaluate(sim.rule, strip) == vPass: passPool.add(strip)
    else: failPool.add(strip)
  sim.rng.shuffle(passPool)
  sim.rng.shuffle(failPool)
  let half = sim.config.testStrips div 2
  var chosen: seq[string]
  for index in 0 ..< min(half, passPool.len):
    chosen.add(passPool[index])
  for index in 0 ..< min(half, failPool.len):
    chosen.add(failPool[index])
  ## Degenerate top-up: only reachable if an episode has experimented on
  ## nearly a whole side of the universe. Never leave a test short — the
  ## answer vector's length is part of the protocol.
  var spare: seq[string]
  for index in 0 ..< StripUniverse:
    let strip = stripOfIndex(index)
    if strip notin chosen and strip notin sim.usedTest:
      spare.add(strip)
  sim.rng.shuffle(spare)
  var extra = 0
  while chosen.len < sim.config.testStrips and extra < spare.len:
    chosen.add(spare[extra])
    inc extra
  var index = 0
  while chosen.len < sim.config.testStrips:
    chosen.add(stripOfIndex(index mod StripUniverse))
    inc index
  sim.rng.shuffle(chosen)
  for strip in chosen:
    result.strips.add(strip)
    result.truth.add(evaluate(sim.rule, strip))

proc openTest*(sim: var Sim) =
  ## Opens the prediction test that follows the round just played.
  let drawn = sim.drawTest()
  sim.test = TestState(
    index: sim.testsDone + 1,
    round: sim.round,
    strips: drawn.strips,
    truth: drawn.truth,
    answers: newSeq[seq[Verdict]](Seats),
    answered: newSeq[bool](Seats),
    open: true
  )
  for strip in drawn.strips:
    sim.usedTest.incl(strip)
  sim.testBoardCut = sim.board.len
  sim.phase = phTest
  for seat in 0 ..< Seats:
    sim.decided[seat] = false
  sim.clearMachine()
  var event = blankEvent(evTest)
  event.test = sim.test.index
  event.round = sim.test.round
  event.strips = drawn.strips
  event.truth = drawn.truth
  sim.addEvent(event)

proc advanceTurn(sim: var Sim) =
  ## The research round just resolved.
  inc sim.roundsPlayed
  if sim.round mod sim.config.testEvery == 0 or sim.round >= sim.config.rounds:
    sim.openTest()
  else:
    inc sim.round
    sim.openRound()

proc settleTest*(sim: var Sim) =
  ## Scores the open test: the knowledge pool, then citation credit, then the
  ## running scores. The rivalrous half and the cooperative half, in order.
  if not sim.test.open:
    return
  var correct = newSeq[int](Seats)
  var total = 0
  for seat in 0 ..< Seats:
    if sim.test.answered[seat]:
      for index in 0 ..< sim.test.strips.len:
        if index < sim.test.answers[seat].len and
            sim.test.answers[seat][index] == sim.test.truth[index]:
          inc correct[seat]
    total += correct[seat]
  var pool = newSeq[float](Seats)
  for seat in 0 ..< Seats:
    pool[seat] = sim.config.knowledgePool * correct[seat].float /
      max(1, total).float
    sim.seats[seat].knowledge += pool[seat]
  ## Citation credit: only facts published BEFORE this test opened, only a
  ## Hamming distance of exactly one, only for a RIVAL's correct answer, and
  ## an author is paid at most once per (strip, confirmer). A citation ring
  ## cannot manufacture a passing prediction, so it cannot manufacture credit.
  var credit = newSeq[float](Seats)
  var fresh: seq[Citation]
  for index, strip in sim.test.strips:
    for seat in 0 ..< Seats:
      if not sim.test.answered[seat]:
        continue
      if index >= sim.test.answers[seat].len or
          sim.test.answers[seat][index] != sim.test.truth[index]:
        continue
      var authors: seq[int]
      var support: seq[int]     ## the board index that earns the `cites` tag
      for boardIndex in 0 ..< min(sim.testBoardCut, sim.board.len):
        let fact = sim.board[boardIndex]
        if fact.duplicate or fact.author < 0 or fact.author == seat:
          continue
        if hamming(fact.strip, strip) != 1:
          continue
        if fact.author notin authors:
          authors.add(fact.author)
          support.add(boardIndex)
      if authors.len == 0:
        continue
      let amount = sim.config.citePot / authors.len.float
      for position, author in authors:
        credit[author] += amount
        sim.board[support[position]].cites += amount
        let citation = Citation(author: author, by: seat, strip: strip,
          amount: amount, test: sim.test.index)
        fresh.add(citation)
        sim.citations.add(citation)
  var scores = newSeq[float](Seats)
  for seat in 0 ..< Seats:
    sim.seats[seat].credit += credit[seat]
    sim.refreshScore(seat)
    scores[seat] = sim.seats[seat].score
  sim.test.open = false
  inc sim.testsDone
  sim.testCorrect.add(correct)
  sim.clearMachine()
  var event = blankEvent(evSettle)
  event.test = sim.test.index
  event.round = sim.test.round
  event.correctAll = correct
  event.pool = pool
  event.credit = credit
  event.scores = scores
  event.citations = fresh
  sim.addEvent(event)
  if sim.test.round >= sim.config.rounds:
    sim.settle("complete")
  else:
    inc sim.round
    sim.openRound()

proc capText(text: string, limit: int, oneLine = false): string =
  ## Cut on a RUNE boundary, with the cut marked, exactly as `cleanText` does
  ## on the live LLM path: a byte slice through a multi-byte character leaves
  ## invalid UTF-8 in the replay and breaks its strict JSON parse, and an
  ## unmarked cut reads as a sentence the seat never finished writing.
  result = text.strip()
  if oneLine:
    result = result.replace("\n", " ").replace("\r", " ")
  if result.runeLen > limit:
    result = result.runeSubStr(0, limit - 1) & "…"

proc recordTalk(sim: var Sim, seat: int, hypothesis, notes: string) =
  ## The hypothesis line is public and one line; the notes are private and
  ## handed back to the seat verbatim next turn.
  let line = capText(hypothesis, MaxHypothesisLen, oneLine = true)
  if line.len > 0:
    sim.seats[seat].hypothesis = line
  let note = capText(notes, MaxNotesLen)
  if note.len > 0:
    sim.seats[seat].notes = note

proc discloseNow(sim: var Sim, seat: int, publish: bool) =
  ## Applies the seat's decision about the result it is holding. A seat with
  ## nothing pending records nothing at all.
  if sim.seats[seat].pending.isNone:
    return
  let pending = sim.seats[seat].pending.get()
  sim.clearMachine()
  var duplicate = false
  if publish:
    for fact in sim.board:
      if fact.strip == pending.strip:
        duplicate = true
        break
  let mode =
    if not publish: "hoard"
    elif duplicate: "duplicate"
    else: "publish"
  var fact = Fact(strip: pending.strip, verdict: pending.verdict,
    author: (if mode == "publish": seat else: -1), round: sim.round,
    duplicate: duplicate, mode: mode)
  case mode
  of "publish":
    inc sim.seats[seat].published
    sim.board.add(fact)
  of "duplicate":
    ## Recorded as a confirmation: no authorship, and no credit ever.
    sim.board.add(fact)
  else:
    inc sim.seats[seat].hoarded
    var secret = fact
    secret.author = seat
    sim.seats[seat].secrets.add(secret)
  for index in countdown(sim.seats[seat].log.high, 0):
    if sim.seats[seat].log[index].mode.len == 0:
      sim.seats[seat].log[index].mode = mode
      break
  sim.seats[seat].pending = none(Pending)
  var shown = fact
  shown.author = seat
  sim.seats[seat].last = some(shown)
  var event = blankEvent(evDisclose)
  event.round = sim.round
  event.seat = seat
  event.strip = pending.strip
  event.verdict = pending.verdict
  event.mode = mode
  sim.addEvent(event)

proc runExperiment(sim: var Sim, seat: int, strip: string, scripted: bool,
    fallback = false) =
  sim.clearMachine()
  if strip.len == 0:
    var event = blankEvent(evSkip)
    event.round = sim.round
    event.seat = seat
    event.scripted = scripted
    event.fallback = fallback
    event.hypothesis = sim.seats[seat].hypothesis
    event.text = sim.seats[seat].notes
    sim.addEvent(event)
  else:
    let verdict = evaluate(sim.rule, strip)
    sim.seats[seat].spend += sim.config.experimentCost
    inc sim.seats[seat].experiments
    sim.used.incl(strip)
    sim.seats[seat].log.add(Fact(strip: strip, verdict: verdict, author: seat,
      round: sim.round))
    sim.seats[seat].pending = some((strip: strip, verdict: verdict))
    sim.machine = some(MachineState(seat: seat, round: sim.round, strip: strip,
      verdict: verdict))
    sim.refreshScore(seat)
    var event = blankEvent(evExperiment)
    event.round = sim.round
    event.seat = seat
    event.strip = strip
    event.verdict = verdict
    event.cost = sim.config.experimentCost
    event.scripted = scripted
    event.fallback = fallback
    event.hypothesis = sim.seats[seat].hypothesis
    event.text = sim.seats[seat].notes
    sim.addEvent(event)
  sim.decided[seat] = true
  if sim.pendingSeats().len == 0:
    sim.advanceTurn()

proc recordAnswer(sim: var Sim, seat: int, answers: seq[Verdict],
    scripted: bool, fallback = false) =
  if answers.len != sim.test.strips.len:
    raise newException(EleusisError,
      "a test needs exactly " & $sim.test.strips.len & " answers, got " &
        $answers.len)
  sim.clearMachine()
  var correct = 0
  for index in 0 ..< sim.test.strips.len:
    if answers[index] == sim.test.truth[index]:
      inc correct
  sim.test.answers[seat] = answers
  sim.test.answered[seat] = true
  sim.seats[seat].correct += correct
  sim.seats[seat].answered += sim.test.strips.len
  var event = blankEvent(evAnswer)
  event.test = sim.test.index
  event.round = sim.test.round
  event.seat = seat
  event.answers = answers
  event.correct = correct
  event.scripted = scripted
  event.fallback = fallback
  event.hypothesis = sim.seats[seat].hypothesis
  event.text = sim.seats[seat].notes
  sim.addEvent(event)
  sim.decided[seat] = true
  if sim.pendingSeats().len == 0:
    sim.settleTest()

proc applyResearch*(sim: var Sim, seat: int, strip: string, publish: bool,
    hypothesis, notes: string, scripted: bool, fallback = false) =
  ## `seat` decides this research round: what to do with the result it is
  ## holding, and which strip to feed the machine ("" = skip). Raises
  ## EleusisError on anything illegal; the fifth decision resolves the turn.
  if sim.done:
    raise newException(EleusisError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(EleusisError, "bad seat: " & $seat)
  if sim.phase != phResearch:
    raise newException(EleusisError, "this turn is a prediction test")
  if sim.decided[seat]:
    raise newException(EleusisError,
      sim.names[seat] & " has already decided this round")
  let clean = normaliseStrip(strip)
  sim.recordTalk(seat, hypothesis, notes)
  sim.discloseNow(seat, publish)
  sim.runExperiment(seat, clean, scripted, fallback)

proc applyAnswers*(sim: var Sim, seat: int, answers: seq[Verdict],
    publish: bool, hypothesis, notes: string, scripted: bool,
    fallback = false) =
  ## `seat` answers the open prediction test. Its pending result is disclosed
  ## first, so the last research round's result always gets a decision.
  if sim.done:
    raise newException(EleusisError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(EleusisError, "bad seat: " & $seat)
  if sim.phase != phTest or not sim.test.open:
    raise newException(EleusisError, "no prediction test is open")
  if sim.decided[seat]:
    raise newException(EleusisError,
      sim.names[seat] & " has already answered this test")
  if answers.len != sim.test.strips.len:
    raise newException(EleusisError,
      "a test needs exactly " & $sim.test.strips.len & " answers, got " &
        $answers.len)
  sim.recordTalk(seat, hypothesis, notes)
  sim.discloseNow(seat, publish)
  sim.recordAnswer(seat, answers, scripted, fallback)

proc endEarly*(sim: var Sim) =
  ## Stop now, between batches. The platform kills an episode that outlives
  ## its timeout and keeps NOTHING, so a short honest episode always beats a
  ## long one that never lands. An open test that was never fully answered is
  ## discarded unscored; tests already settled keep their money; a result a
  ## seat is still holding stays hoarded.
  if sim.done:
    return
  ## A result a seat is still holding when the clock stops stays HOARDED: it
  ## never reached the corkboard, so it goes to that seat's drawer exactly as
  ## a `hoard` decision would have put it there. The disclosure is recorded on
  ## the transcript, so a replay re-derives the same drawers and counters.
  for seat in 0 ..< Seats:
    if sim.seats[seat].pending.isSome:
      sim.discloseNow(seat, publish = false)
  if sim.phase == phTest and sim.test.open:
    for seat in 0 ..< Seats:
      if not sim.test.answered[seat]:
        continue
      var correct = 0
      for index in 0 ..< sim.test.strips.len:
        if index < sim.test.answers[seat].len and
            sim.test.answers[seat][index] == sim.test.truth[index]:
          inc correct
      sim.seats[seat].correct -= correct
      sim.seats[seat].answered -= sim.test.strips.len
    sim.test.open = false
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var knowledge = newJArray()
  var credit = newJArray()
  var spend = newJArray()
  var correct = newJArray()
  var answered = newJArray()
  var accuracyNode = newJArray()
  var published = newJArray()
  var hoarded = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    knowledge.add(%sim.seats[seat].knowledge)
    credit.add(%sim.seats[seat].credit)
    spend.add(%sim.seats[seat].spend)
    correct.add(%sim.seats[seat].correct)
    answered.add(%sim.seats[seat].answered)
    accuracyNode.add(%sim.accuracy(seat))
    published.add(%sim.seats[seat].published)
    hoarded.add(%sim.seats[seat].hoarded)
  let closest = sim.closestSeat()
  %*{
    "names": names,
    "scores": scores,
    "knowledge": knowledge,
    "credit": credit,
    "spend": spend,
    "correct": correct,
    "answered": answered,
    "accuracy": accuracyNode,
    "published": published,
    "hoarded": hoarded,
    "rounds": sim.roundsPlayed,
    "maxRounds": sim.config.rounds,
    "tests": sim.testsDone,
    "ruleId": sim.ruleId,
    "rule": sim.ruleText(),
    "closest": closest,
    "closestName": (if closest >= 0: sim.config.players[closest].name else: ""),
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc factJson(fact: Fact): JsonNode =
  %*{
    "strip": fact.strip,
    "verdict": $fact.verdict,
    "author": fact.author,
    "round": fact.round,
    "cites": fact.cites,
    "duplicate": fact.duplicate
  }

proc benchStateJson*(sim: Sim): JsonNode =
  ## One frame. This is exactly the JSON the viewer reads, and the wasm
  ## module emits one per event prefix. `seats[].secrets`, `test.truth` and
  ## `rule` are SPECTATOR-ONLY: they ride on /global and in the replay, and
  ## never on a player socket.
  var seats = newJArray()
  for seat in 0 ..< Seats:
    let state = sim.seats[seat]
    var secrets = newJArray()
    for fact in state.secrets:
      secrets.add(%*{
        "strip": fact.strip,
        "verdict": $fact.verdict,
        "round": fact.round
      })
    var last: JsonNode = newJNull()
    if state.last.isSome:
      let shown = state.last.get()
      last = %*{
        "strip": shown.strip,
        "verdict": $shown.verdict,
        "mode": shown.mode
      }
    seats.add(%*{
      "name": sim.names[seat],
      "score": sim.score(seat),
      "knowledge": state.knowledge,
      "credit": state.credit,
      "spend": state.spend,
      "experiments": state.experiments,
      "published": state.published,
      "hoarded": state.hoarded,
      "correct": state.correct,
      "answered": state.answered,
      "hypothesis": state.hypothesis,
      "notes": state.notes,
      "pending": state.pending.isSome,
      "last": last,
      "secrets": secrets
    })
  var board = newJArray()
  for fact in sim.board:
    board.add(factJson(fact))
  var machine: JsonNode = newJNull()
  if sim.machine.isSome:
    let stamped = sim.machine.get()
    machine = %*{
      "seat": stamped.seat,
      "round": stamped.round,
      "strip": stamped.strip,
      "verdict": $stamped.verdict
    }
  var test: JsonNode = newJNull()
  if sim.test.index > 0:
    var strips = newJArray()
    for strip in sim.test.strips:
      strips.add(%strip)
    var truth = newJArray()
    for verdict in sim.test.truth:
      truth.add(%($verdict))
    var answers = newJArray()
    var correct = newJArray()
    for seat in 0 ..< Seats:
      if sim.test.answered[seat]:
        var row = newJArray()
        for verdict in sim.test.answers[seat]:
          row.add(%($verdict))
        answers.add(row)
        var hits = 0
        for index in 0 ..< sim.test.strips.len:
          if index < sim.test.answers[seat].len and
              sim.test.answers[seat][index] == sim.test.truth[index]:
            inc hits
        correct.add(%hits)
      else:
        answers.add(newJNull())
        correct.add(newJNull())
    test = %*{
      "index": sim.test.index,
      "round": sim.test.round,
      "strips": strips,
      "truth": truth,
      "answers": answers,
      "correct": correct,
      "open": sim.test.open
    }
  var citations = newJArray()
  for citation in sim.citations:
    citations.add(%*{
      "author": citation.author,
      "by": citation.by,
      "strip": citation.strip,
      "amount": citation.amount,
      "test": citation.test
    })
  var decided = 0
  for seat in 0 ..< Seats:
    if sim.decided[seat]:
      inc decided
  %*{
    "seats": seats,
    "board": board,
    "machine": machine,
    "test": test,
    "citations": citations,
    "decided": decided,
    "round": sim.round,
    "rounds": sim.config.rounds,
    "testEvery": sim.config.testEvery,
    "testStrips": sim.config.testStrips,
    "testsDone": sim.testsDone,
    "experimentCost": sim.config.experimentCost,
    "knowledgePool": sim.config.knowledgePool,
    "citePot": sim.config.citePot,
    "phase": $sim.phase,
    "rule": sim.ruleText(),
    "ruleId": sim.ruleId,
    "closest": sim.closestSeat(),
    "gameDone": sim.done,
    "reason": sim.reason
  }

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.round >= 0:
    result["round"] = %event.round
  if event.seat >= 0:
    result["seat"] = %event.seat
  case event.kind
  of evStart, evRound:
    discard
  of evExperiment:
    result["strip"] = %event.strip
    result["verdict"] = %($event.verdict)
    result["cost"] = %event.cost
    result["scripted"] = %event.scripted
    result["fallback"] = %event.fallback
    if event.hypothesis.len > 0:
      result["hypothesis"] = %event.hypothesis
  of evSkip:
    result["scripted"] = %event.scripted
    result["fallback"] = %event.fallback
    if event.hypothesis.len > 0:
      result["hypothesis"] = %event.hypothesis
  of evDisclose:
    result["strip"] = %event.strip
    result["verdict"] = %($event.verdict)
    result["mode"] = %event.mode
  of evTest:
    result["test"] = %event.test
    var strips = newJArray()
    for strip in event.strips:
      strips.add(%strip)
    result["strips"] = strips
    var truth = newJArray()
    for verdict in event.truth:
      truth.add(%($verdict))
    result["truth"] = truth
  of evAnswer:
    result["test"] = %event.test
    var answers = newJArray()
    for verdict in event.answers:
      answers.add(%($verdict))
    result["answers"] = answers
    result["correct"] = %event.correct
    result["scripted"] = %event.scripted
    result["fallback"] = %event.fallback
    if event.hypothesis.len > 0:
      result["hypothesis"] = %event.hypothesis
  of evSettle:
    result["test"] = %event.test
    var correct = newJArray()
    for value in event.correctAll:
      correct.add(%value)
    result["correct"] = correct
    var pool = newJArray()
    for value in event.pool:
      pool.add(%value)
    result["pool"] = pool
    var credit = newJArray()
    for value in event.credit:
      credit.add(%value)
    result["credit"] = credit
    var scores = newJArray()
    for value in event.scores:
      scores.add(%value)
    result["scores"] = scores
    var citations = newJArray()
    for citation in event.citations:
      citations.add(%*{
        "author": citation.author,
        "by": citation.by,
        "strip": citation.strip,
        "amount": citation.amount
      })
    result["citations"] = citations
  of evEnd:
    result["rule"] = %event.rule
    result["ruleId"] = %event.ruleId
    result["closest"] = %event.closest
  if event.text.len > 0:
    result["text"] = %event.text

proc parseVerdict(text: string): Verdict =
  case text.toLowerAscii()
  of "pass", "p", "true":
    result = vPass
  of "fail", "f", "false":
    result = vFail
  else:
    raise newException(EleusisError, "not a verdict: " & text)

proc eventFromJson*(node: JsonNode): GameEvent =
  result = blankEvent(parseEnum[EventKind](node["kind"].getStr()))
  result.round = node{"round"}.getInt(-1)
  result.seat = node{"seat"}.getInt(-1)
  result.strip = node{"strip"}.getStr("")
  result.cost = node{"cost"}.getFloat(0.0)
  result.scripted = node{"scripted"}.getBool(false)
  result.fallback = node{"fallback"}.getBool(false)
  result.hypothesis = node{"hypothesis"}.getStr("")
  result.text = node{"text"}.getStr("")
  result.mode = node{"mode"}.getStr("")
  result.test = node{"test"}.getInt(-1)
  result.rule = node{"rule"}.getStr("")
  result.ruleId = node{"ruleId"}.getInt(-1)
  result.closest = node{"closest"}.getInt(-1)
  if node.hasKey("verdict"):
    result.verdict = parseVerdict(node["verdict"].getStr())
  if node.hasKey("strips"):
    for strip in node["strips"]:
      result.strips.add(strip.getStr())
  if node.hasKey("truth"):
    for verdict in node["truth"]:
      result.truth.add(parseVerdict(verdict.getStr()))
  if node.hasKey("answers"):
    for verdict in node["answers"]:
      result.answers.add(parseVerdict(verdict.getStr()))
  if result.kind == evSettle:
    if node.hasKey("correct"):
      for value in node["correct"]:
        result.correctAll.add(value.getInt())
    if node.hasKey("pool"):
      for value in node["pool"]:
        result.pool.add(value.getFloat())
    if node.hasKey("credit"):
      for value in node["credit"]:
        result.credit.add(value.getFloat())
    if node.hasKey("scores"):
      for value in node["scores"]:
        result.scores.add(value.getFloat())
    if node.hasKey("citations"):
      for citation in node["citations"]:
        result.citations.add(Citation(
          author: citation{"author"}.getInt(-1),
          by: citation{"by"}.getInt(-1),
          strip: citation{"strip"}.getStr(""),
          amount: citation{"amount"}.getFloat(0.0),
          test: result.test
        ))
  elif node.hasKey("correct"):
    result.correct = node["correct"].getInt()

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded transcript by replaying
  ## the DECISION events (disclose / experiment / skip / answer) through the
  ## rules; the rule, the test draws, the verdicts, the money and the
  ## settlement are re-derived and CHECKED against what was recorded, never
  ## trusted. frames[i] = state after events[0..<i].
  var sim = initSim(config)
  ## initSim already logged the start and the first round; the recorded log
  ## opens with those same two.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evRound:
      if sim.done or sim.phase != phResearch or event.round != sim.round:
        raise newException(EleusisError,
          "round " & $event.round & " does not match the re-derivation")
      if sim.events.len == 0 or sim.events[^1].kind != evRound:
        sim.events.add(event)
    of evDisclose:
      sim.discloseNow(event.seat, event.mode != "hoard")
      if sim.events.len == 0 or sim.events[^1].kind != evDisclose or
          sim.events[^1].mode != event.mode:
        raise newException(EleusisError,
          "disclosure by seat " & $event.seat &
            " does not match the re-derivation")
    of evExperiment:
      ## The seat's public hypothesis line and private notes are recorded on
      ## the decision event, so the replay restores them with it.
      sim.recordTalk(event.seat, event.hypothesis, event.text)
      sim.runExperiment(event.seat, event.strip, event.scripted,
        event.fallback)
      if evaluate(sim.rule, event.strip) != event.verdict:
        raise newException(EleusisError,
          "the machine's verdict for " & event.strip &
            " does not match the re-derivation")
    of evSkip:
      sim.recordTalk(event.seat, event.hypothesis, event.text)
      sim.runExperiment(event.seat, "", event.scripted, event.fallback)
    of evTest:
      if sim.test.strips != event.strips or sim.test.truth != event.truth:
        raise newException(EleusisError,
          "test " & $event.test & " does not match the seeded re-derivation")
      if sim.events.len == 0 or sim.events[^1].kind != evTest:
        sim.events.add(event)
    of evAnswer:
      sim.recordTalk(event.seat, event.hypothesis, event.text)
      sim.recordAnswer(event.seat, event.answers, event.scripted,
        event.fallback)
    of evSettle:
      if sim.testCorrect.len == 0 or sim.testCorrect[^1] != event.correctAll:
        raise newException(EleusisError,
          "test " & $event.test & " settled differently on re-derivation")
      var mirrored = false
      for index in countdown(sim.events.high, max(0, sim.events.len - 2)):
        if sim.events[index].kind == evSettle:
          mirrored = true
      if not mirrored:
        sim.events.add(event)
    of evEnd:
      if not sim.done:
        ## A deadline stop is not derivable from the decisions alone; a
        ## recorded "complete" that the rules did not reach is a tamper.
        if event.text != "deadline":
          raise newException(EleusisError,
            "the recorded ending does not match the re-derivation")
        sim.endEarly()
      if sim.reason != event.text:
        raise newException(EleusisError,
          "the recorded ending does not match the re-derivation")
    result.add(sim)
