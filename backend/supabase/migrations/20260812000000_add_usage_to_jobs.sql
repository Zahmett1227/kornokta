-- Per-call cost accounting for every provider call a job makes (§16.8, §20.3).
--
-- One array element per call, in order, successes and failures alike:
--   { attempt, provider, model, purpose, promptVersion, outcome,
--     failureReason?, billing, usage: { inputTokens, cachedInputTokens,
--     outputTokens, reasoningTokens }, estimatedCostUSD, latencyMs, at }
--
-- Why this lives on the row rather than only on the phone: a page that fails
-- twice and succeeds on the third attempt cost three generations, and the
-- phone is routinely asleep for the first two. Anything derived from what the
-- phone happened to witness reads low by an unknown amount — which is the bug
-- this column exists to close.
--
-- Accumulated, never reset. `requeue` deliberately does not clear it (it
-- clears result/error/retryable, which describe the attempt about to start);
-- this field describes attempts that already happened and their money already
-- left the account.
--
-- Contains no card text, no page text and no image data — counts, prices and
-- durations only, so it falls outside §7.3's deletion rules and rides the same
-- 60-day row retention as everything else on the job (docs/PRIVACY.md).
--
-- Defaulted rather than nullable so `[...row.usage, entry]` in _jobs.ts is
-- always spreading an array; `toJobRow` still coerces defensively for rows
-- read before this ran.
--
-- ⚠ Apply to the live database BEFORE deploying the code that writes it:
-- PostgREST rejects a PATCH naming a missing column, which would fail every
-- job's terminal write and leave pages stuck at `processing` until the
-- staleness sweep reclaimed them (the mc_mode lesson, CLAUDE.md "Migration
-- sırası").
alter table public.jobs add column usage jsonb not null default '[]'::jsonb;

-- The shape is the server's contract, not the database's, so there is no CHECK
-- on the element keys — the same reasoning that kept `subject` unconstrained.
-- Only the outermost invariant is enforced, because every reader spreads it.
alter table public.jobs add constraint jobs_usage_is_array
  check (jsonb_typeof(usage) = 'array');
