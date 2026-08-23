## Eleusis game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared stage renderer
##   GET /client/chrome.css          - shared broadcast chrome
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (eleusis.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...,"rounds":R,...}
##                   {"type":"state",...} after every event, REDACTED to the
##                   seat's own numbers (the rule, the test truth, other
##                   seats' drawers and notes are not for the seats)
##                   {"type":"final","scores":[...],"rule":...,...}
##   player -> game: {"type":"prompt","prompt":"...","scripted":"openbook"}
##                   (max 4000 runes; scripted plays a built-in baseline for
##                   that seat: "openbook" / "1", or "hoarder")

import
  std/[json, locks, options, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  ReplayVersion = 1
  ShutdownGraceMs = 20_000
    ## The certifier pings /healthz and /global AFTER the player pods start;
    ## a short episode that exits the instant it writes its artifacts fails
    ## that check. Keep answering for a bounded grace, then exit.

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous cog aliases; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.benchStateJson()
  result["type"] = %"state"
  result["game"] = %"eleusis"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## Eleusis is a hidden-information game: a seat never sees the rule, the
  ## test truth, another seat's drawer or another seat's notes. Decisions are
  ## server-side, so this redaction loses the policy nothing.
  let seat = gs.sim.seats[slot]
  var pending: JsonNode = newJNull()
  if seat.pending.isSome:
    let held = seat.pending.get()
    pending = %*{"strip": held.strip, "verdict": $held.verdict}
  %*{
    "type": "state",
    "slot": slot,
    "name": gs.sim.names[slot],
    "round": gs.sim.round,
    "rounds": gs.config.rounds,
    "phase": $gs.sim.phase,
    "score": gs.sim.score(slot),
    "knowledge": seat.knowledge,
    "credit": seat.credit,
    "spend": seat.spend,
    "experiments": seat.experiments,
    "published": seat.published,
    "hoarded": seat.hoarded,
    "correct": seat.correct,
    "answered": seat.answered,
    "pending": pending,
    "boardSize": gs.sim.board.len,
    "started": gs.started,
    "done": gs.sim.done,
    "reason": gs.sim.reason
  }

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole bench; players get the
  ## redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError,
        "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  $ %*{
    "protocol": "eleusis.replay.v" & $ReplayVersion,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": {
      "rounds": gs.config.rounds,
      "testEvery": gs.config.testEvery,
      "testStrips": gs.config.testStrips,
      "seed": gs.config.seed,
      "experimentCost": gs.config.experimentCost,
      "knowledgePool": gs.config.knowledgePool,
      "citePot": gs.config.citePot,
      "ruleId": gs.sim.ruleId,
      "ruleText": gs.sim.ruleText(),
      "sampled": true
    },
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One bench-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.benchStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform, but the final frame goes
    ## to the player sockets — hand them the bench aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "names": aliasNames,
      "rule": results["rule"],
      "closest": results["closest"],
      "rounds": results["rounds"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "eleusis: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  ## Keep /healthz and /global answering while the platform finishes its
  ## post-start probes, then leave.
  echo "eleusis: artifacts written; holding the socket open for ",
    ShutdownGraceMs div 1000, "s"
  sleep(ShutdownGraceMs)
  echo "eleusis: episode complete, shutting down"
  quit(0)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let deadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < deadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "eleusis: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing. Play
    ## inside a fraction of it so results and the replay are written with
    ## room to spare. The hosted dispatcher hands the timeout only to its own
    ## worker sidecar, NOT to the game container, so when the env is silent
    ## assume the configured platform default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "eleusis: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    while true:
      var simCopy: Sim
      var seats: seq[int]
      var prompts: seq[string]
      var scripted: seq[ScriptKind]
      var testing = false
      withLock stateLock:
        if state.sim.done:
          break
        ## Checked BEFORE every batch: an episode that outruns the platform
        ## timeout is discarded whole, so give up rounds rather than the
        ## result.
        if playDeadline > 0.0 and epochTime() > playDeadline:
          echo "eleusis: episode deadline reached after ",
            state.sim.roundsPlayed, "/", config.rounds,
            " rounds; ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        seats = state.sim.pendingSeats()
        simCopy = state.sim
        prompts = state.prompts
        scripted = state.scripted
        testing = state.sim.phase == phTest
        echo "eleusis: ",
          (if testing: "prediction test " & $state.sim.test.index
           else: "round " & $state.sim.round & " of " & $config.rounds),
          " at ", (epochTime() - gameStart).int, "s"

      let batchStart = epochTime()
      ## The slow part (Claude, ONE parallel batch for all five seats) runs
      ## outside the lock on a snapshot; only this thread mutates the sim, so
      ## the snapshot cannot go stale.
      let decisions = client.decideAll(simCopy, seats, prompts, scripted)

      withLock stateLock:
        for index, seat in seats:
          let decision = decisions[index]
          ## A decision the LLM never delivered is a scripted move, and it is
          ## recorded as one: `scripted` true and `fallback` true on the event.
          let wasScripted =
            scripted[seat] != skNone or client.disabled or decision.fallback
          try:
            if testing:
              state.sim.applyAnswers(seat, decision.answers, decision.publish,
                decision.hypothesis, decision.notes, wasScripted,
                decision.fallback)
            else:
              echo "eleusis: ", state.sim.names[seat], " tests ",
                (if decision.strip.len > 0: decision.strip else: "(nothing)"),
                (if decision.publish: " and publishes" else: " and hoards")
              state.sim.applyResearch(seat, decision.strip, decision.publish,
                decision.hypothesis, decision.notes, wasScripted,
                decision.fallback)
          except CatchableError as error:
            echo "eleusis: reply rejected (", error.msg,
              "); using scripted fallback"
            ## Degrade, never hang: if even the fallback is refused the turn
            ## simply stays open and the play deadline settles the episode.
            try:
              let fallback = scriptedAction(state.sim, seat, skOpenbook)
              if testing:
                state.sim.applyAnswers(seat, fallback.answers,
                  fallback.publish, fallback.hypothesis, "", true, true)
              else:
                state.sim.applyResearch(seat, fallback.strip,
                  fallback.publish, fallback.hypothesis, "", true, true)
            except CatchableError as inner:
              echo "eleusis: scripted fallback refused too: ", inner.msg
        state.broadcastLocked()

      ## Floor the wall-clock gap between the STARTS of consecutive batches:
      ## the hosted Bedrock sidecar caps an episode at 30 requests/minute and
      ## sim-time pacing alone gives no floor at all.
      if config.minBatchSpacingMs > 0:
        let elapsedMs = int((epochTime() - batchStart) * 1000.0)
        if elapsedMs < config.minBatchSpacingMs:
          sleep(config.minBatchSpacingMs - elapsedMs)
      if config.turnDelayMs > 0:
        sleep(config.turnDelayMs)

    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8"
    )

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(
      request, clientDir() / "chrome.css",
      "text/css; charset=utf-8"
    )

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "eleusis: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "eleusis.player.v1",
        "slot": slot,
        "name": state.sim.names[slot],
        "rounds": state.config.rounds,
        "testEvery": state.config.testEvery
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering them
      ## itself; the platform's certifier pings /global to check the game is
      ## alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          ## Cut on a rune boundary: a byte slice through a multi-byte
          ## character leaves invalid UTF-8 in the prompt and the replay.
          if prompt.runeLen > MaxPromptLen:
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let node = payload{"scripted"}
          let scripted =
            if node.isNil: skNone
            elif node.kind == JBool: (if node.getBool(): skOpenbook
              else: skNone)
            else: parseScriptKind(node.getStr())
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
          echo "eleusis: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted != skNone: ", scripted " & $scripted else: ""), ")"
      except CatchableError as error:
        echo "eleusis: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  ## Registered in this order and BEFORE any catch-all: the episode runner
  ## probes /healthz, /client/player and /client/global before the player
  ## pods start, and neither /client/ route may open the player socket.
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  let config = payload["config"]
  result.rounds = config{"rounds"}.getInt(24)
  result.testEvery = config{"testEvery"}.getInt(6)
  result.testStrips = config{"testStrips"}.getInt(6)
  result.seed = config{"seed"}.getInt(0)
  result.experimentCost = config{"experimentCost"}.getFloat(1.0)
  result.knowledgePool = config{"knowledgePool"}.getFloat(20.0)
  result.citePot = config{"citePot"}.getFloat(0.5)
  ## The replay carries the episode's fitted cap; never re-fit it. The rule
  ## and every test draw are re-derived from the seed.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states, and
  ## serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("eleusis.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "eleusis: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(EleusisError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "eleusis: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
