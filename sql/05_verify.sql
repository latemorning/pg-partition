-- =============================================================================
-- 05_verify.sql — 커트오버 결과 검증 (읽기 전용)
--
-- 실행:
--   psql "$DATABASE_URL" -f params/app-prod.psql -f sql/05_verify.sql
--
-- 필수 파라미터: :parent, :partition_col, :legacy_suffix
-- =============================================================================
\set ON_ERROR_STOP on

\echo ''
\echo '============================================================'
\echo ' pg-partition-migrate :: 05 VERIFY'
\echo '============================================================'
SELECT set_config('my.parent',        :'parent',        false);
SELECT set_config('my.partition_col', :'partition_col', false);
SELECT set_config('my.legacy_suffix', :'legacy_suffix', false);

\echo ''

-- ---------------------------------------------------------------------------
\echo '--- [1] 테이블 타입 확인 (relkind: p = partitioned, r = ordinary) ---'
-- ---------------------------------------------------------------------------
SELECT
    c.relname,
    CASE c.relkind
        WHEN 'p' THEN '✓ PARTITIONED (선언형)'
        WHEN 'r' THEN '  ORDINARY TABLE'
        ELSE c.relkind::text
    END AS table_type,
    n.nspname AS schema
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname IN (
    split_part(:'parent', '.', 2),
    split_part(:'parent', '.', 2) || :'legacy_suffix'
)
  AND n.nspname = CASE WHEN position('.' IN :'parent') > 0
                       THEN split_part(:'parent', '.', 1)
                       ELSE 'public' END
ORDER BY c.relname;

-- ---------------------------------------------------------------------------
\echo ''
\echo '--- [2] 행 수 비교 (legacy vs new) ---'
-- ---------------------------------------------------------------------------
DO $cnt$
DECLARE
    v_parent      regclass := current_setting('my.parent')::regclass;
    v_legacy_name text;
    v_schema      text;
    v_table       text;
    v_count_new   bigint;
    v_count_legacy bigint;
BEGIN
    SELECT n.nspname, c.relname INTO v_schema, v_table
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = v_parent;

    v_legacy_name := format('%I.%I', v_schema, v_table || current_setting('my.legacy_suffix'));

    IF to_regclass(v_legacy_name) IS NULL THEN
        RAISE NOTICE 'SKIP: 레거시 테이블 % 없음 (이미 cleanup 됐거나 커트오버 전)', v_legacy_name;
        RETURN;
    END IF;

    EXECUTE format('SELECT count(*) FROM %s', v_parent)       INTO v_count_new;
    EXECUTE format('SELECT count(*) FROM %s', v_legacy_name)  INTO v_count_legacy;

    IF v_count_new = v_count_legacy THEN
        RAISE NOTICE '✓ 행 수 일치: % = %', v_count_new, v_count_legacy;
    ELSE
        RAISE WARNING '✗ 행 수 불일치: new=% / legacy=% (차이: %)',
            v_count_new, v_count_legacy, v_count_new - v_count_legacy;
    END IF;
END;
$cnt$;

-- ---------------------------------------------------------------------------
\echo ''
\echo '--- [3] 선언형 파티션 목록 및 범위 ---'
-- ---------------------------------------------------------------------------
SELECT
    c.relname                                    AS partition_name,
    pg_get_expr(c.relpartbound, c.oid, true)     AS partition_range,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS size
FROM pg_class parent
JOIN pg_inherits i   ON i.inhparent = parent.oid
JOIN pg_class c      ON c.oid = i.inhrelid
WHERE parent.oid = :'parent'::regclass
ORDER BY c.relname;

-- ---------------------------------------------------------------------------
\echo ''
\echo '--- [4] EXPLAIN — 파티션 프루닝 확인 ---'
-- ---------------------------------------------------------------------------
\echo '(현재 월 기준 단일 파티션만 스캔되어야 함)'

DO $explain$
DECLARE
    v_parent     regclass := current_setting('my.parent')::regclass;
    v_col        text     := current_setting('my.partition_col');
    v_sql        text;
    v_row        record;
    v_typname    text;
    v_sample_val text;   -- 파티션 바운드에서 추출한 실제 값 (포맷 판별용)
    v_lo_expr    text;
    v_hi_expr    text;
BEGIN
    -- 파티션 키 컬럼 타입 확인
    SELECT t.typname INTO v_typname
    FROM pg_attribute a
    JOIN pg_type t ON t.oid = a.atttypid
    WHERE a.attrelid = v_parent AND a.attname = v_col;

    IF v_typname IN ('varchar', 'bpchar', 'text') THEN
        -- 바운드 표현식에서 FROM 절의 첫 번째 리터럴 값만 추출
        -- pg_get_expr 결과 예: FOR VALUES FROM ('20260401000000') TO ('20260501000000')
        SELECT (regexp_matches(
                    pg_get_expr(c.relpartbound, c.oid, true),
                    $$FROM \('([^']+)'\)$$
                ))[1]
        INTO v_sample_val
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = v_parent AND c.relpartbound IS NOT NULL
        ORDER BY c.relname
        LIMIT 1;

        -- 실제 값의 길이와 패턴으로 포맷 판별 (겹침 없음)
        IF v_sample_val ~ '^\d{14}$' THEN
            -- YYYYMMDDHHMMSS
            v_lo_expr := 'to_char(date_trunc(''month'', CURRENT_DATE)::date, ''YYYYMMDD'') || ''000000''';
            v_hi_expr := 'to_char((date_trunc(''month'', CURRENT_DATE) + INTERVAL ''1 month'')::date, ''YYYYMMDD'') || ''000000''';
        ELSIF v_sample_val ~ '^\d{8}$' THEN
            -- YYYYMMDD
            v_lo_expr := 'to_char(date_trunc(''month'', CURRENT_DATE)::date, ''YYYYMMDD'')';
            v_hi_expr := 'to_char((date_trunc(''month'', CURRENT_DATE) + INTERVAL ''1 month'')::date, ''YYYYMMDD'')';
        ELSIF v_sample_val ~ '^\d{4}-\d{2}$' THEN
            -- YYYY-MM
            v_lo_expr := 'to_char(date_trunc(''month'', CURRENT_DATE)::date, ''YYYY-MM'')';
            v_hi_expr := 'to_char((date_trunc(''month'', CURRENT_DATE) + INTERVAL ''1 month'')::date, ''YYYY-MM'')';
        ELSIF v_sample_val ~ '^\d{6}$' THEN
            -- YYYYMM
            v_lo_expr := 'to_char(date_trunc(''month'', CURRENT_DATE)::date, ''YYYYMM'')';
            v_hi_expr := 'to_char((date_trunc(''month'', CURRENT_DATE) + INTERVAL ''1 month'')::date, ''YYYYMM'')';
        ELSE
            RAISE NOTICE '[4] 바운드 포맷 감지 실패 (sample: %) — EXPLAIN 건너뜀', v_sample_val;
            RETURN;
        END IF;
    ELSE
        -- date / timestamp 등 네이티브 날짜 타입
        v_lo_expr := 'date_trunc(''month'', CURRENT_DATE)';
        v_hi_expr := 'date_trunc(''month'', CURRENT_DATE) + INTERVAL ''1 month''';
    END IF;

    IF v_sample_val IS NOT NULL THEN
        RAISE NOTICE '[4] varchar 포맷 감지: sample=%, lo=%', v_sample_val, v_lo_expr;
    ELSE
        RAISE NOTICE '[4] 네이티브 날짜 타입 (%), date_trunc 사용', v_typname;
    END IF;

    v_sql := format(
        'EXPLAIN (FORMAT TEXT) SELECT count(*) FROM %s WHERE %I >= %s AND %I < %s',
        v_parent, v_col, v_lo_expr, v_col, v_hi_expr
    );
    FOR v_row IN EXECUTE v_sql LOOP
        RAISE NOTICE '%', v_row;
    END LOOP;
END;
$explain$;

-- ---------------------------------------------------------------------------
\echo ''
\echo '--- [5] 미검증 제약 확인 (0건이어야 함) ---'
-- ---------------------------------------------------------------------------
SELECT
    c.relname        AS table_name,
    con.conname      AS constraint_name,
    con.contype      AS type,
    con.convalidated AS validated
FROM pg_constraint con
JOIN pg_class c ON c.oid = con.conrelid
WHERE c.oid IN (
    SELECT i.inhrelid
    FROM pg_inherits i
    WHERE i.inhparent = :'parent'::regclass
)
AND NOT con.convalidated
ORDER BY c.relname, con.conname;

-- ---------------------------------------------------------------------------
\echo ''
\echo '--- [6] 트리거 잔존 확인 (부모에 0건이어야 함) ---'
-- ---------------------------------------------------------------------------
SELECT t.tgname, p.proname AS function
FROM pg_trigger t
JOIN pg_proc p ON p.oid = t.tgfoid
WHERE t.tgrelid = :'parent'::regclass
  AND NOT t.tgisinternal;

\echo ''
\echo '► 모든 항목이 정상이면 애플리케이션 쓰기를 재개하세요.'
\echo '  이상 시 06_rollback.sql 로 되돌릴 수 있습니다 (새 write 유실 주의).'
\echo ''
