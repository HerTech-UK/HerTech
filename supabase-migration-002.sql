-- HerTech migration 002: reporting & moderation, suspensions, avatars, photo storage, events managed by admins.
-- Safe to re-run.

-- ───────────── Suspensions & avatars on profiles ─────────────
alter table public.profiles add column if not exists is_banned boolean not null default false;
alter table public.profiles add column if not exists avatar_url text;
alter table public.profiles drop constraint if exists profiles_avatar_url_check;
alter table public.profiles add constraint profiles_avatar_url_check
  check (avatar_url is null or avatar_url ~ '^https://[a-z0-9]+\.supabase\.co/storage/v1/object/public/avatars/[^\s"''<>]+$');
grant update (avatar_url) on public.profiles to authenticated;

-- True when the caller is a signed-in member who is not suspended.
create or replace function public.can_post() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and not coalesce((select is_banned from public.profiles where id = auth.uid()), false)
$$;
grant execute on function public.can_post() to anon, authenticated;

-- Suspended members can still read, but can no longer post or message.
drop policy if exists "post question" on public.questions;
create policy "post question" on public.questions for insert to authenticated with check (author_id = auth.uid() and public.can_post());
drop policy if exists "post answer" on public.answers;
create policy "post answer" on public.answers for insert to authenticated with check (author_id = auth.uid() and public.can_post());
drop policy if exists "post comment" on public.comments;
create policy "post comment" on public.comments for insert to authenticated with check (author_id = auth.uid() and public.can_post());
drop policy if exists "start group" on public.event_groups;
create policy "start group" on public.event_groups for insert to authenticated with check (author_id = auth.uid() and public.can_post());
drop policy if exists "post swap" on public.swaps;
create policy "post swap" on public.swaps for insert to authenticated with check (author_id = auth.uid() and public.can_post());
drop policy if exists "share resource" on public.resources;
create policy "share resource" on public.resources for insert to authenticated with check (author_id = auth.uid() and public.can_post());
drop policy if exists "send message" on public.messages;
create policy "send message" on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and public.can_post() and not public.is_blocked(sender_id, recipient_id));

-- Admins suspend or restore a member. Admins cannot be suspended.
create or replace function public.set_suspended(member uuid, suspended boolean) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then return 'forbidden'; end if;
  if exists (select 1 from public.profiles where id = member and is_admin) then return 'admin'; end if;
  update public.profiles set is_banned = suspended where id = member;
  return 'ok';
end $$;
revoke execute on function public.set_suspended(uuid, boolean) from public, anon;
grant execute on function public.set_suspended(uuid, boolean) to authenticated;

-- ───────────── Reports ─────────────
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null default auth.uid() references public.profiles on delete cascade,
  target_type text not null check (target_type in ('question','answer','comment','swap','resource','message','member','event_group')),
  target_id text not null check (char_length(target_id) <= 80),
  target_author uuid references public.profiles on delete set null,
  reason text not null check (reason in ('Spam or advertising','Harassment or hate','Scam or unsafe','Shares personal information','Off-topic','Other')),
  details text not null default '' check (char_length(details) <= 1000),
  snapshot text not null default '' check (char_length(snapshot) <= 4000),
  status text not null default 'open' check (status in ('open','resolved','dismissed')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.profiles on delete set null,
  unique (reporter_id, target_type, target_id)
);

-- The database copies the reported content itself, so a report can't be faked
-- and admins never need access to anyone's private messages.
create or replace function public.fill_report() returns trigger
language plpgsql security definer set search_path = public as $$
declare author uuid; content text;
begin
  if tg_op = 'UPDATE' then
    if new.status <> old.status then new.resolved_at := case when new.status = 'open' then null else now() end; new.resolved_by := auth.uid(); end if;
    new.snapshot := old.snapshot; new.target_author := old.target_author; new.reporter_id := old.reporter_id;
    new.target_type := old.target_type; new.target_id := old.target_id;
    return new;
  end if;
  case new.target_type
    when 'question' then select author_id, title || E'\n\n' || body into author, content from public.questions where id::text = new.target_id;
    when 'answer' then select author_id, body into author, content from public.answers where id::text = new.target_id;
    when 'comment' then select author_id, body into author, content from public.comments where id::text = new.target_id;
    when 'swap' then select author_id, title || E'\n\n' || offer || E'\n\nWants: ' || want into author, content from public.swaps where id::text = new.target_id;
    when 'resource' then select author_id, title || ' ' || url || E'\n\n' || description into author, content from public.resources where id::text = new.target_id;
    when 'event_group' then select author_id, title || E'\n\n' || body into author, content from public.event_groups where id::text = new.target_id;
    when 'member' then select id, name || coalesce(E'\n\n' || bio, '') into author, content from public.profiles where id::text = new.target_id;
    when 'message' then
      select sender_id, body into author, content from public.messages
      where id::text = new.target_id and recipient_id = new.reporter_id;
  end case;
  if author is null then raise exception 'report target not found'; end if;
  if author = new.reporter_id then raise exception 'cannot report yourself'; end if;
  new.target_author := author;
  new.snapshot := left(content, 4000);
  new.status := 'open'; new.resolved_at := null; new.resolved_by := null;
  return new;
end $$;
drop trigger if exists fill_report on public.reports;
create trigger fill_report before insert or update on public.reports for each row execute function public.fill_report();
revoke execute on function public.fill_report() from public, anon, authenticated;

alter table public.reports enable row level security;
drop policy if exists "report" on public.reports;
create policy "report" on public.reports for insert to authenticated with check (reporter_id = auth.uid());
drop policy if exists "see reports" on public.reports;
create policy "see reports" on public.reports for select to authenticated using (reporter_id = auth.uid() or public.is_admin());
drop policy if exists "handle reports" on public.reports;
create policy "handle reports" on public.reports for update to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.reports from anon, authenticated;
grant select on public.reports to authenticated;
grant insert (target_type, target_id, reason, details) on public.reports to authenticated;
grant update (status) on public.reports to authenticated;

-- ───────────── Events managed by admins ─────────────
create table if not exists public.events (
  id text primary key check (id ~ '^[a-z0-9-]{3,80}$'),
  name text not null check (char_length(name) between 1 and 140),
  city text not null check (char_length(city) between 1 and 60),
  date_label text not null check (char_length(date_label) between 1 and 60),
  ends_on date not null,
  venue text not null default '' check (char_length(venue) <= 120),
  lat double precision check (lat between 49 and 61),
  lng double precision check (lng between -9 and 3),
  url text not null check (url ~* '^https://[^\s]+$' and char_length(url) <= 500),
  created_by uuid default auth.uid() references public.profiles on delete set null,
  created_at timestamptz not null default now()
);
alter table public.events enable row level security;
drop policy if exists "read events" on public.events;
create policy "read events" on public.events for select using (true);
drop policy if exists "admins add events" on public.events;
create policy "admins add events" on public.events for insert to authenticated with check (public.is_admin());
drop policy if exists "admins edit events" on public.events;
create policy "admins edit events" on public.events for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins delete events" on public.events;
create policy "admins delete events" on public.events for delete to authenticated using (public.is_admin());
revoke all on public.events from anon, authenticated;
grant select on public.events to anon, authenticated;
grant insert (id, name, city, date_label, ends_on, venue, lat, lng, url), update (name, city, date_label, ends_on, venue, lat, lng, url), delete on public.events to authenticated;

insert into public.events (id, name, city, date_label, ends_on, venue, lat, lng, url) values
  ('digital-economy-2026', 'UK Digital Economy Conference 2026', 'Manchester', '26 November', '2026-11-26', 'Friends’ Meeting House', 53.4776, -2.2467, 'https://www.techuk.org/events/uk-digital-economy-conference-2026'),
  ('digital-ethics-2026', 'Digital Ethics Summit 2026', 'London', '2 December', '2026-12-02', '', 51.5074, -0.1278, 'https://www.techuk.org/events/digital-ethics-summit-2026'),
  ('ciuk-2026', 'CIUK 2026', 'Manchester', '2–4 December', '2026-12-04', 'Manchester Central', 53.4761, -2.2468, 'https://www.cake.ac.uk/events/202612-CIUK26/')
on conflict (id) do nothing;

-- ───────────── Photo storage (avatars and swap photos) ─────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('avatars', 'avatars', true, 524288, array['image/jpeg']),
  ('swap-images', 'swap-images', true, 524288, array['image/jpeg'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Each member may only add, replace or remove files inside a folder named after her own id.
drop policy if exists "hertech upload own photos" on storage.objects;
create policy "hertech upload own photos" on storage.objects for insert to authenticated
  with check (bucket_id in ('avatars','swap-images') and (storage.foldername(name))[1] = auth.uid()::text and public.can_post());
drop policy if exists "hertech replace own photos" on storage.objects;
create policy "hertech replace own photos" on storage.objects for update to authenticated
  using (bucket_id in ('avatars','swap-images') and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id in ('avatars','swap-images') and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "hertech delete own photos" on storage.objects;
create policy "hertech delete own photos" on storage.objects for delete to authenticated
  using (bucket_id in ('avatars','swap-images') and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "hertech read own photos" on storage.objects;
create policy "hertech read own photos" on storage.objects for select to authenticated
  using (bucket_id in ('avatars','swap-images') and (storage.foldername(name))[1] = auth.uid()::text);
