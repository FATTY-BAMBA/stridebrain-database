-- StrideBrain tenant-read isolation — DESIGN STAGING ONLY
-- Depends on: 001_striderbrain_entities.sql AND reviewed PrimeStride SaaS core schema.
-- Never deploy without verified Clerk -> Supabase authenticated JWT integration.
-- No application table in this migration allows browser-side INSERT/UPDATE/DELETE.

BEGIN;

-- Core identity is a Clerk subject authenticated by the server/Supabase JWT gateway.
-- auth.uid() cannot be used blindly: Clerk subjects are NOT UUIDs.
-- Functions run with migration-owner rights to avoid recursive RLS on org memberships.
-- They must be audited after each change to the SaaS core migration.
CREATE OR REPLACE FUNCTION stridebrain.is_org_member(p_organization_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
 SELECT
   auth.role() = 'authenticated'
   AND NULLIF(auth.jwt()->>'sub','') IS NOT NULL
   AND EXISTS (
     SELECT 1
     FROM public.organization_members AS m
     WHERE m.organization_id = p_organization_id
       AND m.user_id = auth.jwt()->>'sub'
       AND m.is_active IS TRUE
   );
$$;

CREATE OR REPLACE FUNCTION stridebrain.is_org_finance_reader(p_organization_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
 SELECT
   auth.role() = 'authenticated'
   AND NULLIF(auth.jwt()->>'sub','') IS NOT NULL
   AND EXISTS (
     SELECT 1
     FROM public.organization_members AS m
     WHERE m.organization_id = p_organization_id
       AND m.user_id = auth.jwt()->>'sub'
       AND m.is_active IS TRUE
       AND m.role IN ('owner','admin')
   );
$$;

REVOKE ALL ON FUNCTION stridebrain.is_org_member(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION stridebrain.is_org_finance_reader(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION stridebrain.is_org_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION stridebrain.is_org_finance_reader(uuid) TO authenticated;

REVOKE ALL ON ALL TABLES IN SCHEMA stridebrain FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA stridebrain FROM anon, authenticated;
GRANT USAGE ON SCHEMA stridebrain TO authenticated;

ALTER TABLE stridebrain.tenant_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.work_objects ENABLE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.source_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.document_revisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.private_file_blobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.historical_cost_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.historical_cost_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.quotation_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.quotation_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.approval_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.work_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.audit_events ENABLE ROW LEVEL SECURITY;

ALTER TABLE stridebrain.tenant_settings FORCE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.work_objects FORCE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.source_documents FORCE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.document_revisions FORCE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.private_file_blobs FORCE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.historical_cost_cases FORCE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.historical_cost_lines FORCE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.quotation_drafts FORCE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.quotation_lines FORCE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.approval_requests FORCE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.work_tasks FORCE ROW LEVEL SECURITY;
ALTER TABLE stridebrain.audit_events FORCE ROW LEVEL SECURITY;

-- Org members may read nonfinancial, nonrestricted company records.
CREATE POLICY tenant_settings_read_member ON stridebrain.tenant_settings
FOR SELECT TO authenticated
USING (stridebrain.is_org_member(organization_id));

CREATE POLICY work_objects_read_member ON stridebrain.work_objects
FOR SELECT TO authenticated
USING (stridebrain.is_org_member(organization_id));

CREATE POLICY source_documents_read_authorized ON stridebrain.source_documents
FOR SELECT TO authenticated
USING (
  stridebrain.is_org_member(organization_id)
  AND (
    classification <> 'TENANT_RESTRICTED'
    OR stridebrain.is_org_finance_reader(organization_id)
  )
);

-- A revision inherits its parent's document access decision.
-- Do not directly grant access to a revision based only on its organization.
CREATE POLICY revisions_read_via_parent ON stridebrain.document_revisions
FOR SELECT TO authenticated
USING (
  stridebrain.is_org_member(organization_id)
  AND (lifecycle = 'approved' OR stridebrain.is_org_finance_reader(organization_id))
  AND EXISTS (
    SELECT 1 FROM stridebrain.source_documents AS d
    WHERE d.organization_id = document_revisions.organization_id
      AND d.id = document_revisions.document_id
  )
);

CREATE POLICY tasks_read_member ON stridebrain.work_tasks
FOR SELECT TO authenticated
USING (stridebrain.is_org_member(organization_id));

-- Financial information remains limited to owner/admin until fine-grained
-- estimator roles and project-scoped permissions have been designed and tested.
CREATE POLICY cost_cases_read_finance ON stridebrain.historical_cost_cases
FOR SELECT TO authenticated
USING (stridebrain.is_org_finance_reader(organization_id));

CREATE POLICY cost_lines_read_finance ON stridebrain.historical_cost_lines
FOR SELECT TO authenticated
USING (stridebrain.is_org_finance_reader(organization_id));

CREATE POLICY quotations_read_finance ON stridebrain.quotation_drafts
FOR SELECT TO authenticated
USING (stridebrain.is_org_finance_reader(organization_id));

CREATE POLICY quotation_lines_read_finance ON stridebrain.quotation_lines
FOR SELECT TO authenticated
USING (stridebrain.is_org_finance_reader(organization_id));

CREATE POLICY approvals_read_finance ON stridebrain.approval_requests
FOR SELECT TO authenticated
USING (stridebrain.is_org_finance_reader(organization_id));

CREATE POLICY audit_read_finance ON stridebrain.audit_events
FOR SELECT TO authenticated
USING (stridebrain.is_org_finance_reader(organization_id));

-- ZERO RLS read policy AND ZERO authenticated SELECT GRANT on private_file_blobs.
-- Private bucket paths must only be read by a server after membership and
-- document-classification authorization and malware scan state are verified.

GRANT SELECT ON stridebrain.tenant_settings TO authenticated;
GRANT SELECT ON stridebrain.work_objects TO authenticated;
GRANT SELECT ON stridebrain.source_documents TO authenticated;
GRANT SELECT ON stridebrain.document_revisions TO authenticated;
GRANT SELECT ON stridebrain.historical_cost_cases TO authenticated;
GRANT SELECT ON stridebrain.historical_cost_lines TO authenticated;
GRANT SELECT ON stridebrain.quotation_drafts TO authenticated;
GRANT SELECT ON stridebrain.quotation_lines TO authenticated;
GRANT SELECT ON stridebrain.approval_requests TO authenticated;
GRANT SELECT ON stridebrain.work_tasks TO authenticated;
GRANT SELECT ON stridebrain.audit_events TO authenticated;

COMMENT ON FUNCTION stridebrain.is_org_member(uuid) IS
 'Membership reads validated Supabase/Clerk JWT sub; never use caller-supplied user IDs. SECURITY DEFINER must have restricted owner and audited search_path';
COMMENT ON FUNCTION stridebrain.is_org_finance_reader(uuid) IS
 'Owner/admin-only access helper; membership grants must originate from trusted server-side account management';

COMMIT;
