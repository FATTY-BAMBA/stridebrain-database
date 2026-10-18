-- StrideBrain data-integrity gates — DESIGN STAGING ONLY
-- Not a substitute for authenticated server commands, financial audit or evidence review.

BEGIN;

-- A "verified actual cost" requires an approved document revision and a complete
-- cost ledger. Once verified, the entire case and its lines are immutable in v0.
CREATE OR REPLACE FUNCTION stridebrain.guard_cost_case_verification()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  ledger_count bigint;
  ledger_total numeric(18,2);
  document_state text;
  blob_scan_state text;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.verification_status = 'verified_actual' THEN
    RAISE EXCEPTION 'Verified actual costs are immutable. Create a new reviewed version.'
      USING ERRCODE='23514';
  END IF;

  IF NEW.verification_status = 'verified_actual' THEN
    IF TG_OP = 'INSERT' THEN
      RAISE EXCEPTION 'Create the cost case and cost lines as a draft before verification.'
        USING ERRCODE='23514';
    END IF;

    IF NEW.completed_on IS NULL OR NEW.completed_on > CURRENT_DATE THEN
      RAISE EXCEPTION 'Actual-cost verification requires a completed, non-future job.'
        USING ERRCODE='23514';
    END IF;

    SELECT dr.lifecycle INTO document_state
      FROM stridebrain.document_revisions AS dr
     WHERE dr.organization_id=NEW.organization_id
       AND dr.id=NEW.source_revision_id;

    IF document_state IS DISTINCT FROM 'approved' THEN
      RAISE EXCEPTION 'Actual-cost verification requires a human-approved source revision.'
        USING ERRCODE='23514';
    END IF;

    SELECT f.scan_state INTO blob_scan_state
      FROM stridebrain.private_file_blobs f
     WHERE f.organization_id=NEW.organization_id
       AND f.revision_id=NEW.source_revision_id;

    IF blob_scan_state IS DISTINCT FROM 'passed' THEN
      RAISE EXCEPTION 'Actual-cost verification requires scanned, private source-file evidence.'
        USING ERRCODE='23514';
    END IF;

    SELECT count(*),coalesce(sum(actual_cost),0)
      INTO ledger_count,ledger_total
      FROM stridebrain.historical_cost_lines AS line
     WHERE line.organization_id=NEW.organization_id
       AND line.cost_case_id=NEW.id;

    IF ledger_count=0 OR abs(ledger_total-NEW.direct_cost_total) > 0.01 THEN
      RAISE EXCEPTION 'Ledger lines must exist and reconcile to direct_cost_total before verification.'
        USING ERRCODE='23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER sb_cost_case_guard
 BEFORE INSERT OR UPDATE ON stridebrain.historical_cost_cases
 FOR EACH ROW EXECUTE FUNCTION stridebrain.guard_cost_case_verification();

CREATE OR REPLACE FUNCTION stridebrain.guard_verified_cost_lines()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  scope_org uuid;
  scope_case uuid;
  verified boolean;
BEGIN
  IF TG_OP='DELETE' THEN
    scope_org := OLD.organization_id;
    scope_case := OLD.cost_case_id;
  ELSE
    scope_org := NEW.organization_id;
    scope_case := NEW.cost_case_id;
  END IF;

  SELECT (c.verification_status='verified_actual') INTO verified
    FROM stridebrain.historical_cost_cases AS c
   WHERE c.organization_id=scope_org
     AND c.id=scope_case
   FOR UPDATE;

  IF verified IS TRUE THEN
    RAISE EXCEPTION 'Cost lines of a verified case cannot be mutated.'
      USING ERRCODE='23514';
  END IF;

  -- Prevent changing a line's organization or cost case to bypass the old parent.
  IF TG_OP='UPDATE' AND (
    OLD.organization_id IS DISTINCT FROM NEW.organization_id OR
    OLD.cost_case_id IS DISTINCT FROM NEW.cost_case_id
  ) THEN
    RAISE EXCEPTION 'A cost line cannot be reparented; create a new version.'
      USING ERRCODE='23514';
  END IF;

  IF TG_OP='DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER sb_verified_cost_lines_guard
 BEFORE INSERT OR UPDATE OR DELETE ON stridebrain.historical_cost_lines
 FOR EACH ROW EXECUTE FUNCTION stridebrain.guard_verified_cost_lines();

-- Approved document revision bytes, metadata and approval references must never
-- be overwritten. New revisions are inserted as independent rows.
CREATE OR REPLACE FUNCTION stridebrain.guard_approved_revision()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  IF OLD.lifecycle = 'approved' THEN
    RAISE EXCEPTION 'Approved source revisions are immutable. Create a new revision.'
      USING ERRCODE='23514';
  END IF;
  IF TG_OP='DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER sb_approved_revision_guard
 BEFORE UPDATE OR DELETE ON stridebrain.document_revisions
 FOR EACH ROW EXECUTE FUNCTION stridebrain.guard_approved_revision();

-- A quotation marked approved or issued must reference an approved, decided
-- approval request for the same tenant and same quotation.
CREATE OR REPLACE FUNCTION stridebrain.guard_quotation_approval()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE has_approval boolean;
BEGIN
  IF TG_OP='UPDATE' AND OLD.state IN ('approved','issued') AND
      NOT (OLD.state='approved' AND NEW.state='issued'
           AND (to_jsonb(OLD) - 'state') = (to_jsonb(NEW) - 'state')) THEN
    RAISE EXCEPTION 'An approved quotation cannot be reopened or altered; issue only or create a new revision.'
      USING ERRCODE='23514';
  END IF;

  IF NEW.state IN ('approved','issued') THEN
    SELECT EXISTS (
      SELECT 1 FROM stridebrain.approval_requests a
       WHERE a.organization_id=NEW.organization_id
         AND a.quotation_id=NEW.id
         AND a.status='approved'
         AND a.decided_by=NEW.approved_by
         AND a.decided_at <= NEW.approved_at
    ) INTO has_approval;

    IF has_approval IS NOT TRUE THEN
      RAISE EXCEPTION 'An approved/issued quotation requires a matching decided approval request.'
        USING ERRCODE='23514';
    END IF;

    IF NEW.pricing_method='historical_comparison' AND NOT EXISTS (
      SELECT 1 FROM stridebrain.quotation_precedents evidence
       WHERE evidence.organization_id=NEW.organization_id
         AND evidence.quotation_id=NEW.id
    ) THEN
      RAISE EXCEPTION 'Historical quotations require at least one verified, linked cost precedent.'
        USING ERRCODE='23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER sb_quotation_approval_guard
 BEFORE INSERT OR UPDATE ON stridebrain.quotation_drafts
 FOR EACH ROW EXECUTE FUNCTION stridebrain.guard_quotation_approval();

CREATE OR REPLACE FUNCTION stridebrain.guard_issued_quotation_lines()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  org_id uuid;
  quotation_id uuid;
  state_now text;
BEGIN
  IF TG_OP='DELETE' THEN
    org_id:=OLD.organization_id;quotation_id:=OLD.quotation_id;
  ELSE
    org_id:=NEW.organization_id;quotation_id:=NEW.quotation_id;
  END IF;

  SELECT q.state INTO state_now FROM stridebrain.quotation_drafts q
   WHERE q.organization_id=org_id AND q.id=quotation_id
   FOR UPDATE;

  IF state_now IN ('approved','issued') THEN
    RAISE EXCEPTION 'Approved quotation lines cannot be modified. Revise the quote instead.'
      USING ERRCODE='23514';
  END IF;

  IF TG_OP='UPDATE' AND (OLD.organization_id IS DISTINCT FROM NEW.organization_id OR
                         OLD.quotation_id IS DISTINCT FROM NEW.quotation_id) THEN
    RAISE EXCEPTION 'Quotation lines cannot be reparented.'
      USING ERRCODE='23514';
  END IF;

  IF TG_OP='DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER sb_approved_quotation_lines_guard
 BEFORE INSERT OR UPDATE OR DELETE ON stridebrain.quotation_lines
 FOR EACH ROW EXECUTE FUNCTION stridebrain.guard_issued_quotation_lines();



-- An historical quotation may link only to a verified, same-tenant actual-cost
-- record. A draft quote can gain/lose links; an approved or issued quote cannot.
CREATE OR REPLACE FUNCTION stridebrain.guard_quotation_precedents()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $
DECLARE
  target_org uuid;
  target_quote uuid;
  quote_state text;
  case_state text;
  cost_basis text;
BEGIN
  IF TG_OP='DELETE' THEN
    target_org := OLD.organization_id;
    target_quote := OLD.quotation_id;
  ELSE
    target_org := NEW.organization_id;
    target_quote := NEW.quotation_id;
  END IF;

  SELECT q.state INTO quote_state
    FROM stridebrain.quotation_drafts q
   WHERE q.organization_id=target_org AND q.id=target_quote
   FOR UPDATE;

  IF quote_state IN ('approved','issued') THEN
    RAISE EXCEPTION 'Approved/issued quotation evidence is immutable.'
      USING ERRCODE='23514';
  END IF;

  IF TG_OP='UPDATE' AND (OLD.organization_id IS DISTINCT FROM NEW.organization_id
                        OR OLD.quotation_id IS DISTINCT FROM NEW.quotation_id
                        OR OLD.cost_case_id IS DISTINCT FROM NEW.cost_case_id) THEN
    RAISE EXCEPTION 'Evidence references cannot be moved to a different case.'
      USING ERRCODE='23514';
  END IF;

  IF TG_OP<>'DELETE' THEN
    SELECT c.verification_status,c.cost_basis INTO case_state,cost_basis
      FROM stridebrain.historical_cost_cases c
     WHERE c.organization_id=NEW.organization_id AND c.id=NEW.cost_case_id;

    IF case_state IS DISTINCT FROM 'verified_actual'
       OR cost_basis IS DISTINCT FROM 'actual_reconciled' THEN
      RAISE EXCEPTION 'A historical quotation precedent must be a verified actual-cost case.'
        USING ERRCODE='23514';
    END IF;
  END IF;

  IF TG_OP='DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$;

CREATE TRIGGER sb_quotation_precedent_guard
 BEFORE INSERT OR UPDATE OR DELETE ON stridebrain.quotation_precedents
 FOR EACH ROW EXECUTE FUNCTION stridebrain.guard_quotation_precedents();

-- A decided approval cannot be retracted, rewritten or deleted.
-- Reversal requires a new, separately auditable business event.
CREATE OR REPLACE FUNCTION stridebrain.guard_decided_approval()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $
BEGIN
  IF OLD.status IN ('approved','rejected') THEN
    RAISE EXCEPTION 'A decided approval is immutable; create a new review request.'
      USING ERRCODE='23514';
  END IF;
  IF TG_OP='DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$;

CREATE TRIGGER sb_decided_approval_guard
 BEFORE UPDATE OR DELETE ON stridebrain.approval_requests
 FOR EACH ROW EXECUTE FUNCTION stridebrain.guard_decided_approval();

-- The audit table is append-only even for privileged writers. No client role
-- receives write privileges through RLS or GRANT.
CREATE OR REPLACE FUNCTION stridebrain.prevent_audit_rewrite()
RETURNS trigger LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'Audit events are append-only.' USING ERRCODE='23514';
END;
$$;

CREATE TRIGGER sb_audit_append_only
 BEFORE UPDATE OR DELETE ON stridebrain.audit_events
 FOR EACH ROW EXECUTE FUNCTION stridebrain.prevent_audit_rewrite();

COMMENT ON FUNCTION stridebrain.guard_cost_case_verification() IS
  'Enforces cost evidence and total consistency. Server still must verify real-world source authenticity and authorization.';
COMMENT ON FUNCTION stridebrain.guard_quotation_approval() IS
  'DB integrity check only, not authentication or approval-role verification. Server must check approval authority.';

-- Only database trigger machinery needs execute rights on these functions.
REVOKE ALL ON FUNCTION stridebrain.guard_cost_case_verification() FROM PUBLIC;
REVOKE ALL ON FUNCTION stridebrain.guard_verified_cost_lines() FROM PUBLIC;
REVOKE ALL ON FUNCTION stridebrain.guard_approved_revision() FROM PUBLIC;
REVOKE ALL ON FUNCTION stridebrain.guard_quotation_approval() FROM PUBLIC;
REVOKE ALL ON FUNCTION stridebrain.guard_issued_quotation_lines() FROM PUBLIC;
REVOKE ALL ON FUNCTION stridebrain.prevent_audit_rewrite() FROM PUBLIC;
REVOKE ALL ON FUNCTION stridebrain.guard_decided_approval() FROM PUBLIC;
REVOKE ALL ON FUNCTION stridebrain.guard_quotation_precedents() FROM PUBLIC;

COMMIT;
