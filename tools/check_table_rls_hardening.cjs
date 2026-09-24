const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const file = path.join(__dirname, "..", "supabase", "migrations", "20260822170000_table_rls_hardening.sql");
const sql = fs.readFileSync(file, "utf8");

const protectedTables = [
  "residents", "admissions", "rooms", "beds", "contracts", "bills", "ac_bills",
  "payments", "payment_receipts", "payment_allocations", "payment_status_history",
  "notices", "notice_recipients", "maintenance_requests", "maintenance_photos",
  "inspections", "room_inspections", "complaints", "visitors", "resident_portal_links",
  "staff_users", "staff", "system_settings", "admin_data_action_audits",
];

assert.doesNotMatch(sql, /USING\s*\(\s*true\s*\)|WITH CHECK\s*\(\s*true\s*\)/i);
assert.doesNotMatch(sql, /Allow authenticated full access/i);
assert.doesNotMatch(sql, /Staff full access|for all to authenticated using \(public\.is_staff_user\(\)\)/i);
assert.match(sql, /function public\.staff_can_operate\(p_module text, p_roles text\[\]\)/);
assert.match(sql, /p_module = any\(s\.permissions\)/);
const policies = [...sql.matchAll(/create policy "([^"]+)" on public\.(\w+)[\s\S]*?;/g)].map(m => ({ name: m[1], table: m[2], sql: m[0] }));
for (const table of ['payments', 'payment_allocations', 'payment_status_history', 'admin_data_action_audits', 'resident_portal_links']) {
  const writes = policies.filter(p => p.table === table && /for (insert|update|delete|all)\b/i.test(p.sql));
  if (table !== 'payments') assert.equal(writes.length, 0, `${table} must not have authenticated writes`);
  else {
    assert.equal(writes.length, 2);
    for (const p of writes) {
      assert.match(p.sql, /staff_can_operate\('payments', array\['accountant'\]/);
      assert.doesNotMatch(p.sql, /'staff'|'reception'|'manager'|for delete/i);
    }
  }
}
for (const p of policies.filter(p => ['bills','ac_bills','system_settings','staff_users'].includes(p.table) && /for (insert|update|delete|all)\b/i.test(p.sql))) {
  if (p.name === 'Staff update own contact details') {
    assert.match(p.sql, /lower\(btrim\(email\)\) = lower\(coalesce\(auth.jwt\(\)/);
    assert.match(sql, /array\['full_name','phone','notes','updated_at'\]::text\[\]/);
    assert.match(sql, /staff_profile_columns before update on public.staff_users/);
    continue;
  }
  assert.doesNotMatch(p.sql, /'staff'|'reception'|is_staff_user/);
}
assert.ok(!policies.some(p => p.table === 'residents' && /for (delete|all)\b/i.test(p.sql)), 'resident deletion uses audited RPC only');
const cleanup = policies.find(p => p.name === 'Admission entry rollback');
assert.match(cleanup.sql, /status = 'Pending'/);
assert.match(sql, /Reception claim beds/);
assert.match(sql, /Admission resident status/);
assert.match(sql, /select tablename from pg_tables[\s\S]*alter table public\.%I enable row level security/i);
assert.match(sql, /payment_allocations[\s\S]*payment_status_history/i);
assert.match(sql, /public\.is_staff_user\(\)/i);
assert.match(sql, /public\.is_admin_user\(\)/i);
assert.match(sql, /coalesce\(auth\.role\(\), ''\) = 'service_role'/i);
assert.match(sql, /Residents submit pending own receipts/i);
assert.match(sql, /Residents read own payment allocations/i);
assert.match(sql, /Residents read own payment history/i);
assert.match(sql, /Staff read payment allocations/i);
assert.match(sql, /Staff read payment status history/i);
assert.match(sql, /security definer[\s\S]*record_payment_status_change/i);
assert.match(sql, /Residents cannot|Residents may only submit their own contract signature/i);
for (const table of protectedTables) {
  assert.match(sql, new RegExp(`\\b${table}\\b`, "i"), `${table} must be covered by the migration model`);
}
console.log(`PASS table RLS hardening static checks (${protectedTables.length} sensitive tables)`);
