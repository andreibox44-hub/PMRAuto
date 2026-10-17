-- PMRAuto: схема базы для Supabase.
-- Запускать целиком в Supabase → SQL Editor → New query → Run.
-- Скрипт можно запускать повторно: он ничего не удаляет из данных.

-- ============ Профили ============
-- Одна строка на пользователя. Создаётся автоматически при регистрации (триггер ниже).
-- Профили видны всем. Телефон из профиля сюда не попадает: он личный
-- и хранится в данных пользователя (auth.users.raw_user_meta_data.phone).
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  username    text not null check (username ~ '^[a-zA-Z0-9_.-]{3,20}$'),
  name        text not null default '' check (char_length(name) <= 80),
  city        text not null default '' check (char_length(city) <= 80),
  email       text not null default '' check (char_length(email) <= 120),  -- контактный e-mail, показывается покупателям
  telegram    text not null default '' check (char_length(telegram) <= 60),
  avatar      text not null default '' check (char_length(avatar) <= 500), -- адрес картинки в Storage
  created_at  timestamptz not null default now()
);
alter table public.profiles drop column if exists phone; -- было в первой версии схемы
create unique index if not exists profiles_username_lower on public.profiles (lower(username));

alter table public.profiles enable row level security;
drop policy if exists "profiles: читают все" on public.profiles;
create policy "profiles: читают все" on public.profiles for select using (true);
drop policy if exists "profiles: меняет владелец" on public.profiles;
create policy "profiles: меняет владелец" on public.profiles for update
  using (auth.uid() = id) with check (auth.uid() = id);

-- Логин нельзя поменять после регистрации
create or replace function public.keep_username() returns trigger
language plpgsql as $$
begin
  new.username := old.username;
  new.created_at := old.created_at;
  return new;
end $$;
drop trigger if exists profiles_keep_username on public.profiles;
create trigger profiles_keep_username before update on public.profiles
  for each row execute function public.keep_username();

-- Профиль создаётся из логина, переданного при регистрации (options.data.username)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username)
  values (new.id, new.raw_user_meta_data ->> 'username');
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Проверка, свободен ли логин (до регистрации, без входа).
-- username_taken.name — параметр функции; просто name внутри запроса означало бы колонку profiles.name
create or replace function public.username_taken(name text) returns boolean
language sql stable security definer set search_path = public as $$
  select lower(username_taken.name) in ('demo', 'automarkt', 'pmrauto')
      or exists (select 1 from public.profiles p where lower(p.username) = lower(username_taken.name));
$$;
grant execute on function public.username_taken(text) to anon, authenticated;

-- ============ Объявления ============
create table if not exists public.listings (
  id           uuid primary key default gen_random_uuid(),
  owner        uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at   timestamptz not null default now(),
  vehicle      text not null check (vehicle in ('car', 'moto', 'truck', 'van')),
  brand        text not null check (char_length(brand) between 1 and 60),
  model        text not null check (char_length(model) between 1 and 80),
  year         int  not null check (year between 1950 and 2100),
  mileage      int  not null check (mileage >= 0),
  price        int  not null check (price > 0),
  fuel         text not null check (fuel in ('petrol', 'diesel', 'hybrid', 'electric', 'gas')),
  transmission text not null default '' check (transmission in ('', 'automatic', 'manual')),
  power        int  check (power is null or power between 1 and 3000),
  body         text not null default '' check (char_length(body) <= 30),
  color        text not null default '' check (char_length(color) <= 60),
  city         text not null default '' check (char_length(city) <= 80),
  phone        text not null default '' check (char_length(phone) <= 40),
  description  text not null default '' check (char_length(description) <= 5000),
  photos       text[] not null default '{}' check (cardinality(photos) <= 10)
);
create index if not exists listings_created_at on public.listings (created_at desc);
create index if not exists listings_owner on public.listings (owner);

alter table public.listings enable row level security;
drop policy if exists "listings: читают все" on public.listings;
create policy "listings: читают все" on public.listings for select using (true);
drop policy if exists "listings: создаёт владелец" on public.listings;
create policy "listings: создаёт владелец" on public.listings for insert
  to authenticated with check (auth.uid() = owner);
drop policy if exists "listings: меняет владелец" on public.listings;
create policy "listings: меняет владелец" on public.listings for update
  to authenticated using (auth.uid() = owner) with check (auth.uid() = owner);
drop policy if exists "listings: удаляет владелец" on public.listings;
create policy "listings: удаляет владелец" on public.listings for delete
  to authenticated using (auth.uid() = owner);

-- ============ Чаты ============
-- Один чат на пару «покупатель + объявление»
create table if not exists public.chats (
  id             uuid primary key default gen_random_uuid(),
  listing_id     uuid references public.listings (id) on delete set null,
  buyer          uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  seller         uuid not null references public.profiles (id) on delete cascade,
  listing        jsonb not null default '{}', -- марка, модель и цена на момент начала диалога
  created_at     timestamptz not null default now(),
  buyer_read_at  timestamptz not null default now(),
  seller_read_at timestamptz not null default 'epoch',
  check (buyer <> seller),
  unique (listing_id, buyer)
);
create index if not exists chats_buyer on public.chats (buyer);
create index if not exists chats_seller on public.chats (seller);

alter table public.chats enable row level security;
drop policy if exists "chats: видят участники" on public.chats;
create policy "chats: видят участники" on public.chats for select
  to authenticated using (auth.uid() in (buyer, seller));
-- Начать чат можно только с владельцем существующего объявления
drop policy if exists "chats: начинает покупатель" on public.chats;
create policy "chats: начинает покупатель" on public.chats for insert
  to authenticated with check (
    auth.uid() = buyer
    and exists (select 1 from public.listings l where l.id = listing_id and l.owner = seller)
  );

create table if not exists public.messages (
  id         uuid primary key default gen_random_uuid(),
  chat_id    uuid not null references public.chats (id) on delete cascade,
  sender     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  text       text not null check (char_length(text) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index if not exists messages_chat on public.messages (chat_id, created_at);

alter table public.messages enable row level security;
drop policy if exists "messages: видят участники" on public.messages;
create policy "messages: видят участники" on public.messages for select
  to authenticated using (
    exists (select 1 from public.chats c where c.id = chat_id and auth.uid() in (c.buyer, c.seller))
  );
drop policy if exists "messages: пишут участники" on public.messages;
create policy "messages: пишут участники" on public.messages for insert
  to authenticated with check (
    auth.uid() = sender
    and exists (select 1 from public.chats c where c.id = chat_id and auth.uid() in (c.buyer, c.seller))
  );

-- Отметить чат прочитанным (только свою сторону)
create or replace function public.mark_chat_read(chat uuid) returns void
language sql security definer set search_path = public as $$
  update public.chats set
    buyer_read_at  = case when buyer  = auth.uid() then now() else buyer_read_at  end,
    seller_read_at = case when seller = auth.uid() then now() else seller_read_at end
  where id = chat and auth.uid() in (buyer, seller);
$$;
grant execute on function public.mark_chat_read(uuid) to authenticated;

-- Список чатов пользователя с последним сообщением и числом непрочитанных
create or replace function public.my_chats() returns table (
  id uuid, listing_id uuid, buyer uuid, seller uuid, listing jsonb, created_at timestamptz,
  last_text text, last_sender uuid, last_at timestamptz, unread int
)
language sql stable security invoker set search_path = public as $$
  select c.id, c.listing_id, c.buyer, c.seller, c.listing, c.created_at,
         m.text, m.sender, m.created_at,
         (select count(*)::int from public.messages u
           where u.chat_id = c.id and u.sender <> auth.uid()
             and u.created_at > case when c.buyer = auth.uid() then c.buyer_read_at else c.seller_read_at end)
  from public.chats c
  left join lateral (
    select text, sender, created_at from public.messages
    where chat_id = c.id order by created_at desc limit 1
  ) m on true
  where auth.uid() in (c.buyer, c.seller)
  order by coalesce(m.created_at, c.created_at) desc;
$$;
grant execute on function public.my_chats() to authenticated;

-- Новые сообщения приходят в браузер сразу (Realtime)
do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; end $$;

-- ============ Удаление аккаунта ============
-- Удаляет пользователя; профиль, объявления, чаты и сообщения удалятся каскадом.
-- Фото в Storage браузер удаляет сам перед вызовом.
create or replace function public.delete_my_account() returns void
language sql security definer set search_path = public as $$
  delete from auth.users where id = auth.uid();
$$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ============ Фото (Storage) ============
-- Публичная папка photos: читать может любой, загружать — только в свою папку <id пользователя>/...
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = 2097152,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "photos: загрузка в свою папку" on storage.objects;
create policy "photos: загрузка в свою папку" on storage.objects for insert
  to authenticated with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
-- Без права «видеть» свои файлы через API Supabase молча не даёт их удалить
drop policy if exists "photos: свои файлы" on storage.objects;
create policy "photos: свои файлы" on storage.objects for select
  to authenticated using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "photos: удаление своих" on storage.objects;
create policy "photos: удаление своих" on storage.objects for delete
  to authenticated using (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
