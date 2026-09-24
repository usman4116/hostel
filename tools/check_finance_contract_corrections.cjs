// Read-only structural regression checks plus independent edge-case models.
// Does not parse/execute SQL in a database, load environment files, or use a network client.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const dir = path.join(__dirname, '..', 'supabase', 'migrations');
const name = '20260822200000_finance_contract_security_corrections.sql';
const sql = fs.readFileSync(path.join(dir, name), 'utf8');
const previous = fs.readFileSync(path.join(dir, '20260822160000_combined_payment_allocations.sql'), 'utf8');
const clean = sql.replace(/--[^\n]*/g, '');
function body(source, name) {
  const start = source.indexOf('create or replace function public.' + name + '(');
  assert.notEqual(start, -1, name);
  return source.slice(start, source.indexOf('\n$$;', start) + 4);
}
const validation = body(clean, 'validate_payment_allocation_total');
assert.match(validation, /tg_table_name = 'payments' then\s*if tg_op <> 'INSERT' then affected_ids := array_append\(affected_ids, old.id\); end if;\s*if tg_op <> 'DELETE' then affected_ids := array_append\(affected_ids, new.id\); end if;/);
assert.match(validation, /tg_table_name = 'payment_allocations' then\s*if tg_op <> 'INSERT' then affected_ids := array_append\(affected_ids, old.payment_id\); end if;\s*if tg_op <> 'DELETE' then affected_ids := array_append\(affected_ids, new.payment_id\); end if;/);
assert.match(validation, /select distinct parent_id from unnest\(affected_ids\)/);
assert.match(validation, /where id = affected_id for update/);
assert.match(validation, /if not found then continue; end if;/);
assert.match(validation, /allocation_count <> 1 or allocation_total <> payment_row.amount/);
assert.match(validation, /payment_row.payment_status = 'Verified' and allocation_total <> payment_row.amount/);
assert.match(validation, /allocation_total > 0 and allocation_total <> payment_row.amount/);
assert.match(clean, /create constraint trigger payment_status_allocation_check\s+after insert or update or delete on public.payments\s+deferrable initially deferred/);
assert.doesNotMatch(clean, /drop trigger payment_allocations_total_check|disable trigger|disable row level security/i);
assert.match(previous, /create constraint trigger payment_allocations_total_check[\s\S]*?deferrable initially deferred/);
const sync = body(clean, 'sync_single_bill_payment_allocation');
assert.match(sync, /security definer\s+set search_path = pg_catalog, public/);
assert.match(sync, /if new.bill_id is null then return new; end if;/);
assert.match(sync, /delete from public.payment_allocations\s+where payment_id = new.id and bill_id <> new.bill_id/);
assert.match(sync, /values \(new.id, new.bill_id, new.amount\)\s+on conflict \(payment_id, bill_id\) do update set amount = excluded.amount/);
assert.doesNotMatch(sync, /payment_status|update public.payments|update public.bills|update public.admissions/);
assert.match(clean, /after insert or update of bill_id, amount on public.payments/);
assert.match(clean, /select id, bill_id, amount from public.payments where bill_id is not null\s+on conflict \(payment_id, bill_id\) do update set amount = excluded.amount/);
assert.ok(clean.indexOf('create or replace function public.validate_payment_allocation_total') < clean.indexOf('select id, bill_id, amount from public.payments'));
assert.match(clean, /Reconcile conflicting single-bill allocations/);
assert.doesNotMatch(clean, /create or replace function public.(create_combined_payment_submission|verify_payment_with_allocations|reject_payment_with_allocations)/);
const guard = body(clean, 'prevent_resident_contract_privilege_changes');
assert.match(guard, /coalesce\(auth.role\(\), ''\) = 'service_role' or public.is_staff_user\(\)/);
assert.match(guard, /old.resident_id is distinct from public.current_resident_id\(\)/);
assert.match(guard, /old.resident_signature_status not in \('Pending', 'Re-sign Required'\)/);
assert.match(guard, /new.resident_signature_status is distinct from 'Submitted'/);
assert.match(guard, /new.signed_by_resident is distinct from true/);
assert.match(guard, /new.signed_at is null/);
assert.match(guard, /nullif\(btrim\(new.resident_signature_url\), ''\) is null/);
assert.match(guard, /a.status = 'Pending'/);
const lists = [...guard.matchAll(/array\[([^\]]+)\]::text\[\]/g)].map(m => [...m[1].matchAll(/'([^']+)'/g)].map(x=>x[1]));
const editable = ['resident_signature_url','resident_signature_status','signed_by_resident','signed_at','updated_at'];
assert.deepEqual(lists, [editable, editable]);
assert.match(guard, /to_jsonb\(new\)[\s\S]*is distinct from[\s\S]*to_jsonb\(old\)/);
const cancellation = body(clean, 'cancel_payment_with_allocations');
assert.match(cancellation, /if exists \(select 1 from public.bills where id = allocation_row.bill_id and bill_type = 'Security Deposit'\) then\s+select admission_id into deposit_admission_id[\s\S]*?end if;/);
// Verify the cancellation body is otherwise identical to the previously reviewed RPC.
const oldCancellation = body(previous, 'cancel_payment_with_allocations').replace(/--[^\n]*/g, '');
const restored = cancellation.replace(/if exists \(select 1 from public.bills where id = allocation_row.bill_id and bill_type = 'Security Deposit'\) then\s+select admission_id into deposit_admission_id from public.bills\s+where id = allocation_row.bill_id and bill_type = 'Security Deposit';\s+end if;/, "select admission_id into deposit_admission_id from public.bills where id = allocation_row.bill_id and bill_type = 'Security Deposit';");
assert.equal(restored.replace(/\s+/g,' ').trim(), oldCancellation.replace(/\s+/g,' ').trim());
for (const fn of ['validate_payment_allocation_total', 'sync_single_bill_payment_allocation', 'prevent_resident_contract_privilege_changes']) assert.ok(clean.includes(`revoke all on function public.${fn}() from public, anon, authenticated;`));
assert.match(clean, /grant execute on function public.cancel_payment_with_allocations\(uuid, text, text\) to service_role/);
assert.ok(fs.readdirSync(dir).filter(f=>f.endsWith('.sql')).sort().includes(name));
console.log('PASS SQL structural regressions: correct row shapes, both parents, deferred exact totals, single-bill synchronization, resident-only submission, deposit retention and privileges.');

// Independent scenario models clarify the required semantics; these are not PostgreSQL execution.
function parents(table, op, oldRow, newRow) {
  const key = table === 'payments' ? 'id' : 'payment_id';
  return [...new Set([...(op !== 'INSERT' ? [oldRow[key]] : []), ...(op !== 'DELETE' ? [newRow[key]] : [])])];
}
const unavailable = new Proxy({}, { get() { throw Error('Unavailable trigger record was accessed'); } });
for(const [table,key] of [['payments','id'],['payment_allocations','payment_id']]) {
  assert.deepEqual(parents(table,'INSERT',unavailable,{[key]:'new'}),['new']);
  assert.deepEqual(parents(table,'DELETE',{[key]:'old'},unavailable),['old']);
  assert.deepEqual(parents(table,'UPDATE',{[key]:'old'},{[key]:'new'}),['old','new']);
}
function exact(p, allocations) {
  if(!p) return true; // deleted parent
  const own=allocations.filter(a=>a.payment_id===p.id), total=own.reduce((n,a)=>n+a.amount,0);
  return !(p.bill_id && (own.length!==1 || total!==p.amount || own.some(a=>a.bill_id!==p.bill_id))) && !(p.bill_id===null && p.status==='Verified' && total!==p.amount) && !(total>0 && total!==p.amount);
}
const single={id:'one',bill_id:'rent',amount:100,status:'Pending'};
assert.equal(exact(single,[]),false);
assert.equal(exact(null,[]),true);
for(const amount of [99,101]) assert.equal(exact(single,[{payment_id:'one',bill_id:'rent',amount}]),false);
for(const status of ['Pending','Verified','Rejected','Cancelled']) assert.equal(exact({...single,status},[{payment_id:'one',bill_id:'rent',amount:100}]),true);
const combined={id:'two',bill_id:null,amount:200,status:'Verified'};
assert.equal(exact(combined,[{payment_id:'two',bill_id:'rent',amount:100},{payment_id:'two',bill_id:'deposit',amount:100}]),true);
assert.equal(exact(combined,[]),false);
assert.equal(exact({...combined,status:'Pending'},[]),true);
// Moving the final allocation off a live single-bill payment invalidates the source.
assert.equal(exact(single,[{payment_id:'two',bill_id:'rent',amount:100}]),false);
function project(p, rows) {
  if(p.bill_id===null) return rows;
  return [...rows.filter(a=>a.payment_id!==p.id),{payment_id:p.id,bill_id:p.bill_id,amount:p.amount}];
}
const once=project(single,[]);assert.deepEqual(project(single,once),once);
assert.equal(project({...single,bill_id:'deposit',amount:50},once).length,1);
assert.equal(project({...single,bill_id:'deposit',amount:50},once)[0].amount,50);
assert.deepEqual(project(combined,once),once);
for(const order of [['deposit','rent'],['rent','deposit'],['rent']]) {
  let admission=null,count=0;for(const kind of order)if(kind==='deposit')admission='current';
  if(admission)count++;assert.equal(count,order.includes('deposit')?1:0);
}
function residentChange(oldRow,newRow) {
  if(!['Pending','Re-sign Required'].includes(oldRow.resident_signature_status)||newRow.resident_signature_status!=='Submitted'||!newRow.signed_by_resident||!newRow.signed_at||!newRow.resident_signature_url?.trim())return false;
  const fixed=r=>Object.fromEntries(Object.entries(r).filter(([k])=>!editable.includes(k)));
  return JSON.stringify(fixed(oldRow))===JSON.stringify(fixed(newRow));
}
const old={status:'Pending Signature',resident_signature_status:'Pending',owner_signature_status:'Pending',contract_content:'Agreed'};
const submitted={...old,resident_signature_status:'Submitted',resident_signature_url:'signature',signed_by_resident:true,signed_at:'2026-09-22'};
assert.equal(residentChange(old,submitted),true);
assert.equal(residentChange({...old,resident_signature_status:'Re-sign Required'},submitted),true);
for(const state of ['Approved','Signed','Rejected','Pending'])assert.equal(residentChange(old,{...submitted,resident_signature_status:state}),false);
for(const status of ['Active','Cancelled','Terminated'])assert.equal(residentChange(old,{...submitted,status}),false);
for(const [key,value] of [['owner_signature_status','Approved'],['contract_content','Changed'],['resident_id','other'],['monthly_rent',0]])assert.equal(residentChange(old,{...submitted,[key]:value}),false);
assert.equal(residentChange(submitted,submitted),false);
console.log('PASS edge-case models: insert/update/delete, moved allocations, exact amounts, statuses, idempotent single allocation, combined bypass, both cancellation orders, and prohibited resident approval.');
