-- Haps v3: svar på kommentarer og forslag til venner.
-- Kør hele filen én gang i Supabase: SQL Editor → New query → indsæt → Run.

-- ---------- svar på kommentarer ----------
alter table public.comments add column if not exists parent_id bigint references public.comments(id) on delete cascade;
create index if not exists comments_parent on public.comments (parent_id);

alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('haps','comment','friend_request','friend_accept','comment_haps','tag','reply'));

create or replace function public.make_notification()
returns trigger language plpgsql security definer set search_path = public as $$
declare owner uuid; parent_author uuid;
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
    if TG_OP = 'INSERT' then
      if new.parent_id is not null then
        select user_id into parent_author from comments where id = new.parent_id;
        if parent_author is not null and parent_author <> new.user_id then
          insert into notifications (user_id, actor, kind, meal_id, comment_id) values (parent_author, new.user_id, 'reply', new.meal_id, new.id);
        end if;
      end if;
      if owner is not null and owner <> new.user_id and owner is distinct from parent_author then
        insert into notifications (user_id, actor, kind, meal_id, comment_id) values (owner, new.user_id, 'comment', new.meal_id, new.id);
      end if;
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

-- En tagget person, der også får "svarede", skal ikke have begge
create or replace function public.notify_tags(author uuid, owner uuid, new_text text, old_text text, p_meal uuid, p_comment bigint)
returns void language plpgsql security definer set search_path = public as $$
declare names text[]; parent_author uuid;
begin
  if coalesce(current_setting('app.renaming', true), '') = '1' then return; end if;
  names := array(select unnest(mentions(new_text)) except select unnest(mentions(old_text)));
  if cardinality(names) = 0 then return; end if;
  if p_comment is not null and old_text is null then
    select c2.user_id into parent_author from comments c1 join comments c2 on c2.id = c1.parent_id where c1.id = p_comment;
  end if;
  insert into notifications (user_id, actor, kind, meal_id, comment_id)
  select p.id, author, 'tag', p_meal, p_comment
  from profiles p
  where p.username = any(names) and p.id <> author
    and (p.id = owner or exists (select 1 from friendships f where f.status = 'accepted'
         and ((f.requester = owner and f.addressee = p.id) or (f.addressee = owner and f.requester = p.id))))
    and not (p_comment is not null and p.id = owner and old_text is null)
    and p.id is distinct from parent_author;
end $$;
revoke execute on function public.notify_tags(uuid, uuid, text, text, uuid, bigint) from public, anon, authenticated;

-- ---------- forslag til venner ----------
-- Venners venner først (flest fælles venner), derefter de nyeste brugere. Aldrig en selv,
-- nuværende venner eller folk, man allerede har en anmodning med.
create or replace function public.suggest_friends(max_count int default 12)
returns table (id uuid, username text, display_name text, avatar text, mutual int)
language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as uid),
  mine as (
    select case when f.requester = me.uid then f.addressee else f.requester end as other, f.status
    from friendships f, me where me.uid in (f.requester, f.addressee)
  ),
  friends as (select other from mine where status = 'accepted'),
  fof as (
    select case when f.requester = fr.other then f.addressee else f.requester end as cand, count(*)::int as mutual
    from friendships f join friends fr on fr.other in (f.requester, f.addressee)
    where f.status = 'accepted'
    group by 1
  )
  select p.id, p.username, p.display_name, p.avatar, coalesce(fof.mutual, 0) as mutual
  from profiles p
  cross join me
  left join fof on fof.cand = p.id
  where me.uid is not null and p.id <> me.uid and p.id not in (select other from mine)
  order by coalesce(fof.mutual, 0) desc, p.created_at desc
  limit least(greatest(coalesce(max_count, 12), 1), 30);
$$;
revoke execute on function public.suggest_friends(int) from public, anon;
grant execute on function public.suggest_friends(int) to authenticated;

-- ---------- en vens venner (migration "haps_friends_of") ----------
-- Kun synlig for personen selv og dennes venner.
create or replace function public.friends_of(target uuid)
returns table (id uuid, username text, display_name text, avatar text)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar
  from friendships f
  join profiles p on p.id = case when f.requester = target then f.addressee else f.requester end
  where f.status = 'accepted' and target in (f.requester, f.addressee)
    and auth.uid() is not null
    and (auth.uid() = target or public.are_friends(auth.uid(), target))
  order by coalesce(nullif(p.display_name, ''), p.username);
$$;
revoke execute on function public.friends_of(uuid) from public, anon;
grant execute on function public.friends_of(uuid) to authenticated;
