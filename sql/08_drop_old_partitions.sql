-- =============================================================================
-- 08_drop_old_partitions.sql — 보존 기간 초과 자식 파티션 삭제
--
-- 실행:
--   psql "$DATABASE_URL" -f params/app-prod.psql -f sql/08_drop_old_partitions.sql
--
-- 동작:
--   자식 테이블의 CHECK 제약을 파싱하여 상한(hi)이 보존 기간 이전이면 DROP.
--   상속형(inheritance) / 선언형(declarative) 모두 지원.
--
--   dry_run = true  → DROP 하지 않고 대상 목록만 출력 (기본값)
--   dry_run = false → 실제 DROP 실행
--
-- 필수 파라미터: :parent, :partition_col
-- 선택 파라미터: :retention_years (기본 5), :dry_run (기본 true)
-- =============================================================================
\set ON_ERROR_STOP on

\if :{?retention_years}
\else
\set retention_years '5'
\endif

\if :{?dry_run}
\else
\set dry_run 'true'
\endif

\echo ''
\echo '============================================================'
\echo ' pg-partition-migrate :: 08 DROP OLD PARTITIONS'
\echo '============================================================'
\echo ''

SELECT set_config('my.parent',          :'parent',          false);
SELECT set_config('my.partition_col',   :'partition_col',   false);
SELECT set_config('my.retention_years', :'retention_years', false);
SELECT set_config('my.dry_run',         :'dry_run',         false);

DO $BODY$
DECLARE
    v_parent         regclass := current_setting('my.parent')::regclass;
    v_col            text     := current_setting('my.partition_col');
    v_retention      interval := (current_setting('my.retention_years') || ' years')::interval;
    v_dry_run        boolean  := current_setting('my.dry_run')::boolean;

    v_cutoff         date     := (CURRENT_DATE - v_retention)::date;

    r                record;
    v_check_def      text;
    v_matches        text[];
    v_hi             date;
    v_drop_count     int := 0;
    v_skip_count     int := 0;
BEGIN
    RAISE NOTICE '기준일: %, 보존 기간: %, 삭제 대상: % 이전',
        CURRENT_DATE, v_retention, v_cutoff;

    IF v_dry_run THEN
        RAISE NOTICE '[DRY RUN] 실제 DROP 은 실행되지 않습니다.';
    ELSE
        RAISE WARNING '[LIVE] 파티션을 실제로 DROP 합니다. 되돌릴 수 없습니다.';
    END IF;

    RAISE NOTICE '';

    FOR r IN
        SELECT c.oid, c.relname,
               n.nspname
        FROM pg_inherits i
        JOIN pg_class     c ON c.oid = i.inhrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE i.inhparent = v_parent
        ORDER BY c.relname
    LOOP
        -- CHECK / 바운드에서 상한 날짜 추출
        -- 지원 포맷: YYYY-MM-DD / YYYYMMDD / YYYY-MM / YYYYMM
        v_hi := NULL;

        -- 1순위: 선언형 파티션 바운드 (TO ('...'))
        SELECT pg_get_expr(c2.relpartbound, c2.oid, true) INTO v_check_def
        FROM pg_class c2
        WHERE c2.oid = r.oid AND c2.relpartbound IS NOT NULL;

        IF v_check_def IS NOT NULL THEN
            -- YYYY-MM-DD
            v_matches := regexp_matches(v_check_def, $re$TO \('(\d{4}-\d{2}-\d{2})'\)$re$);
            IF v_matches IS NOT NULL THEN v_hi := v_matches[1]::date; END IF;
            -- YYYYMMDD
            IF v_hi IS NULL THEN
                v_matches := regexp_matches(v_check_def, $re$TO \('(\d{8})'\)$re$);
                IF v_matches IS NOT NULL THEN v_hi := to_date(v_matches[1], 'YYYYMMDD'); END IF;
            END IF;
            -- YYYY-MM  (월 단위 → 해당 월 1일)
            IF v_hi IS NULL THEN
                v_matches := regexp_matches(v_check_def, $re$TO \('(\d{4}-\d{2})'\)$re$);
                IF v_matches IS NOT NULL THEN v_hi := to_date(v_matches[1], 'YYYY-MM'); END IF;
            END IF;
            -- YYYYMM
            IF v_hi IS NULL THEN
                v_matches := regexp_matches(v_check_def, $re$TO \('(\d{6})'\)$re$);
                IF v_matches IS NOT NULL THEN v_hi := to_date(v_matches[1], 'YYYYMM'); END IF;
            END IF;
        END IF;

        -- 2순위: 상속형 CHECK 제약
        IF v_hi IS NULL THEN
            SELECT pg_get_constraintdef(con.oid, true) INTO v_check_def
            FROM pg_constraint con
            WHERE con.conrelid = r.oid
              AND con.contype = 'c'
              AND pg_get_constraintdef(con.oid) ~* v_col
            ORDER BY con.conname
            LIMIT 1;

            IF v_check_def IS NOT NULL THEN
                -- < 'YYYY-MM-DD'  (exclusive)
                v_matches := regexp_matches(v_check_def, $re$< '(\d{4}-\d{2}-\d{2})$re$);
                IF v_matches IS NOT NULL THEN v_hi := v_matches[1]::date; END IF;
                -- < 'YYYYMMDDHHMMSS'  (14자리 varchar timestamp)
                IF v_hi IS NULL THEN
                    v_matches := regexp_matches(v_check_def, $re$< '(\d{14})$re$);
                    IF v_matches IS NOT NULL THEN v_hi := to_date(left(v_matches[1], 8), 'YYYYMMDD'); END IF;
                END IF;
                -- < 'YYYYMMDD'  (일(day)이 잘못된 경우 대비 — 앞 6자리 YYYYMM 만 사용)
                IF v_hi IS NULL THEN
                    v_matches := regexp_matches(v_check_def, $re$< '(\d{8})$re$);
                    IF v_matches IS NOT NULL THEN
                        v_hi := (to_date(left(v_matches[1], 6), 'YYYYMM'))::date;
                    END IF;
                END IF;
                -- < 'YYYY-MM'
                IF v_hi IS NULL THEN
                    v_matches := regexp_matches(v_check_def, $re$< '(\d{4}-\d{2})$re$);
                    IF v_matches IS NOT NULL THEN v_hi := to_date(v_matches[1], 'YYYY-MM'); END IF;
                END IF;
                -- < 'YYYYMM'
                IF v_hi IS NULL THEN
                    v_matches := regexp_matches(v_check_def, $re$< '(\d{6})$re$);
                    IF v_matches IS NOT NULL THEN v_hi := to_date(v_matches[1], 'YYYYMM'); END IF;
                END IF;
                -- <= 'YYYY-MM-DD'  (inclusive → +1일)
                IF v_hi IS NULL THEN
                    v_matches := regexp_matches(v_check_def, $re$<= '(\d{4}-\d{2}-\d{2})$re$);
                    IF v_matches IS NOT NULL THEN v_hi := v_matches[1]::date + 1; END IF;
                END IF;
                -- <= 'YYYYMMDD'  (일(day)이 잘못된 경우 대비 — 앞 6자리 YYYYMM 으로 다음달 첫날)
                IF v_hi IS NULL THEN
                    v_matches := regexp_matches(v_check_def, $re$<= '(\d{8})$re$);
                    IF v_matches IS NOT NULL THEN
                        v_hi := (to_date(left(v_matches[1], 6), 'YYYYMM') + INTERVAL '1 month')::date;
                    END IF;
                END IF;
                -- <= 'YYYYMM'  (inclusive 월 → 다음달 첫날)
                IF v_hi IS NULL THEN
                    v_matches := regexp_matches(v_check_def, $re$<= '(\d{6})$re$);
                    IF v_matches IS NOT NULL THEN v_hi := (to_date(v_matches[1], 'YYYYMM') + INTERVAL '1 month')::date; END IF;
                END IF;
            END IF;
        END IF;

        -- 3순위: 테이블명에서 날짜 추출 (CHECK/바운드 없는 경우 폴백)
        -- 지원 패턴: _YYYYMM / _YYYYMMDD / _YYYYyMMm (예: swap_hist_202612, pt_2026y12m)
        IF v_hi IS NULL THEN
            -- _YYYYyMMm  (예: pt_2026y12m → 2026-12)
            v_matches := regexp_matches(r.relname, $re$_(\d{4})y(\d{2})m$re$);
            IF v_matches IS NOT NULL THEN
                v_hi := (to_date(v_matches[1] || v_matches[2], 'YYYYMM') + INTERVAL '1 month')::date;
            END IF;
            -- _YYYYMMDD  (예: _20261201)
            IF v_hi IS NULL THEN
                v_matches := regexp_matches(r.relname, $re$_(\d{8})$re$);
                IF v_matches IS NOT NULL THEN
                    v_hi := (to_date(v_matches[1], 'YYYYMMDD') + INTERVAL '1 month')::date;
                END IF;
            END IF;
            -- _YYYYMM  (예: _202612)
            IF v_hi IS NULL THEN
                v_matches := regexp_matches(r.relname, $re$_(\d{6})$re$);
                IF v_matches IS NOT NULL THEN
                    v_hi := (to_date(v_matches[1], 'YYYYMM') + INTERVAL '1 month')::date;
                END IF;
            END IF;
            IF v_hi IS NOT NULL THEN
                RAISE NOTICE 'INFO %  — 테이블명에서 날짜 추출 (상한: %)', r.relname, v_hi;
            END IF;
        END IF;

        IF v_hi IS NULL THEN
            RAISE NOTICE 'SKIP %  — 날짜 범위를 파싱할 수 없음 (수동 확인 필요)', r.relname;
            v_skip_count := v_skip_count + 1;
            CONTINUE;
        END IF;

        IF v_hi > v_cutoff THEN
            RAISE NOTICE 'KEEP %  (상한: %)', r.relname, v_hi;
            CONTINUE;
        END IF;

        -- 삭제 대상
        IF v_dry_run THEN
            RAISE NOTICE 'DROP % (상한: %) [DRY RUN]', r.relname, v_hi;
        ELSE
            -- 선언형이면 DETACH 후 DROP, 상속형이면 바로 DROP
            IF EXISTS (
                SELECT 1 FROM pg_class c2
                WHERE c2.oid = r.oid AND c2.relpartbound IS NOT NULL
            ) THEN
                EXECUTE format(
                    'ALTER TABLE %s DETACH PARTITION %I CONCURRENTLY',
                    v_parent, r.relname
                );
            END IF;

            EXECUTE format('DROP TABLE %I.%I', r.nspname, r.relname);
            RAISE NOTICE 'OK   DROP % (상한: %)', r.relname, v_hi;
        END IF;

        v_drop_count := v_drop_count + 1;
    END LOOP;

    RAISE NOTICE '';
    RAISE NOTICE '결과: DROP 대상 % 개 / SKIP % 개 (범위 불명)', v_drop_count, v_skip_count;

    IF v_dry_run AND v_drop_count > 0 THEN
        RAISE NOTICE '실제 삭제하려면: \set dry_run false 후 재실행';
    END IF;
END;
$BODY$;

\echo ''
\echo '► 완료.'
\echo ''
