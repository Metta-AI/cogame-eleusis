## Claude-backed decision making for Eleusis. Each seat's policy is just a
## prompt: the game server composes the seat's view (its own experiment log,
## the corkboard, the scoreboard, the test results, its private notes) plus
## that seat's prompt and asks Claude what it experiments on, and whether it
## publishes what it is holding.
##
## Every seat decides SIMULTANEOUSLY by rule, so all five requests go out as
## ONE parallel batch per turn (curly.makeRequests); invalid replies are
## retried once as a smaller batch with a hint, and anything still failing
## falls back to the `openbook` scripted baseline.
##
## Credentials, in order of preference:
##   COWORLD_LLM_ENDPOINT            - hosted sidecar
##   Bedrock bearer token            - local play
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal scripted
## baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## scripted plays one deliberately, LLM or not.

import
  std/[json, options, os, random, sets, strutils, times, unicode],
  bitworld/[runtime, decision_trajectory],
  curly,
  sim, prompts
export prompts

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  ScriptKind* = enum
    skNone = "none"
    skOpenbook = "openbook"
    skHoarder = "hoarder"
    skFreerider = "freerider"

  Decision* = object
    attempts*: seq[DecisionAttempt]
    selectedAttemptId*: Option[string]
    strip*: string          ## "" = skip (no experiment, no cost)
    publish*: bool
    answers*: seq[Verdict]  ## test turns only
    hypothesis*: string
    notes*: string          ## "" when the reply carried none
    fallback*: bool         ## true when the scripted baseline stood in for an
                            ## LLM reply that never arrived, so the server can
                            ## record it on the event and phase 60 can count it

  LlmTransport = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    sidecarEndpoint: string
    bedrockEndpoint: string ## local Bedrock transport
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string         ## direct-Anthropic transport only; Bedrock
                          ## picks from bedrockModels instead
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"openbook" play the publish-
  ## everything baseline, "hoarder" the publish-nothing one, anything else
  ## nothing (the seat is LLM-driven).
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "openbook", "open-book", "open": skOpenbook
  of "hoarder", "hoard", "secretive": skHoarder
  of "freerider", "free-rider", "free": skFreerider
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "eleusis llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL pins
  ## a single id; without it, fall through this list — model access is a
  ## per-account Marketplace subscription, so an id that works in one account
  ## 403s in another. Haiku leads: hosted Bedrock capacity is shared
  ## account-wide and the sonnet profiles run out of daily tokens first.
  ## `us.anthropic.claude-sonnet-4-6` is deliberately NOT a candidate: it
  ## times out on every sidecar call, and one throttle then cascades into
  ## scripted fallbacks (cogame-raid, 2026-08-23).
  ## The config "model" field is NOT consulted here: it applies to
  ## the direct-Anthropic transport only, and the haiku-first
  ## ordering is a shared-capacity decision that trumps per-game
  ## preference.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "eleusis llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "eleusis llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel],
      ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "eleusis llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "eleusis llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------
#
# One engine, two disclosure policies: `openbook` publishes every pending
# result, `hoarder` publishes none. That is exactly the axis the game is
# about, so the two fillers are a live control experiment.

proc sweepOrder(seed, seat: int): seq[int] =
  ## A per-seat shuffle of the strip universe, so five baselines do not run
  ## the same sweep and tie-breaking differs seat by seat.
  var rng = initRand(int64(seed) * 7919 + 101 * seat + 3)
  result = newSeq[int](StripUniverse)
  for index in 0 ..< StripUniverse:
    result[index] = index
  rng.shuffle(result)

proc splitCount(consistent: seq[Rule], strip: string): int =
  for rule in consistent:
    if evaluate(rule, strip) == vPass:
      inc result

proc predict*(consistent: seq[Rule], strip: string): Verdict =
  ## Majority vote of the surviving hypotheses; ties (and an empty version
  ## space, only reachable from a corrupt board) predict PASS.
  if consistent.len == 0:
    return vPass
  if 2 * splitCount(consistent, strip) >= consistent.len: vPass else: vFail

proc chooseStrip*(sim: Sim, seat: int, consistent: seq[Rule],
    known: HashSet[string]): string =
  ## Information-greedy: the strip whose PASS-split among the surviving
  ## hypotheses is closest to half, skipping strips whose verdict this seat
  ## already knows. Ties break by the seat's own sweep order.
  var best = -1
  for index in sweepOrder(sim.config.seed, seat):
    let strip = stripOfIndex(index)
    if strip in known:
      continue
    let hits = splitCount(consistent, strip)
    let gap = abs(2 * hits - consistent.len)
    if best < 0 or gap < best:
      best = gap
      result = strip
      if gap <= 1:
        return

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## Rule-based baseline for `seat`, legal by construction: a strip from the
  ## universe (or a skip) on a research round, exactly `testStrips`
  ## PASS/FAIL answers on a test. Never writes notes.
  let facts = sim.knownFacts(seat)
  let consistent = consistentRules(facts)
  result.hypothesis =
    if consistent.len > 0: describeRule(consistent[0])
    else: "no consistent rule"
  result.publish = kind == skOpenbook
  if sim.phase == phTest:
    for strip in sim.test.strips:
      result.answers.add(predict(consistent, strip))
  else:
    if kind != skFreerider:
      var known = initHashSet[string]()
      for fact in facts:
        known.incl(fact.strip)
      result.strip = chooseStrip(sim, seat, consistent, known)

# ---- Prompt building --------------------------------------------------------

proc money(value: float): string =
  formatFloat(value, ffDecimal, 2)

const SystemTemplate = """<introduction>

A sealed machine holds ONE hidden rule. You feed it a STRIP of exactly 4
coloured tokens - each token is R (red), B (blue), G (green) or Y (yellow),
written as 4 letters, e.g. RBGY - and it stamps PASS (the strip obeys the
rule) or FAIL (it does not).

The hidden rule is exactly ONE entry of this public catalogue (68 in all):
  CONTAINS c        - c appears at least once                  (c in R,B,G,Y)
  AT-LEAST-2 c      - c appears two or more times
  PARITY c even/odd - the number of c's is even (0 is even) / odd
  ADJACENT c d      - somewhere c is immediately followed by d (d may equal c)
  BEFORE c d        - both appear, and the first c is left of the first d
  STARTS c          - the first token is c
  ENDS c            - the fourth token is c
  ENDS-SAME / ENDS-DIFFER - first token equals / differs from the fourth
  NO-REPEAT / HAS-REPEAT  - no two neighbouring tokens are equal / some are
  MORE c d          - c appears strictly more often than d
Every strip the machine PASSES obeys that one rule; every strip it FAILS
breaks it. Nothing else is random.

<research>

<rewards>

Your notes are private and are handed back to you every turn. Your
hypothesis line is PUBLIC - every rival reads it, and it is not binding.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis,
no explanation, no markdown fences, no text before or after the object. Your
reply must begin with the character { and end with }."""

proc systemPrompt*(sim: Sim, seat: int, selection: PromptSelection): string =
  ## The seat's rules-of-the-world block. The whole hypothesis space is
  ## public; only the instance is hidden.
  let research = case selection.selectedVariant
    of pvCanonical: "Each round you may run ONE experiment; it costs $<experimentCost>. ONLY YOU\nsee the verdict. On your NEXT turn you decide what to do with it:\n - PUBLISH: it is pinned to the shared corkboard. Every rival reads it, and\n   you may earn citation credit later. Publishing a strip somebody already\n   published earns nothing, ever.\n - HOARD: it stays yours alone."
    of pvPlain: "Each round allows one experiment costing $<experimentCost>; only you learn its verdict. On your next turn, choose PUBLISH to put that result on the public corkboard, where rivals can read it and it may earn citation credit, or HOARD to keep it private. Publishing an already published strip never earns anything."
    of pvNumbered: "1. Run at most one experiment per round for $<experimentCost>.\n2. Its verdict is private to you.\n3. Next turn, PUBLISH it to the corkboard for rivals to read and possible citation credit, or HOARD it privately.\n4. A strip already published can never earn anything through duplicate publication."
    of pvQuestions: "What does an experiment cost? $<experimentCost>, with one allowed each round. Who sees its verdict? Only you. What happens next turn? You choose PUBLISH for the public corkboard and possible citation credit, or HOARD to keep it private. Can publishing an already published strip pay? Never."
    of pvReordered: "PUBLISH puts a result on the corkboard for every rival to read and may earn citation credit; HOARD keeps it private. You make this choice on the turn after the experiment. Each round permits one experiment costing $<experimentCost>, with a verdict visible only to you. Duplicate publication never earns anything."
    of pvHeldoutBriefing: "Run one experiment in a round at a cost of $<experimentCost> and receive its verdict privately. At the following turn, decide whether to share it through PUBLISH or retain it through HOARD. Publication makes it visible to all rivals and eligible for citation credit, but publishing a strip already on the corkboard never pays."
    of pvHeldoutReference: "Experiment limit: one per round. Cost: $<experimentCost>. Verdict visibility: you alone. Following-turn choice: PUBLISH to the shared corkboard for rival access and possible citation credit, or HOARD privately. Duplicate publication: never pays."
    of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")
  let rewards = case selection.selectedVariant
    of pvCanonical: "Every <testEvery> rounds a PREDICTION TEST scores everyone: <testStrips>\nstrips nobody has ever tested, exactly half of which the machine passes. A\nprize pool of $<knowledgePool> is split between the seats in proportion to\nhow many each got right - so every rival you teach takes a slice of your\npool. Citation credit pays the other way: when another seat answers a test\nstrip correctly and one of YOUR published results differs from that strip in\nexactly one token, a $<citePot> pot for that strip is shared between the\nseats whose published results do. You are never paid for your own answers.\n\nYour score is prize money + citation credit - $<experimentCost> per\nexperiment. Highest score wins. Nothing else scores."
    of pvPlain: "Every <testEvery> rounds, all seats predict <testStrips> never-tested strips, exactly half of which PASS. Split the $<knowledgePool> prize pool in proportion to each seat's correct answers: teaching rivals increases their share of your pool. For each correct rival answer, a $<citePot> citation pot is shared among seats with a published result differing from that test strip in exactly one token. Your own answers never pay you citation credit. Score = prize money + citation credit - $<experimentCost> per experiment. Highest score wins; nothing else scores."
    of pvNumbered: "1. Every <testEvery> rounds, predict <testStrips> previously untested strips; exactly half PASS.\n2. Divide $<knowledgePool> among seats in proportion to correct answers. A rival you teach takes a slice of this pool.\n3. When a rival is correct, split a $<citePot> pot among seats whose published results differ from that test strip in exactly one token. Your own answers never earn you citation credit.\n4. Score only prize money + citation credit - $<experimentCost> per experiment. Highest wins."
    of pvQuestions: "When are predictions tested? Every <testEvery> rounds on <testStrips> never-tested strips, exactly half PASS. How is $<knowledgePool> divided? In proportion to each seat's correct answers; teaching a rival gives it a slice of your pool. When do citations pay? A correct rival answer triggers a $<citePot> pot shared among seats whose published results differ from that strip in exactly one token. Your own answers never pay you citations. What wins? The highest prize money plus citation credit minus $<experimentCost> per experiment; nothing else scores."
    of pvReordered: "Win with the highest score: prize money + citation credit - $<experimentCost> per experiment, with nothing else scoring. Citation pots of $<citePot> reward seats whose published results differ by exactly one token from a test strip answered correctly by a rival; your own answers never pay you citations. Prediction tests occur every <testEvery> rounds on <testStrips> untested strips, exactly half PASS. The $<knowledgePool> prize pool is shared in proportion to correct answers, so teaching rivals gives them a slice of your pool."
    of pvHeldoutBriefing: "Balance shared science against competition. Every <testEvery> rounds, all seats predict <testStrips> untested strips, half PASS. Correct-answer counts determine proportional shares of $<knowledgePool>, so informed rivals take a slice of your pool. A correct rival answer also shares a $<citePot> citation pot among seats with published results one token away from that strip; your own answers cannot pay you citations. Only prize money plus citation credit minus $<experimentCost> per experiment determines score. Highest wins."
    of pvHeldoutReference: "Test cadence: every <testEvery> rounds. Test set: <testStrips> never-tested strips, exactly half PASS. Prize: $<knowledgePool>, divided in proportion to correct answers; teaching rivals increases their share. Citation trigger: a rival answers a test strip correctly. Citation pool: $<citePot> per strip, shared among seats with published results exactly one token different; no citation payment for your own answers. Score: prize + citations - $<experimentCost> per experiment; highest wins, no other scoring."
    of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")
  SystemTemplate
    .replace("<research>", research)
    .replace("<rewards>", rewards)
    .replace("<introduction>", selection.introduction(sim.names[seat]))
    .replace("<experimentCost>", money(sim.config.experimentCost))
    .replace("<testEvery>", $sim.config.testEvery)
    .replace("<testStrips>", $sim.config.testStrips)
    .replace("<knowledgePool>", money(sim.config.knowledgePool))
    .replace("<citePot>", money(sim.config.citePot))

proc experimentTable(sim: Sim, seat: int): string =
  var lines: seq[string]
  lines.add("round | strip | verdict | published?")
  for fact in sim.seats[seat].log:
    let mode =
      if fact.mode.len == 0: "PENDING — decide now"
      else: fact.mode
    lines.add($fact.round & " | " & fact.strip & " | " &
      ($fact.verdict).toUpperAscii() & " | " & mode)
  if sim.seats[seat].log.len == 0:
    lines.add("(you have run no experiments yet)")
  lines.join("\n")

proc boardTable(sim: Sim): string =
  var lines: seq[string]
  lines.add("round | author | strip | verdict")
  for fact in sim.board:
    let author =
      if fact.duplicate or fact.author < 0: "(confirmed, no author)"
      else: sim.names[fact.author]
    lines.add($fact.round & " | " & author & " | " & fact.strip & " | " &
      ($fact.verdict).toUpperAscii())
  if sim.board.len == 0:
    lines.add("(nothing has been published yet)")
  lines.join("\n")

proc scoreTable(sim: Sim, seat: int): string =
  var lines: seq[string]
  lines.add("seat | score | prizes | credit | experiments | published | " &
    "latest hypothesis")
  for other in 0 ..< Seats:
    let state = sim.seats[other]
    lines.add(sim.names[other] & (if other == seat: " (you)" else: "") &
      " | $" & money(sim.score(other)) & " | $" & money(state.knowledge) &
      " | $" & money(state.credit) & " | " & $state.experiments & " | " &
      $state.published & " | " &
      (if state.hypothesis.len > 0: "\"" & state.hypothesis & "\""
       else: "(silent)"))
  lines.join("\n")

proc testTable(sim: Sim): string =
  if sim.testCorrect.len == 0:
    return "(no prediction test has been scored yet)"
  var lines: seq[string]
  for index, correct in sim.testCorrect:
    var parts: seq[string]
    for other in 0 ..< Seats:
      parts.add(sim.names[other] & " " & $correct[other] & "/" &
        $sim.config.testStrips)
    lines.add("test " & $(index + 1) & ": " & parts.join(", "))
  lines.join("\n")

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let testing = sim.phase == phTest
  if testing:
    result.add("PREDICTION TEST " & $sim.test.index & " — answer all " &
      $sim.config.testStrips & " strips.\n")
    var parts: seq[string]
    for index, strip in sim.test.strips:
      parts.add($(index + 1) & ". " & strip)
    result.add("THE STRIPS, IN ORDER: " & parts.join("   ") & "\n")
    result.add("Nobody has ever tested these; exactly half of them PASS.\n\n")
  else:
    let nextTest =
      ((sim.round - 1) div sim.config.testEvery + 1) * sim.config.testEvery
    result.add("ROUND " & $sim.round & " OF " & $sim.config.rounds &
      " — next prediction test after round " &
      $min(nextTest, sim.config.rounds) & ".\n\n")
    if sim.seats[seat].pending.isSome:
      let pending = sim.seats[seat].pending.get()
      result.add("YOUR PENDING RESULT: " & pending.strip & " -> " &
        ($pending.verdict).toUpperAscii() &
        " (publish it or hoard it now)\n\n")
    else:
      result.add("YOUR PENDING RESULT: (none)\n\n")
  result.add("YOUR EXPERIMENTS SO FAR:\n" & sim.experimentTable(seat) & "\n\n")
  result.add("THE CORKBOARD (" & $sim.board.len & " published results):\n" &
    sim.boardTable() & "\n\n")
  result.add("SCOREBOARD:\n" & sim.scoreTable(seat) & "\n\n")
  result.add("TEST RESULTS SO FAR:\n" & sim.testTable() & "\n\n")
  result.add("YOUR NOTES FROM EARLIER ROUNDS:\n" &
    (if sim.seats[seat].notes.len > 0: sim.seats[seat].notes
     else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  if testing:
    var slots: seq[string]
    for index in 0 ..< sim.config.testStrips:
      slots.add("\"PASS\"")
    result.add("Reply with ONLY {\"answers\": [" & slots.join(", ") &
      "], \"publish\": true, \"hypothesis\": \"…\", \"notes\": \"…\"} — " &
      "answers is exactly " & $sim.config.testStrips &
      " entries of PASS or FAIL, one per strip in the order listed; " &
      "publish decides the result you are holding (if any); hypothesis is " &
      "PUBLIC and at most " & $MaxHypothesisLen &
      " characters; notes are private and at most " & $MaxNotesLen &
      " characters.")
  else:
    result.add("Reply with ONLY {\"experiment\": \"RBGY\", " &
      "\"publish\": true, \"hypothesis\": \"…\", \"notes\": \"…\"} — " &
      "experiment is 4 letters from RBGY (or \"\" to run none and pay " &
      "nothing); publish decides the result you are holding (if any); " &
      "hypothesis is PUBLIC and at most " & $MaxHypothesisLen &
      " characters; notes are private and at most " & $MaxNotesLen &
      " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model sent
    ## instead of JSON (prose, a refusal, a cut-off analysis...).
    var head = text.strip()
    if head.len > 160:
      head = head[0 ..< 160] & "..."
    raise newException(EleusisError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string, slot: int):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    result.url = client.sidecarEndpoint & "/v1/messages"
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or an EleusisError describing why there
  ## is none. Auth failures disable the client; model-access and throttle
  ## failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(EleusisError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(EleusisError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(EleusisError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(EleusisError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(EleusisError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(EleusisError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(EleusisError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked. A byte
  ## slice through a multi-byte character would leave invalid UTF-8 in the
  ## replay and break its JSON.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc parseBoolish(node: JsonNode): bool =
  if node.isNil:
    return false
  case node.kind
  of JBool: node.getBool()
  of JInt: node.getInt() != 0
  of JFloat: node.getFloat() != 0.0
  of JString:
    case node.getStr().strip().toLowerAscii()
    of "true", "yes", "y", "1", "publish": true
    else: false
  else: false

proc parseAnswer(node: JsonNode): Verdict =
  if node.kind == JBool:
    return (if node.getBool(): vPass else: vFail)
  if node.kind != JString:
    raise newException(EleusisError,
      "an answer must be PASS or FAIL, got " & $node)
  case node.getStr().strip().toLowerAscii()
  of "pass", "p", "true", "yes":
    result = vPass
  of "fail", "f", "false", "no":
    result = vFail
  else:
    raise newException(EleusisError,
      "an answer must be PASS or FAIL: " & node.getStr())

proc parseDecision*(payload: JsonNode, testStrips: int, testing: bool):
    Decision =
  ## Tolerant on shape, strict on legality.
  if payload.isNil or payload.kind != JObject:
    raise newException(EleusisError, "the reply is not a JSON object")
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.hypothesis = cleanText(payload{"hypothesis"}.getStr(),
    MaxHypothesisLen).replace("\n", " ")
  result.publish = parseBoolish(payload{"publish"})
  if testing:
    let node = payload{"answers"}
    if node.isNil or node.kind != JArray:
      raise newException(EleusisError, "no answers array in the reply")
    if node.len != testStrips:
      raise newException(EleusisError, "answers must have exactly " &
        $testStrips & " entries, got " & $node.len)
    for entry in node:
      result.answers.add(parseAnswer(entry))
  else:
    let node = payload{"experiment"}
    if node.isNil:
      raise newException(EleusisError, "no experiment in the reply")
    if node.kind != JString:
      raise newException(EleusisError,
        "experiment must be a 4-letter string: " & $node)
    result.strip = normaliseStrip(node.getStr())

proc decisionJson*(decision: Decision, testing: bool): JsonNode =
  result = %*{"publish": decision.publish, "hypothesis": decision.hypothesis, "notes": decision.notes}
  if testing:
    result["answers"] = newJArray()
    for answer in decision.answers: result["answers"].add(%($answer))
  else:
    result["experiment"] = %decision.strip

proc playsScripted*(client: LlmClient, prompt: string,
    kind: ScriptKind): bool =
  ## A seat plays a built-in baseline instead of Claude when it registered as
  ## scripted, when there are no credentials at all, or when it has never
  ## delivered a prompt — the reference player always sends one (its own
  ## default strategy when `PLAYER_PROMPT` is empty), so an empty prompt means
  ## the pod never connected inside `playerConnectTimeoutSeconds`. Such a slot
  ## plays `openbook` rather than an LLM call with no operator guidance.
  kind != skNone or client.disabled or prompt.strip().len == 0

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind],
  selection: PromptSelection
): seq[Decision] =
  ## One decision per seat in `seats`, in order — all of them as ONE parallel
  ## batch, because every seat decides simultaneously by rule. Never raises:
  ## any failure falls back to the `openbook` scripted baseline so the
  ## episode always advances. `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  let testing = sim.phase == phTest
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if client.playsScripted(prompts[seat], kind):
      result[index] = scriptedAction(sim, seat,
        (if kind == skNone: skOpenbook else: kind))
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    var evidenceBatch: seq[DecisionAttempt]
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\n\nYour previous reply was invalid. Respond with ONLY " &
          "the requested JSON object and nothing else.")
      let request = client.requestFor(systemPrompt(sim, seat, selection), user, seat)
      var evidence = newDecisionAttempt($sim.round & "-" & $sim.phase & "-" & $seat & "-" & $attempt,
        "prompt", aoModel)
      evidence.prompt = %*[{"role": "system", "content": systemPrompt(sim, seat, selection)},
        {"role": "user", "content": user}]
      evidence.request = parseJson(request.body)
      evidence.decoder = %*{"max_tokens": client.maxOutputTokens}
      if evidence.request.hasKey("output_config"):
        evidence.decoder["output_config"] = evidence.request["output_config"]
      if evidence.request.hasKey("model"):
        evidence.model = some(evidence.request["model"].getStr())
      evidenceBatch.add(evidence)
      batch.post(request.url, request.headers, request.body, $index)
    let started = epochTime()
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      var evidence = evidenceBatch[position]
      let native = responses[position].response
      evidence.rawResponse = %native.body
      evidence.httpStatus = some(native.code)
      evidence.latencyMs = some((epochTime() - started) * 1000)
      if native.headers["x-softmax-llm-call-id"].len > 0:
        evidence.platformCallId = some(native.headers["x-softmax-llm-call-id"])
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        evidence.response = %text
        let payload = parseJson(native.body)
        if payload.hasKey("model"): evidence.model = some(payload["model"].getStr())
        if payload.hasKey("stop_reason"): evidence.stopReason = some(payload["stop_reason"].getStr())
        if payload.hasKey("usage"):
          if payload["usage"].hasKey("input_tokens"): evidence.inputTokens = some(payload["usage"]["input_tokens"].getInt())
          if payload["usage"].hasKey("output_tokens"): evidence.outputTokens = some(payload["usage"]["output_tokens"].getInt())
        var decision = parseDecision(extractJsonObject(text),
          sim.config.testStrips, testing)
        evidence.parsedAction = decisionJson(decision, testing)
        ## Reject illegal replies HERE so the retry carries the hint and an
        ## illegal move never reaches the real sim.
        var probe = sim
        if testing:
          probe.applyAnswers(seat, decision.answers, decision.publish,
            decision.hypothesis, decision.notes, false)
        else:
          probe.applyResearch(seat, decision.strip, decision.publish,
            decision.hypothesis, decision.notes, false)
        evidence.accepted = true
        decision.attempts = result[index].attempts & @[evidence]
        decision.selectedAttemptId = some(evidence.attemptId)
        result[index] = decision
      except CatchableError as error:
        evidence.rejectionReason = some(error.msg)
        result[index].attempts.add(evidence)
        echo "eleusis llm: seat ", seat, " attempt ", attempt, " failed: ",
          error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "eleusis llm: seat ", seat, " falling back to scripted decision"
    let attempts = result[index].attempts
    result[index] = scriptedAction(sim, seat, skOpenbook)
    result[index].attempts = attempts
    ## Recorded on the decision event too, not only on stdout: the replay is
    ## what phase 60 counts fallbacks from.
    result[index].fallback = true
