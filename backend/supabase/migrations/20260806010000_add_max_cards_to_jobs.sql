-- The user's "sayfa başına kart" setting, carried on the job (ANA-PLAN §6.7).
--
-- The worker runs long after the request that carried the setting has gone, so
-- it has to be written down with the job rather than read from the request.
--
-- Nullable: null means "use the deployment default"
-- (OPENAI_MAX_CARDS_PER_KNOWLEDGE_UNIT), which is what every job written before
-- this column existed meant too. The server still clamps to that default, so a
-- client can only ever ask for fewer cards, never raise someone else's spending
-- ceiling (§21.3).
alter table public.jobs add column max_cards integer;

alter table public.jobs add constraint jobs_max_cards_positive
  check (max_cards is null or max_cards >= 1);
