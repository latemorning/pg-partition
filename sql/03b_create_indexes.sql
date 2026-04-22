-- =============================================================================
-- 03b_create_indexes.sql — 자식별 누락 인덱스 CREATE INDEX CONCURRENTLY
--                          (무중단, 트랜잭션 밖, 자동커밋)
--
-- 실행:
--   psql "$DATABASE_URL" -f params/app-prod.psql -f sql/03b_create_indexes.sql
--
-- 동작:
--   02_validate 에서 인덱스 불일치 경고가 있었던 경우에만 필요.
--   자식 A 에는 있는데 자식 B 에는 없는 인덱스를 CONCURRENTLY 로 채운다.
--   CONCURRENTLY 는 트랜잭션 블록 안에서 실행 불가 — 이 파일에는 BEGIN/COMMIT 없음.
--
-- 필수 파라미터: :parent, :partition_col
-- =============================================================================
\set ON_ERROR_STOP on

\echo ''
\echo '============================================================'
\echo ' pg-partition-migrate :: 03b CREATE MISSING INDEXES'
\echo '============================================================'
\echo ''
\echo '※ 인덱스 생성 진행 상황은 pg_stat_progress_create_index 에서 확인 가능.'
\echo ''

SELECT set_config('my.parent',        :'parent',        false);
SELECT set_config('my.partition_col', :'partition_col', false);

-- 누락 인덱스 탐지 후 CREATE INDEX CONCURRENTLY 문 생성 → \gexec 으로 실행
-- 전략: 첫 번째 자식을 기준으로 삼아, 나머지 자식에서 동등한 인덱스가 없는 경우 생성

DO $detect$
DECLARE
    v_parent    regclass := current_setting('my.parent')::regclass;
    v_col       text     := current_setting('my.partition_col');
    r_ref       record;
    r_child     record;
    r_idx       record;
    v_ref_oid   oid;
    v_ref_name  text;
    v_ref_defs  text[];
    v_child_defs text[];
    v_ref_norm  text;
    v_child_norm text;
    v_new_def   text;
    v_found     boolean;
    v_count     int := 0;
BEGIN
    -- 기준 자식 (첫 번째)
    SELECT c.oid, c.relname INTO r_ref
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    WHERE i.inhparent = v_parent
    ORDER BY c.relname
    LIMIT 1;

    IF r_ref IS NULL THEN
        RAISE NOTICE 'SKIP: 자식 없음';
        RETURN;
    END IF;

    v_ref_oid  := r_ref.oid;
    v_ref_name := r_ref.relname;

    -- 나머지 자식 순회
    FOR r_child IN
        SELECT c.oid, c.relname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = v_parent
          AND c.relname != r_ref.relname
        ORDER BY c.relname
    LOOP
        -- 기준 자식의 인덱스를 순회하며 r_child 에 없는 것 확인
        FOR r_idx IN
            SELECT ix.relname AS idx_name,
                   pg_get_indexdef(ix.oid, 0, true) AS idx_def,
                   idx.indisunique
            FROM pg_index idx
            JOIN pg_class ix ON ix.oid = idx.indexrelid
            WHERE idx.indrelid = v_ref_oid AND NOT idx.indisprimary
        LOOP
            -- 기준 인덱스를 정규화 (테이블명 → __TABLE__)
            v_ref_norm := regexp_replace(r_idx.idx_def, v_ref_name, '__TABLE__', 'g');

            -- r_child 에 동등한 인덱스가 있는지 확인
            v_found := EXISTS (
                SELECT 1
                FROM pg_index idx2
                JOIN pg_class ix2 ON ix2.oid = idx2.indexrelid
                WHERE idx2.indrelid = r_child.oid
                  AND NOT idx2.indisprimary
                  AND regexp_replace(
                          pg_get_indexdef(ix2.oid, 0, true),
                          r_child.relname, '__TABLE__', 'g'
                      ) = v_ref_norm
            );

            IF NOT v_found THEN
                -- 새 인덱스 정의: 기준 인덱스 정의에서 테이블명을 r_child 로 치환
                v_new_def := regexp_replace(
                    r_idx.idx_def,
                    'ON\s+\S+\s+USING',
                    format('ON %I USING', r_child.relname)
                );
                -- 인덱스명 제거 (PG 가 자동 생성하도록)
                v_new_def := regexp_replace(
                    v_new_def,
                    'CREATE (UNIQUE )?INDEX \S+ ON',
                    'CREATE \1INDEX CONCURRENTLY ON'
                );

                RAISE NOTICE 'MISSING INDEX on %: %', r_child.relname, v_new_def;
                v_count := v_count + 1;
            END IF;
        END LOOP;
    END LOOP;

    IF v_count = 0 THEN
        RAISE NOTICE '✓ 누락 인덱스 없음. 03c_validate_checks.sql 로 진행하세요.';
    ELSE
        RAISE NOTICE '위 % 개 인덱스 생성이 필요합니다. 이 스크립트가 자동 생성합니다.', v_count;
    END IF;
END;
$detect$;

-- 실제 CREATE INDEX CONCURRENTLY 실행 (psql \gexec 사용)
-- 아래 SELECT 가 생성하는 SQL 문을 psql 이 자동 실행함
SELECT
    regexp_replace(
        regexp_replace(
            pg_get_indexdef(ix.oid, 0, true),
            'ON\s+\S+\s+USING',
            format('ON %I USING', r_child.relname)
        ),
        'CREATE (UNIQUE )?INDEX \S+ ON',
        'CREATE \1INDEX CONCURRENTLY ON'
    ) AS create_index_sql
FROM (
    -- 기준 자식 (알파벳 첫 번째)
    SELECT c.oid AS ref_oid, c.relname AS ref_name
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    WHERE i.inhparent = :'parent'::regclass
    ORDER BY c.relname
    LIMIT 1
) ref
-- 누락 대상 자식
CROSS JOIN LATERAL (
    SELECT c.oid, c.relname
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    WHERE i.inhparent = :'parent'::regclass
      AND c.relname != ref.ref_name
) r_child(oid, relname)
-- 기준 자식의 인덱스
JOIN pg_index idx  ON idx.indrelid = ref.ref_oid AND NOT idx.indisprimary
JOIN pg_class ix   ON ix.oid = idx.indexrelid
-- r_child 에 동등한 인덱스가 없는 경우만
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_index idx2
    JOIN pg_class ix2 ON ix2.oid = idx2.indexrelid
    WHERE idx2.indrelid = r_child.oid
      AND NOT idx2.indisprimary
      AND regexp_replace(
              pg_get_indexdef(ix2.oid, 0, true),
              r_child.relname, '__TABLE__', 'g'
          ) = regexp_replace(
              pg_get_indexdef(ix.oid, 0, true),
              ref.ref_name, '__TABLE__', 'g'
          )
)
ORDER BY r_child.relname, ix.relname
\gexec

\echo ''
\echo '► 완료. 03c_validate_checks.sql 을 실행하세요.'
\echo ''
