-- Haps v2: flere billeder, hap kommentarer, @tags, ret kommentarer, slet konto, live opdatering.
-- Kør hele filen én gang i Supabase: SQL Editor → New query → indsæt → Run.

-- ---------- flere billeder og deres format ----------
alter table public.meals add column if not exists photos text[] not null default '{}',
                         add column if not exists ratios real[] not null default '{}';
update public.meals set photos = array[photo] where photo <> '' and photos = '{}';
do $$ begin
  alter table public.meals add constraint meals_photos_max check (cardinality(photos) <= 6);
exception when duplicate_object then null; end $$;

-- ---------- hap kommentarer ----------
create table if not exists public.comment_haps (
  comment_id bigint not null references public.comments(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);
create index if not exists comment_haps_user on public.comment_haps (user_id);
alter table public.comment_haps enable row level security;
drop policy if exists "comment haps read" on public.comment_haps;
create policy "comment haps read" on public.comment_haps for select to authenticated
  using (exists (select 1 from public.comments c where c.id = comment_id));
drop policy if exists "comment haps add" on public.comment_haps;
create policy "comment haps add" on public.comment_haps for insert to authenticated
  with check (user_id = (select auth.uid()) and exists (select 1 from public.comments c where c.id = comment_id));
drop policy if exists "comment haps remove" on public.comment_haps;
create policy "comment haps remove" on public.comment_haps for delete to authenticated using (user_id = (select auth.uid()));

-- ---------- nye slags notifikationer ----------
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('haps','comment','friend_request','friend_accept','comment_haps','tag'));

-- @brugernavne i en tekst
create or replace function public.mentions(t text)
returns text[] language sql immutable set search_path = public as $$
  select coalesce(array_agg(distinct lower(regexp_replace(m[2], '\.+$', ''))), '{}')
  from regexp_matches(coalesce(t,''), '(^|[^a-z0-9_.æøå@])@([a-z0-9_.æøå]{3,24})', 'gi') as m;
$$;

-- Giv besked til nye @tags, der må se aftensmaden (ejeren og ejerens venner), og ikke er forfatteren selv
create or replace function public.notify_tags(author uuid, owner uuid, new_text text, old_text text, p_meal uuid, p_comment bigint)
returns void language plpgsql security definer set search_path = public as $$
declare names text[];
begin
  if coalesce(current_setting('app.renaming', true), '') = '1' then return; end if;
  names := array(select unnest(mentions(new_text)) except select unnest(mentions(old_text)));
  if cardinality(names) = 0 then return; end if;
  insert into notifications (user_id, actor, kind, meal_id, comment_id)
  select p.id, author, 'tag', p_meal, p_comment
  from profiles p
  where p.username = any(names) and p.id <> author
    and (p.id = owner or exists (select 1 from friendships f where f.status = 'accepted'
         and ((f.requester = owner and f.addressee = p.id) or (f.addressee = owner and f.requester = p.id))))
    and not (p_comment is not null and p.id = owner and old_text is null);
end $$;
revoke execute on function public.notify_tags(uuid, uuid, text, text, uuid, bigint) from public, anon, authenticated;

create or replace function public.make_notification()
returns trigger language plpgsql security definer set search_path = public as $$
declare owner uuid;
begin
  if TG_TABLE_NAME = 'haps' then
    select user_id into owner from meals where id = new.meal_id;
    if owner is not null and owner <> new.user_id then
      delete from notifications where kind = 'haps' and meal_id = new.meal_id and actor = new.user_id;
      insert into notifications (user_id, actor, kind, meal_id) values (owner, new.user_id, 'haps', new.meal_id);
    end if;
  elsif TG_TABLE_NAME = 'comment_haps' then
    select c.user_id into owner from comments c where c.id = new.comment_id;
    if owner is not null and owner <> new.user_id then
      delete from notifications where kind = 'comment_haps' and comment_id = new.comment_id and actor = new.user_id;
      insert into notifications (user_id, actor, kind, meal_id, comment_id)
        select owner, new.user_id, 'comment_haps', c.meal_id, c.id from comments c where c.id = new.comment_id;
    end if;
  elsif TG_TABLE_NAME = 'comments' then
    select user_id into owner from meals where id = new.meal_id;
    if TG_OP = 'INSERT' and owner is not null and owner <> new.user_id then
      insert into notifications (user_id, actor, kind, meal_id, comment_id) values (owner, new.user_id, 'comment', new.meal_id, new.id);
    end if;
    if owner is not null then
      perform notify_tags(new.user_id, owner, new.body, case when TG_OP = 'UPDATE' then old.body else null end, new.meal_id, new.id);
    end if;
  elsif TG_TABLE_NAME = 'meals' then
    perform notify_tags(new.user_id, new.user_id, new.note, case when TG_OP = 'UPDATE' then old.note else null end, new.id, null);
  elsif TG_TABLE_NAME = 'friendships' then
    if TG_OP = 'INSERT' then
      insert into notifications (user_id, actor, kind) values (new.addressee, new.requester, 'friend_request');
    elsif new.status = 'accepted' and old.status <> 'accepted' then
      delete from notifications where kind = 'friend_request' and user_id = new.addressee and actor = new.requester;
      insert into notifications (user_id, actor, kind) values (new.requester, new.addressee, 'friend_accept');
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.make_notification() from public, anon, authenticated;

drop trigger if exists comments_notify on public.comments;
create trigger comments_notify after insert or update of body on public.comments for each row execute function public.make_notification();
drop trigger if exists meals_notify on public.meals;
create trigger meals_notify after insert or update of note on public.meals for each row execute function public.make_notification();
drop trigger if exists comment_haps_notify on public.comment_haps;
create trigger comment_haps_notify after insert on public.comment_haps for each row execute function public.make_notification();

create or replace function public.uncomment_haps_cleanup()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from notifications where kind = 'comment_haps' and comment_id = old.comment_id and actor = old.user_id;
  return old;
end $$;
revoke execute on function public.uncomment_haps_cleanup() from public, anon, authenticated;
drop trigger if exists comment_haps_unnotify on public.comment_haps;
create trigger comment_haps_unnotify after delete on public.comment_haps for each row execute function public.uncomment_haps_cleanup();

-- Ret kommentarer: markér som redigeret (ikke under omdøbning)
create or replace function public.comment_edited()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.body is distinct from old.body and coalesce(current_setting('app.renaming', true), '') <> '1' then new.edited_at = now(); end if;
  return new;
end $$;

-- Skift brugernavn: ret gamle @tags
create or replace function public.rename_mentions()
returns trigger language plpgsql security definer set search_path = public as $$
declare pat text;
begin
  if new.username = old.username then return new; end if;
  perform set_config('app.renaming', '1', true);
  pat := '(^|[^a-z0-9_.æøå@])@' || regexp_replace(old.username, '([.])', '\\\1', 'g') || '(?![a-z0-9_æøå]|\.[a-z0-9_æøå])';
  update meals set note = regexp_replace(note, pat, '\1@' || new.username, 'gi') where note ~* pat;
  update comments set body = regexp_replace(body, pat, '\1@' || new.username, 'gi') where body ~* pat;
  perform set_config('app.renaming', '', true);
  return new;
end $$;
revoke execute on function public.rename_mentions() from public, anon, authenticated;
drop trigger if exists profiles_rename_mentions on public.profiles;
create trigger profiles_rename_mentions after update of username on public.profiles for each row execute function public.rename_mentions();

-- ---------- slet konto ----------
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = me;
end $$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ---------- live opdatering ----------
alter table public.haps replica identity full;
alter table public.comment_haps replica identity full;
alter table public.comments replica identity full;
do $$ declare t text; begin
  foreach t in array array['haps','comment_haps','comments','notifications','meals'] loop
    if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
