-- StrideBrain quote and cost integrity test — staging ONLY.
-- DRAFT; do not run in production. All fixtures ROLLBACK.
-- Requires migrations 001,002,003 and a trusted privileged staging test runner.

BEGIN;

INSERT INTO public.organizations(id,name,slug)
VALUES ('00000000-0000-4000-8000-000000001a11','TEST StrideBrain Integrity','test-stridebrain-integrity-org');

INSERT INTO public.organization_members(organization_id,user_id,role,is_active)
VALUES ('00000000-0000-4000-8000-000000001a11','test_integrity_owner','owner',true);

INSERT INTO stridebrain.work_objects
 (organization_id,id,code,object_kind,title,created_by)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000001b11','TEST-PRJ','renovation_project','Fictional project','test_integrity_owner');

INSERT INTO stridebrain.source_documents
 (organization_id,id,work_object_id,title,classification,created_by)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000001c11','00000000-0000-4000-8000-000000001b11','Fictional reconciled ledger','TENANT_RESTRICTED','test_integrity_owner');

INSERT INTO stridebrain.document_revisions
 (organization_id,id,document_id,revision_no,lifecycle,original_file_name,reviewed_by,reviewed_at,created_by)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000001d11','00000000-0000-4000-8000-000000001c11',1,'approved','test-ledger.xlsx','test_integrity_owner',now(),'test_integrity_owner');

INSERT INTO stridebrain.private_file_blobs
 (organization_id,id,revision_id,private_bucket,private_object_key,bytes,content_sha256,scan_state)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000001e11','00000000-0000-4000-8000-000000001d11','staging-private','test/stridebrain/ledger.xlsx',321,repeat('a',64),'pending');

INSERT INTO stridebrain.historical_cost_cases
 (organization_id,id,work_object_id,source_revision_id,cost_basis,verification_status,
  completed_on,normalized_quantity,normalized_unit,direct_cost_total,created_by)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000001f11','00000000-0000-4000-8000-000000001b11',
  '00000000-0000-4000-8000-000000001d11','actual_reconciled','draft',
  '2026-09-30',28,'ping',100000,'test_integrity_owner');

INSERT INTO stridebrain.historical_cost_lines
 (organization_id,id,cost_case_id,cost_code,description,quantity,unit,actual_cost,source_cell_or_page)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000002011',
  '00000000-0000-4000-8000-000000001f11','carpentry','Cabinetry',1,'job',60000,'Sheet1!F5'),
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000002012',
  '00000000-0000-4000-8000-000000001f11','electrical','Electrical',1,'job',40000,'Sheet1!F6');

-- Cannot verify a ledger when source-file malware scan has not passed.
DO $$
BEGIN
 UPDATE stridebrain.historical_cost_cases SET
  verification_status='verified_actual',reviewer_subject='test_integrity_owner',verified_at=now()
 WHERE id='00000000-0000-4000-8000-000000001f11';
 RAISE EXCEPTION 'FAIL: unscanned source ledger was marked verified';
EXCEPTION WHEN check_violation THEN NULL;
END $$;

UPDATE stridebrain.private_file_blobs SET scan_state='passed'
WHERE id='00000000-0000-4000-8000-000000001e11';

-- Cannot verify a mismatching amount.
DO $$
BEGIN
 UPDATE stridebrain.historical_cost_cases SET
  direct_cost_total=110000,
  verification_status='verified_actual',reviewer_subject='test_integrity_owner',verified_at=now()
 WHERE id='00000000-0000-4000-8000-000000001f11';
 RAISE EXCEPTION 'FAIL: unreconciled cost ledger was marked verified';
EXCEPTION WHEN check_violation THEN NULL;
END $$;

-- Correctly reconciled, scanned and approved revision may pass.
UPDATE stridebrain.historical_cost_cases SET
 verification_status='verified_actual',reviewer_subject='test_integrity_owner',verified_at=now()
WHERE id='00000000-0000-4000-8000-000000001f11';

DO $$
DECLARE n integer;
BEGIN
 SELECT count(*) INTO n FROM stridebrain.historical_cost_cases
 WHERE verification_status='verified_actual' AND direct_cost_total=100000;
 IF n<>1 THEN RAISE EXCEPTION 'Expected one verified actual-cost case, got %',n; END IF;
END $$;

-- The record and lines of a verified case must remain immutable.
DO $$
BEGIN
 UPDATE stridebrain.historical_cost_lines SET actual_cost=50000
 WHERE id='00000000-0000-4000-8000-000000002011';
 RAISE EXCEPTION 'FAIL: verified ledger line was changed';
EXCEPTION WHEN check_violation THEN NULL;
END $$;

DO $$
BEGIN
 UPDATE stridebrain.historical_cost_cases SET direct_cost_total=200000
 WHERE id='00000000-0000-4000-8000-000000001f11';
 RAISE EXCEPTION 'FAIL: verified ledger total changed';
EXCEPTION WHEN check_violation THEN NULL;
END $$;

DO $$
BEGIN
 UPDATE stridebrain.document_revisions SET original_file_name='silent-replacement.xlsx'
 WHERE id='00000000-0000-4000-8000-000000001d11';
 RAISE EXCEPTION 'FAIL: approved document revision was changed';
EXCEPTION WHEN check_violation THEN NULL;
END $$;

-- Quotation approval: a draft cannot approve itself.
INSERT INTO stridebrain.quotation_drafts
 (organization_id,id,work_object_id,quote_number,pricing_method,created_by,
  proposed_price_before_tax,cost_estimate)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000002111',
  '00000000-0000-4000-8000-000000001b11','TEST-Q-0001','historical_comparison',
  'test_integrity_owner',135000,100000);

INSERT INTO stridebrain.quotation_lines
 (organization_id,id,quotation_id,item_no,description,quantity,unit,proposed_unit_price,line_total)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000002211',
  '00000000-0000-4000-8000-000000002111',1,'Fictional interior work',1,'job',135000,135000);

DO $$
BEGIN
 UPDATE stridebrain.quotation_drafts SET state='approved',
 approved_by='test_integrity_owner',approved_at=now()
 WHERE id='00000000-0000-4000-8000-000000002111';
 RAISE EXCEPTION 'FAIL: quote approved without corresponding decision';
EXCEPTION WHEN check_violation THEN NULL;
END $$;


-- Only a verified actual-cost record may support a historical quotation.
-- Quote-only cases cannot be laundered into historical cost evidence.
INSERT INTO stridebrain.historical_cost_cases
 (organization_id,id,work_object_id,cost_basis,verification_status,normalized_quantity,normalized_unit,direct_cost_total,created_by)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000002511',
  '00000000-0000-4000-8000-000000001b11','quoted','draft',28,'ping',100000,'test_integrity_owner');

DO $
BEGIN
 INSERT INTO stridebrain.quotation_precedents
 (organization_id,id,quotation_id,cost_case_id,relevance_score)
 VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000002611',
  '00000000-0000-4000-8000-000000002111','00000000-0000-4000-8000-000000002511',0.9);
 RAISE EXCEPTION 'FAIL: quote-only historical record was used as verified cost evidence';
EXCEPTION WHEN check_violation THEN NULL;
END $;

INSERT INTO stridebrain.approval_requests
 (organization_id,id,quotation_id,status,requested_by)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000002311',
 '00000000-0000-4000-8000-000000002111','pending','test_integrity_owner');

UPDATE stridebrain.approval_requests SET
 status='approved',decided_by='test_integrity_owner',decided_at=now()
WHERE id='00000000-0000-4000-8000-000000002311';

INSERT INTO stridebrain.quotation_precedents
 (organization_id,id,quotation_id,cost_case_id,relevance_score,comparison_note)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000002612',
  '00000000-0000-4000-8000-000000002111','00000000-0000-4000-8000-000000001f11',
  0.8750,'Verified example completed-cost comparison, staging only');

UPDATE stridebrain.quotation_drafts SET state='approved',
 approved_by='test_integrity_owner',approved_at=now()
WHERE id='00000000-0000-4000-8000-000000002111';

DO $
BEGIN
 UPDATE stridebrain.quotation_drafts SET state='draft'
 WHERE id='00000000-0000-4000-8000-000000002111';
 RAISE EXCEPTION 'FAIL: approved quote reverted to draft';
EXCEPTION WHEN check_violation THEN NULL;
END $$;

DO $
BEGIN
 UPDATE stridebrain.quotation_lines SET line_total=1
 WHERE id='00000000-0000-4000-8000-000000002211';
 RAISE EXCEPTION 'FAIL: approved quote line was changed';
EXCEPTION WHEN check_violation THEN NULL;
END $;

DO $
BEGIN
 DELETE FROM stridebrain.quotation_precedents
 WHERE id='00000000-0000-4000-8000-000000002612';
 RAISE EXCEPTION 'FAIL: approved historical quotation source evidence was removed';
EXCEPTION WHEN check_violation THEN NULL;
END $;

UPDATE stridebrain.quotation_drafts SET state='issued'
WHERE id='00000000-0000-4000-8000-000000002111';

DO $$
BEGIN
 UPDATE stridebrain.approval_requests SET status='cancelled'
 WHERE id='00000000-0000-4000-8000-000000002311';
 RAISE EXCEPTION 'FAIL: decided approval was rewritten';
EXCEPTION WHEN check_violation THEN NULL;
END $$;

INSERT INTO stridebrain.audit_events
 (organization_id,id,actor_subject,event_type,entity_kind,entity_id)
VALUES
 ('00000000-0000-4000-8000-000000001a11','00000000-0000-4000-8000-000000002411',
 'test_integrity_owner','quote.issued','quotation','00000000-0000-4000-8000-000000002111');

DO $$
BEGIN
 UPDATE stridebrain.audit_events SET event_type='erase'
 WHERE id='00000000-0000-4000-8000-000000002411';
 RAISE EXCEPTION 'FAIL: audit event was rewritten';
EXCEPTION WHEN check_violation THEN NULL;
END $$;

ROLLBACK;
-- A complete run without an exception demonstrates only THESE STAGING DATA
-- integrity checks. It does NOT validate real-world cost truth, signer authority,
-- JWT signatures, API authorization, source scans, or production backups.
