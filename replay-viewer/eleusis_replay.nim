## Eleusis static replay viewer, wasm side.
##
## JS hands the raw replay bytes to el_load_replay; this module parses them
## with the SAME sim code the game server runs, re-derives the per-event
## bench states, and exposes the enriched payload (identical shape to the
## game's /replay websocket message) for the shared renderer.js to draw.

import
  std/json,
  eleusis/sim

var
  payload: string
  lastError: string

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc elLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "el_load_replay", cdecl.} =
  try:
    lastError = ""
    let replay = parseJson(bytesFromPointer(data, int(length)))
    var config = defaultGameConfig()
    config.rounds = replay["config"]{"rounds"}.getInt(24)
    config.testEvery = replay["config"]{"testEvery"}.getInt(6)
    config.testStrips = replay["config"]{"testStrips"}.getInt(6)
    config.seed = replay["config"]{"seed"}.getInt(0)
    config.experimentCost = replay["config"]{"experimentCost"}.getFloat(1.0)
    config.knowledgePool = replay["config"]{"knowledgePool"}.getFloat(20.0)
    config.citePot = replay["config"]{"citePot"}.getFloat(0.5)
    config.sampled = true
    for name in replay["names"]:
      config.players.add(PlayerConfig(name: name.getStr()))
    ## The hidden rule is re-derived from the seed, never read from the
    ## payload: a recorded ruleId that disagrees with the re-derivation means
    ## the bytes and this build's rules are not the same game.
    let recordedRule = replay["config"]{"ruleId"}.getInt(-1)
    let derived = pickRule(config.seed)
    if recordedRule >= 0 and derived.id != recordedRule:
      raise newException(EleusisError,
        "the replay's ruleId " & $recordedRule &
          " does not match the seeded re-derivation " & $derived.id)
    var events: seq[GameEvent]
    for node in replay["events"]:
      events.add(eventFromJson(node))
    var states = newJArray()
    for frame in replayMatch(config, events):
      states.add(frame.benchStateJson())
    payload = $ %*{
      "type": "replay",
      "protocol": replay{"protocol"}.getStr("eleusis.replay.v1"),
      "names": replay["names"],
      "policyNames": replay{"policyNames"},
      "config": replay["config"],
      "events": replay["events"],
      "results": replay{"results"},
      "states": states
    }
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc elPayloadPointer(): ptr uint8 {.exportc: "el_payload_ptr", cdecl.} =
  if payload.len == 0:
    nil
  else:
    cast[ptr uint8](payload[0].addr)

proc elPayloadLength(): cint {.exportc: "el_payload_len", cdecl.} =
  cint(payload.len)

proc elErrorPointer(): ptr uint8 {.exportc: "el_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc elErrorLength(): cint {.exportc: "el_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `payload` and friends while JS keeps calling into the module.
  ## Exiting with a live runtime skips the destructor epilogue so globals
  ## stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
