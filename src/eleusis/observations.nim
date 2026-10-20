## Private decision observations for full-game collection.
import std/[json, options]
import sim

proc decisionView*(view: Sim, seat: int, textMode: bool): JsonNode =
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
  result = %*{"round": view.round, "rounds": view.config.rounds,
      "phase": $view.phase, "board": board, "own_facts": ownFacts,
      "seats": seats, "test_strips": strips,
      "pending": (if view.seats[seat].pending.isSome:
        %*{"strip": view.seats[seat].pending.get().strip,
          "verdict": $view.seats[seat].pending.get().verdict}
        else: newJNull())}

  if textMode:
    result["notes"] = %view.seats[seat].notes
    for other in 0 ..< Seats:
      result["seats"][other]["hypothesis"] = %view.seats[other].hypothesis
