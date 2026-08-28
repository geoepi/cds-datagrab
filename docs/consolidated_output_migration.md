# Consolidated output migration

The four product-specific production roots were consolidated so that products share one auditable storage contract while remaining isolated beneath `data/production/<product_id>`, `runs/production/<product_id>`, and `logs/slurm/production`.

Canonical roots are `/project/disease_ecology/cds-datagrab-output` and `/project/disease_ecology/cds-datagrab-smoke-output`.

```text
/project/disease_ecology/cds-datagrab-production-output
  → /project/disease_ecology/cds-datagrab-output/data/production/era5_mintemp
/project/disease_ecology/cds-datagrab-soilmoist-production-output
  → /project/disease_ecology/cds-datagrab-output/data/production/era5_soilmoist
/project/disease_ecology/cds-datagrab-lai-low-production-output
  → /project/disease_ecology/cds-datagrab-output/data/production/era5_lai_low
/project/disease_ecology/cds-datagrab-relhum-min-production-output
  → /project/disease_ecology/cds-datagrab-output/data/production/agera5_relhum_min
```

Migration used copy–verify–switch: data and run records were migrated manually, matching counts/bytes and checksum verification were required, then repository defaults were changed. Planning tests for the four pre-existing standalone products found zero newly missing dates after switching to the consolidated root. ERA5-Land uses the additional shared source-family path documented in `docs/output_schema.md`; historical `run_manifest.json` files remain unchanged as provenance records.

Legacy roots are retired and are never searched automatically. Explicit use produces a warning. Rollback means restoring the previous repository defaults only after validating the target records; it does not move or delete migrated data.
