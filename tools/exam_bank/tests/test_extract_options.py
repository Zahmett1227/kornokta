"""Stem and options from a block (A1 §5.3/4)."""
from tools.exam_bank.extract import columns, options
from tools.exam_bank.extract.columns import Line

from .layout import LEFT_TEXT, row


def _lines(*rows, page=1, column=0):
    return [Line(page, column, r) for r in rows]


def test_one_option_per_line_with_glued_labels():
    lines = _lines(row("Hangi damar yaralanır?", LEFT_TEXT, 100),
                   row("A) Vena marginalis dextra", LEFT_TEXT, 120),
                   row("B) Vena cardiaca magna", LEFT_TEXT, 140),
                   row("C)Vena cardiaca parva", LEFT_TEXT, 160),
                   row("D)Sinus coronarius", LEFT_TEXT, 180),
                   row("E) Vena cardiaca media", LEFT_TEXT, 200))
    parsed = options.parse(lines)
    assert parsed.stem == "Hangi damar yaralanır?"
    assert parsed.options == ["Vena marginalis dextra", "Vena cardiaca magna", "Vena cardiaca parva",
                              "Sinus coronarius", "Vena cardiaca media"]
    assert parsed.problems == []


def test_two_options_to_a_line_and_a_centred_e():
    lines = _lines(row("Hangisi?", LEFT_TEXT, 100),
                   row("A) Os scaphoideum", LEFT_TEXT, 120) + row("B) Os pisiforme", 179, 120),
                   row("C) Os trapezium", LEFT_TEXT, 140) + row("D) Os hamatum", 179, 140),
                   row("E) Os trapezoideum", 126, 160))
    assert options.parse(lines).options == ["Os scaphoideum", "Os pisiforme", "Os trapezium",
                                            "Os hamatum", "Os trapezoideum"]


def test_a_wrapped_option_stays_with_its_label():
    lines = _lines(row("Hangisi?", LEFT_TEXT, 100),
                   row("A) Sol dördüncü kıkırdak kaburganın sternumla bir-", LEFT_TEXT, 120),
                   row("leştiği yerde", LEFT_TEXT + 18, 130),
                   row("B) b", LEFT_TEXT, 145), row("C) c", LEFT_TEXT, 160),
                   row("D) d", LEFT_TEXT, 175), row("E) e", LEFT_TEXT, 190))
    assert options.parse(lines).options[0] == "Sol dördüncü kıkırdak kaburganın sternumla birleştiği yerde"


def test_labels_first_texts_below():
    # "A) B)" on one line, their texts on the line below: a coordinate rule,
    # not reading order, keeps "A) B) textA textB" from happening.
    lines = _lines(row("Hangisi?", LEFT_TEXT, 100),
                   row("A)", LEFT_TEXT, 120) + row("B)", 179, 120),
                   row("Birinci", LEFT_TEXT + 12, 132) + row("İkinci", 191, 132),
                   row("C) c", LEFT_TEXT, 150), row("D) d", LEFT_TEXT, 165), row("E) e", LEFT_TEXT, 180))
    assert options.parse(lines).options[:2] == ["Birinci", "İkinci"]


def test_an_option_that_runs_into_the_next_column():
    left = _lines(row("Hangisi?", LEFT_TEXT, 700), row("A) a", LEFT_TEXT, 720), row("B) b", LEFT_TEXT, 735),
                  row("C) uzun bir şıkkın ilk", LEFT_TEXT, 750), column=0)
    right = _lines(row("satırı devam ediyor", 334, 80), row("D) d", 334, 95), row("E) e", 334, 110), column=1)
    assert options.parse(left + right).options[2] == "uzun bir şıkkın ilk satırı devam ediyor"


def test_a_label_quoted_in_the_stem_is_not_the_first_option():
    lines = _lines(row("Tabloda A) ile gösterilen değer hangisidir?", LEFT_TEXT, 100),
                   *[row(f"{l}) {l.lower()}", LEFT_TEXT, 120 + 15 * i) for i, l in enumerate("ABCDE")])
    parsed = options.parse(lines)
    assert parsed.stem == "Tabloda A) ile gösterilen değer hangisidir?"
    assert parsed.options == list("abcde")


def test_options_printed_as_images_are_reported_not_invented():
    # 2013/2 Temel 28: "A) H₂ … E) M₃" are small images; the labels are text.
    lines = _lines(row("Histamin hangi reseptörle etki eder?", LEFT_TEXT, 100),
                   row("A)", LEFT_TEXT, 120) + row("B) CCK-B", 110, 120) + row("C)", 170, 120)
                   + row("D)", 215, 120) + row("E)", 262, 120))
    parsed = options.parse(lines)
    assert parsed.options[1] == "CCK-B"
    assert "A şıkkı boş" in parsed.problems


def test_no_labels_at_all():
    parsed = options.parse(_lines(row("Şıkları görsel olan soru", LEFT_TEXT, 100)))
    assert parsed.options is None and parsed.problems == ["şıklar bulunamadı"]
