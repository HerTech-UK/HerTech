-- HerTech community database (Supabase / Postgres)
-- Run once in the Supabase SQL editor. Safe to re-run on an empty project.

-- ───────────────────────── Profiles ─────────────────────────
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null check (char_length(name) between 1 and 30),
  stage text check (char_length(stage) <= 40),
  bio text check (char_length(bio) <= 500),
  offers text check (char_length(offers) <= 300),
  wants text check (char_length(wants) <= 300),
  link text check (link is null or link = '' or link ~* '^https?://'),
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

-- ───────────────────────── Coffee Bean ledger ─────────────────────────
create table if not exists public.ledger (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.profiles on delete cascade,
  delta int not null,
  reason text not null,
  key text not null unique,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, stage)
  values (new.id,
          left(coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), 'HerTech member'), 30),
          left(new.raw_user_meta_data->>'stage', 40))
  on conflict (id) do nothing;
  insert into public.ledger (member_id, delta, reason, key)
  values (new.id, 2, 'Welcome Coffee Beans', 'join-' || new.id)
  on conflict (key) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ───────────────────────── Q&A ─────────────────────────
create table if not exists public.questions (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null default auth.uid() references public.profiles on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  body text not null check (char_length(body) between 1 and 2500),
  topic text not null check (topic in ('UK Tech Jobs','CVs & Portfolios','Interviews','Moving into Tech','Networking','Learning & Skills')),
  created_at timestamptz not null default now(),
  closes_at timestamptz not null default now() + interval '7 days',
  settled boolean not null default false
);

create table if not exists public.answers (
  id uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions on delete cascade,
  author_id uuid not null default auth.uid() references public.profiles on delete cascade,
  body text not null check (char_length(body) between 1 and 4000),
  is_top boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.answer_votes (
  answer_id uuid not null references public.answers on delete cascade,
  voter_id uuid not null default auth.uid() references public.profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (answer_id, voter_id)
);

create or replace function public.reward_helpful() returns trigger
language plpgsql security definer set search_path = public as $$
declare author uuid; total int;
begin
  select a.author_id into author from public.answers a where a.id = new.answer_id;
  select count(*) into total from public.answer_votes where answer_id = new.answer_id;
  if total >= 2 then
    insert into public.ledger (member_id, delta, reason, key)
    values (author, 1, 'Answer marked helpful by two members', 'help-' || new.answer_id)
    on conflict (key) do nothing;
  end if;
  return new;
end $$;

drop trigger if exists on_vote on public.answer_votes;
create trigger on_vote after insert on public.answer_votes
  for each row execute function public.reward_helpful();

-- Awards the top-answer bonus for questions older than 7 days. Anyone may call it; it is idempotent.
create or replace function public.settle_questions() returns void
language plpgsql security definer set search_path = public as $$
declare q record; best int;
begin
  for q in select id from public.questions where not settled and closes_at <= now() for update skip locked loop
    select max(c) into best from (
      select count(v.voter_id) c from public.answers a
      left join public.answer_votes v on v.answer_id = a.id
      where a.question_id = q.id group by a.id) t;
    if coalesce(best, 0) >= 3 then
      update public.answers a set is_top = true
      where a.question_id = q.id
        and (select count(*) from public.answer_votes v where v.answer_id = a.id) = best;
      insert into public.ledger (member_id, delta, reason, key)
      select a.author_id, 2, 'Top answer bonus', 'top-' || a.id
      from public.answers a where a.question_id = q.id and a.is_top
      on conflict (key) do nothing;
    end if;
    update public.questions set settled = true where id = q.id;
  end loop;
end $$;

-- ───────────────────────── Comments (questions, answers, events, groups) ─────────────────────────
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null default auth.uid() references public.profiles on delete cascade,
  target_type text not null check (target_type in ('question','answer','event')),
  target_id text not null check (char_length(target_id) <= 80),
  reply_to uuid references public.comments on delete cascade,
  group_id uuid,
  body text not null check (char_length(body) between 1 and 1500),
  created_at timestamptz not null default now()
);
create index if not exists comments_target on public.comments (target_type, target_id);

create table if not exists public.event_groups (
  id uuid primary key default gen_random_uuid(),
  event_id text not null check (char_length(event_id) <= 80),
  author_id uuid not null default auth.uid() references public.profiles on delete cascade,
  title text not null check (char_length(title) between 1 and 100),
  body text not null check (char_length(body) between 1 and 1500),
  created_at timestamptz not null default now()
);
create table if not exists public.event_group_members (
  group_id uuid not null references public.event_groups on delete cascade,
  member_id uuid not null default auth.uid() references public.profiles on delete cascade,
  primary key (group_id, member_id)
);

-- ───────────────────────── Follows ─────────────────────────
create table if not exists public.follows (
  follower_id uuid not null default auth.uid() references public.profiles on delete cascade,
  followee_id uuid not null references public.profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

-- ───────────────────────── Swaps ─────────────────────────
create table if not exists public.swaps (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null default auth.uid() references public.profiles on delete cascade,
  type text not null check (type in ('Skill Swap','Item Swap','Home Swap')),
  title text not null check (char_length(title) between 1 and 120),
  place text not null check (char_length(place) between 1 and 80),
  offer text not null check (char_length(offer) between 1 and 1500),
  want text not null default '' check (char_length(want) <= 1000),
  from_date date,
  to_date date,
  images jsonb not null default '[]'::jsonb
    check (jsonb_typeof(images) = 'array' and jsonb_array_length(images) <= 3 and pg_column_size(images) <= 800000),
  status text not null default 'open' check (status in ('open','closed')),
  created_at timestamptz not null default now(),
  check (type <> 'Home Swap' or (from_date is not null and to_date is not null and to_date >= from_date))
);

-- ───────────────────────── Resources ─────────────────────────
create table if not exists public.resources (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null default auth.uid() references public.profiles on delete cascade,
  title text not null check (char_length(title) between 1 and 120),
  url text not null check (url ~* '^https?://[^\s]+$' and char_length(url) <= 500),
  description text not null check (char_length(description) between 1 and 600),
  category text not null check (category in ('Learning','Job hunting','Courses & skills','Tools','Communities & events')),
  cost text not null default 'Free' check (cost in ('Free','Paid','Free & paid')),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  is_pick boolean not null default false,
  created_at timestamptz not null default now()
);

-- Members' submissions always start as pending; only admins can approve or mark HerTech picks.
create or replace function public.guard_resource() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    if tg_op = 'INSERT' then
      new.status := 'pending'; new.is_pick := false;
    else
      new.status := 'pending'; new.is_pick := old.is_pick and false;
      new.author_id := old.author_id;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists guard_resource on public.resources;
create trigger guard_resource before insert or update on public.resources
  for each row execute function public.guard_resource();

create table if not exists public.resource_votes (
  resource_id uuid not null references public.resources on delete cascade,
  member_id uuid not null default auth.uid() references public.profiles on delete cascade,
  primary key (resource_id, member_id)
);

-- ───────────────────────── Private messages ─────────────────────────
create table if not exists public.blocks (
  blocker_id uuid not null default auth.uid() references public.profiles on delete cascade,
  blocked_id uuid not null references public.profiles on delete cascade,
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null default auth.uid() references public.profiles on delete cascade,
  recipient_id uuid not null references public.profiles on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  check (sender_id <> recipient_id)
);
create index if not exists messages_pair on public.messages (sender_id, recipient_id, created_at);
create index if not exists messages_recipient on public.messages (recipient_id, created_at);

create or replace function public.is_blocked(sender uuid, recipient uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.blocks
    where (blocker_id = recipient and blocked_id = sender) or (blocker_id = sender and blocked_id = recipient))
$$;

-- ───────────────────────── Ticket redemption ─────────────────────────
create table if not exists public.redemptions (
  event_id text not null check (char_length(event_id) <= 80),
  member_id uuid not null references public.profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (event_id, member_id)
);

create or replace function public.ticket_status(event text, seats int default 8)
returns table (places_left int, mine boolean)
language sql stable security definer set search_path = public as $$
  select greatest(0, seats - (select count(*)::int from public.redemptions where event_id = event)),
         exists (select 1 from public.redemptions where event_id = event and member_id = auth.uid())
$$;

create or replace function public.redeem_ticket(event text) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); price int := 2; seats int := 8; bal int;
begin
  if me is null then return 'login'; end if;
  if event <> 'cv-workshop' then return 'unknown'; end if;
  perform pg_advisory_xact_lock(hashtext('ticket-' || event));
  if exists (select 1 from public.redemptions where event_id = event and member_id = me) then return 'already'; end if;
  if (select count(*) from public.redemptions where event_id = event) >= seats then return 'full'; end if;
  select coalesce(sum(delta), 0) into bal from public.ledger where member_id = me;
  if bal < price then return 'balance'; end if;
  insert into public.redemptions (event_id, member_id) values (event, me);
  insert into public.ledger (member_id, delta, reason, key)
  values (me, -price, 'Redeemed a CV workshop ticket', 'ticket-' || event || '-' || me);
  return 'ok';
end $$;

-- ───────────────────────── Row level security ─────────────────────────
alter table public.profiles enable row level security;
alter table public.ledger enable row level security;
alter table public.questions enable row level security;
alter table public.answers enable row level security;
alter table public.answer_votes enable row level security;
alter table public.comments enable row level security;
alter table public.event_groups enable row level security;
alter table public.event_group_members enable row level security;
alter table public.follows enable row level security;
alter table public.swaps enable row level security;
alter table public.resources enable row level security;
alter table public.resource_votes enable row level security;
alter table public.blocks enable row level security;
alter table public.messages enable row level security;
alter table public.redemptions enable row level security;

-- Public reading for community content
drop policy if exists "read profiles" on public.profiles;
create policy "read profiles" on public.profiles for select using (true);
drop policy if exists "read questions" on public.questions;
create policy "read questions" on public.questions for select using (true);
drop policy if exists "read answers" on public.answers;
create policy "read answers" on public.answers for select using (true);
drop policy if exists "read votes" on public.answer_votes;
create policy "read votes" on public.answer_votes for select using (true);
drop policy if exists "read comments" on public.comments;
create policy "read comments" on public.comments for select using (true);
drop policy if exists "read groups" on public.event_groups;
create policy "read groups" on public.event_groups for select using (true);
drop policy if exists "read group members" on public.event_group_members;
create policy "read group members" on public.event_group_members for select using (true);
drop policy if exists "read follows" on public.follows;
create policy "read follows" on public.follows for select using (true);
drop policy if exists "read swaps" on public.swaps;
create policy "read swaps" on public.swaps for select using (true);
drop policy if exists "read resources" on public.resources;
create policy "read resources" on public.resources for select
  using (status = 'approved' or author_id = auth.uid() or public.is_admin());
drop policy if exists "read resource votes" on public.resource_votes;
create policy "read resource votes" on public.resource_votes for select using (true);

-- Private reading
drop policy if exists "own ledger" on public.ledger;
create policy "own ledger" on public.ledger for select using (member_id = auth.uid());
drop policy if exists "own blocks" on public.blocks;
create policy "own blocks" on public.blocks for select using (blocker_id = auth.uid());
drop policy if exists "own messages" on public.messages;
create policy "own messages" on public.messages for select using (auth.uid() in (sender_id, recipient_id));
drop policy if exists "own redemptions" on public.redemptions;
create policy "own redemptions" on public.redemptions for select using (member_id = auth.uid());

-- Writing your own things
drop policy if exists "edit own profile" on public.profiles;
create policy "edit own profile" on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "post question" on public.questions;
create policy "post question" on public.questions for insert to authenticated with check (author_id = auth.uid());
drop policy if exists "edit own question" on public.questions;
create policy "edit own question" on public.questions for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
drop policy if exists "delete own question" on public.questions;
create policy "delete own question" on public.questions for delete to authenticated using (author_id = auth.uid() or public.is_admin());

drop policy if exists "post answer" on public.answers;
create policy "post answer" on public.answers for insert to authenticated with check (author_id = auth.uid());
drop policy if exists "edit own answer" on public.answers;
create policy "edit own answer" on public.answers for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
drop policy if exists "delete own answer" on public.answers;
create policy "delete own answer" on public.answers for delete to authenticated using (author_id = auth.uid() or public.is_admin());

drop policy if exists "vote" on public.answer_votes;
create policy "vote" on public.answer_votes for insert to authenticated
  with check (voter_id = auth.uid() and not exists (select 1 from public.answers a where a.id = answer_id and a.author_id = auth.uid()));
drop policy if exists "unvote" on public.answer_votes;
create policy "unvote" on public.answer_votes for delete to authenticated using (voter_id = auth.uid());

drop policy if exists "post comment" on public.comments;
create policy "post comment" on public.comments for insert to authenticated with check (author_id = auth.uid());
drop policy if exists "delete own comment" on public.comments;
create policy "delete own comment" on public.comments for delete to authenticated using (author_id = auth.uid() or public.is_admin());

drop policy if exists "start group" on public.event_groups;
create policy "start group" on public.event_groups for insert to authenticated with check (author_id = auth.uid());
drop policy if exists "delete own group" on public.event_groups;
create policy "delete own group" on public.event_groups for delete to authenticated using (author_id = auth.uid() or public.is_admin());
drop policy if exists "join group" on public.event_group_members;
create policy "join group" on public.event_group_members for insert to authenticated with check (member_id = auth.uid());
drop policy if exists "leave group" on public.event_group_members;
create policy "leave group" on public.event_group_members for delete to authenticated using (member_id = auth.uid());

drop policy if exists "follow" on public.follows;
create policy "follow" on public.follows for insert to authenticated with check (follower_id = auth.uid());
drop policy if exists "unfollow" on public.follows;
create policy "unfollow" on public.follows for delete to authenticated using (follower_id = auth.uid());

drop policy if exists "post swap" on public.swaps;
create policy "post swap" on public.swaps for insert to authenticated with check (author_id = auth.uid());
drop policy if exists "edit own swap" on public.swaps;
create policy "edit own swap" on public.swaps for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
drop policy if exists "delete own swap" on public.swaps;
create policy "delete own swap" on public.swaps for delete to authenticated using (author_id = auth.uid() or public.is_admin());

drop policy if exists "share resource" on public.resources;
create policy "share resource" on public.resources for insert to authenticated with check (author_id = auth.uid());
drop policy if exists "edit resource" on public.resources;
create policy "edit resource" on public.resources for update to authenticated
  using (author_id = auth.uid() or public.is_admin()) with check (author_id = auth.uid() or public.is_admin());
drop policy if exists "delete resource" on public.resources;
create policy "delete resource" on public.resources for delete to authenticated using (author_id = auth.uid() or public.is_admin());
drop policy if exists "upvote resource" on public.resource_votes;
create policy "upvote resource" on public.resource_votes for insert to authenticated with check (member_id = auth.uid());
drop policy if exists "remove upvote" on public.resource_votes;
create policy "remove upvote" on public.resource_votes for delete to authenticated using (member_id = auth.uid());

drop policy if exists "block" on public.blocks;
create policy "block" on public.blocks for insert to authenticated with check (blocker_id = auth.uid());
drop policy if exists "unblock" on public.blocks;
create policy "unblock" on public.blocks for delete to authenticated using (blocker_id = auth.uid());

drop policy if exists "send message" on public.messages;
create policy "send message" on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and not public.is_blocked(sender_id, recipient_id));
drop policy if exists "mark read" on public.messages;
create policy "mark read" on public.messages for update to authenticated
  using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());

-- Column-level limits on what can be changed
revoke all on public.profiles, public.ledger, public.questions, public.answers, public.answer_votes,
  public.comments, public.event_groups, public.event_group_members, public.follows, public.swaps,
  public.resources, public.resource_votes, public.blocks, public.messages, public.redemptions from anon, authenticated;

grant select on public.profiles, public.questions, public.answers, public.answer_votes, public.comments,
  public.event_groups, public.event_group_members, public.follows, public.swaps, public.resources,
  public.resource_votes to anon, authenticated;
grant select on public.ledger, public.blocks, public.messages, public.redemptions to authenticated;

grant update (name, stage, bio, offers, wants, link) on public.profiles to authenticated;
grant insert (title, body, topic) on public.questions to authenticated;
grant update (title, body) on public.questions to authenticated;
grant delete on public.questions to authenticated;
grant insert (question_id, body) on public.answers to authenticated;
grant update (body) on public.answers to authenticated;
grant delete on public.answers to authenticated;
grant insert (answer_id), delete on public.answer_votes to authenticated;
grant insert (target_type, target_id, reply_to, group_id, body), delete on public.comments to authenticated;
grant insert (event_id, title, body), delete on public.event_groups to authenticated;
grant insert (group_id), delete on public.event_group_members to authenticated;
grant insert (followee_id), delete on public.follows to authenticated;
grant insert (type, title, place, offer, want, from_date, to_date, images, status) on public.swaps to authenticated;
grant update (title, place, offer, want, from_date, to_date, images, status) on public.swaps to authenticated;
grant delete on public.swaps to authenticated;
grant insert (title, url, description, category, cost, status, is_pick) on public.resources to authenticated;
grant update (title, url, description, category, cost, status, is_pick) on public.resources to authenticated;
grant delete on public.resources to authenticated;
grant insert (resource_id), delete on public.resource_votes to authenticated;
grant insert (blocked_id), delete on public.blocks to authenticated;
grant insert (recipient_id, body) on public.messages to authenticated;
grant update (read_at) on public.messages to authenticated;

revoke execute on function public.handle_new_user(), public.reward_helpful(), public.guard_resource() from public, anon, authenticated;
grant execute on function public.settle_questions() to anon, authenticated;
grant execute on function public.ticket_status(text, int) to anon, authenticated;
grant execute on function public.redeem_ticket(text) to authenticated;
grant execute on function public.is_admin() to anon, authenticated;
grant execute on function public.is_blocked(uuid, uuid) to authenticated;

-- Live updates for private messages
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table public.messages;
    exception when duplicate_object then null;
    end;
  end if;
end $$;

-- Profiles + welcome beans for people who signed up before this script ran
insert into public.profiles (id, name, stage)
select id, left(coalesce(nullif(trim(raw_user_meta_data->>'name'), ''), 'HerTech member'), 30), left(raw_user_meta_data->>'stage', 40)
from auth.users on conflict (id) do nothing;
insert into public.ledger (member_id, delta, reason, key)
select id, 2, 'Welcome Coffee Beans', 'join-' || id from auth.users on conflict (key) do nothing;
