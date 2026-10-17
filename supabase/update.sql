-- PMRAuto: обновление базы до версии 4.
-- Запускать целиком в Supabase → SQL Editor → New query → Run.
-- Можно запускать повторно: данные не меняются, только добавляются колонки и правила.
-- (Полная схема с нуля — в schema.sql, там всё то же самое.)

-- Версия 2–3: год выпуска с 1930, количество дверей, пять коробок передач
alter table public.listings drop constraint if exists listings_year_check;
alter table public.listings add constraint listings_year_check check (year between 1930 and 2100);
alter table public.listings add column if not exists doors int check (doors is null or doors between 1 and 9);
alter table public.listings drop constraint if exists listings_transmission_check;
alter table public.listings add constraint listings_transmission_check
  check (transmission in ('', 'manual', 'automatic', 'cvt', 'robot', 'semiauto'));

-- Версия 4: дополнительные характеристики и комплектация (всё необязательное)
alter table public.listings add column if not exists engine_volume int
  check (engine_volume is null or engine_volume between 50 and 20000);              -- см³
alter table public.listings add column if not exists drive text
  check (drive is null or drive in ('fwd', 'rwd', 'awd'));                          -- передний, задний, полный
alter table public.listings add column if not exists seats int
  check (seats is null or seats between 1 and 60);
alter table public.listings add column if not exists condition text
  check (condition is null or condition in ('new', 'used', 'damaged'));              -- новая, с пробегом, после ДТП
alter table public.listings add column if not exists customs_cleared boolean;       -- растаможена
alter table public.listings add column if not exists inspection_until date;        -- техосмотр до (1-е число месяца)
alter table public.listings add column if not exists fuel_consumption numeric(4, 1)
  check (fuel_consumption is null or (fuel_consumption > 0 and fuel_consumption < 100)); -- л/100 км
alter table public.listings add column if not exists eco_class text
  check (eco_class is null or eco_class in ('euro1', 'euro2', 'euro3', 'euro4', 'euro5', 'euro6'));
alter table public.listings add column if not exists interior_color text
  check (interior_color is null or char_length(interior_color) <= 30);
alter table public.listings add column if not exists interior_material text
  check (interior_material is null or interior_material in ('fabric', 'leather', 'eco_leather', 'alcantara', 'velour', 'combined'));
alter table public.listings add column if not exists features text[] not null default '{}'
  check (features <@ array['ac', 'climate', 'navigation', 'parking_sensors', 'rear_camera', 'heated_seats',
    'leather', 'sunroof', 'cruise', 'bluetooth', 'alloy_wheels', 'towbar']::text[]);  -- комплектация

-- Версия схемы: по ней сайт понимает, какие поля база уже умеет хранить
create or replace function public.schema_version() returns int
language sql immutable as $$ select 4 $$;
grant execute on function public.schema_version() to anon, authenticated;
