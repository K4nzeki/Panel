-- MyReadList (panel) — database setup for project wecprrznfhrebjhkbdxm
-- Paste this whole file into Supabase Dashboard → SQL Editor → New query → Run.
-- Safe to run on an empty project. Creates everything the Flutter app uses.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  username     text,
  list_visible boolean not null default true,
  created_at   timestamptz not null default now()
);
create unique index if not exists profiles_username_lower_key
  on public.profiles (lower(username));

create table if not exists public.entries (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title          text not null,
  type           text not null default 'Manga',
  status         text not null default 'Reading',
  chapter        integer not null default 0,
  reread         integer not null default 0,
  position       integer not null default 0,
  cover_url      text,
  author         text,
  total_chapters integer,
  read_on_url    text,
  last_read_at   timestamptz,
  source_id         text,         -- e.g. mangadex:<uuid>, or 'none'
  latest_chapter    integer,      -- newest chapter the source has
  latest_checked_at timestamptz,
  created_at     timestamptz not null default now()
);
create index if not exists entries_user_position_idx on public.entries (user_id, position);

create table if not exists public.chapter_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  entry_id   uuid references public.entries(id) on delete cascade,
  day        date not null,
  delta      integer not null,
  created_at timestamptz not null default now()
);
create index if not exists chapter_log_user_day_idx on public.chapter_log (user_id, day);

create table if not exists public.completion_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  entry_id   uuid references public.entries(id) on delete set null,
  title      text,
  month      date not null,
  created_at timestamptz not null default now()
);
create index if not exists completion_log_user_month_idx on public.completion_log (user_id, month);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.profiles       enable row level security;
alter table public.entries        enable row level security;
alter table public.chapter_log    enable row level security;
alter table public.completion_log enable row level security;

-- Profiles: signed-in users can see usernames (Community tab); edit only your own.
drop policy if exists "profiles read" on public.profiles;
create policy "profiles read" on public.profiles
  for select to authenticated using (true);
drop policy if exists "profiles insert own" on public.profiles;
create policy "profiles insert own" on public.profiles
  for insert to authenticated with check (id = (select auth.uid()));
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles update own" on public.profiles
  for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Entries: you see your own, plus other people's if their list is public.
drop policy if exists "entries read" on public.entries;
create policy "entries read" on public.entries
  for select to authenticated using (
    user_id = (select auth.uid())
    or exists (select 1 from public.profiles p
               where p.id = entries.user_id and p.list_visible)
  );
drop policy if exists "entries insert own" on public.entries;
create policy "entries insert own" on public.entries
  for insert to authenticated with check (user_id = (select auth.uid()));
drop policy if exists "entries update own" on public.entries;
create policy "entries update own" on public.entries
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists "entries delete own" on public.entries;
create policy "entries delete own" on public.entries
  for delete to authenticated using (user_id = (select auth.uid()));

-- Stats logs: private to their owner.
drop policy if exists "chapter_log own" on public.chapter_log;
create policy "chapter_log own" on public.chapter_log
  for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists "completion_log own" on public.completion_log;
create policy "completion_log own" on public.completion_log
  for all to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Create a profile automatically on sign-up (username comes from signUp data)
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, username)
  values (new.id, nullif(trim(new.raw_user_meta_data ->> 'username'), ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- RPC functions the app calls
-- ---------------------------------------------------------------------------

-- Sign-up form: is this username free?
create or replace function public.username_available(p_username text)
returns boolean language sql stable security definer set search_path = '' as $$
  select not exists (
    select 1 from public.profiles where lower(username) = lower(trim(p_username))
  );
$$;

-- Sign in with username: look up the email for that username.
create or replace function public.email_for_username(p_username text)
returns text language sql stable security definer set search_path = '' as $$
  select u.email::text
  from public.profiles p join auth.users u on u.id = p.id
  where lower(p.username) = lower(trim(p_username))
  limit 1;
$$;

-- Profile → Delete account. Cascades to profiles, entries and logs.
create or replace function public.delete_own_account()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.username_available(text) from public;
revoke all on function public.email_for_username(text) from public;
revoke all on function public.delete_own_account()     from public;
grant execute on function public.username_available(text) to anon, authenticated;
grant execute on function public.email_for_username(text) to anon, authenticated;
grant execute on function public.delete_own_account()     to authenticated;
