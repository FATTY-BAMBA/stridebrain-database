# StrideBrain Data — Release Gates

These conditions must be satisfied before any real private SME workspace can be opened. The four synthetic CSV/XLSX demo checks are accepted, but they are not security tests.

## Gate A — staging platform
- [ ] Create an isolated Supabase project with no real client data.
- [ ] Pin PostgreSQL/Supabase versions, extensions and migration runner.
- [ ] Verify primestride-saas-core base tables, current RLS and migration compatibility.
- [ ] Apply 001, 002 and 003 in staging, with rollback/backup plan.
- [ ] Run static SQL checks then the rollback-only tests/001_manual_staging_rls_isolation.sql as a database owner.
- [ ] Test concurrent quotation approval and cost-line mutations to confirm row locks and immutable state.
- [ ] Audit SECURITY DEFINER function owners, search_path, function grants and RLS behavior.

## Gate B — verified account access
- [ ] Choose Clerk/server session verification and properly validated JWT mapping to Supabase.
- [ ] Confirm JWT issuer/audience/sub/expiry and org membership using trusted server, never an arbitrary URL/cookie/profile setting.
- [ ] Member, owner/admin and finance permissions match configured product needs.
- [ ] Test two active orgs, cross-tenant ID swaps, revoked access, outsider and anon.
- [ ] Harden saas-core organization/team views and service-role usage.
- [ ] Test invite token hashing, expiration, one-time use and wrong-identity acceptance.
- [ ] Prove all API, batch, export and AI tools enforce tenant scope.

## Gate C — secure document intake
- [ ] MIME sniffing, file-size caps, zip-bomb/symlink/embedded active-content defenses.
- [ ] Malware scanning/quarantine before parsing or signed download.
- [ ] Private bucket policies, short-lived scoped signed links and encrypted storage.
- [ ] Revoked membership blocks old download links or minimizes exposure through very short expiration.
- [ ] OCR/table parsing with source-cell/page provenance and version metadata.
- [ ] Human review of extraction, cost-code mappings, actual-vs-quoted classification and completeness.
- [ ] Deterministic duplicate handling, error recovery, deletion/retention and legal/privacy review.

## Gate D — quotation/business workflow
- [ ] Compare *reconciled actual costs*, not old selling prices, as historical cost evidence.
- [ ] Verify current supplier pricebooks, effective dates, quantity units, labor, waste, overhead and tax assumptions.
- [ ] Require reviewable quote version, responsible approver and approval audit before issuance.
- [ ] Validate document/source revision consistency, immutable approved quotes and no silent overwrite.
- [ ] Produce customer PDF only after authenticated approval; channel sending separately authorized.
- [ ] Measure estimate-to-actual differences and run pilot evaluations with Taiwanese interior-design and printing SMEs.

## Gate E — trustworthy production UI
- [ ] Traditional Chinese first-class UI and English translation.
- [ ] Keyboard/screen-reader/mobile browser review across five applications.
- [ ] Operational logging without leaking customer documents or cost/PII content.
- [ ] Backup restoration, tenant export, deletion and offboarding rehearsals.
- [ ] Legal/privacy and contractual responsibility review.
- [ ] Written release approval, owner, rollback contact and incident response plan.

## Current actual evidence

- Public synthetic demo QA: 4 passed / 0 failed in browser for interior & printing CSV/XLSX.
- Draft schema created in GitHub only; **ZERO staging database execution and ZERO authenticated tenant isolation tests completed**.
- No connection to a live Supabase database, no customer sign-ins created and no real documents uploaded.

Do not check any of the staging/production boxes solely because a SQL script or automated static check exists.
