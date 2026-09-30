-- หอพักห้าดาว: ตั้งค่าเข้าสู่ระบบเจ้าของหอ (บัญชีเดียว)
-- แก้ 2 บรรทัดที่มี <<< ก่อนกด Run

-- 1) เบอร์มือถือที่ใช้เข้าระบบแทนอีเมลได้
alter table public.dorm_owner_emails add column if not exists phone text default '';
update public.dorm_owner_emails
set phone = '0812345678'                         -- <<< ใส่เบอร์มือถือเจ้าของหอ
where lower(email) = 'admiin.oncare.th@gmail.com';

-- 2) รหัสผ่านเจ้าของหอ (ยืนยันอีเมลให้ด้วย เข้าได้ทันที)
update auth.users
set encrypted_password = crypt('fivestar2569', gen_salt('bf')),   -- <<< เปลี่ยนรหัสได้
    email_confirmed_at = coalesce(email_confirmed_at, now())
where lower(email) = 'admiin.oncare.th@gmail.com';

-- 3) เจ้าของหอมีบัญชีเดียว: เหลือแค่ admiin.oncare.th@gmail.com
delete from public.dorm_owner_emails where lower(email) <> 'admiin.oncare.th@gmail.com';
delete from public.dorm_owners o using auth.users u
where o.user_id = u.id and lower(u.email) <> 'admiin.oncare.th@gmail.com';

-- 4) แปลงเบอร์มือถือเป็นอีเมลตอนเข้าระบบ
create or replace function public.dorm_login_email(p_id text) returns text
language sql stable security definer set search_path = public as $$
  select lower(email) from public.dorm_owner_emails
  where coalesce(phone, '') <> ''
    and regexp_replace(regexp_replace(phone, '\D', '', 'g'), '^66', '0')
      = regexp_replace(regexp_replace(coalesce(p_id, ''), '\D', '', 'g'), '^66', '0')
  limit 1
$$;
grant execute on function public.dorm_login_email(text) to anon, authenticated;

select email, phone from public.dorm_owner_emails;
