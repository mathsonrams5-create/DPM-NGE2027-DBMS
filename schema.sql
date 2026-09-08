-- ═══════════════════════════════════════════════════════════════════════
-- DPM NGE 2027 Resignation Register — Supabase / PostgreSQL schema
-- ═══════════════════════════════════════════════════════════════════════
-- This schema turns the static prototype (index.html, backed by Claude's
-- artifact `window.storage`) into a real, hosted Postgres database on
-- Supabase, with row-level security enforcing the four roles already
-- defined in the prototype's "Security & Safeguards" page:
--   Administrator | Data Entry Officer | Verifying Officer | Read-only Viewer
--
-- Run this once in the Supabase SQL editor (or via `supabase db push`)
-- on a fresh project. Safe to re-run: objects are created with
-- IF NOT EXISTS / OR REPLACE where possible.
-- ═══════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────
-- Extensions
-- ─────────────────────────────────────────────
create extension if not exists "pgcrypto";   -- gen_random_uuid()

-- ─────────────────────────────────────────────
-- Enum types
-- ─────────────────────────────────────────────
do $$ begin
  create type app_role as enum ('Administrator', 'Data Entry Officer', 'Verifying Officer', 'Read-only Viewer');
exception when duplicate_object then null; end $$;

do $$ begin
  create type record_category as enum ('Agency Head', 'Public Servant');
exception when duplicate_object then null; end $$;

do $$ begin
  create type record_status as enum ('Received', 'Under Verification', 'Acknowledged', 'Released to PNGEC', 'Withdrawn');
exception when duplicate_object then null; end $$;

do $$ begin
  create type audit_action as enum ('Create', 'Update', 'Delete', 'Export', 'Feedback', 'Sign in', 'Sign out');
exception when duplicate_object then null; end $$;

-- ─────────────────────────────────────────────
-- profiles — one row per authenticated user, extends auth.users
-- (replaces the login screen's free-text name + role-chip selector
--  with real Supabase Auth + a role that only an Administrator can change)
-- ─────────────────────────────────────────────
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null,
  role        app_role not null default 'Read-only Viewer',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.profiles is 'One row per DPM officer with access to the register; role drives RLS permissions.';

-- ─────────────────────────────────────────────
-- resignation_records — the Agency Heads / Public Servants register
-- (the 15 fields from the DPM Secretariat Data Entry Matrix)
-- ─────────────────────────────────────────────
create table if not exists public.resignation_records (
  id              bigint generated always as identity primary key,
  category        record_category not null,
  name            text not null,
  designation     text not null default 'TBA',
  agency          text not null default 'TBA',
  institution     text not null default 'TBA',
  province        text not null default 'TBA',
  electorate      text not null default 'TBA',
  party           text not null default 'TBA',
  resign_date     date,
  received_date   date,
  ack_date        date,
  phone           text,
  email           text,
  subject         text not null default 'TBA',
  status          record_status not null default 'Received',
  remarks         text not null default 'TBA',
  entered_by      uuid references public.profiles(id),
  entered_by_name text not null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

comment on table public.resignation_records is 'Combined register of Agency Heads and Public Servants who resigned to contest NGE 2027.';

create index if not exists idx_records_category on public.resignation_records (category);
create index if not exists idx_records_status   on public.resignation_records (status);
create index if not exists idx_records_province on public.resignation_records (province);
create index if not exists idx_records_search   on public.resignation_records using gin (
  to_tsvector('simple', coalesce(name,'') || ' ' || coalesce(agency,'') || ' ' || coalesce(province,''))
);

-- ─────────────────────────────────────────────
-- audit_log — every create / update / delete / export / sign-in / sign-out
-- ─────────────────────────────────────────────
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  action      audit_action not null,
  detail      text not null,
  user_id     uuid references public.profiles(id),
  user_name   text not null default 'Unknown',
  role        app_role,
  ts          timestamptz not null default now()
);

create index if not exists idx_audit_ts on public.audit_log (ts desc);

-- ─────────────────────────────────────────────
-- feedback — committee comments on the prototype
-- ─────────────────────────────────────────────
create table if not exists public.feedback (
  id          bigint generated always as identity primary key,
  name        text not null default 'Anonymous',
  role        app_role,
  comment     text not null,
  created_at  timestamptz not null default now()
);

-- ─────────────────────────────────────────────
-- updated_at triggers
-- ─────────────────────────────────────────────
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

drop trigger if exists trg_records_updated_at on public.resignation_records;
create trigger trg_records_updated_at
  before update on public.resignation_records
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────
-- Auto-create a profile row whenever a new auth user signs up
-- (defaults new users to the lowest-privilege role; an Administrator
--  must promote them afterwards)
-- ─────────────────────────────────────────────
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, full_name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email), 'Read-only Viewer');
  return new;
end;
$$;

drop trigger if exists trg_on_auth_user_created on auth.users;
create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─────────────────────────────────────────────
-- Helper: current user's role (used inside RLS policies)
-- ─────────────────────────────────────────────
create or replace function public.current_role_name()
returns app_role language sql stable security definer as $$
  select role from public.profiles where id = auth.uid();
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- Row-Level Security
-- Mirrors the "Role Permissions" table in the prototype exactly:
--
--   Role                 | View | Add | Edit status | Delete
--   ---------------------|------|-----|-------------|-------
--   Administrator        |  Y   |  Y  |     Y       |   Y
--   Data Entry Officer   |  Y   |  Y  |     Y       |   -
--   Verifying Officer    |  Y   |  -  |     Y       |   -
--   Read-only Viewer     |  Y   |  -  |     -       |   -
-- ═══════════════════════════════════════════════════════════════════════
alter table public.profiles             enable row level security;
alter table public.resignation_records  enable row level security;
alter table public.audit_log            enable row level security;
alter table public.feedback             enable row level security;

-- profiles: everyone signed in can read all profiles (for name/role display);
-- only an Administrator can change roles; users can update their own name.
drop policy if exists "profiles_select_all"        on public.profiles;
drop policy if exists "profiles_update_own_name"   on public.profiles;
drop policy if exists "profiles_admin_manage"      on public.profiles;

create policy "profiles_select_all" on public.profiles
  for select using (auth.role() = 'authenticated');

create policy "profiles_update_own_name" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

create policy "profiles_admin_manage" on public.profiles
  for all using (public.current_role_name() = 'Administrator')
  with check (public.current_role_name() = 'Administrator');

-- resignation_records
drop policy if exists "records_select_all"      on public.resignation_records;
drop policy if exists "records_insert_entry"    on public.resignation_records;
drop policy if exists "records_update_status"   on public.resignation_records;
drop policy if exists "records_delete_admin"    on public.resignation_records;

create policy "records_select_all" on public.resignation_records
  for select using (auth.role() = 'authenticated');

create policy "records_insert_entry" on public.resignation_records
  for insert with check (
    public.current_role_name() in ('Administrator', 'Data Entry Officer')
  );

create policy "records_update_status" on public.resignation_records
  for update using (
    public.current_role_name() in ('Administrator', 'Data Entry Officer', 'Verifying Officer')
  );

create policy "records_delete_admin" on public.resignation_records
  for delete using (public.current_role_name() = 'Administrator');

-- audit_log: everyone signed in can read and append; no updates/deletes
-- (append-only, for accountability under Section 5.3 of the DBMS design)
drop policy if exists "audit_select_all"  on public.audit_log;
drop policy if exists "audit_insert_all"  on public.audit_log;

create policy "audit_select_all" on public.audit_log
  for select using (auth.role() = 'authenticated');

create policy "audit_insert_all" on public.audit_log
  for insert with check (auth.role() = 'authenticated');

-- feedback: everyone signed in can read and add comments; no edits/deletes
-- other than by an Administrator (e.g. to remove inappropriate comments)
drop policy if exists "feedback_select_all"   on public.feedback;
drop policy if exists "feedback_insert_all"   on public.feedback;
drop policy if exists "feedback_delete_admin" on public.feedback;

create policy "feedback_select_all" on public.feedback
  for select using (auth.role() = 'authenticated');

create policy "feedback_insert_all" on public.feedback
  for insert with check (auth.role() = 'authenticated');

create policy "feedback_delete_admin" on public.feedback
  for delete using (public.current_role_name() = 'Administrator');

-- ═══════════════════════════════════════════════════════════════════════
-- Seed data — the two labelled sample entries already in the prototype
-- (safe to delete once real, DPM-approved entries are loaded)
-- ═══════════════════════════════════════════════════════════════════════
insert into public.resignation_records
  (category, name, designation, agency, institution, province, electorate, party,
   resign_date, received_date, ack_date, phone, email, subject, status, remarks, entered_by_name)
select * from (values
  ('Agency Head'::record_category, 'Sample Entry — Provincial Administrator', 'Provincial Administrator',
   'Sample Provincial Administration', 'Office of the Provincial Administrator', 'New Ireland',
   'Kavieng Open (To Be Confirmed)', 'TBA', date '2026-09-02', date '2026-07-14', null::date,
   null::text, null::text, 'Sample record for demonstration — replace with real entries after committee review',
   'Under Verification'::record_status, 'Demo data — not a real resignation record', 'Sample data'),
  ('Agency Head'::record_category, 'Sample Entry — Agency CEO', 'Chief Executive Officer',
   'Sample Provincial Health Authority', 'Office of the Chief Executive Officer', 'Southern Highlands',
   'Mendi Open (To Be Confirmed)', 'TBA', date '2026-10-29', date '2026-08-04', null::date,
   null::text, null::text, 'Sample record for demonstration — replace with real entries after committee review',
   'Under Verification'::record_status, 'Demo data — not a real resignation record', 'Sample data')
) as seed
where not exists (select 1 from public.resignation_records);
