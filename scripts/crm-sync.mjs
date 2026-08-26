#!/usr/bin/env node
/**
 * ADC Outbound Performance Board — CRM status sync
 * =================================================
 * Reconciles each booking's job reference against the Apollo CRM and records
 * what the CRM says about that job. Run nightly.
 *
 *   node scripts/crm-sync.mjs --dry-run     # print every intended change, write nothing
 *   node scripts/crm-sync.mjs               # apply
 *   node scripts/crm-sync.mjs --windows 12  # look further back (default 10)
 *
 * Credentials are read from files outside this repo and are never printed:
 *   ~/.claude/secrets/apollo.env   CRM_WEBHOOK_URL, CRM_WEBHOOK_TOKEN
 *   ~/.config/adc/supabase.env     SUPABASE_URL, SUPABASE_ANON_KEY
 *
 * This runs server-side on purpose. The board is a single public static file;
 * an API token placed in it would be world-readable.
 */

import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

/* ---------- CRM status vocabulary ---------------------------------------
 * Verified against the live API 2026-08-26. Match on the CODE: the CRM spells
 * it "Canceled" with one L while this app uses "cancelled" with two, so any
 * string comparison silently misses every cancellation.
 */
const CRM_CANCELED = 40;
const CRM_STATUS = { 1: 'New', 2: 'Pending', 3: 'Won', 5: 'Closed', 7: 'Paid', 40: 'Canceled' };

/* `20_assignment_log` is clamped to 7 days and rejects the call outright if
 * end - start > 6. It filters on updated_at, not scheduled_date, which makes
 * it a change feed: an old job reappears whenever its status moves. */
const QUERY_ID = '20_assignment_log';
const WINDOW_SPAN_DAYS = 6;
const DEFAULT_WINDOWS = 10;
const REQ_DELAY_MS = 2200;   // 30 req/min ceiling, with headroom

const args = process.argv.slice(2);
const DRY_RUN = args.includes('--dry-run');
const WINDOWS = Number(args[args.indexOf('--windows') + 1]) || DEFAULT_WINDOWS;

const sleep = ms => new Promise(r => setTimeout(r, ms));

function loadEnv(path) {
  let raw;
  try { raw = readFileSync(path, 'utf8'); }
  catch { die(`Cannot read ${path}. See the header of this file for what it must contain.`); }
  const out = {};
  for (const line of raw.split('\n')) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)$/);
    if (m) out[m[1]] = m[2].trim().replace(/^["']|["']$/g, '');
  }
  return out;
}

function die(msg) { console.error(`\n  ✗ ${msg}\n`); process.exit(1); }

/** Today in Los Angeles. The CRM reports LA wall-clock with no offset, and the
 *  board's own date logic is PST throughout, so UTC would drift by a day. */
function laToday() {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Los_Angeles', year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date());
}

const addDays = (iso, n) => {
  const d = new Date(iso + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};

/** Consecutive 7-day windows walking backwards from today, newest first. */
function windows(count) {
  const out = [];
  let end = laToday();
  for (let i = 0; i < count; i++) {
    const start = addDays(end, -WINDOW_SPAN_DAYS);
    out.push([start, end]);
    end = addDays(start, -1);
  }
  return out;
}

/* ---------- CRM ---------- */

async function fetchWindow(cfg, start, end) {
  const res = await fetch(cfg.CRM_WEBHOOK_URL, {
    method: 'POST',
    headers: { 'Authorization': cfg.CRM_WEBHOOK_TOKEN, 'Content-Type': 'application/json' },
    body: JSON.stringify({ queries: [QUERY_ID], start_date: start, end_date: end }),
  });

  // 403 means the token was revoked. Retrying just burns the rate limit and
  // hides the real problem, so stop immediately and say so.
  if (res.status === 403) die('CRM returned 403 — the token is revoked. Do not retry; get a new one.');
  if (res.status === 429) die('CRM returned 429 — rate limited. Wait a minute and re-run.');

  const body = await res.json().catch(() => null);
  if (!res.ok || !body) die(`CRM HTTP ${res.status}: ${JSON.stringify(body)?.slice(0, 300)}`);
  if (body.error) die(`CRM error for ${start}..${end}: ${body.error} ${JSON.stringify(body.violations || '')}`);

  const result = Object.values(body.results || {})[0];
  if (!result) die(`CRM returned no result block for ${start}..${end}`);

  // 20k cap with no pagination. If this ever trips, the window is silently
  // incomplete and refs would look unresolved for no visible reason.
  if (result.truncated) {
    console.warn(`  ! window ${start}..${end} came back TRUNCATED — ${result.row_count} rows. Results are incomplete.`);
  }
  return result.rows || [];
}

/* ---------- Supabase ----------
 * PostgREST here takes a plain `apikey` header and nothing else. Adding an
 * `Authorization: Bearer` alongside it makes these calls fail. */

const sbHeaders = cfg => ({ apikey: cfg.SUPABASE_ANON_KEY, 'Content-Type': 'application/json' });

async function getBookings(cfg) {
  const url = `${cfg.SUPABASE_URL}/rest/v1/bookings`
    + `?select=id,job_ref,status,kind,report_date,sale_amount,crm_status_code,crm_status,crm_conflict`
    + `&order=report_date.desc`;
  const res = await fetch(url, { headers: sbHeaders(cfg) });
  if (!res.ok) {
    const t = await res.text();
    if (/crm_status_code/.test(t)) die('bookings has no crm_* columns yet — run crm_sync_schema.sql first.');
    die(`Supabase read failed (HTTP ${res.status}): ${t.slice(0, 300)}`);
  }
  return res.json();
}

async function patchBooking(cfg, id, patch) {
  const res = await fetch(`${cfg.SUPABASE_URL}/rest/v1/bookings?id=eq.${id}`, {
    method: 'PATCH',
    headers: { ...sbHeaders(cfg), Prefer: 'return=minimal' },
    body: JSON.stringify(patch),
  });
  if (!res.ok) throw new Error(`PATCH ${id} → HTTP ${res.status}: ${(await res.text()).slice(0, 200)}`);
}

/* ---------- the rules ----------
 * CRM drives cancellation. It never reverts an outcome someone recorded and
 * never un-cancels; those disagreements are flagged for a person instead.
 */
function decide(b, crm) {
  const code = Number(crm.status_code);
  const label = String(crm.status ?? CRM_STATUS[code] ?? `code ${code}`);
  const patch = {
    crm_status_code: code,
    crm_status: label,
    crm_scheduled_date: crm.scheduled_date || null,
    crm_synced_at: new Date().toISOString(),
    crm_conflict: null,
  };
  let action = 'no change';

  if (code === CRM_CANCELED) {
    if (b.status === 'pending') {
      patch.status = 'cancelled';
      action = 'pending → cancelled';
    } else if (b.status === 'sold' || b.status === 'ran_not_sold') {
      // A recorded outcome outranks the sync. Flag it; a sold job that got
      // cancelled is a real event someone needs to look at, not a silent edit.
      patch.crm_conflict = `CRM says Canceled; this booking is recorded as ${b.status}`;
      action = `CONFLICT (${b.status} vs Canceled)`;
    }
  } else if (b.status === 'cancelled') {
    // Un-cancelling would reverse a human judgement on the strength of an
    // accounting status. Flag only.
    patch.crm_conflict = `Marked cancelled here, but CRM says ${label}`;
    action = `CONFLICT (cancelled vs ${label})`;
  }
  return { patch, action };
}

/** True when the patch would change nothing already stored. Keeps a second
 *  run a genuine no-op instead of a rewrite with a fresh timestamp. */
const isNoop = (b, p) =>
  b.crm_status_code === p.crm_status_code &&
  (b.crm_conflict ?? null) === (p.crm_conflict ?? null) &&
  p.status === undefined;

/* ---------- main ---------- */

async function main() {
  const crmCfg = loadEnv(join(homedir(), '.claude/secrets/apollo.env'));
  const sbCfg = loadEnv(join(homedir(), '.config/adc/supabase.env'));
  for (const k of ['CRM_WEBHOOK_URL', 'CRM_WEBHOOK_TOKEN']) if (!crmCfg[k]) die(`${k} missing from apollo.env`);
  for (const k of ['SUPABASE_URL', 'SUPABASE_ANON_KEY']) if (!sbCfg[k]) die(`${k} missing from supabase.env`);

  console.log(`\nADC CRM sync${DRY_RUN ? '  [DRY RUN — nothing will be written]' : ''}`);
  console.log(`LA date ${laToday()} · up to ${WINDOWS} windows (~${WINDOWS * 7} days)\n`);

  const bookings = await getBookings(sbCfg);
  console.log(`  ${bookings.length} bookings in the board`);

  const wanted = new Map();                       // job_ref → [booking, …]
  for (const b of bookings) {
    if (!b.job_ref) continue;
    const k = b.job_ref.trim().toUpperCase();
    if (!wanted.has(k)) wanted.set(k, []);
    wanted.get(k).push(b);
  }
  console.log(`  ${wanted.size} distinct job references to resolve\n`);

  const found = new Map();
  for (const [start, end] of windows(WINDOWS)) {
    if (found.size >= wanted.size) break;         // everything resolved; stop early
    const rows = await fetchWindow(crmCfg, start, end);
    let fresh = 0;
    for (const r of rows) {
      const k = String(r.job_ref ?? '').trim().toUpperCase();
      if (k && wanted.has(k) && !found.has(k)) { found.set(k, r); fresh++; }
    }
    console.log(`  ${start} → ${end}   ${String(rows.length).padStart(5)} rows   +${String(fresh).padStart(3)} matched   ${found.size}/${wanted.size}`);
    if (found.size < wanted.size) await sleep(REQ_DELAY_MS);
  }

  const missing = [...wanted.keys()].filter(k => !found.has(k));
  console.log(`\n  resolved ${found.size}/${wanted.size}`);
  if (missing.length) {
    // Never swallow these. An unresolved ref is a booking whose status we are
    // guessing at, and it stays unsynced so the next run retries it.
    console.log(`  UNRESOLVED (${missing.length}) — left unsynced, will retry next run:`);
    console.log(`    ${missing.join(', ')}`);
    console.log(`    (a longer --windows may reach them; a typo'd reference never will)`);
  }

  const plan = [];
  for (const [ref, crm] of found) {
    for (const b of wanted.get(ref)) {
      const { patch, action } = decide(b, crm);
      if (isNoop(b, patch)) continue;
      plan.push({ b, ref, patch, action });
    }
  }

  const changes = plan.filter(p => p.patch.status);
  const conflicts = plan.filter(p => p.patch.crm_conflict);
  console.log(`\n  ${plan.length} rows to write`);
  console.log(`    ${changes.length} status changes`);
  console.log(`    ${conflicts.length} conflicts flagged`);

  if (changes.length || conflicts.length) {
    console.log('');
    for (const p of [...changes, ...conflicts]) {
      console.log(`    ${p.ref}  ${p.b.report_date}  ${String(p.b.status).padEnd(13)} ${p.action}`);
    }
  }

  if (DRY_RUN) { console.log('\n  dry run — nothing written.\n'); return; }
  if (!plan.length) { console.log('\n  nothing to do.\n'); return; }

  let ok = 0; const failed = [];
  for (const p of plan) {
    try { await patchBooking(sbCfg, p.b.id, p.patch); ok++; }
    catch (e) { failed.push(`${p.ref}: ${e.message}`); }
  }
  console.log(`\n  wrote ${ok}/${plan.length}`);
  if (failed.length) { console.error(`  ${failed.length} FAILED:`); failed.forEach(f => console.error(`    ${f}`)); process.exitCode = 1; }
  console.log('');
}

main().catch(e => die(e.stack || e.message));
