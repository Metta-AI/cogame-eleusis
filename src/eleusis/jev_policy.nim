## Eleusis policy: rank ordinary experiments, disclosures, and predictions.

import std/[json, os, sets, strutils]
import curly

proc rankedChoice(payload, questions: JsonNode, name: string): string =
  let criteria = questions[name]["criteria"]
  let answer = payload["answers"][name]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      result = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")

proc chooseAction*(observation: JsonNode): JsonNode =
  let testing = observation["phase"].getStr() == "test"
  var questions = newJObject()
  if testing:
    for index, strip in observation["testStrips"].elems:
      questions["answer_" & $index] = %*{
        "type": "choice",
        "instructions": "Predict this strip's hidden verdict.",
        "criteria": {"pass": "The machine accepts " & strip.getStr(),
          "fail": "The machine rejects " & strip.getStr()}
      }
  else:
    var known = initHashSet[string]()
    for fact in observation["facts"]:
      known.incl(fact["strip"].getStr())
    var criteria = newJObject()
    criteria["skip"] = %"Run no experiment and pay nothing"
    for strip in observation["catalogue"]:
      let text = strip.getStr()
      if text notin known and criteria.len <= 12:
        criteria[text] = %("Test " & text)
    questions["experiment"] = %*{
      "type": "choice",
      "instructions": "Choose an experiment that advances your eventual prize and citation income.",
      "criteria": criteria
    }
  if observation["pending"].kind != JNull:
    questions["publish"] = %*{
      "type": "choice",
      "instructions": "Publish your pending result for citations or keep it private.",
      "criteria": {"publish": "Share the result", "hoard": "Keep it private"}
    }

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Eleusis Jev policy has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing Eleusis. Infer the hidden four-colour rule " &
      "from your own results and the public board. The following is your " &
      "seat-private observation:\n" & $observation,
    "questions": questions
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  result = %*{"publish": false, "hypothesis": "", "notes": ""}
  if questions.hasKey("publish"):
    result["publish"] = %(rankedChoice(payload, questions,
      "publish") == "publish")
  if testing:
    var answers = newJArray()
    for index, _ in observation["testStrips"].elems:
      answers.add(%(rankedChoice(payload, questions,
        "answer_" & $index).toUpperAscii()))
    result["answers"] = answers
  else:
    let choice = rankedChoice(payload, questions, "experiment")
    result["experiment"] = %(if choice == "skip": "" else: choice)
  echo "Eleusis Jev player: phase ", observation["phase"].getStr(),
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
