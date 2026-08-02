"""Export the critical-token patterns for the TypeScript backend.

    python -m evals.ocr_eval.export_patterns

The detector has to run in two places: here, where the gold set is scored, and
in the backend, where OCR reconciliation happens (ANA-PLAN §10.3, §10.5). The
patterns are the same facts, and this project has already been bitten twice by
implementing one behaviour in two places and updating only one.

So the Python source stays the single definition and the JavaScript form is
**generated** from it. The translation is mechanical, which is the point: there
is no judgement call for a port to get subtly wrong.

Two constructs genuinely differ between the engines and are rewritten:

``\\w``
    Unicode-aware in Python; ASCII-only in JavaScript even under the ``u``
    flag. Left alone, every Turkish word would stop matching — the negation
    paradigm (``\\w+?m[ae]...``) would silently detect nothing.

``\\b``
    Python's word boundary knows Turkish letters are word characters;
    JavaScript's does not. ``\\b(?:sağ|sol)\\b`` would then match *inside*
    ``kısağ``, because JavaScript sees ``ı`` as a non-word character and finds a
    boundary where Python finds none. Replaced with the equivalent lookaround
    pair over a Unicode word class.

Everything else — character classes, quantifiers, alternation, lookaround — has
the same meaning in both engines and is passed through untouched.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from .critical_tokens import (
    _PATTERNS,
    _UNITS,
    ROUTE_SYNONYMS,
    TOKEN_CLASSES,
)

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "backend" / "providers" / "criticalTokenPatterns.json"

#: JavaScript equivalent of Python's Unicode-aware ``\w``.
JS_WORD_CHAR = r"[\p{L}\p{N}_]"

#: JavaScript equivalent of Python's Unicode-aware ``\b``.
#:
#: A word boundary is a position where exactly one side is a word character,
#: which is what this pair of alternatives says. Both string edges are covered:
#: a lookbehind at position 0 fails, so the second alternative matches when the
#: first character is a word character.
JS_WORD_BOUNDARY = (
    rf"(?:(?<={JS_WORD_CHAR})(?!{JS_WORD_CHAR})|(?<!{JS_WORD_CHAR})(?={JS_WORD_CHAR}))"
)


#: The contents of `JS_WORD_CHAR` without its brackets, for use *inside* a
#: character class where a nested `[...]` would be a syntax error.
JS_WORD_CHAR_INNER = r"\p{L}\p{N}_"


class PatternTranslationError(ValueError):
    """A construct that cannot be translated safely."""


def to_javascript_source(pattern: str) -> str:
    """Rewrite a Python regex source into its JavaScript equivalent.

    Scans left to right so an escaped backslash (``\\\\w``, a literal backslash
    followed by a ``w``) is not mistaken for ``\\w``.

    Character-class state is tracked, because the substitutions differ inside
    one. ``[\\w+-]`` must become ``[\\p{L}\\p{N}_+-]``, not
    ``[[\\p{L}\\p{N}_]+-]`` — nested brackets are a syntax error, and an
    earlier version of this function produced exactly that.
    """
    out: list[str] = []
    index = 0
    in_class = False
    class_start = -1

    while index < len(pattern):
        char = pattern[index]

        if char == "\\":
            following = pattern[index + 1] if index + 1 < len(pattern) else ""
            if following == "w":
                out.append(JS_WORD_CHAR_INNER if in_class else JS_WORD_CHAR)
            elif following == "W":
                if in_class:
                    # A negated class cannot be nested inside another class.
                    # Refusing is the only safe answer: emitting anything else
                    # would silently change what the pattern matches.
                    raise PatternTranslationError(
                        r"\W inside a character class cannot be translated: " + pattern
                    )
                out.append(r"[^\p{L}\p{N}_]")
            elif following == "b":
                # Inside a class, \b means backspace in both engines, so it is
                # left alone; outside, it is a word boundary and needs the
                # Unicode-aware emulation.
                out.append(r"\b" if in_class else JS_WORD_BOUNDARY)
            else:
                # Any other escape — \d, \s, \., \\ — means the same in both
                # engines and is copied verbatim.
                out.append(char)
                out.append(following)
            index += 2
            continue

        if not in_class and char == "[":
            in_class = True
            class_start = index
        elif in_class and char == "]":
            # ']' is a literal when it is the first character of the class, or
            # the first after a leading '^'.
            first_content = class_start + (2 if pattern[class_start + 1 : class_start + 2] == "^" else 1)
            if index != first_content:
                in_class = False

        out.append(char)
        index += 1

    if in_class:
        raise PatternTranslationError(f"Kapanmamış karakter sınıfı: {pattern}")
    return "".join(out)


def javascript_flags(flags: int) -> str:
    """Python flags -> JavaScript flag string.

    ``u`` is always present: the rewritten source uses ``\\p{...}``, which is
    only recognised under it. ``re.UNICODE`` has no JavaScript counterpart —
    it is Python's default and the ``\\w``/``\\b`` rewriting above is what
    carries its meaning across.
    """
    result = "u"
    if flags & re.IGNORECASE:
        result += "i"
    if flags & re.MULTILINE:
        result += "m"
    if flags & re.DOTALL:
        result += "s"
    return result


def build_payload() -> dict:
    return {
        "_comment": (
            "GENERATED by `python -m evals.ocr_eval.export_patterns`. "
            "Do not edit by hand — change evals/ocr_eval/critical_tokens.py "
            "and re-run. evals/tests/test_pattern_export.py fails if this file "
            "drifts from its source."
        ),
        "tokenClasses": list(TOKEN_CLASSES),
        "units": list(_UNITS),
        "routeSynonyms": {code: list(surfaces) for code, surfaces in ROUTE_SYNONYMS.items()},
        "patterns": [
            {
                "tokenClass": token_class,
                "source": to_javascript_source(pattern.pattern),
                "flags": javascript_flags(pattern.flags),
            }
            for token_class, pattern in _PATTERNS
        ],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Yazma; dosya güncel değilse 1 döndür.",
    )
    args = parser.parse_args(argv)

    payload = json.dumps(build_payload(), ensure_ascii=False, indent=2) + "\n"

    if args.check:
        if not args.output.exists():
            print(f"{args.output} yok. Üretmek için --check olmadan çalıştır.", file=sys.stderr)
            return 1
        if args.output.read_text(encoding="utf-8") != payload:
            print(
                f"{args.output} kaynağıyla uyuşmuyor.\n"
                "Düzeltmek için: python -m evals.ocr_eval.export_patterns",
                file=sys.stderr,
            )
            return 1
        print(f"{args.output} güncel.")
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(payload, encoding="utf-8")
    print(f"Yazıldı: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
