const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.join(__dirname, "..");
const migrationFile = path.join(root, "supabase", "migrations", "20260822190000_retire_plaintext_passwords.sql");
const migration = fs.readFileSync(migrationFile, "utf8");

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(full) : [full];
  });
}

const appSources = ["app", "components", "lib"].flatMap((dir) => walk(path.join(root, dir)));
const sourceFiles = appSources.filter((file) => /\.(ts|tsx)$/.test(file));
const allSourceCode = sourceFiles.map((file) => fs.readFileSync(file, "utf8")).join("\n");

// 1. Migration checks: historical plaintext is cleared and column dropped safely
assert.match(migration, /update\s+public\.residents\s+set\s+portal_temp_password\s*=\s*null/i, "Migration must clear historical plaintext passwords");
assert.match(migration, /alter\s+table\s+public\.residents\s+drop\s+column\s+portal_temp_password/i, "Migration must drop portal_temp_password column");
assert.doesNotMatch(migration, /add\s+column.*password/i, "Migration must not create a password replacement column");

// 2. Application checks: no write to portal_temp_password in app/components/lib
assert.doesNotMatch(allSourceCode, /portal_temp_password/i, "Application code must have no references to portal_temp_password");
assert.doesNotMatch(allSourceCode, /\.(?:insert|update)\(\s*\{[^}]*password/i, "No database insert/update of passwords");

// 3. No password logging in credential create/reset routes
const createLoginCode = fs.readFileSync(path.join(root, "app", "api", "residents", "create-login", "route.ts"), "utf8");
const resetPasswordCode = fs.readFileSync(path.join(root, "app", "api", "residents", "create-login", "reset-password", "route.ts"), "utf8");

assert.doesNotMatch(createLoginCode, /console\.(log|info|warn|error)\([^)]*temporaryPassword/i, "Create login route must not log temporary password");
assert.doesNotMatch(resetPasswordCode, /console\.(log|info|warn|error)\([^)]*temporaryPassword/i, "Reset password route must not log temporary password");

// 4. No storage persistence replacement (localStorage, sessionStorage)
assert.doesNotMatch(allSourceCode, /(?:localStorage|sessionStorage)\.setItem\([^)]*password/i, "No localStorage/sessionStorage persistence for passwords");

// 5. One-time response restricted to authorized create/reset actions
assert.match(createLoginCode, /ALLOWED_STAFF_ROLES/i, "Create login must restrict to authorized staff roles");
assert.match(createLoginCode, /authClient\.auth\.getUser/i, "Create login must verify user session");
assert.match(resetPasswordCode, /ALLOWED_STAFF_ROLES/i, "Reset password must restrict to authorized staff roles");
assert.match(resetPasswordCode, /authClient\.auth\.getUser/i, "Reset password must verify user session");

console.log("PASS password hardening static checks");
