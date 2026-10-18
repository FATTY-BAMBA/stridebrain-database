-- StrideBrain customer data schema — DESIGN STAGING ONLY
-- PostgreSQL 15 / Supabase. NOT YET APPLIED TO A LIVE DATABASE.
-- Prerequisite: primestride-saas-core 001_base_schema.sql must exist
-- with public.organizations and public.organization_members.
-- This migration creates tenant-owned tables. Access policies follow in 002.

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.organizations') IS NULL OR
     to_regclass('public.organization_members') IS NULL THEN
    RAISE EXCEPTION 'Run and review primestride-saas-core base schema before StrideBrain migrations';
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS stridebrain;
COMMENT ON SCHEMA stridebrain IS 'Private organization-owned StrideBrain operational data; public demo fixtures prohibited';
REVOKE ALL ON SCHEMA stridebrain FROM PUBLIC;

-- Each organization has exactly one industry configuration.
CREATE TABLE stridebrain.tenant_settings (
  organization_id uuid PRIMARY KEY REFERENCES public.organizations(id) ON DELETE CASCADE,
  industry_pack_id text NOT NULL CHECK (industry_pack_id IN ('interior','printing','manufacturing','trading','professional_services')),
  locale text NOT NULL DEFAULT 'zh-TW' CHECK (locale IN ('zh-TW','en')),
  default_currency char(3) NOT NULL DEFAULT 'TWD',
  settings jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(settings)='object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- One shared work identity, configured by the industry pack.
CREATE TABLE stridebrain.work_objects (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  code text NOT NULL CHECK (length(btrim(code)) BETWEEN 1 AND 80),
  object_kind text NOT NULL CHECK (object_kind IN ('renovation_project','print_job','production_order','sales_order','purchase_order','client_engagement')),
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 250),
  stage text NOT NULL DEFAULT 'intake',
  created_by text NOT NULL, -- verified IdP subject, set by trusted backend
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,id),
  UNIQUE (organization_id,code)
);

-- Safe metadata only. Private object-storage paths do not belong in this table.
CREATE TABLE stridebrain.source_documents (
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  work_object_id uuid,
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 300),
  classification text NOT NULL DEFAULT 'TENANT_PRIVATE'
     CHECK (classification IN ('TENANT_PRIVATE','TENANT_RESTRICTED','TENANT_APPROVED_KNOWLEDGE')),
  source_category text NOT NULL DEFAULT 'other',
  current_revision_no integer,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,id),
  FOREIGN KEY (organization_id,work_object_id)
    REFERENCES stridebrain.work_objects(organization_id,id) ON DELETE RESTRICT
);

CREATE TABLE stridebrain.document_revisions (
  organization_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  document_id uuid NOT NULL,
  revision_no integer NOT NULL CHECK (revision_no >= 1),
  lifecycle text NOT NULL DEFAULT 'draft'
     CHECK (lifecycle IN ('draft','parsing','needs_review','approved','superseded','rejected')),
  original_file_name text,
  declared_media_type text,
  checksum_sha256 text CHECK (checksum_sha256 IS NULL OR checksum_sha256 ~ '^[0-9a-fA-F]{64}$'),
  parser_version text,
  reviewed_by text,
  reviewed_at timestamptz,
  effective_at timestamptz,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,id),
  UNIQUE (organization_id,document_id,revision_no),
  FOREIGN KEY (organization_id,document_id)
    REFERENCES stridebrain.source_documents(organization_id,id) ON DELETE RESTRICT,
  CHECK (lifecycle <> 'approved' OR (reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);

-- Storage credentials and object keys must NEVER be exposed to the browser or AI.
-- Signed downloads require server-side membership and document-access checks.
CREATE TABLE stridebrain.private_file_blobs (
  organization_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  revision_id uuid NOT NULL,
  private_bucket text NOT NULL,
  private_object_key text NOT NULL,
  bytes bigint NOT NULL CHECK (bytes > 0 AND bytes <= 2147483648),
  content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[0-9a-fA-F]{64}$'),
  scan_state text NOT NULL DEFAULT 'pending' CHECK (scan_state IN ('pending','passed','quarantined','rejected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,id),
  UNIQUE (organization_id,revision_id),
  UNIQUE (private_bucket,private_object_key),
  FOREIGN KEY (organization_id,revision_id)
    REFERENCES stridebrain.document_revisions(organization_id,id) ON DELETE RESTRICT
);

-- Only VERIFIED ACTUAL costs may be used as evidence in live quoting.
-- Quoted prices, budgets and generated demos have different basis values.
CREATE TABLE stridebrain.historical_cost_cases (
  organization_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  work_object_id uuid NOT NULL,
  source_revision_id uuid,
  cost_basis text NOT NULL CHECK (cost_basis IN ('actual_reconciled','quoted','budget','simulation')),
  verification_status text NOT NULL DEFAULT 'draft'
     CHECK (verification_status IN ('draft','in_review','verified_actual','rejected')),
  completed_on date,
  normalized_quantity numeric(16,4) NOT NULL CHECK (normalized_quantity > 0),
  normalized_unit text NOT NULL CHECK (length(btrim(normalized_unit)) BETWEEN 1 AND 40),
  direct_cost_total numeric(18,2) NOT NULL DEFAULT 0 CHECK (direct_cost_total >= 0),
  currency char(3) NOT NULL DEFAULT 'TWD',
  reviewer_subject text,
  verified_at timestamptz,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,id),
  FOREIGN KEY (organization_id,work_object_id)
    REFERENCES stridebrain.work_objects(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,source_revision_id)
    REFERENCES stridebrain.document_revisions(organization_id,id) ON DELETE RESTRICT,
  CHECK (
    verification_status <> 'verified_actual' OR
    (cost_basis='actual_reconciled'
     AND source_revision_id IS NOT NULL
     AND completed_on IS NOT NULL
     AND reviewer_subject IS NOT NULL
     AND verified_at IS NOT NULL)
  )
);

CREATE TABLE stridebrain.historical_cost_lines (
  organization_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  cost_case_id uuid NOT NULL,
  cost_code text NOT NULL CHECK (length(btrim(cost_code)) BETWEEN 1 AND 80),
  description text NOT NULL,
  quantity numeric(16,4) NOT NULL CHECK (quantity > 0),
  unit text NOT NULL,
  actual_cost numeric(18,2) NOT NULL CHECK (actual_cost >= 0),
  source_cell_or_page text NOT NULL CHECK (length(btrim(source_cell_or_page)) > 0),
  PRIMARY KEY (organization_id,id),
  FOREIGN KEY (organization_id,cost_case_id)
    REFERENCES stridebrain.historical_cost_cases(organization_id,id) ON DELETE RESTRICT
);

-- Draft quotes must not be counted as cash/invoice/revenue.
-- The server will implement state changes and authorization; RLS below is read-only.
CREATE TABLE stridebrain.quotation_drafts (
  organization_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  work_object_id uuid NOT NULL,
  quote_number text NOT NULL,
  revision_no integer NOT NULL DEFAULT 1 CHECK (revision_no > 0),
  state text NOT NULL DEFAULT 'draft'
     CHECK (state IN ('draft','needs_review','approved','issued','void')),
  pricing_method text NOT NULL CHECK (pricing_method IN ('manual','historical_comparison','pricebook')),
  currency char(3) NOT NULL DEFAULT 'TWD',
  cost_estimate numeric(18,2) NOT NULL DEFAULT 0 CHECK (cost_estimate >= 0),
  proposed_price_before_tax numeric(18,2) NOT NULL DEFAULT 0 CHECK (proposed_price_before_tax >= 0),
  tax_estimate numeric(18,2) NOT NULL DEFAULT 0 CHECK (tax_estimate >= 0),
  created_by text NOT NULL,
  approved_by text,
  approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,id),
  UNIQUE (organization_id,quote_number,revision_no),
  FOREIGN KEY (organization_id,work_object_id)
    REFERENCES stridebrain.work_objects(organization_id,id) ON DELETE RESTRICT,
  CHECK (state NOT IN ('approved','issued') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);

CREATE TABLE stridebrain.quotation_lines (
  organization_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  quotation_id uuid NOT NULL,
  item_no integer NOT NULL CHECK (item_no >= 1),
  description text NOT NULL,
  quantity numeric(16,4) NOT NULL CHECK (quantity > 0),
  unit text NOT NULL,
  cost_code text,
  proposed_unit_price numeric(18,4) NOT NULL CHECK (proposed_unit_price >= 0),
  line_total numeric(18,2) NOT NULL CHECK (line_total >= 0),
  PRIMARY KEY (organization_id,id),
  UNIQUE (organization_id,quotation_id,item_no),
  FOREIGN KEY (organization_id,quotation_id)
    REFERENCES stridebrain.quotation_drafts(organization_id,id) ON DELETE RESTRICT
);


-- Every historically informed quotation retains which VERIFIED ACTUAL jobs it used.
-- This is not a claim that those jobs are directly comparable: the estimator
-- must also preserve cost-code differences, units, current prices and exclusions.
CREATE TABLE stridebrain.quotation_precedents (
  organization_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  quotation_id uuid NOT NULL,
  cost_case_id uuid NOT NULL,
  relevance_score numeric(5,4) CHECK (relevance_score IS NULL OR relevance_score BETWEEN 0 AND 1),
  comparison_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,id),
  UNIQUE (organization_id,quotation_id,cost_case_id),
  FOREIGN KEY (organization_id,quotation_id)
    REFERENCES stridebrain.quotation_drafts(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,cost_case_id)
    REFERENCES stridebrain.historical_cost_cases(organization_id,id) ON DELETE RESTRICT
);

CREATE TABLE stridebrain.approval_requests (
  organization_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  quotation_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending','approved','rejected','cancelled')),
  requested_by text NOT NULL,
  assigned_to text,
  decided_by text,
  decided_at timestamptz,
  decision_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,id),
  FOREIGN KEY (organization_id,quotation_id)
    REFERENCES stridebrain.quotation_drafts(organization_id,id) ON DELETE RESTRICT,
  CHECK (status NOT IN ('approved','rejected') OR (decided_by IS NOT NULL AND decided_at IS NOT NULL))
);

CREATE TABLE stridebrain.work_tasks (
  organization_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  work_object_id uuid NOT NULL,
  source_revision_id uuid,
  title text NOT NULL,
  status text NOT NULL DEFAULT 'upcoming'
    CHECK (status IN ('upcoming','blocked','in_progress','complete','cancelled')),
  assigned_subject text,
  due_on date,
  created_by text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,id),
  FOREIGN KEY (organization_id,work_object_id)
    REFERENCES stridebrain.work_objects(organization_id,id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,source_revision_id)
    REFERENCES stridebrain.document_revisions(organization_id,id) ON DELETE RESTRICT
);

-- Write-only through a trusted, authenticated, audited server command.
CREATE TABLE stridebrain.audit_events (
  organization_id uuid NOT NULL,
  id uuid NOT NULL DEFAULT gen_random_uuid(),
  actor_subject text NOT NULL,
  event_type text NOT NULL,
  entity_kind text NOT NULL,
  entity_id uuid NOT NULL,
  source_action_id text,
  data jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(data)='object'),
  recorded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id,id)
);

CREATE INDEX idx_sb_work_org_stage ON stridebrain.work_objects(organization_id,stage);
CREATE INDEX idx_sb_documents_org_work ON stridebrain.source_documents(organization_id,work_object_id);
CREATE INDEX idx_sb_revisions_document ON stridebrain.document_revisions(organization_id,document_id,revision_no DESC);
CREATE INDEX idx_sb_cases_org_work ON stridebrain.historical_cost_cases(organization_id,work_object_id,verification_status);
CREATE INDEX idx_sb_costlines_case ON stridebrain.historical_cost_lines(organization_id,cost_case_id);
CREATE INDEX idx_sb_quotes_org_work ON stridebrain.quotation_drafts(organization_id,work_object_id,state);
CREATE INDEX idx_sb_precedents_quote ON stridebrain.quotation_precedents(organization_id,quotation_id);
CREATE INDEX idx_sb_tasks_org_work ON stridebrain.work_tasks(organization_id,work_object_id,status);
CREATE INDEX idx_sb_audit_org_time ON stridebrain.audit_events(organization_id,recorded_at DESC);

COMMENT ON TABLE stridebrain.historical_cost_cases IS
  'Cost basis is always explicit; only verified_actual and actual_reconciled may be future live pricing evidence after server-side review';
COMMENT ON TABLE stridebrain.private_file_blobs IS
  'Private storage keys: no SELECT grant for anon/authenticated; direct storage access must be explicitly denied';
COMMENT ON TABLE stridebrain.quotation_drafts IS
  'Draft quotations are not contracts, invoices, collected cash or recognized revenue';

COMMIT;
