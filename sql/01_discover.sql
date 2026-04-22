-- =============================================================================
-- 01_discover.sql — 현재 상속형 파티션 구조 조회 (읽기 전용, 무중단)
--
-- 실행:
--   psql "$DATABASE_URL" -f params/app-prod.psql -f sql/01_discover.sql
--
-- 필수 파라미터: :parent, :partition_col
-- =============================================================================
\set ON_ERROR_STOP on

\echo ''
\echo '============================================================'
\echo ' pg-partition-migrate :: 01 DISCOVER'
\echo '============================================================'
\echo ''

-- ---------------------------------------------------------------------------
\echo '--- [1] 자식 테이블 목록 및 CHECK 제약 ---'
-- ---------------------------------------------------------------------------
SELECT
    c.relname                               AS child_table,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    (SELECT pg_get_constraintdef(con.oid, true)
     FROM pg_constraint con
     WHERE con.conrelid = c.oid
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) ~* :'partition_col'
     LIMIT 1)                               AS range_check
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = :'parent'::regclass
ORDER BY c.relname;

-- ---------------------------------------------------------------------------
\echo ''
\echo '--- [2] 자식별 인덱스 정의 ---'
-- ---------------------------------------------------------------------------
SELECT
    c.relname                       AS child_table,
    ix.relname                      AS index_name,
    pg_get_indexdef(ix.oid, 0, true) AS index_def
FROM pg_inherits i
JOIN pg_class c  ON c.oid  = i.inhrelid
JOIN pg_index idx ON idx.indrelid = c.oid
JOIN pg_class ix  ON ix.oid = idx.indexrelid
WHERE i.inhparent = :'parent'::regclass
  AND NOT idx.indisprimary          -- PK 는 [4] 에서 별도 표시
ORDER BY c.relname, ix.relname;

-- ---------------------------------------------------------------------------
\echo ''
\echo '--- [3] 부모 테이블의 BEFORE INSERT 트리거 ---'
-- ---------------------------------------------------------------------------
SELECT
    t.tgname                                    AS trigger_name,
    p.proname                                   AS function_name,
    n.nspname || '.' || p.proname || '()'       AS function_oid_text,
    CASE t.tgenabled
        WHEN 'O' THEN 'ENABLED'
        WHEN 'D' THEN 'DISABLED'
        ELSE t.tgenabled::text
    END                                         AS status
FROM pg_trigger t
JOIN pg_proc p      ON p.oid  = t.tgfoid
JOIN pg_namespace n ON n.oid  = p.pronamespace
WHERE t.tgrelid = :'parent'::regclass
  AND t.tgtype & 2 = 2      -- BEFORE
  AND t.tgtype & 4 = 4      -- INSERT
  AND NOT t.tgisinternal
ORDER BY t.tgname;

-- ---------------------------------------------------------------------------
\echo ''
\echo '--- [4] 부모 테이블의 PK / UNIQUE 제약 ---'
-- ---------------------------------------------------------------------------
SELECT
    con.conname                                     AS constraint_name,
    CASE con.contype
        WHEN 'p' THEN 'PRIMARY KEY'
        WHEN 'u' THEN 'UNIQUE'
    END                                             AS type,
    array_agg(a.attname ORDER BY u.ord)             AS columns,
    CASE WHEN bool_or(a.attname = :'partition_col')
         THEN '✓ partition_col included'
         ELSE '✗ partition_col NOT included — pk_strategy required'
    END                                             AS partition_col_check
FROM pg_constraint con
JOIN pg_class cl ON cl.oid = con.conrelid
CROSS JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS u(attnum, ord)
JOIN pg_attribute a ON a.attrelid = cl.oid AND a.attnum = u.attnum
WHERE con.conrelid = :'parent'::regclass
  AND con.contype IN ('p', 'u')
GROUP BY con.conname, con.contype
ORDER BY con.contype, con.conname;

-- ---------------------------------------------------------------------------
\echo ''
\echo '--- [5] 시퀀스 / IDENTITY 컬럼 ---'
-- ---------------------------------------------------------------------------
SELECT
    a.attname                                   AS column_name,
    CASE a.attidentity
        WHEN 'a' THEN 'ALWAYS'
        WHEN 'd' THEN 'BY DEFAULT'
        ELSE NULL
    END                                         AS identity,
    pg_get_serial_sequence(:'parent', a.attname) AS linked_sequence
FROM pg_attribute a
WHERE a.attrelid = :'parent'::regclass
  AND a.attnum > 0
  AND NOT a.attisdropped
  AND (
      a.attidentity IS NOT NULL AND a.attidentity != ''
      OR pg_get_serial_sequence(:'parent', a.attname) IS NOT NULL
  )
ORDER BY a.attnum;

-- ---------------------------------------------------------------------------
\echo ''
\echo '--- [6] 요약 ---'
-- ---------------------------------------------------------------------------
SELECT
    (SELECT count(*) FROM pg_inherits WHERE inhparent = :'parent'::regclass)  AS child_count,
    (SELECT count(*) FROM pg_trigger
     WHERE tgrelid = :'parent'::regclass
       AND tgtype & 6 = 6            -- BEFORE INSERT
       AND NOT tgisinternal)         AS insert_trigger_count,
    pg_size_pretty(
        (SELECT sum(pg_total_relation_size(inhrelid))
         FROM pg_inherits
         WHERE inhparent = :'parent'::regclass)
    )                                                                          AS total_data_size;

\echo ''
\echo '► 위 결과를 확인한 후 02_validate.sql 을 실행하세요.'
\echo ''
