-- ATA MURA — схема базы данных Supabase
-- Выполните этот файл целиком: Supabase → SQL Editor → New query → Run.
-- Можно в том же проекте, что и KKSU: таблицы ATA MURA называются atamura_* и не пересекаются с kksu_*.
--
-- Модель данных:
--   atamura_members — участники: роль (member / admin) и блокировка.
--                     admin — единственный владелец платформы. Назначается только вручную
--                     функцией atamura_set_owner в SQL Editor (см. README.md), из приложения — никогда.
--   atamura_admin_secret / atamura_admin_sessions — пароль админки (bcrypt) и открытые сессии админки;
--                     недоступны через API.
--   atamura_records — записи приложения (публикации, проекты, музей, курсы, новости…) в JSON.
--                     published = видно всем; иначе — автору, адресатам (visible_to) и редакции.
-- Правила доступа (RLS):
--   • опубликованное читают все вошедшие участники;
--   • неопубликованное (модерация, заказы, черновики) — автор, адресаты и редакция;
--   • участник меняет только свои записи; редакционные разделы (новости, журнал, курсы,
--     Creator Studio) меняет только владелец, и только после ввода пароля админки;
--   • участник не может сам «одобрить» публикацию или «оплатить» заказ — это делает триггер.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Участники
-- ---------------------------------------------------------------------------
create table if not exists public.atamura_members (
    user_id     uuid primary key references auth.users (id) on delete cascade,
    role        text not null default 'member' check (role in ('member', 'admin')),
    full_name   text not null default '',
    blocked     boolean not null default false,
    created_at  timestamptz not null default now()
);

alter table public.atamura_members enable row level security;

-- Если схема уже выполнялась раньше: убираем роль «editor» и разрешаем только member / admin.
select set_config('atamura.owner_setup', 'on', false);
update public.atamura_members set role = 'member' where role not in ('member', 'admin');
select set_config('atamura.owner_setup', '', false);
alter table public.atamura_members drop constraint if exists atamura_members_role_check;
alter table public.atamura_members add constraint atamura_members_role_check check (role in ('member', 'admin'));

-- Администратор может быть только один.
create unique index if not exists atamura_single_admin on public.atamura_members (role) where role = 'admin';

-- Пароль админки (одна строка) и открытые сессии админки. RLS без политик: через API не читаются.
create table if not exists public.atamura_admin_secret (
    id               int primary key default 1 check (id = 1),
    password_hash    text not null,
    failed_attempts  int not null default 0,
    locked_until     timestamptz,
    updated_at       timestamptz not null default now()
);
alter table public.atamura_admin_secret enable row level security;
revoke all on public.atamura_admin_secret from anon, authenticated;

create table if not exists public.atamura_admin_sessions (
    user_id         uuid primary key references auth.users (id) on delete cascade,
    unlocked_until  timestamptz not null
);
alter table public.atamura_admin_sessions enable row level security;
revoke all on public.atamura_admin_sessions from anon, authenticated;

create or replace function public.atamura_my_role() returns text
language sql stable security definer set search_path = public as $$
    select role from public.atamura_members where user_id = auth.uid() and not blocked
$$;

-- Права администратора: аккаунт владельца И открытая сессия админки (введён пароль админки).
create or replace function public.atamura_is_admin() returns boolean
language sql stable security definer set search_path = public as $$
    select exists (
        select 1 from public.atamura_members m
        join public.atamura_admin_sessions s on s.user_id = m.user_id
        where m.user_id = auth.uid() and m.role = 'admin' and not m.blocked and s.unlocked_until > now()
    )
$$;

create or replace function public.atamura_is_staff() returns boolean
language sql stable security definer set search_path = public as $$
    select public.atamura_is_admin()
$$;

create or replace function public.atamura_is_member() returns boolean
language sql stable security definer set search_path = public as $$
    select public.atamura_my_role() is not null
$$;

-- Новый участник всегда member. Роль нельзя изменить никаким запросом из приложения:
-- только функцией atamura_set_owner, которую выполняет владелец в SQL Editor.
create or replace function public.atamura_member_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
declare
    owner_setup boolean := coalesce(current_setting('atamura.owner_setup', true), '') = 'on';
begin
    if tg_op = 'INSERT' then
        if not owner_setup then
            new.role := 'member';
            new.blocked := false;
        end if;
    elsif new.role is distinct from old.role and not owner_setup then
        raise exception 'role can only be changed by the platform owner in Supabase';
    elsif old.role = 'admin' and new.blocked and not owner_setup then
        raise exception 'the owner cannot be blocked';
    end if;
    return new;
end $$;

drop trigger if exists atamura_member_defaults on public.atamura_members;
create trigger atamura_member_defaults before insert or update on public.atamura_members
for each row execute function public.atamura_member_defaults();

drop policy if exists "members: read" on public.atamura_members;
create policy "members: read" on public.atamura_members for select
    using (user_id = auth.uid() or public.atamura_is_member());

drop policy if exists "members: register self" on public.atamura_members;
create policy "members: register self" on public.atamura_members for insert
    with check (user_id = auth.uid());

-- Владелец (после ввода пароля админки) может только блокировать участников.
drop policy if exists "members: admin manage" on public.atamura_members;
create policy "members: admin manage" on public.atamura_members for update
    using (public.atamura_is_admin())
    with check (public.atamura_is_admin());

-- ---------------------------------------------------------------------------
-- Записи приложения
-- ---------------------------------------------------------------------------
create table if not exists public.atamura_records (
    collection  text not null,
    id          uuid not null,
    owner_id    uuid,
    visible_to  uuid[] not null default '{}',
    published   boolean not null default false,
    data        jsonb not null,
    deleted     boolean not null default false,
    updated_at  timestamptz not null default now(),
    primary key (collection, id)
);

create index if not exists atamura_records_updated on public.atamura_records (updated_at);
create index if not exists atamura_records_visible on public.atamura_records using gin (visible_to);

alter table public.atamura_records enable row level security;

-- Разделы, которые меняет только редакция.
create or replace function public.atamura_is_staff_only(c text) returns boolean
language sql immutable as $$
    select c in ('topics', 'forgottenIdeas', 'kidsThemes', 'news', 'magazines', 'courses', 'products',
                 'contentItems', 'ideas', 'vlog', 'guests', 'series', 'media', 'events', 'partners',
                 'tasks', 'settings')
$$;

-- Разделы, где участник создаёт запись для другого человека (уведомление, приглашение).
create or replace function public.atamura_is_shared_write(c text) returns boolean
language sql immutable as $$
    select c in ('notifications', 'invites')
$$;

-- Разделы с модерацией: публикует только редакция.
create or replace function public.atamura_is_moderated(c text) returns boolean
language sql immutable as $$
    select c in ('posts', 'places', 'projects', 'museum', 'kidsWorks', 'research')
$$;

create or replace function public.atamura_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    new.updated_at := now();
    if not public.atamura_is_staff() then
        -- Участник не может сам опубликовать материал, который проходит модерацию.
        if public.atamura_is_moderated(new.collection) then
            if tg_op = 'INSERT' or not old.published then
                new.published := false;
                new.data := jsonb_set(new.data, '{status}', '"pending"', true);
                if new.collection = 'research' then
                    new.data := jsonb_set(new.data, '{reviewStatus}',
                        to_jsonb(case when new.data->>'reviewStatus' in ('draft', 'submitted') then new.data->>'reviewStatus' else 'draft' end), true);
                end if;
            end if;
        end if;
        -- Заказ участник создаёт только «ожидающим оплаты».
        if new.collection = 'orders' then
            if tg_op = 'INSERT' then
                new.data := jsonb_set(new.data, '{status}', '"pending"', true);
            elsif old.data->>'status' is distinct from new.data->>'status' then
                new.data := jsonb_set(new.data, '{status}', to_jsonb(old.data->>'status'), true);
            end if;
        end if;
        -- Записаться самостоятельно можно только на бесплатный курс.
        if new.collection = 'enrollments' and tg_op = 'INSERT' then
            if not exists (
                select 1 from public.atamura_records c
                where c.collection = 'courses' and c.id = (new.data->>'courseId')::uuid
                  and (c.data->>'access' = 'free' or coalesce((c.data->>'price')::int, 0) = 0
                       or c.data->>'access' = 'membersOnly')
            ) then
                raise exception 'paid course requires a confirmed order';
            end if;
        end if;
    end if;
    -- Роль в профиле не хранится в записях: настоящая роль — только в atamura_members.
    if new.collection = 'users' and new.data ? 'role' then
        new.data := jsonb_set(new.data, '{role}', '"member"', true);
    end if;
    return new;
end $$;

drop trigger if exists atamura_guard on public.atamura_records;
create trigger atamura_guard before insert or update on public.atamura_records
for each row execute function public.atamura_guard();

drop policy if exists "records: read" on public.atamura_records;
create policy "records: read" on public.atamura_records for select
    using (public.atamura_is_member()
           and (published
                or public.atamura_is_staff()
                or owner_id = auth.uid()
                or auth.uid() = any (visible_to)));

drop policy if exists "records: insert" on public.atamura_records;
create policy "records: insert" on public.atamura_records for insert
    with check (public.atamura_is_staff()
                or (public.atamura_is_member()
                    and not public.atamura_is_staff_only(collection)
                    and (owner_id = auth.uid()
                         or (public.atamura_is_shared_write(collection) and owner_id is null))));

drop policy if exists "records: update" on public.atamura_records;
create policy "records: update" on public.atamura_records for update
    using (public.atamura_is_staff()
           or (public.atamura_is_member()
               and not public.atamura_is_staff_only(collection)
               and (owner_id = auth.uid()
                    or (public.atamura_is_shared_write(collection) and auth.uid() = any (visible_to)))))
    with check (public.atamura_is_staff()
                or (not public.atamura_is_staff_only(collection)
                    and (owner_id = auth.uid()
                         or (public.atamura_is_shared_write(collection) and auth.uid() = any (visible_to)))));

-- Удаление — через флаг deleted (update); физически удаляет только администратор.
drop policy if exists "records: admin delete" on public.atamura_records;
create policy "records: admin delete" on public.atamura_records for delete
    using (public.atamura_is_admin());

-- ---------------------------------------------------------------------------
-- Владелец и пароль админки
-- ---------------------------------------------------------------------------

-- Назначает владельца (единственного администратора) и задаёт пароль админки.
-- Выполняется ТОЛЬКО в Supabase SQL Editor: из приложения вызвать её нельзя.
--   select public.atamura_set_owner('ваш-email@example.com', 'ваш-пароль-админки');
create or replace function public.atamura_set_owner(owner_email text, admin_password text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
    owner_id uuid;
begin
    select id into owner_id from auth.users where lower(email) = lower(owner_email);
    if owner_id is null then
        raise exception 'user % not found: register in the ATA MURA app first', owner_email;
    end if;
    if length(admin_password) < 10 then
        raise exception 'admin password must be at least 10 characters';
    end if;
    perform set_config('atamura.owner_setup', 'on', true);
    update public.atamura_members set role = 'member' where role = 'admin' and user_id <> owner_id;
    insert into public.atamura_members (user_id, role, full_name, blocked)
        values (owner_id, 'admin', '', false)
        on conflict (user_id) do update set role = 'admin', blocked = false;
    insert into public.atamura_admin_secret (id, password_hash)
        values (1, crypt(admin_password, gen_salt('bf', 10)))
        on conflict (id) do update set password_hash = excluded.password_hash,
            failed_attempts = 0, locked_until = null, updated_at = now();
    delete from public.atamura_admin_sessions;
end $$;

revoke execute on function public.atamura_set_owner(text, text) from public, anon, authenticated;

-- Проверка пароля админки. 5 неверных попыток — блокировка на 15 минут.
create or replace function public.atamura_admin_unlock(password text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
    secret public.atamura_admin_secret;
begin
    if not exists (select 1 from public.atamura_members
                   where user_id = auth.uid() and role = 'admin' and not blocked) then
        return 'denied';
    end if;
    select * into secret from public.atamura_admin_secret where id = 1 for update;
    if not found then
        return 'denied';
    end if;
    if secret.locked_until is not null and secret.locked_until > now() then
        return 'locked';
    end if;
    if secret.password_hash = crypt(password, secret.password_hash) then
        update public.atamura_admin_secret set failed_attempts = 0, locked_until = null where id = 1;
        insert into public.atamura_admin_sessions (user_id, unlocked_until)
            values (auth.uid(), now() + interval '2 hours')
            on conflict (user_id) do update set unlocked_until = excluded.unlocked_until;
        return 'ok';
    end if;
    update public.atamura_admin_secret
        set failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end,
            locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else null end
        where id = 1;
    return case when secret.failed_attempts + 1 >= 5 then 'locked' else 'wrong' end;
end $$;

revoke execute on function public.atamura_admin_unlock(text) from public, anon;
grant execute on function public.atamura_admin_unlock(text) to authenticated;

create or replace function public.atamura_admin_lock() returns void
language sql security definer set search_path = public as $$
    delete from public.atamura_admin_sessions where user_id = auth.uid()
$$;

grant execute on function public.atamura_admin_lock() to authenticated;

-- ---------------------------------------------------------------------------
-- Удаление аккаунта самим пользователем (App Store 5.1.1(v))
-- ---------------------------------------------------------------------------
create or replace function public.atamura_delete_my_account() returns void
language plpgsql security definer set search_path = public as $$
begin
    update public.atamura_records set deleted = true, data = '{}'::jsonb, published = false
        where owner_id = auth.uid() or (collection = 'users' and id = auth.uid());
    delete from public.atamura_members where user_id = auth.uid();
    delete from auth.users where id = auth.uid();
end $$;

grant execute on function public.atamura_delete_my_account() to authenticated;
