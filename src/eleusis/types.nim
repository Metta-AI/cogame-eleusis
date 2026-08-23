import std/[json, strutils]

type
  EleusisError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    rounds*: int              ## research rounds in the episode
    testEvery*: int           ## a prediction test after every N research rounds
    testStrips*: int          ## strips per prediction test (even)
    experimentCost*: float    ## charged per experiment run
    knowledgePool*: float     ## prize money split by each test's correct answers
    citePot*: float           ## per test strip, shared by the supporting authors
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool            ## true once the budget cap has been applied
    minBatchSpacingMs*: int   ## wall-clock floor between the STARTS of two batches
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  Verdict* = enum
    ## What the sealed machine stamps on a strip.
    vPass = "pass"
    vFail = "fail"

  Citation* = object
    ## One citation payment: `author`'s published fact sat one token away
    ## from a strip `by` answered correctly in test `test`.
    author*: int
    by*: int
    strip*: string
    amount*: float
    test*: int

  EventKind* = enum
    evStart = "start"
    evRound = "round"
    evExperiment = "experiment"
    evSkip = "skip"
    evDisclose = "disclose"
    evTest = "test"
    evAnswer = "answer"
    evSettle = "settle"
    evEnd = "end"

  GameEvent* = object
    ## Flat, JSON-friendly transcript entry. The replay's `events[]` is the
    ## whole transcript, and the wasm viewer re-derives every frame from it.
    kind*: EventKind
    round*: int              ## round/experiment/skip/disclose/test: the round;
                             ## end: rounds played; start: -1
    seat*: int               ## -1 when the event is not a seat's
    strip*: string           ## experiment/disclose
    verdict*: Verdict        ## experiment/disclose
    cost*: float             ## experiment
    scripted*: bool          ## experiment/skip/answer
    fallback*: bool          ## experiment/skip/answer: the scripted baseline
                             ## stood in for an LLM reply that never arrived
    hypothesis*: string      ## experiment/skip/answer: the seat's public line
    text*: string            ## experiment/skip/answer: notes; end: reason
    mode*: string            ## disclose: publish | hoard | duplicate
    test*: int               ## test/answer/settle: 1-based test index
    strips*: seq[string]     ## test
    truth*: seq[Verdict]     ## test (spectator-only; derived and asserted)
    answers*: seq[Verdict]   ## answer
    correct*: int            ## answer: this seat's correct count
    correctAll*: seq[int]    ## settle: correct per seat
    pool*: seq[float]        ## settle: prize share per seat
    credit*: seq[float]      ## settle: citation credit per seat
    scores*: seq[float]      ## settle: running score per seat
    citations*: seq[Citation] ## settle
    rule*: string            ## end: the revealed rule text
    ruleId*: int             ## end
    closest*: int            ## end: the seat with the best test accuracy, or -1

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    rounds: 24,
    testEvery: 6,
    testStrips: 6,
    experimentCost: 1.0,
    knowledgePool: 20.0,
    citePot: 0.5,
    episodeTimeoutSeconds: 1200,
    minBatchSpacingMs: 12000,
    turnDelayMs: 0,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 40
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(EleusisError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("rounds"):
    config.rounds = node["rounds"].getInt()
  if node.hasKey("testEvery"):
    config.testEvery = node["testEvery"].getInt()
  if node.hasKey("testStrips"):
    config.testStrips = node["testStrips"].getInt()
  if node.hasKey("experimentCost"):
    config.experimentCost = node["experimentCost"].getFloat()
  if node.hasKey("knowledgePool"):
    config.knowledgePool = node["knowledgePool"].getFloat()
  if node.hasKey("citePot"):
    config.citePot = node["citePot"].getFloat()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("minBatchSpacingMs"):
    config.minBatchSpacingMs = node["minBatchSpacingMs"].getInt()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.rounds < 4:
    raise newException(EleusisError, "rounds must be at least 4")
  if config.testEvery < 2:
    raise newException(EleusisError, "testEvery must be at least 2")
  if config.testStrips mod 2 != 0:
    raise newException(EleusisError, "testStrips must be even")
  if config.testStrips < 2 or config.testStrips > 12:
    raise newException(EleusisError, "testStrips must be 2..12")
