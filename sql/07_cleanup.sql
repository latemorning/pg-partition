-- =============================================================================
-- 07_cleanup.sql — 관찰 기간 후 레거시 테이블 및 트리거 함수 제거
--
-- 실행 (관찰 기간 종료 후 — 보통 1~2주):
--   psql "$DATABASE_URL" -f params/app-prod.psql -f sql/07_cleanup.sql
--
-- 동작:
--   1. 자식별 기존 (비정규화) CHECK 제약 DROP (ck_*_attach 는 선언형으로 자동 관리됨)
--   2. 레거시 부모 테이블 DROP (자식은 이미 새 부모 소속)
--   3. 라우팅 트리거 함수 DROP (의존성 없을 때만)
--
-- 필수 파라미터: :parent, :legacy_suffix
-- =============================================================================
\set ON_ERROR_STOP on

\echo ''
\echo '============================================================'
\echo ' pg-partition-migrate :: 07 CLEANUP'
\echo '============================================================'
\echo ''
\echo '⚠ 이 작업은 되돌릴 수 없습니다. 06_rollback.sql 이 더 이상 작동하지 않습니다.'
\echo ''

SELECT set_config('my.parent',        :'parent',        false);
SELECT set_config('my.legacy_suffix', :'legacy_suffix', false);

BEGIN;
SET LOCAL lock_timeout = '10s';

DO $BODY$
DECLARE
    v_parent        regclass := current_setting('my.parent')::regclass;
    v_legacy_suffix text     := current_setting('my.legacy_suffix');

    v_schema        text;
    v_table         text;
    v_legacy_table  text;

    r               record;
    v_dep_count     int;
BEGIN
    SELECT n.nspname, c.relname INTO v_schema, v_table
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = v_parent;

    v_legacy_table := format('%I.%I', v_schema, v_table || v_legacy_suffix);

    -- -------------------------------------------------------------------------
    -- [1] 자식별 기존(비정규화) CHECK 제약 DROP
    --     - ck_*_attach (정규화 CHECK) 는 자식이 ATTACH 된 후 선언형 바운드로 대체됨
    --     - 이전에 있던 원래 CHECK (파티션 컬럼 조건) 를 제거
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT c.oid AS child_oid, c.relname, con.conname
        FROM pg_inherits i
        JOIN pg_class c   ON c.oid = i.inhrelid
        JOIN pg_constraint con ON con.conrelid = c.oid
        WHERE i.inhparent = v_parent
          AND con.contype = 'c'
          AND con.conname NOT LIKE 'ck_%_attach'  -- 정규화 CHECK 는 유지
          AND pg_get_constraintdef(con.oid) ~* current_setting('my.partition_col')
    LOOP
        -- 이 CHECK 가 아직 자식에 남아있을 수 있음 (ATTACH 시 바운드와 중복)
        EXECUTE format(
            'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
            r.relname, r.conname
        );
        RAISE NOTICE 'OK   [1] % . % DROP', r.relname, r.conname;
    END LOOP;

    -- ck_*_attach CHECK 도 이제 불필요 (ATTACH 이후 바운드로 관리됨)
    FOR r IN
        SELECT c.oid AS child_oid, c.relname, con.conname
        FROM pg_inherits i
        JOIN pg_class c   ON c.oid = i.inhrelid
        JOIN pg_constraint con ON con.conrelid = c.oid
        WHERE i.inhparent = v_parent
          AND con.contype = 'c'
          AND con.conname LIKE 'ck_%_attach'
    LOOP
        EXECUTE format(
            'ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I',
            r.relname, r.conname
        );
        RAISE NOTICE 'OK   [1] % . % DROP (정규화 CHECK, 이제 불필요)', r.relname, r.conname;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- [2] 레거시 부모 테이블 DROP
    --     자식 테이블은 이미 새 부모 소속이므로 CASCADE 불필요
    -- -------------------------------------------------------------------------
    IF to_regclass(v_legacy_table) IS NULL THEN
        RAISE NOTICE 'SKIP [2] % 없음', v_legacy_table;
    ELSE
        EXECUTE format('DROP TABLE %s', v_legacy_table);
        RAISE NOTICE 'OK   [2] % DROP', v_legacy_table;
    END IF;

    -- -------------------------------------------------------------------------
    -- [3] 라우팅 트리거 함수 DROP
    --     다른 테이블/트리거에서 참조하면 건너뜀
    -- -------------------------------------------------------------------------
    FOR r IN
        -- 04_cutover 에서 DROP 된 트리거의 함수를 찾음
        -- pg_depend 로 의존성 확인
        SELECT p.oid AS func_oid,
               n.nspname || '.' || p.proname AS func_name
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE p.prorettype = (SELECT oid FROM pg_type WHERE typname = 'trigger')
          AND n.nspname = v_schema
          AND NOT EXISTS (
              -- 다른 트리거에서 여전히 사용 중인지 확인
              SELECT 1 FROM pg_trigger t
              WHERE t.tgfoid = p.oid AND NOT t.tgisinternal
          )
          -- 이름 패턴으로 라우팅 함수 특정 (일반적으로 <table>_insert_trigger 류)
          AND (p.proname ILIKE '%' || v_table || '%insert%'
               OR p.proname ILIKE '%' || v_table || '%route%'
               OR p.proname ILIKE '%' || v_table || '%partition%')
    LOOP
        -- 의존성 재확인
        SELECT count(*) INTO v_dep_count
        FROM pg_depend d
        WHERE d.objid = r.func_oid
          AND d.deptype = 'n';

        IF v_dep_count > 0 THEN
            RAISE NOTICE 'SKIP [3] % — 의존성 % 개 있음 (수동 처리 필요)',
                r.func_name, v_dep_count;
        ELSE
            EXECUTE format('DROP FUNCTION IF EXISTS %s()', r.func_name);
            RAISE NOTICE 'OK   [3] % DROP', r.func_name;
        END IF;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '✓ cleanup 완료.';
END;
$BODY$;

COMMIT;

\echo ''
\echo '► 완료. 마이그레이션이 모두 종료됐습니다.'
\echo ''
