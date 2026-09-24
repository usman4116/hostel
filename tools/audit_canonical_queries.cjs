// Static source audit only. Does not import or initialize the application.
const fs = require("node:fs");
const path = require("node:path");
const ts = require("typescript");
const root = path.resolve(__dirname, "..");
const schema = new Map();
const migrations = fs.readdirSync(path.join(root, "supabase/migrations")).filter(f => f.endsWith(".sql")).sort();
for (const file of migrations) {
  const sql = fs.readFileSync(path.join(root, "supabase/migrations", file), "utf8");
  for (const match of sql.matchAll(/create table (?:if not exists )?public\.(\w+)\s*\(\r?\n([\s\S]*?)\r?\n\);/gi)) {
    schema.set(match[1], new Set([...match[2].matchAll(/^\s{2}(\w+)\s+(?:uuid|bigint|integer|text|date|numeric|boolean|timestamptz|jsonb)\b/gm)].map(m => m[1])));
  }
  for (const match of sql.matchAll(/alter table public\.(\w+)\s+([\s\S]*?);/gi)) {
    for (const col of match[2].matchAll(/add column (?:if not exists )?(\w+)\s/g)) schema.get(match[1])?.add(col[1]);
    for (const col of match[2].matchAll(/drop column (?:if exists )?(\w+)\b/g)) schema.get(match[1])?.delete(col[1]);
  }
}
const queries = [], findings = [], unresolved = [], syntax = [];
const methods = new Set(["select", "insert", "update", "upsert", "eq", "in", "order", "is", "neq", "like", "ilike", "gte", "lte", "gt", "lt", "or"]);
function tableOf(node) {
  if (!ts.isCallExpression(node) || !ts.isPropertyAccessExpression(node.expression)) return null;
  if (node.expression.name.text === "from") return node.arguments[0] && ts.isStringLiteralLike(node.arguments[0]) ? node.arguments[0].text : null;
  return tableOf(node.expression.expression);
}
function splitSelect(value) {
  const out = []; let depth = 0, start = 0;
  for (let i = 0; i < value.length; i++) {
    if (value[i] === "(") depth++;
    if (value[i] === ")") depth--;
    if (value[i] === "," && depth === 0) { out.push(value.slice(start, i).trim()); start = i + 1; }
  }
  out.push(value.slice(start).trim()); return out.filter(Boolean);
}
function selectColumns(table, value, context) {
  for (const field of splitSelect(value)) {
    const nested = field.match(/^(?:\w+:)?(\w+)(?:![\w]+)?\((.*)\)$/s);
    if (nested) {
      if (schema.has(nested[1])) selectColumns(nested[1], nested[2], context);
      else unresolved.push({ ...context, reason: "relationship", field });
    } else if (field !== "*" && /^\w+$/.test(field) && !schema.get(table)?.has(field)) findings.push({ ...context, table, field });
  }
}
for (const folder of ["app", "lib", "components"]) {
  for (const file of fs.readdirSync(path.join(root, folder), { recursive: true }).filter(f => /\.tsx?$/.test(f))) {
    const relative = `${folder}/${file}`.replaceAll("\\", "/");
    const source = ts.createSourceFile(relative, fs.readFileSync(path.join(root, relative), "utf8"), ts.ScriptTarget.Latest, true);
    for (const diagnostic of source.parseDiagnostics) syntax.push({ file: relative, message: ts.flattenDiagnosticMessageText(diagnostic.messageText, " ") });
    function visit(node) {
      if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)) {
        const table = tableOf(node), method = node.expression.name.text, argument = node.arguments[0];
        if (schema.has(table) && methods.has(method)) {
          const context = { file: relative, line: source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1, table, method };
          queries.push(context);
          if (argument && ts.isStringLiteralLike(argument) && method === "select") selectColumns(table, argument.text, context);
          else if (argument && ts.isStringLiteralLike(argument) && !["insert", "update", "upsert", "or"].includes(method)) {
            if (!schema.get(table).has(argument.text)) findings.push({ ...context, field: argument.text });
          } else if (["insert", "update", "upsert"].includes(method) && argument && ts.isObjectLiteralExpression(argument)) {
            for (const property of argument.properties.filter(p => ts.isPropertyAssignment(p) || ts.isShorthandPropertyAssignment(p))) {
              const field = property.name.getText(source).replace(/^["']|["']$/g, "");
              if (!schema.get(table).has(field)) findings.push({ ...context, field });
            }
          } else if (!["select"].includes(method)) unresolved.push({ ...context, reason: "variable payload/filter; manual review required" });
        }
      }
      ts.forEachChild(node, visit);
    }
    visit(source);
  }
}
const report = { note: "Static checks only; wildcard results, variable payloads, computed columns, RLS, transactions and PostgreSQL execution require separate review.", migrationOrder: migrations, tables: Object.fromEntries([...schema].map(([table, columns]) => [table, [...columns]])), queryCount: queries.length, syntax, findings, manualReview: unresolved, queries };
if (!process.argv.includes('--check')) {
  fs.mkdirSync(path.join(root, "docs/phase3"), { recursive: true });
  fs.writeFileSync(path.join(root, "docs/phase3/query-audit.json"), JSON.stringify(report, null, 2) + "\n");
}
console.log(JSON.stringify({ migrations: migrations.length, tables: schema.size, queries: queries.length, syntaxErrors: syntax.length, findings, manualReview: unresolved.length }, null, 2));
process.exitCode = findings.length || syntax.length ? 1 : 0;
