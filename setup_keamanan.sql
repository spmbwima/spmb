-- =========================================================
-- TAHAP 2 KEAMANAN: kunci tabel data, akses hanya lewat fungsi ber-sandi
-- Prasyarat: setup_auth.sql sudah dijalankan.
-- Jalankan SEKALI di Supabase > SQL Editor.
-- Urutan aman: 1) jalankan SQL ini  2) segera commit index.html terbaru
--   (di antara langkah 1 dan 2 aplikasi versi lama tidak bisa menyimpan/membaca data pendaftar)
-- =========================================================

-- ---------- 1. Kunci tabel ----------
alter table public.spmb_settings    enable row level security;
alter table public.spmb_schema      enable row level security;
alter table public.spmb_lists       enable row level security;
alter table public.spmb_submissions enable row level security;

-- buang SEMUA policy lama (mis. "public write", "public delete")
do $$
declare r record;
begin
  for r in select schemaname, tablename, policyname from pg_policies
           where schemaname = 'public'
             and tablename in ('spmb_settings','spmb_schema','spmb_lists','spmb_submissions')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

revoke all on public.spmb_submissions from anon, authenticated;
revoke insert, update, delete, truncate on public.spmb_settings, public.spmb_schema, public.spmb_lists from anon, authenticated;

-- Yang boleh dibaca publik (dibutuhkan formulir pendaftaran siswa):
create policy "baca pengaturan" on public.spmb_settings for select using (true);
create policy "baca formulir"   on public.spmb_schema   for select using (true);
create policy "baca daftar cari" on public.spmb_lists   for select using (id in ('guru_siswa','smp'));
-- spmb_lists lain (fee_config, kop, kepsek) dan spmb_submissions: TIDAK bisa dibaca publik.

-- ---------- 2. Pemeriksa sandi (internal) ----------
create or replace function public.spmb_require(p_level text, p_pass text)
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
declare ok boolean;
begin
  if p_level = 'admin' then
    select exists (select 1 from spmb_auth where role = 'admin'
                   and pass_hash = crypt(coalesce(p_pass,''), pass_hash)) into ok;
  else  -- level 'panitia': sandi panitia ATAU admin diterima
    select exists (select 1 from spmb_auth where role in ('admin','panitia')
                   and pass_hash = crypt(coalesce(p_pass,''), pass_hash)) into ok;
  end if;
  if not ok then
    perform pg_sleep(0.5);
    raise exception 'Tidak berwenang (sandi salah)' using errcode = '42501';
  end if;
end $$;
revoke all on function public.spmb_require(text, text) from public, anon, authenticated;

-- ---------- 3. Siswa: kirim pendaftaran (hanya menambah, tidak bisa membaca data lain) ----------
create or replace function public.spmb_submit(p_data jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare y spmb_settings.year%type; r spmb_submissions;
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' then raise exception 'Data tidak valid'; end if;
  if octet_length(p_data::text) > 200000 then raise exception 'Data terlalu besar'; end if;
  select year into y from spmb_settings where id = 1;
  insert into spmb_submissions(year, data, source) values (y, p_data, 'siswa') returning * into r;
  return to_jsonb(r);
end $$;

-- ---------- 4. Panitia / Admin: kelola pendaftar ----------
create or replace function public.spmb_list_submissions(p_pass text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform spmb_require('panitia', p_pass);
  return (select coalesce(jsonb_agg(to_jsonb(s) order by s.created_at desc), '[]'::jsonb) from spmb_submissions s);
end $$;

create or replace function public.spmb_add_submissions(p_pass text, p_rows jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
declare res jsonb;
begin
  perform spmb_require('panitia', p_pass);
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then raise exception 'Data tidak valid'; end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'Terlalu banyak baris (maks 5000)'; end if;
  with ins as (
    insert into spmb_submissions(year, data, source)
    select coalesce(nullif(e->>'year',''), (select year from spmb_settings where id = 1)),
           coalesce(e->'data', '{}'::jsonb),
           case when e->>'source' in ('panitia','import') then e->>'source' else 'panitia' end
    from jsonb_array_elements(p_rows) e
    returning *
  )
  select coalesce(jsonb_agg(to_jsonb(ins) order by ins.created_at desc), '[]'::jsonb) into res from ins;
  return res;
end $$;

create or replace function public.spmb_update_submission(p_pass text, p_id text, p_patch jsonb)
returns boolean
language plpgsql security definer
set search_path = public, extensions
as $$
declare n int;
begin
  perform spmb_require('panitia', p_pass);
  update spmb_submissions set
    data      = case when p_patch ? 'data'      then p_patch->'data'                  else data end,
    verified  = case when p_patch ? 'verified'  then (p_patch->>'verified')::boolean  else verified end,
    withdrawn = case when p_patch ? 'withdrawn' then (p_patch->>'withdrawn')::boolean else withdrawn end
  where id::text = p_id;
  get diagnostics n = row_count;
  return n > 0;
end $$;

create or replace function public.spmb_delete_submission(p_pass text, p_id text)
returns boolean
language plpgsql security definer
set search_path = public, extensions
as $$
declare n int;
begin
  perform spmb_require('panitia', p_pass);
  delete from spmb_submissions where id::text = p_id;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- ---------- 5. Panitia / Admin: baca data privat (fee, kop, nomor WA kepsek) ----------
create or replace function public.spmb_get_private(p_pass text)
returns jsonb
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform spmb_require('panitia', p_pass);
  return (select coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) from spmb_lists l where l.id in ('fee_config','kop','kepsek'));
end $$;

-- ---------- 6. Admin: ubah pengaturan, formulir, dan daftar ----------
create or replace function public.spmb_save_settings(p_pass text, p_patch jsonb)
returns boolean
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform spmb_require('admin', p_pass);
  update spmb_settings set
    school_name = case when p_patch ? 'school_name' then p_patch->>'school_name' else school_name end,
    year        = case when p_patch ? 'year'        then p_patch->>'year'        else year end,
    form_title  = case when p_patch ? 'form_title'  then p_patch->>'form_title'  else form_title end,
    logo        = case when p_patch ? 'logo'        then p_patch->>'logo'        else logo end,
    slides      = case when p_patch ? 'slides'      then p_patch->'slides'       else slides end
  where id = 1;
  return found;
end $$;

create or replace function public.spmb_save_schema(p_pass text, p_fields jsonb)
returns boolean
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform spmb_require('admin', p_pass);
  if p_fields is null or jsonb_typeof(p_fields) <> 'array' then raise exception 'Data tidak valid'; end if;
  update spmb_schema set fields = p_fields where id = 1;
  if not found then insert into spmb_schema(id, fields) values (1, p_fields); end if;
  return true;
end $$;

create or replace function public.spmb_save_list(p_pass text, p_id text, p_items jsonb)
returns boolean
language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform spmb_require('admin', p_pass);
  if p_id not in ('guru_siswa','smp','fee_config','kop','kepsek') then raise exception 'Daftar tidak dikenal'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then raise exception 'Data tidak valid'; end if;
  insert into spmb_lists(id, items) values (p_id, p_items)
  on conflict (id) do update set items = excluded.items;
  return true;
end $$;

-- ---------- 7. Hak eksekusi ----------
do $$
declare f text;
begin
  foreach f in array array[
    'spmb_submit(jsonb)',
    'spmb_list_submissions(text)',
    'spmb_add_submissions(text,jsonb)',
    'spmb_update_submission(text,text,jsonb)',
    'spmb_delete_submission(text,text)',
    'spmb_get_private(text)',
    'spmb_save_settings(text,jsonb)',
    'spmb_save_schema(text,jsonb)',
    'spmb_save_list(text,text,jsonb)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to anon, authenticated, service_role', f);
  end loop;
end $$;
