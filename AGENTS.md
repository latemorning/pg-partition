# Repository Guidelines

## Project Structure & Module Organization

This repository contains PostgreSQL scripts for migrating inheritance-based monthly partitions to declarative partitions without moving data.

- `sql/`: ordered migration scripts. Run them by numeric prefix, from discovery through cleanup.
- `params/`: per-database `psql` parameter files. Copy `params/app-prod.example.psql` or `sql/00_params.example.psql` and customize values such as `parent`, `partition_col`, and `pk_strategy`.
- `docs/`: reserved for supporting notes or runbooks.
- `README.md`: primary operator workflow and risk notes.

Do not hard-code connection strings in repository files. Use `DATABASE_URL` or another external secret source.

## Build, Test, and Development Commands

There is no application build step. Validate changes by running the SQL workflow against a disposable or staging PostgreSQL 14+ database.

```bash
export DATABASE_URL="postgresql://user:password@host:5432/dbname"
cp params/app-prod.example.psql params/my-db.psql
psql "$DATABASE_URL" -f params/my-db.psql -f sql/01_discover.sql
psql "$DATABASE_URL" -f params/my-db.psql -f sql/02_validate.sql
psql "$DATABASE_URL" -f params/my-db.psql -f sql/05_verify.sql
```

For retention cleanup, keep the default dry run first:

```bash
psql "$DATABASE_URL" -f params/my-db.psql -f sql/08_drop_old_partitions.sql
psql "$DATABASE_URL" -v dry_run=false -f params/my-db.psql -f sql/08_drop_old_partitions.sql
```

## Coding Style & Naming Conventions

Name new migration scripts with a two-digit sequence and descriptive suffix, for example `09_rebuild_stats.sql`. Keep scripts executable through `psql -f` and start operational scripts with `\set ON_ERROR_STOP on`.

Use lower_snake_case for variables and settings. PL/pgSQL helper variables commonly use prefixes such as `v_`. Prefer four-space indentation inside SQL expressions and PL/pgSQL blocks. Use `format('%I', ...)`, `regclass`, or catalog lookups for dynamic SQL identifiers instead of manual string concatenation.

## Testing Guidelines

No automated test framework is configured. Treat staging execution as the test suite. For any change touching cutover, rollback, constraint validation, or partition attachment, run the relevant sequence end to end: `01_discover`, `02_validate`, `03a_prepare_tx`, optional `03b_create_indexes`, `03c_validate_checks`, `04_cutover`, and `05_verify`.

When changing destructive scripts, verify dry-run output first and document the tested parameter file.

## Commit & Pull Request Guidelines

Git history currently uses concise subjects such as `Initial commit: PostgreSQL partition migration SQL scripts`. Follow that style: short, imperative or descriptive, with an optional scope before a colon.

Pull requests should include the target PostgreSQL version, scripts changed, staging database shape tested, exact `psql` commands run, and any lock-time or downtime implications. Link related issues or runbooks when available.
