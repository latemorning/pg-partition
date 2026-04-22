-- =============================================================================
-- 06_rollback.sql — RENAME 스왑 되돌리기 (관찰 기간 한정)
--
-- 실행 (점검창, 애플리케이션 쓰기 중단 후):
--   psql "$DATABASE_URL" -f params/app-prod.psql -f sql/06_rollback.sql
--
-- ⚠ 경고:
--   커트오버 이후 새 파티션에 유입된 데이터는 legacy 테이블에 없습니다.
--   이 스크립트는 "정책적 롤백" (운영 상 문제 발생 시 일시 되돌리기) 용도입니다.
--   커트오버 후 오래 지났거나 write 가 많이 유입됐다면 데이터 검토 필수.
--
-- 필수 파라미터: :parent, :new_suffix, :legacy_suffix
-- =============================================================================
\set ON_ERROR_STOP on

\echo ''
\echo '============================================================'
\echo ' pg-partition-migrate :: 06 ROLLBACK'
\echo '============================================================'
\echo ''
\echo '⚠ 커트오버 이후 유입된 데이터는 legacy 에 없습니다. 데이터 검토 필수.'
\echo ''

SELECT set_config('my.parent',        :'parent',        false);
SELECT set_config('my.new_suffix',    :'new_suffix',    false);
SELECT set_config('my.legacy_suffix', :'legacy_suffix', false);

BEGIN;
SET LOCAL lock_timeout     = '10s';
SET LOCAL statement_timeout = '5min';

DO $BODY$
DECLARE
    v_parent        regclass := current_setting('my.parent')::regclass;
    v_new_suffix    text     := current_setting('my.new_suffix');
    v_legacy_suffix text     := current_setting('my.legacy_suffix');

    v_schema        text;
    v_table         text;
    v_current_name  text;   -- 현재 선언형 부모 (= v_table)
    v_legacy_name   text;   -- legacy 이름 (= v_table || v_legacy_suffix)
    v_temp_name     text;   -- 임시: 선언형 부모를 _new 로 되돌리기 위한 중간 이름

    r               record;
    v_seq           text;
BEGIN
    SELECT n.nspname, c.relname INTO v_schema, v_table
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = v_parent;

    v_legacy_name := v_table || v_legacy_suffix;
    v_temp_name   := v_table || v_new_suffix;

    -- legacy 존재 확인
    IF to_regclass(format('%I.%I', v_schema, v_legacy_name)) IS NULL THEN
        RAISE EXCEPTION
            '레거시 테이블 %.% 이 없습니다. 이미 cleanup 됐거나 커트오버 전 상태입니다.',
            v_schema, v_legacy_name;
    END IF;

    -- -------------------------------------------------------------------------
    -- [1] 선언형 부모를 _new 로 RENAME (현재 active 를 비켜 줌)
    -- -------------------------------------------------------------------------
    EXECUTE format('ALTER TABLE %s RENAME TO %I', v_parent, v_temp_name);
    RAISE NOTICE 'OK   [1] % → %', v_table, v_temp_name;

    -- -------------------------------------------------------------------------
    -- [2] legacy 를 원래 이름으로 복구
    -- -------------------------------------------------------------------------
    EXECUTE format(
        'ALTER TABLE %I.%I RENAME TO %I',
        v_schema, v_legacy_name, v_table
    );
    RAISE NOTICE 'OK   [2] % → %', v_legacy_name, v_table;

    -- -------------------------------------------------------------------------
    -- [3] 시퀀스 소유권 legacy(= 원래 부모) 로 재지정
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT a.attname,
               pg_get_serial_sequence(
                   format('%I.%I', v_schema, v_table), a.attname
               ) AS seq_name
        FROM pg_attribute a
        WHERE a.attrelid = (format('%I.%I', v_schema, v_table)::regclass)
          AND a.attnum > 0
          AND NOT a.attisdropped
          AND pg_get_serial_sequence(
                  format('%I.%I', v_schema, v_table), a.attname
              ) IS NOT NULL
    LOOP
        EXECUTE format(
            'ALTER SEQUENCE %s OWNED BY %I.%I.%I',
            r.seq_name, v_schema, v_table, r.attname
        );
        RAISE NOTICE 'OK   [3] 시퀀스 % → %.%', r.seq_name, v_table, r.attname;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- [4] 라우팅 트리거 재생성 안내
    --     트리거 함수는 07_cleanup 전까지 남아있으므로 DROP 되지 않음.
    --     트리거 본체를 재생성해야 라우팅이 복구됨.
    -- -------------------------------------------------------------------------
    RAISE WARNING
        E'[4] BEFORE INSERT 라우팅 트리거를 수동으로 재생성해야 합니다.\n'
        '    트리거 함수는 %.* 네임스페이스에서 원본 함수명으로 확인하세요:\n'
        '    SELECT proname FROM pg_proc JOIN pg_namespace ON pg_namespace.oid = pronamespace\n'
        '    WHERE nspname = ''%'';',
        v_schema, v_schema;

    RAISE NOTICE '';
    RAISE NOTICE '✓ 롤백 완료 (트랜잭션 COMMIT 중)';
    RAISE NOTICE '  선언형 부모는 %.% 로 남아있습니다.', v_schema, v_temp_name;
    RAISE NOTICE '  트리거 재생성 후 애플리케이션을 재개하세요.';
END;
$BODY$;

COMMIT;

\echo ''
\echo '► COMMIT 완료. 트리거 재생성 후 애플리케이션 쓰기를 재개하세요.'
\echo ''
