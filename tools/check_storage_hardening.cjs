const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
const migration = fs.readFileSync(path.join(root, "supabase", "migrations", "20260822180000_storage_hardening.sql"), "utf8");
const sources = ["app", "components", "lib"].flatMap((dir) => walk(path.join(root, dir)));
const source = sources.filter((file) => /\.(ts|tsx)$/.test(file)).map((file) => fs.readFileSync(file, "utf8")).join("\n");
const buckets = ["contract-agreements", "contract-signature", "room-inspection-photos", "maintenance-photos", "payment-receipts"];

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(full) : [full];
  });
}

for (const bucket of buckets) {
  assert.match(migration, new RegExp(`['\\"]${bucket}['\\"]`), `${bucket} missing`);
  assert.match(migration, new RegExp(`bucket_id = ['\\"]${bucket}['\\"]`), `${bucket} policy missing`);
}
assert.match(migration, /on conflict\s*\(id\)\s*do update set public\s*=\s*false/i);
assert.match(migration, /grant select, insert, update, delete on storage\.objects to authenticated/i);
assert.doesNotMatch(migration, /USING\s*\(\s*true\s*\)|WITH CHECK\s*\(\s*true\s*\)/i);
assert.doesNotMatch(source, /\.from\(["'](?:contract-agreements|contract-signature|room-inspection-photos|maintenance-photos|payment-receipts)["']\)\.getPublicUrl/i);
assert.doesNotMatch(source, /storage\.from\([^\n]+\)\.getPublicUrl/i);
assert.match(source, /createSignedUrl/i);
assert.match(source, /receipt_url:\s*(?:uploadedPath|filePath)/i);
console.log("PASS storage hardening static checks");
