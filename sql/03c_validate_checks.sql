-- =============================================================================
-- 03c_validate_checks.sql — 각 자식의 ck_*_attach CHECK 를 VALIDATE
--                           (무중단, 오래 걸릴 수 있음 — AccessShareLock 만 사용)
--
-- 실행:
--   psql "$DATABASE_URL" -f params/app-prod.psql -f sql/03c_validate_checks.sql
--
-- 이 단계가 끝나야 04_cutover 의 ATTACH 가 풀스캔 없이 빠르게 완료된다.
-- 자식이 많거나 크면 수십 분 걸릴 수 있음 — 점검창 전에 반드시 완료.
--
-- 필수 파라미터: :parent
-- =============================================================================
\set ON_ERROR_STOP on

\echo ''
\echo '============================================================'
\echo ' pg-partition-migrate :: 03c VALIDATE CHECKS'
\echo '============================================================'
\echo ''
\echo '※ 진행 상황: SELECT pid, query, state FROM pg_stat_activity WHERE query LIKE ''%VALIDATE%'';'
\echo ''

SELECT set_config('my.parent', :'parent', false);

DO $BODY$
DECLARE
    v_parent  regclass := current_setting('my.parent')::regclass;
    r         record;
    v_count   int := 0;
    v_skipped int := 0;
BEGIN
    FOR r IN
        SELECT c.oid, c.relname, con.conname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_constraint con ON con.conrelid = c.oid
        WHERE i.inhparent = v_parent
          AND con.conname LIKE 'ck_%_attach'
          AND con.contype = 'c'
        ORDER BY c.relname
    LOOP
        IF EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE oid = (
                SELECT con2.oid FROM pg_constraint con2
                WHERE con2.conrelid = r.oid AND con2.conname = r.conname
            )
            AND convalidated
        ) THEN
            RAISE NOTICE 'SKIP [%] % — 이미 VALIDATED', r.relname, r.conname;
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        RAISE NOTICE '...  [%] % 를 VALIDATE 중...', r.relname, r.conname;

        EXECUTE format(
            'ALTER TABLE %I VALIDATE CONSTRAINT %I',
            r.relname, r.conname
        );

        RAISE NOTICE 'OK   [%] % VALIDATE 완료', r.relname, r.conname;
        v_count := v_count + 1;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '✓ 완료: 신규 VALIDATE % 개, 기존 SKIP % 개', v_count, v_skipped;
    RAISE NOTICE '  04_cutover.sql 를 실행할 수 있습니다 (점검창 준비 후).';
END;
$BODY$;
