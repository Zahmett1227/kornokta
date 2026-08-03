import json

import pytest

from evals.card_quality.aggregate import (
    DEFAULT_SCHEMA_PATH,
    consistency_errors,
    load_json,
    main,
    schema_errors,
    score_entries,
    summarize,
)
from evals.card_quality.rubric import CRITERIA


def full(value):
    return {name: value for name in CRITERIA}


def scores_file(entries):
    return {"schemaVersion": "1.0", "entries": entries}


def entry(card_id, value=2, label=None, **overrides):
    e = {"cardId": card_id, "scores": {**full(value), **overrides}}
    if label is not None:
        e["goldPassageLabel"] = label
    return e


SCHEMA = load_json(DEFAULT_SCHEMA_PATH)


class TestSchema:
    def test_valid_file_has_no_errors(self):
        f = scores_file([entry("card_1"), entry("card_2", value=0)])
        assert schema_errors(f, SCHEMA) == []

    def test_missing_schema_version_is_rejected(self):
        f = scores_file([entry("card_1")])
        del f["schemaVersion"]
        assert schema_errors(f, SCHEMA)

    def test_unknown_top_level_field_is_rejected(self):
        f = scores_file([entry("card_1")])
        f["extra"] = "nope"
        assert schema_errors(f, SCHEMA)

    def test_out_of_range_score_is_rejected(self):
        f = scores_file([entry("card_1", question_clarity=3)])
        assert schema_errors(f, SCHEMA)

    def test_missing_criterion_is_rejected(self):
        f = scores_file([entry("card_1")])
        del f["entries"][0]["scores"]["medical_accuracy"]
        assert schema_errors(f, SCHEMA)

    def test_unknown_criterion_is_rejected(self):
        f = scores_file([entry("card_1", style_points=2)])
        assert schema_errors(f, SCHEMA)

    def test_empty_card_id_is_rejected(self):
        f = scores_file([entry("")])
        assert schema_errors(f, SCHEMA)


class TestConsistency:
    def test_duplicate_card_id_is_rejected(self):
        f = scores_file([entry("card_1"), entry("card_1", value=0)])
        errors = consistency_errors(f)
        assert errors
        assert "card_1" in errors[0]

    def test_distinct_ids_are_fine(self):
        f = scores_file([entry("card_1"), entry("card_2")])
        assert consistency_errors(f) == []


class TestScoreEntriesAndSummarize:
    def test_verdicts_match_the_rubric_thresholds(self):
        f = scores_file([
            entry("accepted", value=2),  # 14 -> accept
            # base 7 (all at 1) + 3 bumped to 2 (+1 each) = 10 -> revise (§23.3: 9-11)
            entry("revise_me", value=1, medical_accuracy=2, question_clarity=2, learning_value=2),
            entry("rejected", value=0),  # 0 -> reject
        ])
        scored = score_entries(f)
        by_id = {s.card_id: s.result.verdict for s in scored}
        assert by_id["accepted"] == "accept"
        assert by_id["revise_me"] == "revise"
        assert by_id["rejected"] == "reject"

    def test_gold_passage_label_is_carried_through(self):
        f = scores_file([entry("card_1", label="Anafilaksi, s. 42")])
        scored = score_entries(f)
        assert scored[0].gold_passage_label == "Anafilaksi, s. 42"

    def test_a_malformed_entry_raises_rather_than_being_dropped(self):
        f = scores_file([entry("card_1")])
        del f["entries"][0]["scores"]["medical_accuracy"]
        with pytest.raises(ValueError):
            score_entries(f)

    def test_summary_counts_each_verdict_bucket(self):
        f = scores_file([
            entry("a1", value=2),
            entry("a2", value=2),
            entry("r1", value=1, medical_accuracy=2, single_clear_answer=2),
            entry("x1", value=0),
        ])
        scored = score_entries(f)
        summary = summarize(scored)
        assert summary.total == 4
        assert summary.accept == 2
        assert summary.reject == 1
        assert summary.accept + summary.revise + summary.reject == summary.total

    def test_accept_fraction_of_an_empty_corpus_is_zero_not_a_crash(self):
        summary = summarize(score_entries(scores_file([])))
        assert summary.total == 0
        assert summary.accept_fraction == 0.0

    def test_no_single_pass_fail_number_is_invented(self):
        # §0.6: ANA-PLAN gives per-card thresholds, not a corpus-wide
        # acceptance percentage — this module must not manufacture one.
        import evals.card_quality.aggregate as aggregate_module

        assert not hasattr(aggregate_module, "CORPUS_ACCEPT_THRESHOLD")


class TestCLI:
    def test_valid_file_exits_zero_and_reports_the_distribution(self, tmp_path, capsys):
        path = tmp_path / "scores.json"
        path.write_text(json.dumps(scores_file([entry("card_1", value=2), entry("card_2", value=0)])))

        code = main([str(path)])

        assert code == 0
        out = capsys.readouterr().out
        assert "card_1" in out
        assert "accept" in out
        assert "1 kabul" in out

    def test_invalid_file_exits_nonzero_and_names_the_error(self, tmp_path, capsys):
        path = tmp_path / "scores.json"
        broken = scores_file([entry("card_1")])
        del broken["schemaVersion"]
        path.write_text(json.dumps(broken))

        code = main([str(path)])

        assert code == 1
        out = capsys.readouterr().out
        assert "ERROR" in out
