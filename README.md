# StrideBrain Data Platform — tenant-foundation draft

This repository is the **separate, future customer-data architecture** for PrimeStride AI's StrideBrain. It is not the public demo, the marketing website, or a working production service.

**STATUS: DRAFT MIGRATIONS ONLY. They have NOT been applied to any database, and no real organizations, staff accounts, documents or vendor records have been created.**

## Why this is separate

The switchable [StrideBrain synthetic industry demo](https://github.com/FATTY-BAMBA/primestride-web/pull/9) should remain accessible to prospects. A real business workspace must enforce authenticated membership and permissions on every work record, file, search result, quotation, and tool action.

The existing [PrimeStride SaaS Core](https://github.com/FATTY-BAMBA/primestride-saas-core) provides Clerk-based UI hooks, organizations, teams, invitations, and a base Supabase schema. Its base SQL **enables RLS without defining the required tenant policies** and exposes a service-role client. It is a reusable UI/schema foundation, not yet sufficient proof of secure company data isolation. See `docs/SAAS_CORE_SECURITY_REVIEW.md`.

## What's on this draft branch

- `migrations/001_striderbrain_entities.sql` — 12 tenant-owned tables for industry settings, work objects, documents/revisions, private file keys, actual costs, quotations, approvals, tasks, and audit.
- `migrations/002_read_only_tenant_policies.sql` — fail-closed policies for validated org membership, read-only access, and finance-only access; no authenticated direct writes.
- `migrations/003_financial_integrity_guards.sql` — ledger reconciliations, verified-cost immutability, controlled quote state, and append-only audit triggers.
- `tests/001_manual_staging_rls_isolation.sql` — rollback-only **manual** test plan for two companies, active/revoked members, finance secrecy, and cross-org foreign keys.
- `tools/check_contract.mjs` — syntax-adjacent/static coverage checks; not a Postgres migration execution.
- `docs/SAAS_CORE_SECURITY_REVIEW.md` — known integration and trust-boundary concerns.
- `docs/RELEASE_GATES.md` — tests and sign-offs required before accepting private company uploads.

## Quick orientation

The foundational schema references `public.organizations` and `public.organization_members` from the existing SaaS core. Every tenant-owned business table has an `organization_id`; operational relationships use composite `(organization_id, id)` keys to prevent cross-company linking even if a backend query is incorrect.

### Server-only production workflow (planned)

1. Verify user identity with a configured trusted Clerk/Supabase integration.
2. Resolve active membership for the requested organization from trusted server context.
3. Apply role, project assignment, financial sensitivity, and action-level authorization.
4. Process company-uploaded files in a private scanning/quarantine pipeline.
5. Store versioned source document metadata, parsed facts and reviewer decisions.
6. Allow only actual, cost-reconciled, reviewed historical records into quotation algorithms.
7. Require approved quotation version and audit before any external message or sale.
8. Enforce tenant scope at database, storage, search, and AI tool boundaries.

### DO NOT

- Run the migrations against production before integration tests and review.
- Expose Supabase service-role secrets to browsers or model-tool clients.
- Treat an org-switcher UI choice, email domain, URL ID, or profile preference as authorization.
- Import the demo's fictional history as actual customer cost data.
- Expose storage bucket keys or signed download links without server-side access checks.
- Treat a passed four-fixture CSV/XLSX demo test as a security or pricing certification.

## Deployment

No connection, deployment, database migration, user onboarding or customer upload occurs merely by committing these files. A staging database and a compatible authenticated customer application must be explicitly provisioned and tested before any migration is applied.

## Current accepted demo QA result

The user executed the public bridge QA page on 2026-10-18: **4 passed / 0 failed** for synthetic interior and printing CSV/XLSX samples. That closes only the format-bridge smoke gate; real tenant isolation remains untested.

## Next stage

Open a review of the migrations, run isolated PostgreSQL staging tests, validate a Clerk-issued JWT against the Supabase gateway, audit base SaaS core RLS/views and invitation flow, and build a dedicated Next.js customer application using only server-authorized APIs.
