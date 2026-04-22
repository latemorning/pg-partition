-- =============================================================================
-- 02_validate.sql — 마이그레이션 사전 검증 (읽기 전용, 무중단)
--
-- 실행:
--   psql "$DATABASE_URL" -f params/app-prod.psql -f sql/02_validate.sql
--
-- 문제 발견 시 RAISE EXCEPTION 으로 중단. 모두 통과하면 다음 단계로 진행.
-- 필수 파라미터: :parent, :partition_col, :pk_strategy
-- 선택 파라미터: :strict_index_parity (기본 false)
-- =============================================================================
\set ON_ERROR_STOP on

-- 선택 파라미터 기본값
\if :{?strict_index_parity}
\else
\set strict_index_parity 'false'
\endif

\echo ''
\echo '============================================================'
\echo ' pg-partition-migrate :: 02 VALIDATE'
\echo '============================================================'
\echo ''

-- psql 변수를 pg session 설정으로 전달 (DO 블록 내부에서 사용)
SELECT set_config('my.parent',              :'parent',              false);
SELECT set_config('my.partition_col',       :'partition_col',       false);
SELECT set_config('my.pk_strategy',         :'pk_strategy',         false);
SELECT set_config('my.strict_index_parity', :'strict_index_parity', false);

DO $BODY$
DECLARE
    v_parent            regclass := current_setting('my.parent')::regclass;
    v_col               text     := current_setting('my.partition_col');
    v_pk_strategy       text     := current_setting('my.pk_strategy');
    v_strict_idx        boolean  := current_setting('my.strict_index_parity')::boolean;

    v_errors            text[]   := '{}';
    v_warnings          text[]   := '{}';

    r                   record;
    v_prev_hi           date;
    v_lo                date;
    v_hi                date;
    v_lo_str            text;
    v_hi_str            text;
    v_matches           text[];
    v_check_def         text;
    v_child_count       int;

    -- 인덱스 정규화용
    v_ref_indexes       text[];
    v_child_indexes     text[];
    v_norm_def          text;
    v_ref_child         text;
BEGIN
    -- -------------------------------------------------------------------------
    -- [1] 자식 존재 여부
    -- -------------------------------------------------------------------------
    SELECT count(*) INTO v_child_count
    FROM pg_inherits
    WHERE inhparent = v_parent;

    IF v_child_count = 0 THEN
        RAISE EXCEPTION 'FAIL: 부모 테이블 % 에 상속 자식이 없습니다.', v_parent;
    END IF;
    RAISE NOTICE 'OK  [1] 자식 테이블 % 개 발견', v_child_count;

    -- -------------------------------------------------------------------------
    -- [2] pk_strategy 값 검증
    -- -------------------------------------------------------------------------
    IF v_pk_strategy NOT IN ('composite', 'drop', 'partition_local') THEN
        RAISE EXCEPTION
            E'FAIL: pk_strategy 값이 잘못됐거나 설정되지 않았습니다.\n'
            '  현재 값: "%"\n'
            '  허용값: composite | drop | partition_local\n'
            '  composite  — PK(id) 를 PK(id, %) 로 변경 (권장)\n'
            '  drop       — PK 제거 (주의: 애플리케이션 영향 확인)\n'
            '  partition_local — 부모 PK 없이 자식별 PK 유지',
            v_pk_strategy, v_col;
    END IF;
    RAISE NOTICE 'OK  [2] pk_strategy = "%"', v_pk_strategy;

    -- -------------------------------------------------------------------------
    -- [3] PK/UNIQUE 에 partition_col 포함 여부
    -- -------------------------------------------------------------------------
    FOR r IN
        SELECT con.conname,
               CASE con.contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'u' THEN 'UNIQUE' END AS ctype,
               bool_or(a.attname = v_col) AS has_partition_col
        FROM pg_constraint con
        CROSS JOIN LATERAL unnest(con.conkey) AS u(attnum)
        JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = u.attnum
        WHERE con.conrelid = v_parent
          AND con.contype IN ('p', 'u')
        GROUP BY con.conname, con.contype
    LOOP
        IF NOT r.has_partition_col THEN
            IF v_pk_strategy = 'composite' THEN
                -- composite 전략이면 03a 에서 추가하므로 경고만
                v_warnings := v_warnings || format(
                    'WARN [3] %s %s 에 파티션 컬럼(%s) 미포함 → pk_strategy=composite 으로 03a 에서 추가됩니다',
                    r.ctype, r.conname, v_col
                );
            ELSE
                v_warnings := v_warnings || format(
                    'WARN [3] %s %s 에 파티션 컬럼(%s) 미포함. pk_strategy=%s 선택됨 — 의도 확인 필요',
                    r.ctype, r.conname, v_col, v_pk_strategy
                );
            END IF;
        END IF;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- [4] 각 자식 CHECK 파싱 및 월 경계 / overlap / gap 검증
    -- -------------------------------------------------------------------------
    v_prev_hi := NULL;

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
        IF r.check_def IS NULL THEN
            v_errors := v_errors || format(
                'FAIL [4] 자식 %s 에 파티션 컬럼(%s) 기반 CHECK 제약이 없습니다',
                r.relname, v_col
            );
            CONTINUE;
        END IF;

        -- 날짜 파싱 (YYYY-MM-DD / YYYYMMDDHHmmss / YYYYMMDD / YYYY-MM / YYYYMM)
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
        -- YYYY-MM
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
        -- <= 'YYYYMMDD'  (inclusive 상한 — to_char(col,...) >= 'lo' AND to_char(col,...) <= 'hi' 형식)
        --   일(day) 오류 대비: YYYYMM 앞 6자리만 사용, hi = 다음달 첫날
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(r.check_def,
                $re$>= '(\d{8})[^']*'[^<]*<= '(\d{8})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
                v_lo := to_date(left(v_lo_str, 6), 'YYYYMM');
                v_hi := (to_date(left(v_hi_str, 6), 'YYYYMM') + INTERVAL '1 month')::date;
            END IF;
        END IF;
        -- <= 'YYYY-MM-DD'
        IF v_lo_str IS NULL THEN
            v_matches := regexp_matches(r.check_def,
                $re$>= '(\d{4}-\d{2}-\d{2})[^']*'[^<]*<= '(\d{4}-\d{2}-\d{2})$re$);
            IF v_matches IS NOT NULL THEN
                v_lo_str := v_matches[1]; v_hi_str := v_matches[2];
                v_lo := v_lo_str::date;
                v_hi := (date_trunc('month', v_hi_str::date) + INTERVAL '1 month')::date;
            END IF;
        END IF;

        IF v_lo_str IS NULL THEN
            v_errors := v_errors || format(
                E'FAIL [4] 자식 %s 의 CHECK 를 파싱할 수 없습니다.\n'
                '  CHECK: %s\n'
                '  지원 형식: YYYY-MM-DD / YYYYMMDD / YYYYMMDDHHmmss / YYYY-MM / YYYYMM\n'
                '           (상한: < 또는 <= 모두 지원)',
                r.relname, r.check_def
            );
            CONTINUE;
        END IF;

        -- 월 단위 경계 확인 (lo = 월 첫째 날, hi = 다음 달 첫째 날)
        IF EXTRACT(DAY FROM v_lo) != 1 THEN
            v_errors := v_errors || format(
                'FAIL [4] 자식 %s 의 하한(%s) 이 월 첫째 날이 아닙니다', r.relname, v_lo
            );
        END IF;

        IF v_hi != (date_trunc('month', v_lo) + INTERVAL '1 month')::date THEN
            v_errors := v_errors || format(
                'FAIL [4] 자식 %s 의 범위(%s ~ %s) 가 정확히 1개월이 아닙니다',
                r.relname, v_lo, v_hi
            );
        END IF;

        -- gap / overlap 확인
        IF v_prev_hi IS NOT NULL THEN
            IF v_lo < v_prev_hi THEN
                v_errors := v_errors || format(
                    'FAIL [4] 자식 %s 의 하한(%s) 이 이전 자식의 상한(%s) 보다 앞입니다 — 범위 겹침',
                    r.relname, v_lo, v_prev_hi
                );
            ELSIF v_lo > v_prev_hi THEN
                v_warnings := v_warnings || format(
                    'WARN [4] 자식 %s 의 하한(%s) 과 이전 자식 상한(%s) 사이에 빈 기간이 있습니다',
                    r.relname, v_lo, v_prev_hi
                );
            END IF;
        END IF;

        v_prev_hi := v_hi;
    END LOOP;

    -- -------------------------------------------------------------------------
    -- [5] 인덱스 정의 균일성 검사
    --     자식 A 에 있는 인덱스가 자식 B 에 없으면 ATTACH 시 부모 인덱스를 블로킹 빌드
    -- -------------------------------------------------------------------------
    -- 첫 번째 자식의 인덱스를 기준으로 삼아 나머지와 비교 (정규화: 테이블명 → __TABLE__)
    SELECT c.relname INTO v_ref_child
    FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
    WHERE i.inhparent = v_parent
    ORDER BY c.relname
    LIMIT 1;

    IF v_ref_child IS NOT NULL THEN
        SELECT array_agg(
            regexp_replace(pg_get_indexdef(ix.oid, 0, true), v_ref_child, '__TABLE__', 'g')
            ORDER BY ix.relname
        ) INTO v_ref_indexes
        FROM pg_index idx
        JOIN pg_class t  ON t.oid  = idx.indrelid
        JOIN pg_class ix ON ix.oid = idx.indexrelid
        WHERE t.relname = v_ref_child
          AND NOT idx.indisprimary;

        FOR r IN
            SELECT c.relname
            FROM pg_inherits i
            JOIN pg_class c ON c.oid = i.inhrelid
            WHERE i.inhparent = v_parent
              AND c.relname != v_ref_child
            ORDER BY c.relname
        LOOP
            SELECT array_agg(
                regexp_replace(pg_get_indexdef(ix.oid, 0, true), r.relname, '__TABLE__', 'g')
                ORDER BY ix.relname
            ) INTO v_child_indexes
            FROM pg_index idx
            JOIN pg_class t  ON t.oid  = idx.indrelid
            JOIN pg_class ix ON ix.oid = idx.indexrelid
            WHERE t.relname = r.relname
              AND NOT idx.indisprimary;

            IF v_ref_indexes IS DISTINCT FROM v_child_indexes THEN
                v_norm_def := format(
                    'WARN [5] 자식 %s 의 인덱스가 기준(%s) 과 다릅니다.'
                    ' 기준: %s / 자식: %s',
                    r.relname, v_ref_child,
                    v_ref_indexes::text, v_child_indexes::text
                );
                IF v_strict_idx THEN
                    v_errors := v_errors || replace(v_norm_def, 'WARN', 'FAIL');
                ELSE
                    v_warnings := v_warnings || v_norm_def;
                END IF;
            END IF;
        END LOOP;
    END IF;

    -- -------------------------------------------------------------------------
    -- 결과 출력
    -- -------------------------------------------------------------------------
    DECLARE
        w text;
        e text;
    BEGIN
        FOREACH w IN ARRAY v_warnings LOOP
            RAISE WARNING '%', w;
        END LOOP;

        IF array_length(v_errors, 1) > 0 THEN
            FOREACH e IN ARRAY v_errors LOOP
                RAISE WARNING '%', e;
            END LOOP;
            RAISE EXCEPTION
                E'\n검증 실패: 위 % 개 오류를 해결한 후 재실행하세요.',
                array_length(v_errors, 1);
        END IF;
    END;

    RAISE NOTICE '';
    RAISE NOTICE '✓ 모든 검증 통과 (경고 % 개). 03a_prepare_tx.sql 을 실행하세요.',
        coalesce(array_length(v_warnings, 1), 0);
END;
$BODY$;
