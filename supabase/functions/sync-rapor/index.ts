// =========================================================
// EDGE FUNCTION: sync-rapor  (project Supabase SPMB)
// Menarik DATA saja dari project RAPORWIMA:
//   - Guru   : nama (+ keterangan "Wali Kelas <kelas>" bila menjadi wali kelas)
//   - Siswa  : nama + kelas (tahun ajaran aktif di rapor)
// lalu menyimpannya ke tabel spmb_lists (id = 'guru_siswa'), yaitu
// daftar yang dipakai tab "Data Guru/Siswa" dan field bertipe "Cari".
//
// TIDAK membuat akun / username / kata sandi apa pun.
//
// Secret yang harus diset (Edge Functions > Secrets) di project SPMB:
//   RAPOR_URL         = https://iejpwxmcqwecejsrezry.supabase.co
//   RAPOR_SERVICE_KEY = service_role key project RAPORWIMA
// (SUPABASE_URL & SUPABASE_SERVICE_ROLE_KEY sudah otomatis tersedia.)
//
// Aturan:
//   - Baris hasil sinkron diberi penanda src = "rapor" dan id stabil
//     (rapor_g_<id guru> / rapor_s_<id siswa>).
//   - Setiap sinkron, baris ber-src "rapor" DIGANTI dengan data terbaru
//     (siswa yang pindah/lulus otomatis hilang dari daftar).
//   - Data yang diisi manual oleh admin (tanpa src) TIDAK disentuh.
//     Bila nama+jenis sama dengan data manual, baris rapor dilewati.
//   - Hanya admin SPMB (cek kata sandi admin di spmb_settings).
//
// Request (POST): { admin_pass: "<kata sandi admin SPMB>", tahun_ajaran_id?: "<uuid>" }
// =========================================================
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RAPOR_URL = Deno.env.get("RAPOR_URL") ?? "";
const RAPOR_SERVICE_KEY = Deno.env.get("RAPOR_SERVICE_KEY") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders },
  });
}

// deno-lint-ignore no-explicit-any
async function fetchAll(build: (from: number, to: number) => any) {
  const out: any[] = [];
  const size = 1000;
  for (let from = 0; ; from += size) {
    const { data, error } = await build(from, from + size - 1);
    if (error) throw new Error(error.message);
    out.push(...(data ?? []));
    if (!data || data.length < size) break;
  }
  return out;
}

const norm = (s: unknown) => String(s ?? "").trim().replace(/\s+/g, " ");
const lower = (s: unknown) => norm(s).toLowerCase();
const collator = new Intl.Collator("id", { numeric: true, sensitivity: "base" });

interface Item { id: string; nama: string; jenis: "Guru" | "Siswa"; ket: string; src?: string }

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  if (!RAPOR_URL || !RAPOR_SERVICE_KEY) {
    return json({ error: "Secret RAPOR_URL dan RAPOR_SERVICE_KEY belum diset di Edge Functions project SPMB." }, 500);
  }

  const body = await req.json().catch(() => ({}));
  const spmb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // --- hanya admin SPMB ---
  const { data: st, error: stErr } = await spmb.from("spmb_settings").select("admin_pass").eq("id", 1).single();
  if (stErr) return json({ error: "Gagal membaca pengaturan SPMB: " + stErr.message }, 500);
  const adminPass = st?.admin_pass ?? "admin123";
  if (!body.admin_pass || String(body.admin_pass) !== String(adminPass)) {
    return json({ error: "Hanya admin yang boleh menyinkronkan data (kata sandi admin salah)." }, 403);
  }

  try {
    const rapor = createClient(RAPOR_URL, RAPOR_SERVICE_KEY);

    // tahun ajaran (aktif, atau yang dipilih)
    let taQuery = rapor.from("tahun_ajaran").select("id,nama,semester");
    taQuery = body.tahun_ajaran_id ? taQuery.eq("id", body.tahun_ajaran_id) : taQuery.eq("is_aktif", true);
    const { data: taRows, error: taErr } = await taQuery.limit(1);
    if (taErr) return json({ error: "Rapor: " + taErr.message }, 400);
    const ta = taRows?.[0];
    if (!ta) return json({ error: "Tidak ada tahun ajaran aktif di rapor." }, 400);

    // ---------- baca data rapor ----------
    // deno-lint-ignore no-explicit-any
    const skRows: any[] = await fetchAll((f, t) =>
      rapor.from("siswa_kelas")
        .select("siswa(id,nama), kelas(nama)")
        .eq("tahun_ajaran_id", ta.id).order("id").range(f, t)
    );
    // deno-lint-ignore no-explicit-any
    const guruRows: any[] = await fetchAll((f, t) =>
      rapor.from("profiles").select("id,nama").eq("role", "guru").order("id").range(f, t)
    );
    // wali kelas (opsional: kalau gagal, keterangan guru dikosongkan saja)
    const waliByGuru = new Map<string, string>();
    try {
      // deno-lint-ignore no-explicit-any
      const wk: any[] = await fetchAll((f, t) =>
        rapor.from("wali_kelas").select("guru_id, kelas(nama)").eq("tahun_ajaran_id", ta.id).order("id").range(f, t)
      );
      for (const w of wk) if (w.kelas?.nama) waliByGuru.set(w.guru_id, norm(w.kelas.nama));
    } catch (_) { /* abaikan */ }

    // ---------- bentuk item ----------
    const guru: Item[] = [];
    for (const g of guruRows) {
      const nama = norm(g.nama);
      if (!nama) continue;
      const wali = waliByGuru.get(g.id);
      guru.push({ id: `rapor_g_${g.id}`, nama, jenis: "Guru", ket: wali ? `Wali Kelas ${wali}` : "", src: "rapor" });
    }
    guru.sort((a, b) => collator.compare(a.nama, b.nama));

    const siswa: Item[] = [];
    const seenSiswa = new Set<string>();
    for (const r of skRows) {
      const s = r.siswa;
      const nama = norm(s?.nama);
      if (!s || !nama || seenSiswa.has(s.id)) continue;
      seenSiswa.add(s.id);
      siswa.push({ id: `rapor_s_${s.id}`, nama, jenis: "Siswa", ket: norm(r.kelas?.nama), src: "rapor" });
    }
    siswa.sort((a, b) => collator.compare(a.ket, b.ket) || collator.compare(a.nama, b.nama));

    // ---------- gabung dengan data manual di SPMB ----------
    const { data: row, error: listErr } = await spmb.from("spmb_lists").select("items").eq("id", "guru_siswa").maybeSingle();
    if (listErr) return json({ error: "Gagal membaca spmb_lists: " + listErr.message + " (pastikan tabel spmb_lists sudah dibuat)" }, 500);
    const existing: Item[] = Array.isArray(row?.items) ? row!.items : [];
    const manual = existing.filter((it) => it?.src !== "rapor");
    const manualKeys = new Set(manual.map((it) => `${lower(it.jenis)}|${lower(it.nama)}`));

    let duplikat = 0;
    const dedupe = (arr: Item[]) => arr.filter((it) => {
      if (manualKeys.has(`${lower(it.jenis)}|${lower(it.nama)}`)) { duplikat++; return false; }
      return true;
    });
    const guruFinal = dedupe(guru);
    const siswaFinal = dedupe(siswa);
    const items = [...manual, ...guruFinal, ...siswaFinal];

    const { error: upErr } = await spmb.from("spmb_lists").upsert({ id: "guru_siswa", items });
    if (upErr) return json({ error: "Gagal menyimpan: " + upErr.message }, 500);

    return json({
      tahun_ajaran: `${ta.nama} ${ta.semester ?? ""}`.trim(),
      guru: guruFinal.length,
      siswa: siswaFinal.length,
      manual: manual.length,
      dilewati_duplikat: duplikat,
      total: items.length,
      items,
    });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
