# cds-datagrab repository instructions

These instructions define repository-specific operating requirements. Keep repository
behavior aligned with the authoritative files named below; do not turn this
file into a duplicate operator manual.

## Authoritative repository guidance

- Use `README.md` for the workflow overview and `docs/operator_runbook.md` for
  operational procedures.
- Use `docs/atlas_setup.md` for Atlas installation and first-run guidance.
- Use `hpc/lib/cds_datagrab_env.sh` as the authoritative runtime bootstrap,
  root-resolution, credential-presence, and commit-verification implementation.

## Atlas runtime and installation

- Atlas jobs must source `hpc/lib/cds_datagrab_env.sh` and use
  `cds_datagrab_load_atlas_modules` for the module environment. Do not
  reconstruct the module stack manually.
- Establish modules and exported variables in the same shell invocation as the
  command that needs them. Separate SSH invocations do not preserve module or
  exported-environment state.
- Keep the Git checkout, generated output root, and installed R library
  separate. The canonical installer is:
  `bash hpc/install_cdsdatagrab_atlas.sh "$REPO_DIR"`.
  Run `Rscript "$REPO_DIR/hpc/preflight_cdsdatagrab.R"` afterward with
  `REPO_DIR` and `CDS_DATAGRAB_R_LIB` configured.
- Production execution requires the source checkout commit to match
  `$CDS_DATAGRAB_R_LIB/.cds-datagrab-installed-commit`; reinstall and rerun
  preflight after source changes.

## Testing and validation

- The canonical source-tree regression command, run from the repository root,
  is `Rscript --vanilla -e "testthat::test_local()"`. Focused `test_local`
  runs are appropriate during implementation; run the full command once before
  a PR. Hosted CI, when configured, is the independent regression gate.
- `tests/testthat.R` uses `test_check()` for installed-package check semantics.
  Do not use `testthat::test_dir()` without loading the package under test; it
  can miss source/package loading behavior. Do not treat `R CMD check .` as a
  substitute for the source-aware repository tests when repository config
  assets are not present in the installed-package check environment.
- Preserve validation coverage and repository configuration assets. Do not
  weaken tests or validation to make execution pass.

## Production execution

- For a synchronized production update, use the repository-native portfolio
  wrapper `bash hpc/submit_all_products.sh` with exactly one of:
  `--mode plan` or `--mode update`, and `--through latest-common` or an
  explicit ISO date.
- Always run and inspect plan mode first. Plan mode contacts no CDS, submits no
  Slurm jobs, and does not modify production outputs.
- Use the native Slurm wrappers and dependencies. Job submission is not
  completion: treat a portfolio as successful only after source work,
  aggregation, and final portfolio validation have completed successfully.
- Ordinary updates must reuse valid daily/weekly artifacts, must not use
  `--overwrite`, and must not delete valid TIFFs. Inspect the portfolio
  manifest, child manifests, inventories, and Slurm logs before declaring
  success.
- Use `scripts/reconcile_portfolio_manifest.R` for submitted-chain state
  inspection; use `--apply` only after reviewing the reported Slurm states.

## Credentials and production state

- `ecmwfr_PAT` may be checked for presence, including through the shared
  bootstrap helper, but its value must never be printed, logged, copied into a
  report, or committed.
- The canonical Atlas roots are
  `/project/disease_ecology/cds-datagrab-output` for production and
  `/project/disease_ecology/cds-datagrab-smoke-output` for smoke. Use an
  external root for other deployments; never use the Git checkout as an output
  root.
- Treat generated data under `data/<profile>/`, run and manifest records under
  `runs/<profile>/`, and Slurm logs under `logs/slurm/<profile>/` as separate
  from the Git checkout. Portfolio manifests are written under
  `runs/production/_portfolio/<run_id>/portfolio_manifest.json`; the
  ERA5-Land request registry is under
  `data/production/_sources/era5land_daily_mean_utc06/requests/`.

## Configuration and temporal semantics

- `temporal.observed_end` is an operator-confirmed source endpoint, not a
  date inferred from wall-clock time and not proof that a future configured
  date is available. Read the active production YAMLs rather than assuming a
  current endpoint.
- The configured start/end fields define the hard temporal horizon. An
  explicit `--through YYYY-MM-DD` target may be later than `observed_end` only
  when it is within every workflow's hard horizon; report it as unverified
  until the source workflow confirms it.
- `--through latest-common` resolves to the minimum locally configured
  `temporal.observed_end` across the five production source workflows. It does
  not query or scrape CDS for availability and fails conservatively when a
  source endpoint is not known locally.

## ERA5-Land source family

- The eight ERA5-Land products share the
  `era5land_daily_mean_utc06` source family. Their raw monthly archives are
  stored once under the shared `_sources/era5land_daily_mean_utc06` tree;
  derived products remain in separate product directories.
- Do not model the family as eight independent download streams. Use the
  repository-native family planner and wrapper, especially
  `hpc/submit_era5land_daily_mean.sh` and
  `hpc/plan_era5land_daily_mean.R`.

## Recovery and scope discipline

- Recover from manifests, request registries, inventories, and logs first.
  Reuse valid outputs and, when source archives are already valid, resume at
  processing or aggregation rather than repeating acquisition.
- Do not delete shared source archives or valid TIFFs. Avoid `--overwrite`
  during ordinary recovery; use a documented, explicitly scoped repair path
  when a nonroutine overwrite is truly required.
- Operational configuration changes must not silently alter product
  definitions, spatial templates, aggregation rules, source identities, or
  scientific/data-processing semantics. Escalate such changes for explicit
  review.
