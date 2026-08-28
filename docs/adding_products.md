# Adding products

For each new environmental variable:

1. Assign one stable product identifier and use the shared production and smoke roots; never create a product-specific top-level root.
2. Add product-specific configuration defining source dataset, variable, source/output units, daily interpretation, and weekly aggregation.
3. Add or update the reader/decoder, filename, inventory, validation, smoke, production, and reuse tests.
4. Register the product in the variable registry and annual dispatcher, preserve `PROFILE=production|smoke`, and add it to the README product catalog.
5. Validate a short smoke run, a complete ISO week, safe annual production chunks, and reuse from the shared root.

The normal directories are `data/<profile>/<product_id>/{raw,extracted,cache,daily,weekly}`, `runs/<profile>/<product_id>/<run_id>`, and `logs/slurm/<profile>`. ERA5-Land is different: its eight products share `data/<profile>/_sources/era5land_daily_mean_utc06/` for raw archives, extraction, request registry, and source maps, while derived outputs remain in separate product directories.

Changes to the ERA5-Land family require coordinated updates to the eight-product registry, monthly request validation, archive member mapping, source maps, and family completeness checks. Do not make eight copies of a monthly NetCDF. The high/low LAI products are monthly climatologies with no interannual variability; identical consecutive daily layers are acceptable.
