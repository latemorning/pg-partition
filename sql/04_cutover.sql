-- =============================================================================
-- 04_cutover.sql — 점검창 실행 스크립트 (단일 트랜잭션)
--
-- 실행 (애플리케이션 쓰기 중단 후):
--   psql "$DATABASE_URL" -f params/app-prod.psql -f sql/04_cutover.sql
--
-- 순서:
--   1. BEFORE INSERT 트리거 DROP
--   2. 각 자식: NO INHERIT → ATTACH PARTITION (메타데이터만, 빠름)
--   3. RENAME 스왑: <parent> → <parent>_legacy, <parent>_new → <parent>
--   4. 시퀀스 소유권 재지정
--   5. 미래 파티션 생성 (future_months 개월치)
--
-- lock_timeout 초과 시 트랜잭션 자동 롤백 — 원상 복구됨
--
-- 필수 파라미터: :parent, :partition_col, :new_suffix, :legacy_suffix
-- 선택 파라미터: :lock_timeout (기본 5s), :stmt_timeout (기본 10min), :future_months (기본 3)
-- =============================================================================
\set ON_ERROR_STOP on

\if :{?lock_timeout}
\else
\set lock_timeout '5s'
\endif

\if :{?stmt_timeout}
\else
\set stmt_timeout '10min'
\endif

\if :{?future_months}
\else
\set future_months '3'
\endif

\echo ''
\echo '============================================================'
\echo ' pg-partition-migrate :: 04 CUTOVER'
\echo '============================================================'
\echo ''
\echo '⚠ 이 스크립트는 점검창 안에서 실행하세요.'
\echo '⚠ 애플리케이션의 쓰기가 중단된 상태여야 합니다.'
\echo ''

SELECT set_config('my.parent',        :'parent',        false);
SELECT set_config('my.partition_col', :'partition_col', false);
SELECT set_config('my.new_suffix',    :'new_suffix',    false);
SELECT set_config('my.legacy_suffix', :'legacy_suffix', false);
SELECT set_config('my.lock_timeout',  :'lock_timeout',  false);
SELECT set_config('my.stmt_timeout',  :'stmt_timeout',  false);
SELECT set_config('my.future_months', :'future_months', false);

BEGIN;

-- 세션 안전장치: 잠금 대기로 전체 DB 가 묶이는 사고 방지
SELECT set_config('lock_timeout',    current_setting('my.lock_timeout'),  true);
SELECT set_config('statement_timeout', current_setting('my.stmt_timeout'), true);

DO $BODY$
DECLARE
    v_parent        regclass := current_setting('my.parent')::regclass;
    v_col           text     := current_setting('my.partition_col');
    v_new_suffix    text     := current_setting('my.new_suffix');
    v_legacy_suffix text     := current_setting('my.legacy_suffix');
    v_future_months int      := current_setting('my.future_months')::int;

    v_schema        text;
    v_table         text;
    v_new_parent    text;
    v_legacy_name   text;

    r               record;
    r2              record;
    v_check_def     text;
    v_matches       text[];
    v_lo            date;
    v_hi            date;
    v_lo_str        text;   -- 원본 포맷 보존 (varchar 파티션 키 대응)
    v_hi_str        text;
    v_max_hi_str    text;   -- 최대 상한 원본 문자열 (미래 파티션 포맷 결정용)
    v_trigger_name  text;
    v_seq           text;
    v_cur_month     date;
    v_part_name     text;
    v_child_count   int := 0;
    v_max_hi        date;
BEGIN
    -- 스키마/테이블명 분리
    SELECT n.nspname, c.relname INTO v_schema, v_table
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = v_parent;

    v_new_parent  := format('%I.%I', v_schema, v_table || v_new_suffix);
    v_legacy_name := v_table || v_legacy_suffix;

    -- 새 부모 존재 확인
    IF to_regclass(v_new_parent) IS NULL THEN
        RAISE EXCEPTION
            '% 가 없습니다. 03a_prepare_tx.sql 을 먼저 실행하세요.', v_new_parent;
    END IF;

    -- -------------------------------------------------------------------------
    -- [1] BEFORE INSERT 라우팅 트리거 DROP
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT t.tgname
        FROM pg_trigger t
        WHERE t.tgrelid = v_parent
          AND t.tgtype & 2 = 2   -- BEFORE
          AND t.tgtype & 4 = 4   -- INSERT
          AND NOT t.tgisinternal
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', r.tgname, v_parent);
        RAISE NOTICE 'OK   [1] 트리거 % DROP 완료', r.tgname;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- [2] 각 자식: NO INHERIT + ATTACH PARTITION
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT c.oid, c.relname,
               (SELECT pg_get_constraintdef(con.oid, true)
                FROM pg_constraint con
                WHERE con.conrelid = c.oid
                  AND con.contype = 'c'
                  AND con.conname LIKE 'ck_%_attach'   -- 정규화된 CHECK 우선 사용
                ORDER BY con.conname
                LIMIT 1) AS attach_check,
               (SELECT pg_get_constraintdef(con.oid, true)
                FROM pg_constraint con
                WHERE con.conrelid = c.oid
                  AND con.contype = 'c'
                  AND pg_get_constraintdef(con.oid) ~* v_col
                ORDER BY con.conname
                LIMIT 1) AS any_check
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = v_parent
        ORDER BY c.relname
    LOOP
        v_check_def := coalesce(r.attach_check, r.any_check);

        IF v_check_def IS NULL THEN
            RAISE EXCEPTION
                '자식 % 에서 CHECK 를 찾을 수 없습니다. 03a, 03c 를 먼저 실행하세요.',
                r.relname;
        END IF;

        -- CHECK 에서 lo / hi 파싱 (YYYY-MM-DD / YYYYMMDD / YYYY-MM / YYYYMM / YYYYMMDDHHmmss)
        v_lo_str := NULL; v_hi_str := NULL;
        -- YYYY-MM-DD
        v_matches := regexp_matches(v_check_def,
            $re$>= '(\d{4}-\d{2}-\d{2})[^']*'[^<]*< '(\d{4}-\d{2}-\d{2})$re$);
        IF v_matches IS NOT NULL THEN
            v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
            v_lo := v_lo_str::date;   v_hi := v_hi_str::date;
        END IF;
        -- YYYYMMDDHHmmss (14자리 varchar timestamp)
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(v_check_def,
                $re$>= '(\d{14})[^']*'[^<]*< '(\d{14})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
                v_lo := to_date(left(v_lo_str, 8), 'YYYYMMDD');
                v_hi := to_date(left(v_hi_str, 8), 'YYYYMMDD');
            END IF;
        END IF;
        -- YYYYMMDD (8자리)
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(v_check_def,
                $re$>= '(\d{8})[^']*'[^<]*< '(\d{8})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
                v_lo := to_date(v_lo_str, 'YYYYMMDD');
                v_hi := to_date(v_hi_str, 'YYYYMMDD');
            END IF;
        END IF;
        -- YYYY-MM
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(v_check_def,
                $re$>= '(\d{4}-\d{2})[^']*'[^<]*< '(\d{4}-\d{2})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
                v_lo := to_date(v_lo_str, 'YYYY-MM');
                v_hi := to_date(v_hi_str, 'YYYY-MM');
            END IF;
        END IF;
        -- YYYYMM (6자리)
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(v_check_def,
                $re$>= '(\d{6})[^']*'[^<]*< '(\d{6})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
                v_lo := to_date(v_lo_str, 'YYYYMM');
                v_hi := to_date(v_hi_str, 'YYYYMM');
            END IF;
        END IF;
        -- <= 'YYYYMMDD'  (inclusive 상한 — to_char 감싸기 패턴 대응)
        --   hi_str 은 다음달 첫날 YYYYMMDD 로 변환 (ATTACH 바운드 exclusive 용)
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(v_check_def,
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
            v_matches := regexp_matches(v_check_def,
                $re$>= '(\d{4}-\d{2}-\d{2})[^']*'[^<]*<= '(\d{4}-\d{2}-\d{2})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1];
                v_lo     := v_lo_str::date;
                v_hi     := (date_trunc('month', v_matches[2]::date) + INTERVAL '1 month')::date;
                v_hi_str := v_hi::text;
            END IF;
        END IF;

        IF v_lo_str IS NULL THEN
            RAISE EXCEPTION 'CHECK 파싱 실패: % / %', r.relname, v_check_def;
        END IF;

        -- 상속 해제
        EXECUTE format('ALTER TABLE %I NO INHERIT %s', r.relname, v_parent);

        -- ATTACH 전 자식 PK 제거 (부모 PK 가 전파되므로 중복 불허)
        FOR r2 IN
            SELECT con.conname
            FROM pg_constraint con
            WHERE con.conrelid = r.oid AND con.contype = 'p'
        LOOP
            EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I', r.relname, r2.conname);
        END LOOP;

        -- ATTACH 전 파티션 키 NOT NULL 보장 (RANGE 파티션 필수 조건)
        -- 기존 CHECK 가 NULL 을 배제하지 않으므로 명시적으로 추가
        EXECUTE format('ALTER TABLE %I ALTER COLUMN %I SET NOT NULL', r.relname, v_col);

        -- 선언형 부모에 ATTACH (원본 포맷 그대로 사용)
        EXECUTE format(
            'ALTER TABLE %s ATTACH PARTITION %I FOR VALUES FROM (%L) TO (%L)',
            v_new_parent, r.relname, v_lo_str, v_hi_str
        );

        RAISE NOTICE 'OK   [2] % → ATTACH (%s ~ %s)', r.relname, v_lo_str, v_hi_str;
        v_child_count := v_child_count + 1;

        -- 최대 상한 추적 (미래 파티션 시작점 + 포맷 보존)
        IF v_max_hi IS NULL OR v_hi > v_max_hi THEN
            v_max_hi     := v_hi;
            v_max_hi_str := v_hi_str;
        END IF;
    END LOOP;

    RAISE NOTICE 'INFO [2] 총 % 개 자식 ATTACH 완료', v_child_count;

    -- -------------------------------------------------------------------------
    -- [3] RENAME 스왑
    -- -------------------------------------------------------------------------
    EXECUTE format('ALTER TABLE %s RENAME TO %I', v_parent,     v_legacy_name);
    EXECUTE format('ALTER TABLE %s RENAME TO %I', v_new_parent, v_table);

    RAISE NOTICE 'OK   [3] % → %, % → %',
        v_table, v_legacy_name,
        v_table || v_new_suffix, v_table;

    -- -------------------------------------------------------------------------
    -- [4] 시퀀스 소유권 재지정
    --     SERIAL/BIGSERIAL 시퀀스가 legacy 이름에 연결되어 있으면 새 부모로 교체
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT a.attname AS col_name,
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
            r.seq_name, v_schema, v_table, r.col_name
        );
        RAISE NOTICE 'OK   [4] 시퀀스 % 소유권 → %.%',
            r.seq_name, v_table, r.col_name;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- [5] 미래 파티션 생성 (future_months 개월)
    -- -------------------------------------------------------------------------
    IF v_future_months > 0 AND v_max_hi IS NOT NULL THEN
        v_cur_month := v_max_hi;
        FOR i IN 1..v_future_months LOOP
            v_part_name := format('%I.%I',
                v_schema,
                v_table || '_' || to_char(v_cur_month, 'YYYY_MM')
            );

            IF to_regclass(v_part_name) IS NOT NULL THEN
                RAISE NOTICE 'SKIP [5] % 이미 존재', v_part_name;
            ELSE
                EXECUTE format(
                    'CREATE TABLE %s PARTITION OF %I.%I '
                    'FOR VALUES FROM (%L) TO (%L)',
                    v_part_name, v_schema, v_table,
                    CASE
                        WHEN v_max_hi_str ~ '^\d{14}$'      THEN to_char(v_cur_month, 'YYYYMMDD') || '000000'
                        WHEN v_max_hi_str ~ '^\d{8}$'       THEN to_char(v_cur_month, 'YYYYMMDD')
                        WHEN v_max_hi_str ~ '^\d{4}-\d{2}$' THEN to_char(v_cur_month, 'YYYY-MM')
                        WHEN v_max_hi_str ~ '^\d{6}$'       THEN to_char(v_cur_month, 'YYYYMM')
                        ELSE v_cur_month::text  -- YYYY-MM-DD (기본)
                    END,
                    CASE
                        WHEN v_max_hi_str ~ '^\d{14}$'      THEN to_char((v_cur_month + INTERVAL '1 month')::date, 'YYYYMMDD') || '000000'
                        WHEN v_max_hi_str ~ '^\d{8}$'       THEN to_char((v_cur_month + INTERVAL '1 month')::date, 'YYYYMMDD')
                        WHEN v_max_hi_str ~ '^\d{4}-\d{2}$' THEN to_char((v_cur_month + INTERVAL '1 month')::date, 'YYYY-MM')
                        WHEN v_max_hi_str ~ '^\d{6}$'       THEN to_char((v_cur_month + INTERVAL '1 month')::date, 'YYYYMM')
                        ELSE ((v_cur_month + INTERVAL '1 month')::date)::text
                    END
                );
                RAISE NOTICE 'OK   [5] 미래 파티션 % 생성 (%s ~ %s)',
                    v_part_name, v_cur_month,
                    (v_cur_month + INTERVAL '1 month')::date;
            END IF;

            v_cur_month := (v_cur_month + INTERVAL '1 month')::date;
        END LOOP;
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE '✓ 커트오버 완료! 트랜잭션 COMMIT 중...';
    RAISE NOTICE '  이후: 05_verify.sql 로 검증 후 애플리케이션 쓰기 재개';
END;
$BODY$;

COMMIT;

\echo ''
\echo '► COMMIT 완료. 애플리케이션 쓰기 재개 전에 05_verify.sql 을 실행하세요.'
\echo ''
