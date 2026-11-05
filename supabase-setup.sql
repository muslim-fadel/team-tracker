-- Run once in Supabase: SQL Editor > New query > Run.
-- One row per signed-in user. Row Level Security keeps each row visible to its owner only.

create table if not exists public.tracker_state (
  user_id    uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  state      jsonb not null,
  version    bigint not null default 1,
  updated_at timestamptz not null default now()
);

alter table public.tracker_state enable row level security;

revoke all on public.tracker_state from anon, public;
grant select, insert, update on public.tracker_state to authenticated;

drop policy if exists "owner can read" on public.tracker_state;
create policy "owner can read" on public.tracker_state
  for select to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "owner can insert" on public.tracker_state;
create policy "owner can insert" on public.tracker_state
  for insert to authenticated
  with check ((select auth.uid()) = user_id);

drop policy if exists "owner can update" on public.tracker_state;
create policy "owner can update" on public.tracker_state
  for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
