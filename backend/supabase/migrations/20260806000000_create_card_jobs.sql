-- Çizgi — asynchronous card-generation job queue (docs/ADR-006).
--
-- Applied to the `kornokta` Supabase project on 2026-08-06. Kept here as well
-- because a schema that exists only in a cloud console is a schema nobody can
-- review, diff or recreate.
--
-- The phone no longer holds an HTTP connection open for the minutes an OpenAI
-- vision call takes. It submits a job, the backend does the work in the
-- background, and the phone collects the result whenever it is next awake.
--
-- Single user, single device: there is no owner column and no per-user
-- partitioning. RLS is enabled with *no* policies, which denies every
-- anon/publishable key outright; only the service-role key (held by the Vercel
-- backend, never by the phone) can read or write. That keeps the existing
-- security model intact — the device authenticates to Vercel with DEVICE_TOKEN
-- and nothing else, and no Supabase credential ever ships in the app.

create table public.jobs (
  -- The phone's own CapturedPage id. Re-submitting the same page therefore
  -- cannot create a second job, and cannot pay for a second generation.
  id uuid primary key,
  status text not null default 'queued'
    check (status in ('queued', 'processing', 'ready', 'failed')),
  -- Storage object holding the page bytes. Nulled the moment the job reaches a
  -- terminal state and the object is deleted: the image rests here only for as
  -- long as the work needs it (ANA-PLAN §7.3).
  image_path text,
  mime_type text not null,
  -- Optional free-text steer from the user ("sadece sol sütun", §5.1).
  hint text,
  -- The user's "sayfa başına kart" setting. Null means the deployment default;
  -- the server clamps to it either way, so a client can only ask for fewer
  -- (§6.7, §21.3). Added by 20260806010000_add_max_cards_to_jobs.sql.
  max_cards integer check (max_cards is null or max_cards >= 1),
  attempts integer not null default 0,
  -- Exactly the body `/api/cards-vision` returns today: { output, gate,
  -- cardPromptVersion }. Stored verbatim so the iOS decoder is reused unchanged
  -- and this table never becomes a second definition of the card contract.
  result jsonb,
  error text,
  retryable boolean,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
);

-- The reclaim sweep ("which jobs did a killed worker leave behind?") and the
-- dispatch sweep ("which queued jobs was nobody told about?") both scan by
-- status and age.
create index jobs_status_updated_at_idx on public.jobs (status, updated_at);

create function public.set_updated_at() returns trigger
language plpgsql
-- Empty search_path: a SECURITY DEFINER-adjacent function that resolves
-- unqualified names through the caller's search_path is the classic Postgres
-- privilege-escalation shape. Everything below is schema-qualified or built in.
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger jobs_set_updated_at
  before update on public.jobs
  for each row execute function public.set_updated_at();

-- Enabled with no policies: deny-all for anon and authenticated, bypassed by
-- the service role. See the header note.
alter table public.jobs enable row level security;

-- Private bucket for the page bytes. Same reasoning: no policies, so only the
-- service role can put, get or delete objects in it.
insert into storage.buckets (id, name, public)
values ('page-uploads', 'page-uploads', false)
on conflict (id) do nothing;
