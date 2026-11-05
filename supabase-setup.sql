-- Run once in Supabase: SQL Editor > New query > Run.
-- Do not save your real code back into this file.
-- Safe to run again: to change the code, run the whole file with a new code. The data is kept.

-- ===== اكتب رمزك بدل CHANGE_ME في السطر التالي فقط (8 أحرف على الأقل، بدون علامة ') ثم اضغط Run =====
select set_config('tracker.code', 'CHANGE_ME', false);
-- ===== لا تغيّر شيئاً بعد هذا السطر. عند النجاح تظهر في النتائج عبارة: تم الإعداد بنجاح =====

create extension if not exists pgcrypto with schema extensions;

-- One row holds all the data. Nothing can read it directly: only the functions below, after checking the code.
create table if not exists public.tracker_shared (
  id           boolean primary key default true check (id),
  code_hash    text not null,
  state        jsonb,
  version      bigint not null default 0,
  updated_at   timestamptz not null default now(),
  failed       int not null default 0,
  locked_until timestamptz
);

alter table public.tracker_shared enable row level security;
revoke all on public.tracker_shared from public, anon, authenticated;

-- Returns 'ok', 'bad_code' or 'locked'. Ten wrong codes in a row lock access for 5 minutes.
create or replace function public.tracker_check(p_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.tracker_shared;
begin
  select * into r from public.tracker_shared where id for update;
  if not found then
    return 'bad_code';
  end if;
  if r.locked_until is not null and r.locked_until > now() then
    return 'locked';
  end if;
  if extensions.crypt(coalesce(p_code, ''), r.code_hash) = r.code_hash then
    if r.failed > 0 or r.locked_until is not null then
      update public.tracker_shared set failed = 0, locked_until = null where id;
    end if;
    return 'ok';
  end if;
  update public.tracker_shared
     set failed = case when r.failed + 1 >= 10 then 0 else r.failed + 1 end,
         locked_until = case when r.failed + 1 >= 10 then now() + interval '5 minutes' else null end
   where id;
  return 'bad_code';
end;
$$;

create or replace function public.tracker_get(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v text := public.tracker_check(p_code);
  r public.tracker_shared;
begin
  if v <> 'ok' then
    return jsonb_build_object('ok', false, 'reason', v);
  end if;
  select * into r from public.tracker_shared where id;
  return jsonb_build_object('ok', true, 'state', r.state, 'version', r.version, 'updated_at', r.updated_at);
end;
$$;

-- Saves only if p_version is still current, so one device cannot silently overwrite another.
create or replace function public.tracker_save(p_code text, p_state jsonb, p_version bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v text := public.tracker_check(p_code);
  r public.tracker_shared;
  new_version bigint;
begin
  if v <> 'ok' then
    return jsonb_build_object('ok', false, 'reason', v);
  end if;
  update public.tracker_shared
     set state = p_state, version = version + 1, updated_at = now()
   where id and version = p_version
   returning version into new_version;
  if found then
    return jsonb_build_object('ok', true, 'saved', true, 'version', new_version);
  end if;
  select * into r from public.tracker_shared where id;
  return jsonb_build_object('ok', true, 'saved', false, 'state', r.state, 'version', r.version, 'updated_at', r.updated_at);
end;
$$;

revoke all on function public.tracker_check(text) from public, anon, authenticated;
revoke all on function public.tracker_get(text) from public;
revoke all on function public.tracker_save(text, jsonb, bigint) from public;
grant execute on function public.tracker_get(text) to anon;
grant execute on function public.tracker_save(text, jsonb, bigint) to anon;

-- Stores only a hash of the code set at the top of this file.
do $$
declare
  v_code text := trim(current_setting('tracker.code'));
begin
  if v_code = 'CHANGE' || '_ME' or char_length(v_code) < 8 then
    raise exception 'اكتب رمزك بدل CHANGE_ME في أعلى الملف، 8 أحرف على الأقل';
  end if;
  insert into public.tracker_shared (id, code_hash)
  values (true, extensions.crypt(v_code, extensions.gen_salt('bf', 10)))
  on conflict (id) do update
    set code_hash = excluded.code_hash, failed = 0, locked_until = null;
end;
$$;

-- Clear the code from this session, then make the new functions visible to the API right away.
select set_config('tracker.code', '', false);
notify pgrst, 'reload schema';
select 'تم الإعداد بنجاح' as result;
