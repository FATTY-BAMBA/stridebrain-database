# SaaS Core Security Review — StrideBrain Customer Accounts

Scope: static inspection of FATTY-BAMBA/primestride-saas-core as accessed on 2026-10-18. No staging database, IdP secrets, real accounts or production API was inspected. **This is a design review, not a penetration test.**

## Reuse opportunities

The existing package offers Clerk UI providers, an organization switcher, team/member/invitation hooks, TypeScript domain types and a Supabase base migration. Prefer adapting this work for the future customer app over rebuilding the UI from zero.

## Blocking gaps before private company data

1. **RLS enabled but policies absent.** The existing migrations/001_base_schema.sql enables RLS on organizations, organization_members, profiles, teams, team_members and invitations but explicitly defers policy creation. Without proper authenticated policies, operations either fail for normal callers or are pushed through an elevated role. Neither demonstrates secure per-tenant access.
2. **Admin DB client bypass.** src/lib/supabase.ts exports getSupabaseAdmin using SUPABASE_SERVICE_ROLE_KEY. Its correct use must be limited to server-only code with verified identity, membership and per-action authorization. Any generic client-facing admin helper or unscoped query could leak across organizations.
3. **Client org context is not an authorization proof.** AuthProvider obtains /api/profile and OrgSwitcher changes the selected ID in UI. A browser-visible organizationId/profile.activeOrganizationId cannot give access to that organization; the trusted server must check active organization_members entries for the current signed-in identity on EVERY API call.
4. **Clerk JWT ↔ Supabase integration not established by base package.** Its getSupabaseClient uses the public anon key. The future customer app must configure a validated third-party-auth JWT flow (or use server-authorized commands) and test token issuer, audience, subject, expiry and role mapping before PostgreSQL policies depending on auth.jwt()->>'sub' can be trusted.
5. **Potential view bypass.** Existing organization_members_view and team_members_view do not explicitly opt into PostgreSQL security_invoker semantics. Depending on ownership and granted privileges, views can expose rows despite expected RLS behavior. Review and harden their definitions/GRANTs before permitting user-facing reads.
6. **Invitation tokens are stored in token VARCHAR(255).** Plan to store one-way hashes of high-entropy tokens, with expiry, single-use consumption, rate limiting and server-side invitation acceptance. Avoid exposing plaintext invites via direct table SELECT.
7. **Roles are too broad for commercial data.** owner/admin/member can bootstrap a workspace, but estimator, designer, production, accounting, and external contractors need scoped permission and approval thresholds. Never grant sensitive margins or supplier terms to every member by default.
8. **No cross-tenant test evidence yet.** The provided package README does not establish tests for cross-org document retrieval, storage signed links, API authorization, or AI tool calls. Pass the staging isolation suite and actual API red-team tests before first customer.

## Recommended trusted request path

- Authenticated Clerk session → server verifies JWT/session → fetches active org membership and permissions from database → checks requested org ID against that membership → executes restricted tenant-scoped operation.
- Use row-level security with validated JWT claims as an independent layer, NEVER as a replacement for server authorization.
- Elevated service-role DB clients must be fenced behind server-only modules and only called by code that derives verified actor/org scope. Never trust org_id or role exclusively from body, query string or LLM.
- Signed storage object URLs must require the same check as document metadata.
- The AI retrieval layer must apply org and document ACL predicates BEFORE search/ranking, including to sources, citations and follow-up tool calls.
- Audit actor, org, action, target, reviewer and source version on changes to pricing, approvals, document acceptance and messaging.

## Dependency-specific staging checks

- A signed-in owner can list only organizations in which they have active membership.
- Two identities in different organizations cannot read or edit each other's records through REST/RPC, ORM, direct database (where exposed), search, previews, exports, or signed links.
- A revoked member loses access without waiting for a refreshed client-side profile.
- Owner/admin cannot bypass an approved quote/version lifecycle; member cannot read financial margins unless explicitly permitted.
- Invitations cannot be replayed or accepted by unintended accounts.
- No provider secret, service role key or private bucket credential appears in browser code or deployed assets.

## Recommendation

Keep the existing saas-core UI and type components where useful, but subject its base schema, views, server helper usage and invitation mechanism to an explicit hardening PR before integrating real tenant data.

The separate stridebrain schema in this repository uses composite organization-scoped foreign keys, read-only RLS, guarded financial transitions and private-storage metadata. The code is still **DRAFT**. No migration has been run and it cannot be called production secure until trusted JWT configuration, API authorization and staging execution are verified.
