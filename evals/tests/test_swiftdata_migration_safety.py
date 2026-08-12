"""A stored property added to a @Model must carry its own default value.

This test exists because shipping one that did not bricked the app on device.

SwiftData's lightweight migration never calls the initializer. When it finds a
column in the destination schema that the existing store lacks, it fills it
from the *property's* default. A mandatory attribute with no default cannot be
filled, so the migration aborts:

    Cannot migrate store in-place: Validation error missing attribute values
    on mandatory destination attribute
    UserInfo={entity=ModelRun, attribute=attempt}

`CizgiApp.init` treats a store that will not open as unrecoverable and calls
`fatalError` — correctly, since carrying on would silently drop captures. The
result is an app that cannot be opened at all, on a store it cannot repair,
and no amount of restarting helps. Four fields on `ModelRun` (`attempt`,
`cachedInputTokens`, `reasoningTokens`, `billing`) shipped that way; the
`Card.softLapseCount` added one phase earlier had its `= 0` and was fine, so
the correct pattern was already in the file and simply not followed.

The rule this locks: **every new non-optional stored property on a @Model is
either optional or defaulted.** Properties in `BASELINE` predate the guard and
are safe for a different reason — they were present when the store was first
created, so no migration ever had to fill them. Adding to `BASELINE` is
therefore almost always the wrong fix; add `= <default>` to the property
instead.

Written in Python rather than as a Swift test on purpose: `Models.swift`
imports SwiftData and cannot be compiled off a Mac, so a Swift test would only
run in CI's macOS job — which is exactly where this class of bug is least
likely to be caught early. This runs anywhere `pytest` does.
"""

from __future__ import annotations

import re
from pathlib import Path

MODELS = (
    Path(__file__).resolve().parents[2]
    / "ios"
    / "CizgiCore"
    / "Sources"
    / "CizgiCore"
    / "Models"
    / "Models.swift"
)

# Non-optional stored properties that were already in the schema when this
# guard was written. Safe because they shipped with the store rather than
# being migrated into it. Do not extend this to silence a failure.
BASELINE: dict[str, set[str]] = {
    "Source": {"createdAt", "id", "updatedAt"},
    "CapturedPage": {
        "captureDate", "documentQualityScore", "id",
        "originalImagePath", "processingStateRaw", "retryCount",
    },
    "TextRegion": {
        "boundingBoxHeight", "boundingBoxWidth", "boundingBoxX", "boundingBoxY",
        "confidence", "finalText", "id", "isHandwritten",
        "requiresConfirmation", "selectionTypeRaw",
    },
    "KnowledgeUnit": {
        "canonicalClaim", "createdAt", "enriched", "id",
        "sourceFaithful", "updatedAt",
    },
    "Card": {
        "back", "createdAt", "difficulty", "dueDate", "front", "id",
        "lapseCount", "reviewCount", "stability", "statusRaw",
        "typeRaw", "updatedAt",
    },
    "ReviewLog": {
        "deviceTimeZone", "difficultyAfter", "difficultyBefore", "elapsedDays",
        "id", "ratingRaw", "responseTimeMs", "reviewedAt", "scheduledDays",
        "stabilityAfter", "stabilityBefore",
    },
    "OCRCorrection": {
        "correctedText", "id", "isCriticalToken", "observedText", "useCount",
    },
    "ModelRun": {
        "createdAt", "estimatedCostUSD", "id", "inputTokens", "jobId",
        "latencyMs", "model", "outputTokens", "promptVersion", "provider",
        "purpose", "requestId", "success",
    },
    "ExerciseRun": {"id", "modeRaw", "position", "startedAt"},
    "ExerciseAttempt": {"answeredAt", "cardId", "id", "responseTimeMs", "resultRaw"},
}

_MODEL_CLASS = re.compile(r"@Model\s*\n\s*public final class (\w+)\s*\{")
_PROPERTY = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s*\n?\s*)*public var (\w+): ([^\n]+)$", re.M
)


def _class_body(source: str, start: int) -> str:
    """Text between the class's braces, tracking nesting so a computed
    property's own braces do not end the scan early."""
    depth, index = 1, start
    while index < len(source) and depth:
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
        index += 1
    return source[start:index]


def undefaulted_mandatory_properties() -> dict[str, set[str]]:
    """model name → stored properties that migration could not fill."""
    source = MODELS.read_text(encoding="utf-8")
    found: dict[str, set[str]] = {}
    for match in _MODEL_CLASS.finditer(source):
        body = _class_body(source, match.end())
        names = set()
        for prop in _PROPERTY.finditer(body):
            name, declaration = prop.group(1), prop.group(2).strip()
            if "{" in declaration or "=" in declaration:
                continue  # computed, or already defaulted
            if declaration.endswith("?"):
                continue  # optional: migration fills it with nil
            if declaration.startswith("["):
                continue  # to-many relationship: SwiftData supplies an empty set
            names.add(name)
        if names:
            found[match.group(1)] = names
    return found


def test_models_file_is_where_we_think_it_is() -> None:
    # A silently-moved file would make every assertion below vacuously true,
    # which is the one way a guard like this fails without anyone noticing.
    assert MODELS.exists(), MODELS
    assert "@Model" in MODELS.read_text(encoding="utf-8")


def test_no_new_mandatory_property_without_a_default() -> None:
    found = undefaulted_mandatory_properties()
    offenders: list[str] = []
    for model, properties in sorted(found.items()):
        for name in sorted(properties - BASELINE.get(model, set())):
            offenders.append(f"{model}.{name}")

    assert not offenders, (
        "Bu alanlar zorunlu ve varsayılansız:\n  "
        + "\n  ".join(offenders)
        + "\n\nSwiftData hafif göçü init'i çağırmaz; eklenen sütunu özelliğin"
        "\nkendi varsayılanından doldurur. Varsayılan yoksa göç düşer ve"
        "\nuygulama hiç açılmaz (CizgiApp.init → fatalError)."
        "\n\nDüzeltme: özelliğe `= <varsayılan>` ekle. BASELINE'a eklemek"
        "\nneredeyse her zaman yanlış çözümdür."
    )


def test_the_four_fields_that_caused_the_outage_stay_defaulted() -> None:
    # Named individually because a regression here is not a style problem: it
    # is an app that will not launch, and the trace points at SwiftData rather
    # than at the commit that changed the model.
    model_run = undefaulted_mandatory_properties().get("ModelRun", set())
    for field in ("attempt", "cachedInputTokens", "reasoningTokens", "billing"):
        assert field not in model_run, f"ModelRun.{field} varsayılanını kaybetmiş"
