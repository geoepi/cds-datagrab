.initialize_run_manifest_unannotated <- initialize_run_manifest
initialize_run_manifest <- function(config, mode, dry_run = TRUE, execution_source = "default") {
  manifest <- .initialize_run_manifest_unannotated(config, mode, dry_run, execution_source)
  if (exists("era5land_support_provenance", mode = "function")) manifest <- modifyList(manifest, era5land_support_provenance(config))
  repo <- Sys.getenv("REPO_DIR", "")
  source_commit <- if (nzchar(repo)) tryCatch(trimws(system2("git", c("-C", repo, "rev-parse", "HEAD"), stdout=TRUE, stderr=FALSE)), error=function(e) NA_character_) else NA_character_
  lib <- Sys.getenv("CDS_DATAGRAB_R_LIB", "")
  installed_path <- tryCatch(normalizePath(find.package("cdsdatagrab"), winslash="/", mustWork=TRUE), error=function(e) NA_character_)
  marker <- if (nzchar(lib)) file.path(normalizePath(lib, winslash="/", mustWork=FALSE), ".cds-datagrab-installed-commit") else ""
  installed_commit <- if (nzchar(marker) && file.exists(marker)) trimws(readLines(marker, n=1L, warn=FALSE)) else NA_character_
  manifest$source_git_commit <- source_commit
  manifest$installed_package_git_commit <- installed_commit
  manifest$installed_package_path <- installed_path
  manifest$r_library_paths <- .libPaths()
  job_id <- Sys.getenv("SLURM_JOB_ID", "")
  slurm <- nzchar(job_id)
  manifest$execution_context <- if (slurm) "slurm" else "direct"
  manifest$slurm_job_id <- if (slurm) job_id else NULL
  manifest$slurm_array_job_id <- if (slurm) Sys.getenv("SLURM_ARRAY_JOB_ID", "") else NULL
  manifest$slurm_array_task_id <- if (slurm) Sys.getenv("SLURM_ARRAY_TASK_ID", "") else NULL
  manifest$slurm_job_name <- if (slurm) Sys.getenv("SLURM_JOB_NAME", "") else NULL
  manifest$slurm_submit_dir <- if (slurm) Sys.getenv("SLURM_SUBMIT_DIR", "") else NULL
  manifest$slurm_node_list <- if (slurm) Sys.getenv("SLURM_NODELIST", "") else NULL
  write_run_manifest(manifest)
  manifest
}
