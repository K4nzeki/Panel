-- Panel 1.8 — new-chapter tracking. Run once in Supabase → SQL Editor.
-- Safe to run more than once.
alter table public.entries add column if not exists source_id         text;
alter table public.entries add column if not exists latest_chapter    integer;
alter table public.entries add column if not exists latest_checked_at timestamptz;
