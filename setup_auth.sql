-- =========================================================
-- Kata sandi Admin & Panitia disimpan (ter-hash) di database
-- Jalankan SEKALI di Supabase > SQL Editor.
-- Urutan aman: 1) jalankan SQL ini  2) deploy ulang Edge Function sync-rapor
--              3) commit index.html terbaru
-- =========================================================
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.spmb_auth (
  role        text primary key check (role in ('admin','panitia')),
  pass_hash   text not null,
  updated_at  timestamptz not null default now()
);
alter table public.spmb_auth enable row level security;   -- tanpa policy = tidak bisa dibaca/ditulis lewat API publik
revoke all on public.spmb_auth from anon, authenticated;

-- Pindahkan sandi lama dari spmb_settings (jika kolomnya masih ada), lalu hash
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='spmb_settings' and column_name='admin_pass') then
    insert into public.spmb_auth(role, pass_hash)
      select 'admin', extensions.crypt(coalesce(admin_pass,'admin123'), extensions.gen_salt('bf'))
      from public.spmb_settings where id = 1
    on conflict (role) do nothing;
    insert into public.spmb_auth(role, pass_hash)
      select 'panitia', extensions.crypt(coalesce(panitia_pass,'panitia123'), extensions.gen_salt('bf'))
      from public.spmb_settings where id = 1
    on conflict (role) do nothing;
  end if;
end $$;

-- Jika belum ada baris (instalasi baru), pakai sandi awal -> SEGERA ganti di Panel Admin > Pengaturan
insert into public.spmb_auth(role, pass_hash) values
  ('admin',   extensions.crypt('admin123',   extensions.gen_salt('bf'))),
  ('panitia', extensions.crypt('panitia123', extensions.gen_salt('bf')))
on conflict (role) do nothing;

-- Hapus sandi teks-biasa dari spmb_settings (tabel ini bisa dibaca publik)
alter table public.spmb_settings drop column if exists admin_pass;
alter table public.spmb_settings drop column if exists panitia_pass;

-- Cek login: mengembalikan true/false, tidak pernah mengembalikan hash
create or replace function public.spmb_login(p_role text, p_pass text)
returns boolean
language plpgsql security definer
set search_path = public, extensions
as $$
declare ok boolean;
begin
  select exists (select 1 from spmb_auth
                 where role = p_role and pass_hash = crypt(coalesce(p_pass,''), pass_hash)) into ok;
  if not ok then perform pg_sleep(0.5); end if;   -- redam tebak-tebakan sandi
  return ok;
end $$;

-- Ganti sandi (harus menyertakan sandi admin saat ini)
create or replace function public.spmb_set_password(p_admin_pass text, p_role text, p_new text)
returns boolean
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  if p_role not in ('admin','panitia') then raise exception 'Peran tidak valid'; end if;
  if not spmb_login('admin', p_admin_pass) then return false; end if;
  if p_new is null or length(p_new) < 6 then raise exception 'Kata sandi minimal 6 karakter'; end if;
  update spmb_auth set pass_hash = crypt(p_new, gen_salt('bf')), updated_at = now() where role = p_role;
  return true;
end $$;

revoke all on function public.spmb_login(text, text) from public;
revoke all on function public.spmb_set_password(text, text, text) from public;
grant execute on function public.spmb_login(text, text) to anon, authenticated, service_role;
grant execute on function public.spmb_set_password(text, text, text) to anon, authenticated, service_role;
