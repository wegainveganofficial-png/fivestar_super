-- เจ้าของหอ = อีเมลในตาราง dorm_owner_emails (เข้าสู่ระบบด้วย Google หรืออีเมลก็ได้)
-- ถ้าตารางว่าง บัญชีแรกที่เข้าสู่ระบบจะเป็นเจ้าของหอ
create table if not exists public.dorm_owner_emails (email text primary key, created_at timestamptz default now());
alter table public.dorm_owner_emails enable row level security;
drop policy if exists owner_all on public.dorm_owner_emails;
create policy owner_all on public.dorm_owner_emails for all to authenticated using (public.dorm_is_owner()) with check (public.dorm_is_owner());

create or replace function public.dorm_claim_owner() returns boolean language plpgsql security definer set search_path = public as $$
declare v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if auth.uid() is null then return false; end if;
  if exists(select 1 from dorm_owners where user_id = auth.uid()) then return true; end if;
  if exists(select 1 from dorm_owner_emails) then
    if v_email <> '' and exists(select 1 from dorm_owner_emails where lower(email) = v_email) then
      insert into dorm_owners(user_id) values (auth.uid()) on conflict do nothing; return true;
    end if;
    return false;
  end if;
  if not exists(select 1 from dorm_owners) then insert into dorm_owners(user_id) values (auth.uid()); return true; end if;
  return false;
end $$;
revoke execute on function public.dorm_claim_owner() from public, anon;
grant execute on function public.dorm_claim_owner() to authenticated;

-- เพิ่มเจ้าของหอ: insert into public.dorm_owner_emails(email) values ('someone@gmail.com');
