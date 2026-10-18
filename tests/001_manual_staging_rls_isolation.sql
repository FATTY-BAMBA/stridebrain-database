-- StrideBrain tenant security test — DRAFT, NEVER EXECUTE AGAINST PRODUCTION.
-- Manual integration test for an ISOLATED Supabase staging database only.
--
-- PREREQUISITES:
--  1. Verified SaaS core schema and migrations 001, 002, 003 applied in STAGING.
--  2. PostgreSQL roles postgres, authenticated, anon; auth.jwt()/auth.role().
--  3. Test runner can SET ROLE authenticated/anon (normally database owner).
--  4. Real JWT signature validation must be tested separately at API ingress.
--
-- All inserted fixtures ROLLBACK. Test IDs and user IDs are fictional.
-- Setting request.jwt.claims in this SQL script simulates PostgREST's JWT
-- context and is NOT a test of Clerk/JWT signature authenticity.

BEGIN;

INSERT INTO public.organizations (id,name,slug)
VALUES
 ('00000000-0000-4000-8000-0000000000a1','TEST StrideBrain Org A','test-stridebrain-security-org-a'),
 ('00000000-0000-4000-8000-0000000000b2','TEST StrideBrain Org B','test-stridebrain-security-org-b');

INSERT INTO public.organization_members (organization_id,user_id,role,is_active)
VALUES
 ('00000000-0000-4000-8000-0000000000a1','test_sb_owner_a','owner',true),
 ('00000000-0000-4000-8000-0000000000a1','test_sb_member_a','member',true),
 ('00000000-0000-4000-8000-0000000000b2','test_sb_owner_b','owner',true),
 ('00000000-0000-4000-8000-0000000000a1','test_sb_revoked','member',false);

INSERT INTO stridebrain.work_objects
  (organization_id,id,code,object_kind,title,created_by)
VALUES
 ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-000000000101','TEST-PRJ-A','renovation_project','Fictional A project','test_sb_owner_a'),
 ('00000000-0000-4000-8000-0000000000b2','00000000-0000-4000-8000-000000000102','TEST-JOB-B','print_job','Fictional B project','test_sb_owner_b');

INSERT INTO stridebrain.source_documents
  (organization_id,id,work_object_id,title,classification,created_by)
VALUES
 ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-000000000201','00000000-0000-4000-8000-000000000101','A general procedure','TENANT_PRIVATE','test_sb_owner_a'),
 ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-000000000202','00000000-0000-4000-8000-000000000101','A financial margin secrets','TENANT_RESTRICTED','test_sb_owner_a'),
 ('00000000-0000-4000-8000-0000000000b2','00000000-0000-4000-8000-000000000203','00000000-0000-4000-8000-000000000102','B client file','TENANT_PRIVATE','test_sb_owner_b');

INSERT INTO stridebrain.document_revisions
  (organization_id,id,document_id,revision_no,lifecycle,created_by)
VALUES
 ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-000000000301','00000000-0000-4000-8000-000000000201',1,'draft','test_sb_owner_a'),
 ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-000000000302','00000000-0000-4000-8000-000000000202',1,'draft','test_sb_owner_a'),
 ('00000000-0000-4000-8000-0000000000b2','00000000-0000-4000-8000-000000000303','00000000-0000-4000-8000-000000000203',1,'draft','test_sb_owner_b');

INSERT INTO stridebrain.quotation_drafts
  (organization_id,id,work_object_id,quote_number,pricing_method,created_by)
VALUES
 ('00000000-0000-4000-8000-0000000000a1','00000000-0000-4000-8000-000000000401','00000000-0000-4000-8000-000000000101','TEST-A-QUOTE','manual','test_sb_owner_a'),
 ('00000000-0000-4000-8000-0000000000b2','00000000-0000-4000-8000-000000000402','00000000-0000-4000-8000-000000000102','TEST-B-QUOTE','manual','test_sb_owner_b');

-- Positive owner A / negative owner B visibility
SELECT set_config('request.jwt.claims','{"role":"authenticated","sub":"test_sb_owner_a"}',true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE n integer;
BEGIN
 SELECT count(*) INTO n FROM stridebrain.work_objects;
 IF n<>1 THEN RAISE EXCEPTION 'Owner A should see exactly one work object, saw %',n; END IF;
 SELECT count(*) INTO n FROM stridebrain.source_documents;
 IF n<>2 THEN RAISE EXCEPTION 'Owner A should see exactly two A documents, saw %',n; END IF;
 SELECT count(*) INTO n FROM stridebrain.quotation_drafts;
 IF n<>1 THEN RAISE EXCEPTION 'Owner A should see exactly one A quote, saw %',n; END IF;
 SELECT count(*) INTO n FROM stridebrain.document_revisions;
 IF n<>2 THEN RAISE EXCEPTION 'Owner A should see two allowed A revisions, saw %',n; END IF;
END $$;

RESET ROLE;

-- Ordinary member: own nonfinancial docs only; restricted parent revision denied.
SELECT set_config('request.jwt.claims','{"role":"authenticated","sub":"test_sb_member_a"}',true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SET LOCAL ROLE authenticated;

DO $$
DECLARE n integer;
BEGIN
 SELECT count(*) INTO n FROM stridebrain.work_objects;
 IF n<>1 THEN RAISE EXCEPTION 'Member A should see exactly one A work object, saw %',n; END IF;
 SELECT count(*) INTO n FROM stridebrain.source_documents;
 IF n<>1 THEN RAISE EXCEPTION 'Member A should see only one nonrestricted document, saw %',n; END IF;
 SELECT count(*) INTO n FROM stridebrain.document_revisions;
 IF n<>1 THEN RAISE EXCEPTION 'Member A must not see a restricted document revision, saw %',n; END IF;
 SELECT count(*) INTO n FROM stridebrain.quotation_drafts;
 IF n<>0 THEN RAISE EXCEPTION 'Member A must not read finance quotes, saw %',n; END IF;
END $$;

-- Browser-side write must not be possible, even with valid membership.
DO $$
BEGIN
 INSERT INTO stridebrain.work_objects (organization_id,code,object_kind,title,created_by)
 VALUES ('00000000-0000-4000-8000-0000000000a1','ILLEGAL','renovation_project','No direct edits','test_sb_member_a');
 RAISE EXCEPTION 'FAIL: authenticated direct INSERT was permitted';
EXCEPTION WHEN insufficient_privilege THEN
 NULL; -- expected
END $$;

RESET ROLE;

-- Revoked member gets no records.
SELECT set_config('request.jwt.claims','{"role":"authenticated","sub":"test_sb_revoked"}',true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE n integer;
BEGIN
 SELECT count(*) INTO n FROM stridebrain.work_objects;
 IF n<>0 THEN RAISE EXCEPTION 'Revoked membership still sees % work objects',n; END IF;
END $$;
RESET ROLE;

-- Owner B sees only B records, never A.
SELECT set_config('request.jwt.claims','{"role":"authenticated","sub":"test_sb_owner_b"}',true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE n integer;
BEGIN
 SELECT count(*) INTO n FROM stridebrain.work_objects;
 IF n<>1 THEN RAISE EXCEPTION 'Owner B should only see one B work object, saw %',n; END IF;
 SELECT count(*) INTO n FROM stridebrain.quotation_drafts;
 IF n<>1 THEN RAISE EXCEPTION 'Owner B should only see one B quote, saw %',n; END IF;
END $$;
RESET ROLE;

-- Stranger (valid signed-in identity with no org membership) sees nothing.
SELECT set_config('request.jwt.claims','{"role":"authenticated","sub":"test_sb_outsider"}',true);
SELECT set_config('request.jwt.claim.role','authenticated',true);
SET LOCAL ROLE authenticated;
DO $$
DECLARE n integer;
BEGIN
 SELECT count(*) INTO n FROM stridebrain.work_objects;
 IF n<>0 THEN RAISE EXCEPTION 'Outsider sees % business objects',n; END IF;
END $$;
RESET ROLE;

-- Anonymous requests cannot see any tenant table.
SELECT set_config('request.jwt.claims','{"role":"anon"}',true);
SELECT set_config('request.jwt.claim.role','anon',true);
SET LOCAL ROLE anon;
DO $$
DECLARE n integer;
BEGIN
 BEGIN
 SELECT count(*) INTO n FROM stridebrain.work_objects;
 IF n<>0 THEN RAISE EXCEPTION 'Anonymous actor sees % work objects',n; END IF;
 EXCEPTION WHEN insufficient_privilege THEN NULL; -- expected, no schema usage grant
 END;
END $$;
RESET ROLE;

-- Even the database owner cannot insert cross-tenant references due to
-- composite (organization_id,id) foreign keys.
DO $$
BEGIN
 INSERT INTO stridebrain.source_documents (organization_id,work_object_id,title,created_by)
 VALUES ('00000000-0000-4000-8000-0000000000a1',
         '00000000-0000-4000-8000-000000000102',
         'Illegal cross-tenant link','test_sb_owner_a');
 RAISE EXCEPTION 'FAIL: cross-tenant work object FK was accepted';
EXCEPTION WHEN foreign_key_violation THEN NULL; -- expected
END $$;

-- Private storage keys must not be granted to authenticated.
DO $$
BEGIN
 IF has_table_privilege('authenticated','stridebrain.private_file_blobs','SELECT') THEN
   RAISE EXCEPTION 'Private blob table readable by authenticated role';
 END IF;
END $$;

ROLLBACK;
-- If this script reached ROLLBACK without an exception, the basic RLS
-- test matrix passed IN THE STAGING DATABASE ONLY.
