## Eleusis player: prompt, scripted, or external action policy.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default laboratory strategy), then idles until the final frame. All of the
## actual decision making happens inside the game server, which sends this
## seat's prompt to Claude every turn.
##
## PLAYER_SCRIPTED=openbook (or 1) registers the seat as the built-in
## publish-everything baseline instead; PLAYER_SCRIPTED=hoarder as the
## publish-nothing one. The server plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <eleusis-image> --name my-eleusis \
##     --run /bin/eleusis-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  eleusis/jev_policy,
  whisky

const DefaultPrompt = """
Treat the catalogue as a version space. Every turn, narrow it: cross off
every catalogue entry that contradicts a fact you know - your own results
and everything on the corkboard - and write the survivors in your notes.
Spend your experiment on the strip that would split those survivors closest
to in half; a strip whose verdict you can already predict teaches you
nothing and still costs a dollar. Publish early, while the board is thin and
your result sits one token away from strips nobody has tested: those are the
publications that earn citations for the rest of the game. Once your
shortlist is short, hoard - you are about to out-score everyone on the test
and teaching a rival costs you prize money. Never publish a strip that is
already on the board; it pays nothing, ever.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  let jevRequested = getEnv("PLAYER_JEV") == "1"
  let jev = jevRequested and (
    getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    getEnv("METTA_CAPTURE_URL").strip().len > 0 or
    getEnv("TYPESAFE_API_KEY").strip().len > 0)
  if prompt.len == 0 and not jev:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    if jev: $ %*{"type": "register", "control": "external"}
    else: $ %*{"type": "prompt", "prompt": prompt,
      "scripted": (if jevRequested: "openbook" else: scripted)}

  echo "eleusis player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "eleusis player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""),
    (if jev: ", Jev choices" else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read
  ## (only a timeout returns none), and mummy's send only queues - so the
  ## game's quit(0) can outrun the flushed final frame and this container
  ## would exit 1 on a race the certifier counts as a player failure. A dead
  ## socket after the episode is a normal ending: log it and exit 0.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "eleusis player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "eleusis player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "observation":
          if jev:
            let action = chooseAction(payload["observation"])
            socket.send($ %*{"type": "action", "id": payload["id"],
              "action": action})
        of "final":
          echo "eleusis player: final scores ", payload{"scores"}
          echo "eleusis player: the rule was ", payload{"rule"}.getStr()
          break
        else:
          discard
      except CatchableError as error:
        echo "eleusis player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "eleusis player: socket closed by the game (", error.msg,
      "); exiting 0"
  try:
    socket.close()
  except CatchableError:
    discard
