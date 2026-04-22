-- =============================================================================
-- 03a_prepare_tx.sql — 새 선언형 부모 생성 + 인덱스 선언 + CHECK NOT VALID 추가
--                      (무중단, 단일 트랜잭션, 멱등)
--
-- 실행:
--   psql "$DATABASE_URL" -f params/app-prod.psql -f sql/03a_prepare_tx.sql
--
-- 이 스크립트 이후:
--   - <parent>_new 테이블(선언형 파티션드) 생성됨
--   - 자식 테이블마다 ck_<child>_attach CHECK (NOT VALID) 추가됨
--   - 데이터 이동/스캔 없음 — 빠름
--
-- 필수 파라미터: :parent, :partition_col, :pk_strategy, :new_suffix
-- 선택 파라미터: :default_partition (기본 true)
-- =============================================================================
\set ON_ERROR_STOP on

\if :{?default_partition}
\else
\set default_partition 'true'
\endif

\echo ''
\echo '============================================================'
\echo ' pg-partition-migrate :: 03a PREPARE (transactional)'
\echo '============================================================'
\echo ''

SELECT set_config('my.parent',           :'parent',           false);
SELECT set_config('my.partition_col',    :'partition_col',    false);
SELECT set_config('my.pk_strategy',      :'pk_strategy',      false);
SELECT set_config('my.new_suffix',       :'new_suffix',       false);
SELECT set_config('my.default_partition',:'default_partition',false);

BEGIN;
SET LOCAL lock_timeout = '5s';

DO $BODY$
DECLARE
    v_parent         regclass := current_setting('my.parent')::regclass;
    v_col            text     := current_setting('my.partition_col');
    v_pk_strategy    text     := current_setting('my.pk_strategy');
    v_new_suffix     text     := current_setting('my.new_suffix');
    v_default_part   boolean  := current_setting('my.default_partition')::boolean;

    v_schema         text;
    v_table          text;
    v_new_parent     text;      -- schema-qualified 새 부모 이름
    v_default_table  text;      -- 기본 파티션 이름

    r                record;
    v_check_def      text;
    v_matches        text[];
    v_lo             date;
    v_hi             date;
    v_lo_str         text;   -- 원본 포맷 보존 (varchar 파티션 키 대응)
    v_hi_str         text;
    v_ck_name        text;
    v_pk_cols        text[];
    v_col_defs       text;
    v_idx_def        text;
    v_new_idx_def    text;
BEGIN
    -- 스키마/테이블명 분리
    SELECT n.nspname, c.relname INTO v_schema, v_table
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = v_parent;

    v_new_parent    := format('%I.%I', v_schema, v_table || v_new_suffix);
    v_default_table := format('%I.%I', v_schema, v_table || v_new_suffix || '_default');

    -- -------------------------------------------------------------------------
    -- [1] 새 선언형 부모 테이블 생성 (존재하면 skip)
    -- -------------------------------------------------------------------------
    IF to_regclass(v_new_parent) IS NOT NULL THEN
        RAISE NOTICE 'SKIP [1] % 이미 존재', v_new_parent;
    ELSE
        EXECUTE format(
            'CREATE TABLE %s (LIKE %s INCLUDING DEFAULTS INCLUDING COMMENTS INCLUDING STORAGE) '
            'PARTITION BY RANGE (%I)',
            v_new_parent, v_parent, v_col
        );
        RAISE NOTICE 'OK   [1] % 생성 완료', v_new_parent;
    END IF;

    -- -------------------------------------------------------------------------
    -- [2] PK 전략 적용
    -- -------------------------------------------------------------------------
    -- 기존 PK 컬럼 목록 조회
    SELECT array_agg(a.attname ORDER BY u.ord) INTO v_pk_cols
    FROM pg_constraint con
    CROSS JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS u(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = u.attnum
    WHERE con.conrelid = v_parent AND con.contype = 'p';

    IF v_pk_cols IS NULL THEN
        RAISE NOTICE 'SKIP [2] 부모에 PK 없음 — pk_strategy 무관';

    ELSIF v_pk_strategy = 'composite' THEN
        -- PK 에 partition_col 이 없으면 추가
        IF NOT (v_col = ANY(v_pk_cols)) THEN
            v_pk_cols := v_pk_cols || v_col;
        END IF;
        -- 새 부모에 PK 가 없을 때만 추가
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = to_regclass(v_new_parent)
              AND contype = 'p'
        ) THEN
            EXECUTE format(
                'ALTER TABLE %s ADD PRIMARY KEY (%s)',
                v_new_parent,
                (SELECT string_agg(quote_ident(col), ', ' ORDER BY idx)
                 FROM unnest(v_pk_cols) WITH ORDINALITY AS t(col, idx))
            );
            RAISE NOTICE 'OK   [2] PK(%s) 추가 → %',
                array_to_string(v_pk_cols, ', '), v_new_parent;
        ELSE
            RAISE NOTICE 'SKIP [2] % 에 PK 이미 존재', v_new_parent;
        END IF;

    ELSIF v_pk_strategy = 'drop' THEN
        RAISE NOTICE 'INFO [2] pk_strategy=drop: 새 부모에 PK 를 생성하지 않습니다';

    ELSIF v_pk_strategy = 'partition_local' THEN
        RAISE NOTICE 'INFO [2] pk_strategy=partition_local: 자식별 PK 는 유지됩니다. 부모에는 PK 없음';
    END IF;

    -- -------------------------------------------------------------------------
    -- [3] 부모 인덱스 선언 (자식 인덱스를 기반으로, 새 부모에 아직 없는 것만)
    --     새 부모가 비어있으므로 CONCURRENTLY 불필요 — 즉시 생성
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT DISTINCT
            ix.relname                              AS idx_name,
            pg_get_indexdef(ix.oid, 0, true)        AS idx_def,
            idx.indisunique                         AS is_unique
        FROM pg_inherits i
        JOIN pg_class c   ON c.oid  = i.inhrelid
        JOIN pg_index idx ON idx.indrelid = c.oid AND NOT idx.indisprimary
        JOIN pg_class ix  ON ix.oid = idx.indexrelid
        WHERE i.inhparent = v_parent
        ORDER BY ix.relname
        LIMIT 1   -- 첫 번째 자식 기준으로 인덱스 집합 추출 (02_validate 에서 균일성 검증됨)
    LOOP
        -- 인덱스 정의에서 자식 테이블명을 새 부모명으로 치환
        -- pg_get_indexdef 결과: "CREATE INDEX idx_orders_2025_01_xxx ON public.orders_2025_01 USING ..."
        -- CREATE INDEX [UNIQUE] <name> ON <table> USING ... 형식
        -- 새 부모용으로: 테이블명 치환, 인덱스명에서 자식 접미사 제거
        -- 단순 접근: name 은 자동 생성, CREATE 만 유지
        NULL; -- [3] 는 아래 루프로 처리
    END LOOP;

    -- 첫 번째 자식의 인덱스를 기준으로 부모 인덱스 선언
    FOR r IN
        WITH first_child AS (
            SELECT c.oid AS child_oid, c.relname AS child_name
            FROM pg_inherits i
            JOIN pg_class c ON c.oid = i.inhrelid
            WHERE i.inhparent = v_parent
            ORDER BY c.relname
            LIMIT 1
        )
        SELECT
            pg_get_indexdef(ix.oid, 0, true) AS idx_def,
            idx.indisunique                  AS is_unique,
            ix.relname                       AS old_idx_name
        FROM first_child fc
        JOIN pg_index idx ON idx.indrelid = fc.child_oid AND NOT idx.indisprimary
        JOIN pg_class ix  ON ix.oid = idx.indexrelid
        ORDER BY ix.relname
    LOOP
        -- 자식 테이블명을 새 부모로 치환 (정규식: ON <schema.child> USING → ON <schema.new_parent> USING)
        v_new_idx_def := regexp_replace(
            r.idx_def,
            'ON\s+\S+\s+USING',
            format('ON %s USING', v_new_parent)
        );
        -- 인덱스명 제거 (CREATE INDEX [name] ON ... → CREATE INDEX ON ...)
        -- PG 가 자동으로 이름 부여하게 함
        v_new_idx_def := regexp_replace(
            v_new_idx_def,
            'CREATE (UNIQUE )?INDEX \S+ ON',
            'CREATE \1INDEX ON'
        );

        -- UNIQUE 인덱스: 파티션드 테이블은 파티션 키를 포함해야 함
        -- 파티션 키가 컬럼 목록에 없으면 마지막 ) 앞에 추가
        IF r.is_unique AND v_new_idx_def !~ format('\m%s\M', v_col) THEN
            v_new_idx_def := regexp_replace(
                v_new_idx_def,
                '\(([^)]+)\)(\s*)$',
                format('(\1, %I)\2', v_col)
            );
        END IF;

        -- 이미 유사한 인덱스가 있으면 skip (컬럼 expression 비교는 어려우므로 count 만 확인)
        -- 실제로는 idempotent 를 위해 run 전 확인 — 여기서는 에러 무시하는 대신 조건 체크
        BEGIN
            EXECUTE v_new_idx_def;
            RAISE NOTICE 'OK   [3] 부모 인덱스 생성: %', v_new_idx_def;
        EXCEPTION WHEN duplicate_table OR duplicate_object THEN
            RAISE NOTICE 'SKIP [3] 이미 존재하는 인덱스 skip';
        END;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- [4] 기본 파티션 생성 (default_partition = true 일 때)
    -- -------------------------------------------------------------------------
    IF v_default_part THEN
        IF to_regclass(v_default_table) IS NOT NULL THEN
            RAISE NOTICE 'SKIP [4] 기본 파티션 % 이미 존재', v_default_table;
        ELSE
            EXECUTE format(
                'CREATE TABLE %s PARTITION OF %s DEFAULT',
                v_default_table, v_new_parent
            );
            RAISE NOTICE 'OK   [4] 기본 파티션 % 생성', v_default_table;
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- [5] 각 자식에 ATTACH fast-path 용 CHECK 추가 (NOT VALID, 멱등)
    --     형식: col IS NOT NULL AND col >= 'lo' AND col < 'hi'
    --     03c_validate_checks.sql 에서 VALIDATE 함
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT c.oid, c.relname,
               (SELECT pg_get_constraintdef(con.oid, true)
                FROM pg_constraint con
                WHERE con.conrelid = c.oid
                  AND con.contype = 'c'
                  AND pg_get_constraintdef(con.oid) ~* v_col
                LIMIT 1) AS check_def
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = v_parent
        ORDER BY c.relname
    LOOP
        v_ck_name := 'ck_' || r.relname || '_attach';

        -- 이미 있으면 skip
        IF EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = r.oid AND conname = v_ck_name
        ) THEN
            RAISE NOTICE 'SKIP [5] % 이미 존재: %', r.relname, v_ck_name;
            CONTINUE;
        END IF;

        -- 기존 CHECK 에서 lo / hi 파싱 (YYYY-MM-DD / YYYYMMDD / YYYY-MM / YYYYMM / YYYYMMDDHHmmss)
        v_lo_str := NULL; v_hi_str := NULL;
        -- YYYY-MM-DD
        v_matches := regexp_matches(r.check_def,
            $re$>= '(\d{4}-\d{2}-\d{2})[^']*'[^<]*< '(\d{4}-\d{2}-\d{2})$re$);
        IF v_matches IS NOT NULL THEN
            v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
            v_lo := v_lo_str::date;   v_hi := v_hi_str::date;
        END IF;
        -- YYYYMMDDHHmmss (14자리 varchar timestamp)
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(r.check_def,
                $re$>= '(\d{14})[^']*'[^<]*< '(\d{14})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
                v_lo := to_date(left(v_lo_str, 8), 'YYYYMMDD');
                v_hi := to_date(left(v_hi_str, 8), 'YYYYMMDD');
            END IF;
        END IF;
        -- YYYYMMDD (8자리)
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(r.check_def,
                $re$>= '(\d{8})[^']*'[^<]*< '(\d{8})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
                v_lo := to_date(v_lo_str, 'YYYYMMDD');
                v_hi := to_date(v_hi_str, 'YYYYMMDD');
            END IF;
        END IF;
        -- YYYY-MM (6자리+dash)
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(r.check_def,
                $re$>= '(\d{4}-\d{2})[^']*'[^<]*< '(\d{4}-\d{2})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
                v_lo := to_date(v_lo_str, 'YYYY-MM');
                v_hi := to_date(v_hi_str, 'YYYY-MM');
            END IF;
        END IF;
        -- YYYYMM (6자리)
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(r.check_def,
                $re$>= '(\d{6})[^']*'[^<]*< '(\d{6})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
                v_lo := to_date(v_lo_str, 'YYYYMM');
                v_hi := to_date(v_hi_str, 'YYYYMM');
            END IF;
        END IF;
        -- <= 'YYYYMMDD'  (inclusive 상한 — to_char 감싸기 패턴 대응)
        --   hi_str 은 다음달 첫날 YYYYMMDD 로 변환 (exclusive 바운드용)
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(r.check_def,
                $re$>= '(\d{8})[^']*'[^<]*<= '(\d{8})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1];
                v_lo     := to_date(left(v_lo_str, 6), 'YYYYMM');
                v_hi     := (to_date(left(v_matches[2], 6), 'YYYYMM') + INTERVAL '1 month')::date;
                v_hi_str := to_char(v_hi, 'YYYYMMDD');
            END IF;
        END IF;
        -- <= 'YYYY-MM-DD'
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(r.check_def,
                $re$>= '(\d{4}-\d{2}-\d{2})[^']*'[^<]*<= '(\d{4}-\d{2}-\d{2})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1];
                v_lo     := v_lo_str::date;
                v_hi     := (date_trunc('month', v_matches[2]::date) + INTERVAL '1 month')::date;
                v_hi_str := v_hi::text;
            END IF;
        END IF;

        IF v_lo_str IS NULL THEN
            RAISE EXCEPTION
                'CHECK 파싱 실패: % / check_def: %\n02_validate.sql 를 먼저 실행하세요.',
                r.relname, r.check_def;
        END IF;

        EXECUTE format(
            'ALTER TABLE %I ADD CONSTRAINT %I CHECK ('
            '  %I IS NOT NULL AND %I >= %L AND %I < %L'
            ') NOT VALID',
            r.relname,
            v_ck_name,
            v_col, v_col, v_lo_str, v_col, v_hi_str
        );

        RAISE NOTICE 'OK   [5] % 에 % 추가 (NOT VALID, %s ~ %s)',
            r.relname, v_ck_name, v_lo, v_hi;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '✓ 03a 완료. 다음 단계:';
    RAISE NOTICE '    03b_create_indexes.sql  — 자식별 누락 인덱스 생성 (해당 시)';
    RAISE NOTICE '    03c_validate_checks.sql — CHECK NOT VALID 를 VALIDATE (오래 걸림, 온라인)';
END;
$BODY$;

COMMIT;
