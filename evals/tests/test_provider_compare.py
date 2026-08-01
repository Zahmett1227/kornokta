import pytest

from evals.spikes.provider_compare.run import (
    call_provider,
    key_status,
    load_config,
    main,
)


@pytest.fixture(scope="module")
def cfg():
    return load_config()


class TestConfig:
    def test_candidates_present(self, cfg):
        keys = {c["key"] for c in cfg["candidates"]}
        assert {"openai_primary", "gemini_second_opinion", "claude_candidate"} <= keys

    def test_no_raw_keys_in_config(self, cfg):
        # Only env var *names* may appear, never key values (§0.7).
        for cand in cfg["candidates"]:
            assert cand["apiKeyEnv"].endswith("_API_KEY") or cand["apiKeyEnv"].endswith("KEY")
            assert "sk-" not in str(cand)

    def test_all_eight_dimensions(self, cfg):
        assert len(cfg["evaluationDimensions"]) == 8


class TestKeyStatus:
    def test_status_is_boolean_only(self, cfg, monkeypatch):
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        status = key_status(cfg)
        assert status["openai_primary"] is False
        assert all(isinstance(v, bool) for v in status.values())

    def test_presence_detected_without_leaking_value(self, cfg, monkeypatch):
        monkeypatch.setenv("OPENAI_API_KEY", "sk-should-not-appear")
        status = key_status(cfg)
        assert status["openai_primary"] is True
        # The value must never be part of the returned structure.
        assert "sk-should-not-appear" not in str(status)


class TestGuards:
    def test_live_provider_call_not_implemented(self, cfg):
        candidate = cfg["candidates"][0]
        with pytest.raises(NotImplementedError):
            call_provider(candidate, b"", {})

    def test_dry_run_exits_zero(self):
        assert main(["--dry-run"]) == 0

    def test_live_blocked_in_faz0(self):
        assert main(["--live"]) == 3
