# Sinkron Rapor → SPMB (data guru, siswa, kelas)

Hanya menarik DATA (nama guru, nama siswa, kelas). Tidak membuat akun, username, atau kata sandi.
Hasilnya masuk ke tab **Data Guru/Siswa** di panel admin SPMB (dipakai field bertipe "Cari").

## File
- `supabase/functions/sync-rapor/index.ts` → edge function baru di project **SPMB** (nama function: `sync-rapor`)
- `index.html` → ganti file lama (tambahan: tombol "Sinkron dari Rapor" di tab Data Guru/Siswa)

## Deploy
1. Supabase **SPMB** → Edge Functions → buat function `sync-rapor`, tempel isi `index.ts`.
   **Matikan "Verify JWT"** (Function Settings) atau deploy dengan `--no-verify-jwt`,
   karena SPMB memakai publishable key & login admin berbasis kata sandi, bukan Supabase Auth.
   (Akses dibatasi di dalam function: harus mengirim kata sandi admin SPMB yang benar.)
2. Edge Functions → Secrets, tambahkan:
   - `RAPOR_URL` = `https://iejpwxmcqwecejsrezry.supabase.co`
   - `RAPOR_SERVICE_KEY` = service_role key project **rapor** (Project Settings → API di project rapor). Jangan ditaruh di file HTML.
3. Pastikan tabel `spmb_lists` sudah ada (SQL ada di komentar dalam `index.html`).
4. Upload `index.html` baru → login admin → tab **Data Guru/Siswa** → **Sinkron dari Rapor**.

## Aturan
- Guru: semua akun rapor ber-role `guru`. Keterangan = "Wali Kelas <kelas>" bila menjadi wali kelas, selain itu kosong.
- Siswa: nama + kelas pada tahun ajaran aktif di rapor. Keterangan = nama kelas.
- Baris hasil sinkron diberi label **Rapor** dan diganti dengan data terbaru setiap sinkron
  (siswa yang pindah/lulus otomatis hilang dari daftar).
- Data yang ditambah manual (atau lewat Import Excel) tidak diubah. Jika nama + jenis sama dengan data manual, baris rapor dilewati.
- Aman dijalankan berulang.
