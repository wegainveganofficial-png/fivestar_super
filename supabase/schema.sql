-- หอพักจดง่าย: Supabase schema (already applied to project orldpdisplmplxrrqaan)

create table if not exists public.dorm_owners (user_id uuid primary key references auth.users(id) on delete cascade, created_at timestamptz default now());

create table if not exists public.dorm_settings (
  id text primary key default 'main', name text, promptpay text default '', account_name text default '', bank text default '', bank_acc text default '', qr_img text default '',
  water_rate numeric default 18, water_min numeric default 0, elec_rate numeric default 7, trash numeric default 40, due_day int default 5, prefix text default 'APT', demo boolean default false);

create table if not exists public.dorm_rooms (
  no text primary key, floor int, tenant text default '', phone text default '', rent numeric default 0, vacant boolean default false,
  apt_id text unique, water_start numeric default 0, elec_start numeric default 0, move_in text, demo boolean default false);

create table if not exists public.dorm_bills (
  id text primary key, month text not null, room text not null, rent numeric, water_prev numeric, water_curr numeric, elec_prev numeric, elec_curr numeric,
  water_units numeric, elec_units numeric, water_rate numeric, water_min numeric, elec_rate numeric, water numeric, elec numeric, trash numeric, other numeric default 0, other_note text default '',
  total numeric, status text not null default 'unpaid' check (status in ('unpaid','pending','paid')), method text, paid_at timestamptz, slip_at timestamptz, read_at timestamptz,
  verify jsonb, water_reset boolean default false, elec_reset boolean default false, has_water_photo boolean default false, has_elec_photo boolean default false, demo boolean default false);
create index if not exists dorm_bills_room_month on public.dorm_bills(room, month);

create table if not exists public.dorm_expenses (id text primary key, month text, date text, cat text, amount numeric, note text default '', demo boolean default false);

create table if not exists public.dorm_repairs (
  id text primary key, room text not null, cat text, note text, reported_at text, status text not null default 'new' check (status in ('new','scheduled','done','cancelled')),
  scheduled_at text default '', done_at text default '', owner_note text default '', cost numeric default 0, has_photo boolean default false, by text, created_at timestamptz default now(), expense_id text, demo boolean default false);

create table if not exists public.dorm_slips (id text primary key, img text, at timestamptz, by text);
create table if not exists public.dorm_meter_photos (id text primary key, w text, e text, at timestamptz);
create table if not exists public.dorm_repair_photos (id text primary key, img text);

create or replace function public.dorm_is_owner() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from public.dorm_owners where user_id = auth.uid()) $$;

do $$ declare t text; begin
  foreach t in array array['dorm_owners','dorm_settings','dorm_rooms','dorm_bills','dorm_expenses','dorm_repairs','dorm_slips','dorm_meter_photos','dorm_repair_photos'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists owner_all on public.%I', t);
    execute format('create policy owner_all on public.%I for all to authenticated using (public.dorm_is_owner()) with check (public.dorm_is_owner())', t);
  end loop;
end $$;

-- first signed-in user claims ownership; later users cannot
create or replace function public.dorm_claim_owner() returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  if exists(select 1 from dorm_owners where user_id = auth.uid()) then return true; end if;
  if not exists(select 1 from dorm_owners) then insert into dorm_owners(user_id) values (auth.uid()); return true; end if;
  return false;
end $$;

-- tenant access, keyed by Apartment ID
create or replace function public.dorm_room_by_apt(p_apt text) returns public.dorm_rooms language sql stable security definer set search_path = public as
$$ select * from dorm_rooms where upper(apt_id) = upper(trim(p_apt)) and coalesce(vacant,false) = false limit 1 $$;
revoke all on function public.dorm_room_by_apt(text) from public, anon, authenticated;

create or replace function public.dorm_tenant_portal(p_apt text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r dorm_rooms;
begin
  r := dorm_room_by_apt(p_apt);
  if r.no is null then return null; end if;
  return jsonb_build_object(
    'room', jsonb_build_object('no', r.no, 'floor', r.floor, 'tenant', r.tenant, 'apt_id', r.apt_id, 'rent', r.rent),
    'settings', (select jsonb_build_object('name', name, 'promptpay', promptpay, 'account_name', account_name, 'bank', bank, 'bank_acc', bank_acc, 'qr_img', qr_img, 'due_day', due_day, 'water_rate', water_rate, 'elec_rate', elec_rate, 'water_min', water_min, 'trash', trash) from dorm_settings where id='main'),
    'bills', coalesce((select jsonb_agg(to_jsonb(b) order by b.month desc) from (select * from dorm_bills where room = r.no order by month desc limit 12) b), '[]'::jsonb),
    'repairs', coalesce((select jsonb_agg(to_jsonb(x) order by x.reported_at desc) from (select * from dorm_repairs where room = r.no order by reported_at desc limit 20) x), '[]'::jsonb));
end $$;

create or replace function public.dorm_tenant_meter_photos(p_apt text, p_bill text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r dorm_rooms;
begin
  r := dorm_room_by_apt(p_apt);
  if r.no is null or not exists(select 1 from dorm_bills where id = p_bill and room = r.no) then return null; end if;
  return (select to_jsonb(m) from dorm_meter_photos m where id = p_bill);
end $$;

create or replace function public.dorm_tenant_repair_photo(p_apt text, p_id text) returns text language plpgsql stable security definer set search_path = public as $$
declare r dorm_rooms;
begin
  r := dorm_room_by_apt(p_apt);
  if r.no is null or not exists(select 1 from dorm_repairs where id = p_id and room = r.no) then return null; end if;
  return (select img from dorm_repair_photos where id = p_id);
end $$;

create or replace function public.dorm_tenant_submit_slip(p_apt text, p_bill text, p_img text) returns boolean language plpgsql security definer set search_path = public as $$
declare r dorm_rooms;
begin
  r := dorm_room_by_apt(p_apt);
  if r.no is null or p_img is null or length(p_img) > 400000 then return false; end if;
  if not exists(select 1 from dorm_bills where id = p_bill and room = r.no and status in ('unpaid','pending')) then return false; end if;
  insert into dorm_slips(id, img, at, by) values (p_bill, p_img, now(), 'tenant')
    on conflict (id) do update set img = excluded.img, at = excluded.at, by = excluded.by;
  update dorm_bills set status = 'pending', slip_at = now(), verify = jsonb_build_object('state','manual','note','รอเจ้าของหอตรวจสลิป') where id = p_bill;
  return true;
end $$;

create or replace function public.dorm_tenant_new_repair(p_apt text, p_cat text, p_note text, p_reported text, p_img text) returns text language plpgsql security definer set search_path = public as $$
declare r dorm_rooms; v_id text;
begin
  r := dorm_room_by_apt(p_apt);
  if r.no is null or coalesce(trim(p_note),'') = '' or length(p_note) > 2000 or (p_img is not null and length(p_img) > 400000) then return null; end if;
  if (select count(*) from dorm_repairs where room = r.no and created_at > now() - interval '1 hour') >= 10 then return null; end if;
  v_id := 'rp' || replace(gen_random_uuid()::text, '-', '');
  insert into dorm_repairs(id, room, cat, note, reported_at, status, has_photo, by)
    values (v_id, r.no, left(coalesce(p_cat,'อื่นๆ'),60), p_note, coalesce(nullif(p_reported,''), to_char(now() at time zone 'Asia/Bangkok','YYYY-MM-DD')), 'new', p_img is not null and p_img <> '', 'tenant');
  if p_img is not null and p_img <> '' then insert into dorm_repair_photos(id, img) values (v_id, p_img); end if;
  return v_id;
end $$;

create or replace function public.dorm_tenant_cancel_repair(p_apt text, p_id text) returns boolean language plpgsql security definer set search_path = public as $$
declare r dorm_rooms;
begin
  r := dorm_room_by_apt(p_apt);
  if r.no is null then return false; end if;
  update dorm_repairs set status = 'cancelled' where id = p_id and room = r.no and status = 'new';
  return found;
end $$;

grant execute on function public.dorm_tenant_portal(text), public.dorm_tenant_meter_photos(text,text), public.dorm_tenant_repair_photo(text,text),
  public.dorm_tenant_submit_slip(text,text,text), public.dorm_tenant_new_repair(text,text,text,text,text), public.dorm_tenant_cancel_repair(text,text) to anon, authenticated;
revoke execute on function public.dorm_claim_owner() from public, anon;
revoke execute on function public.dorm_is_owner() from public, anon;
grant execute on function public.dorm_claim_owner(), public.dorm_is_owner() to authenticated;

insert into public.dorm_settings(id) values ('main') on conflict do nothing;

do $$ declare t text; begin
  foreach t in array array['dorm_settings','dorm_rooms','dorm_bills','dorm_expenses','dorm_repairs'] loop
    begin execute format('alter publication supabase_realtime add table public.%I', t); exception when duplicate_object then null; end;
  end loop;
end $$;
