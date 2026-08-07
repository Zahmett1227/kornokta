-- The user's "beş şıklı kart" setting, carried on the job (ANA-PLAN §13.3).
--
-- Same reasoning as `max_cards` one migration earlier: the worker runs long
-- after the request that carried the setting has gone, so the choice has to be
-- written down with the job rather than read from a request that no longer
-- exists.
--
-- Nullable: null means "use the deployment default"
-- (OPENAI_MULTIPLE_CHOICE_MODE), which is what every job written before this
-- column existed meant too. The server still clamps to that default on the
-- off < mixed < all scale, so a client can only ask for *less*, never talk a
-- deployment into producing more than it was configured for (§21.3).
--
-- Its own migration, never an edit to the create script: a fresh database runs
-- every file in order, and an ALTER folded into history would fail on a column
-- that already exists (Codex, PR #27 P1).
alter table public.jobs add column mc_mode text;

alter table public.jobs add constraint jobs_mc_mode_known
  check (mc_mode is null or mc_mode in ('off', 'mixed', 'all'));
