# pg-partition-migrate

PostgreSQL 상속형 파티션 → 선언형 파티션 마이그레이션 스크립트

데이터 이동 없이 ATTACH PARTITION 방식으로 전환. 수 분 점검창 안에 완료 가능.

---

## 전제 조건

- PostgreSQL 14+
- 파티션 키: 날짜 컬럼, 월 단위 RANGE
- 기존 구조: 부모 테이블 + 자식 테이블 + BEFORE INSERT 라우팅 트리거

---

## 빠른 시작

```bash
# 1. DB 접속 정보 환경변수로 설정 (스크립트에는 절대 기록 금지)
export DATABASE_URL="postgresql://user:password@host:5432/dbname"

# 2. DB별 파라미터 파일 준비
cp params/app-prod.example.psql params/my-db.psql
# params/my-db.psql 에서 parent, partition_col, pk_strategy 등 수정

# 3. 단계별 실행
psql "$DATABASE_URL" -f params/pointhub_local.psql -f sql/01_discover.sql
psql "$DATABASE_URL" -f params/pointhub_local.psql -f sql/02_validate.sql
psql "$DATABASE_URL" -f params/pointhub_local.psql -f sql/03a_prepare_tx.sql
psql "$DATABASE_URL" -f params/pointhub_local.psql -f sql/03b_create_indexes.sql   # 누락 인덱스 있을 때만
psql "$DATABASE_URL" -f params/pointhub_local.psql -f sql/03c_validate_checks.sql  # 오래 걸림 — 온라인 가능
# --- 이후 점검창 ---
psql "$DATABASE_URL" -f params/pointhub_local.psql -f sql/04_cutover.sql
psql "$DATABASE_URL" -f params/pointhub_local.psql -f sql/05_verify.sql
# --- 관찰 기간 (1~2주) ---
psql "$DATABASE_URL" -f params/pointhub_local.psql -f sql/07_cleanup.sql

# (선택) 보존 기간 초과 파티션 삭제
psql "$DATABASE_URL" -f params/pointhub_local.psql -f sql/08_drop_old_partitions.sql          # dry run
psql "$DATABASE_URL" -v dry_run=false -f params/pointhub_local.psql -f sql/08_drop_old_partitions.sql  # 실제 삭제
```

---

## 스크립트 설명

| 파일 | 단계 | 다운타임 | 비고 |
|------|------|----------|------|
| `01_discover.sql` | 현황 조회 | 없음 | 읽기 전용 |
| `02_validate.sql` | 사전 검증 | 없음 | 실패 시 EXCEPTION 으로 중단 |
| `03a_prepare_tx.sql` | 새 부모 + CHECK NOT VALID 생성 | 없음 | 단일 트랜잭션, 멱등 |
| `03b_create_indexes.sql` | 누락 인덱스 생성 | 없음 | CONCURRENTLY, 자동커밋 |
| `03c_validate_checks.sql` | CHECK VALIDATE | 없음 | 오래 걸릴 수 있음 |
| `04_cutover.sql` | 실제 전환 | **점검창 필요** | 단일 트랜잭션 |
| `05_verify.sql` | 결과 검증 | 없음 | 읽기 전용 |
| `06_rollback.sql` | 되돌리기 | 점검창 필요 | 관찰 기간 한정 |
| `07_cleanup.sql` | 레거시 제거 | 없음 | 되돌리기 불가 |
| `08_drop_old_partitions.sql` | 보존 기간 초과 파티션 삭제 | 없음 | dry_run 기본값 true |

---

## 파라미터 설명

| 변수 | 설명 | 예시 |
|------|------|------|
| `parent` | 부모 테이블 (schema.table) | `public.orders` |
| `partition_col` | 파티션 키 컬럼 | `created_at` |
| `pk_strategy` | PK 처리 방법 (반드시 명시) | `composite` |
| `new_suffix` | 새 부모 임시 접미사 | `_new` |
| `legacy_suffix` | 기존 부모 레거시 접미사 | `_legacy` |
| `default_partition` | 기본 파티션 생성 여부 | `true` |
| `future_months` | 커트오버 시 미래 파티션 생성 수 | `3` |
| `lock_timeout` | 커트오버 잠금 대기 제한 | `5s` |
| `stmt_timeout` | 커트오버 문장 실행 제한 | `10min` |
| `strict_index_parity` | 인덱스 불일치를 오류로 처리 | `false` |
| `retention_years` | 보존 기간 (08 전용) | `5` |
| `dry_run` | 실제 삭제 없이 대상만 출력 (08 전용) | `true` |

### pk_strategy 옵션

| 값 | 설명 | 주의 |
|----|------|------|
| `composite` | `PK(id)` → `PK(id, partition_col)` | `ON CONFLICT (id)` 등 앱 코드 확인 필요 |
| `drop` | 부모 PK 제거 | PK 없어짐. 자식별 개별 PK 도 없음 |
| `partition_local` | 자식별 PK 유지, 부모 PK 없음 | 전역 유니크 보장 안 됨 |

---

## 여러 DB 에 재사용

동일한 `sql/` 스크립트를 그대로 두고, DB 마다 params 파일만 달리 준비:

```bash
# DB A
export DATABASE_URL="postgresql://...host-a.../app"
psql "$DATABASE_URL" -f params/app-a.psql -f sql/04_cutover.sql

# DB B
export DATABASE_URL="postgresql://...host-b.../app"
psql "$DATABASE_URL" -f params/app-b.psql -f sql/04_cutover.sql
```

---

## 주의 사항

- **롤백 한계**: `06_rollback.sql` 은 커트오버 후 레거시 파티션을 원래대로 되돌리지만, 커트오버 이후 새 파티션에 유입된 데이터는 레거시에 없다. "정책적 롤백" 이다.
- **트리거 재생성**: `06_rollback.sql` 실행 후 BEFORE INSERT 라우팅 트리거를 수동으로 재생성해야 한다. 함수 본체는 `07_cleanup.sql` 전까지 DB 에 남아 있다.
- **PK 변경 영향**: `pk_strategy=composite` 선택 시 PK 가 `(id, partition_col)` 로 바뀐다. `ON CONFLICT (id)`, ORM 의 기본키 매핑 등 앱 코드를 미리 확인한다.
- **03c 소요 시간**: 자식이 크면 각 자식마다 풀스캔이 발생한다. 점검창 전에 충분히 여유를 두고 실행한다.
- **스테이징 필수**: 운영 전에 반드시 스테이징 DB 에서 동일한 절차를 한 번 끝까지 수행하고 소요 시간을 측정한다.
