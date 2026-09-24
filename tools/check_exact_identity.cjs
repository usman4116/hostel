// Static source inspection and pure helper execution; no env files, SDK or network.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require('typescript');
const vm = require('node:vm');
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync('lib/identity.ts','utf8'), {
  compilerOptions:{module:ts.ModuleKind.CommonJS},
}).outputText, {exports:exportsObject});
const normalize = exportsObject.normalizeIdentityEmail;
assert.equal(normalize('  A_MIN@Example.COM '), 'a_min@example.com');
assert.equal(normalize('A%MIN@example.com'), 'a%min@example.com');
assert.notEqual(normalize('a_min@example.com'), normalize('admin@example.com'));
assert.notEqual(normalize('a%min@example.com'), normalize('admin@example.com'));
let inspected = 0;
function inspect(file) {
  const source=fs.readFileSync(file,'utf8');
  assert.doesNotMatch(source,/\.ilike\(\s*['"]email['"]/i,file);
  inspected++;
}
for(const folder of ['app','lib','components']) {
  for(const file of fs.readdirSync(folder,{recursive:true}).filter(f=>/\.tsx?$/.test(f)))inspect(path.join(folder,file));
}
inspect('proxy.ts');
for(const file of ['app/api/payment-verification/route.ts','app/api/payment-verification/cancel/route.ts','app/api/resident-portal/combined-payment/route.ts','lib/adminDataManagement.ts','lib/adminApiAuth.ts','proxy.ts']) {
  assert.match(fs.readFileSync(file,'utf8'),/\.eq\("email", normalizeIdentityEmail\(/,file);
}
const sql=fs.readFileSync('supabase/migrations/20260822210000_atomic_finance_and_exact_identity.sql','utf8');
for(const table of ['staff_users','residents']) {
  assert.match(sql,new RegExp(`update public\\.${table} set email = lower\\(btrim\\(email\\)\\)`));
  assert.match(sql,new RegExp(`before insert or update of email on public\\.${table}`));
}
console.log(`PASS exact identity equality (${inspected} source files); percent/underscore are literal, normalization on reads and database writes`);
