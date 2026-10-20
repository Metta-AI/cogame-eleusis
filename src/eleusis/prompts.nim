## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "eleusis-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, alias: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & alias & ", one of 5 rival scientists in the ELEUSIS laboratory."
  of pvPlain: "In the ELEUSIS laboratory, you play " & alias & ". You are one of five scientists competing with each other."
  of pvNumbered: "1. Setting: the ELEUSIS laboratory. 2. Your identity: " & alias & ". 3. Participants: five rival scientists, including you."
  of pvQuestions: "Where are you? The ELEUSIS laboratory. Who are you? " & alias & ", one of its five rival scientists."
  of pvReordered: "Five rival scientists share the ELEUSIS laboratory. You are one of them: " & alias & "."
  of pvHeldoutBriefing: "Take the role of " & alias & " in the ELEUSIS laboratory, competing as one of five scientists."
  of pvHeldoutReference: "Laboratory: ELEUSIS. Scientists: five rivals. Your scientist: " & alias & "."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")
