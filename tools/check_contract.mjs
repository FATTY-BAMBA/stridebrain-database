/**
 * Static SQL contract checks for StrideBrain staging migrations.
 * NOT a PostgreSQL syntax checker, RLS execution test or security audit.
 *
 * Run: node tools/check_contract.mjs
 */
import {readFileSync} from "node:fs";
import {resolve,dirname} from "node:path";
import {fileURLToPath} from "node:url";

const root=resolve(dirname(fileURLToPath(import.meta.url)),"..");
const read=name=>readFileSync(resolve(root,"migrations",name),"utf8");
const schema=read("001_striderbrain_entities.sql");
const policies=read("002_read_only_tenant_policies.sql");
const guards=read("003_financial_integrity_guards.sql");

const failures=[];
const check=(condition,description)=>{if(!condition)failures.push(description);};
const tableNames=[...schema.matchAll(/CREATE TABLE\s+stridebrain\.(\w+)/g)].map(x=>x[1]);
const unique=new Set(tableNames);
check(tableNames.length===12,"Expected 12 tenant-owned tables");
check(unique.size===tableNames.length,"Duplicate table name");

for(const name of tableNames){
 check(new RegExp("ALTER TABLE\\s+stridebrain\\."+name+"\\s+ENABLE ROW LEVEL SECURITY","i").test(policies),
   name+" missing ENABLE RLS");
 check(new RegExp("ALTER TABLE\\s+stridebrain\\."+name+"\\s+FORCE ROW LEVEL SECURITY","i").test(policies),
   name+" missing FORCE RLS");
}
const expectedReads=[
 "tenant_settings","work_objects","source_documents","document_revisions",
 "historical_cost_cases","historical_cost_lines","quotation_drafts","quotation_lines",
 "approval_requests","work_tasks","audit_events"
];
for(const name of expectedReads){
 check(new RegExp("CREATE POLICY\\s+\\w+\\s+ON\\s+stridebrain\\."+name+"\\s+FOR SELECT TO authenticated","i").test(policies),
   name+" missing authenticated SELECT policy");
 check(new RegExp("GRANT SELECT ON stridebrain\\."+name+" TO authenticated","i").test(policies),
   name+" missing explicit authenticated SELECT grant");
}
check(!/CREATE POLICY\s+\w+\s+ON\s+stridebrain\.private_file_blobs/i.test(policies),
 "Private file blob table must not have a user-facing policy");
check(!/GRANT SELECT ON stridebrain\.private_file_blobs TO authenticated/i.test(policies),
 "Private file blob table must not be readable");
check(!/GRANT\s+(?:INSERT|UPDATE|DELETE|ALL)\b[^;]*\bTO\s+(?:authenticated|anon)\b/i.test(policies),
 "Public role has unexpected write grant");
check(/auth\.jwt\(\)->>'sub'/.test(policies),"Clerk subject must come from validated JWT");
check(/m\.is_active IS TRUE/.test(policies),"Revoked members must be denied");
check(/m\.role IN \('owner','admin'\)/.test(policies),"Financial permission must check role");
check(/classification <> 'TENANT_RESTRICTED'/.test(policies),"Restricted document handling missing");
check(/revisions_read_via_parent/.test(policies),"Revision must inherit source-document permissions");
check((schema.match(/PRIMARY KEY \(organization_id,id\)/g)||[]).length>=10,
 "Composite tenant-scoped primary keys missing");
check((schema.match(/FOREIGN KEY \(organization_id,/g)||[]).length>=8,
 "Tenant-scoped composite foreign key coverage low");
for(const trigger of [
 "sb_cost_case_guard","sb_verified_cost_lines_guard",
 "sb_approved_revision_guard","sb_quotation_approval_guard",
 "sb_approved_quotation_lines_guard","sb_decided_approval_guard","sb_audit_append_only"
])check(guards.includes("CREATE TRIGGER "+trigger),"Missing integrity trigger "+trigger);
check((guards.match(/FOR UPDATE;/g)||[]).length>=2,"Concurrent cost and quote mutation locks missing");
check(guards.includes("to_jsonb(OLD) - 'state'"),"Approved quote freeze rule missing");
check(guards.includes("blob_scan_state IS DISTINCT FROM 'passed'"),"Approved actual costs must use malware-cleared source evidence");
for(const [name,text] of [["entities",schema],["policies",policies],["guards",guards]]){
 check(/^\s*BEGIN;/m.test(text),"Missing BEGIN in "+name);
 check(/\bCOMMIT;\s*$/.test(text),"Missing COMMIT in "+name);
}

const summary={tables:tableNames.length,readPolicies:expectedReads.length,integrityTriggers:7,problems:failures.length};
if(failures.length){
 console.error("StrideBrain schema STATIC CONTRACT: FAIL",summary);
 for(const problem of failures)console.error(" - "+problem);
 process.exitCode=1;
}else{
 console.log("StrideBrain schema STATIC CONTRACT: PASS",summary);
 console.log("Still required: Postgres execution, actual JWT integration, RLS tests, concurrency tests, independent security review.");
}
