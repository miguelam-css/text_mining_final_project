################################################################################
#                                                                              #
#   OpenAlex Article Metadata Downloader                                       #
#   -------------------------------------------------------------------        #
#   Downloads academic article metadata from the OpenAlex API using            #
#   openalexR, with incremental CSV/RData storage, crash recovery via          #
#   checkpoints, and multi-journal query support.                              #
#   -------------------------------------------------------------------        #
#   Usage: Source this script in RStudio. Configure only the block below.      #
#   -------------------------------------------------------------------        #                               #
#   Authors:                                                                   #
#   - Miguel Agenjo                                                            #
#   - Eva Lambistos                                                            #
#   - Noah Fürup                                                               #
#   - Alicia Miras                                                             #
#   Using:                                                                     #
#   - Claude Sonnet 4.6                                                        #
################################################################################

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                     USER CONFIGURATION — EDIT HERE ONLY                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# ── OUTPUT ──────────────────────────────────────────────────────────────────
# data_folder: Directory for all output files (CSV, RData, checkpoint).
#              Defaults to a "data" subfolder next to this script.
data_folder <- file.path(
  dirname(rstudioapi::getSourceEditorContext()$path), "data"
)

# output_csv: Name of the CSV output file (human-readable flat export).
output_csv <- "prueba.csv"

# output_rdata: Name of the RData output file (lossless R-native archive).
output_rdata <- "prueba.RData"

# ── CREDENTIALS ─────────────────────────────────────────────────────────────
# email: Your email address, sent to OpenAlex as a polite-pool identifier.
#        Providing an email gives you faster, more reliable access.
email <- "100569505@alumnos.uc3m.es"

# api_key: Your OpenAlex API key. Set to NULL if you do not have one.
api_key <- "W9s9d2CkVTBpNUoPkY2ogW"

# ── JOURNALS ────────────────────────────────────────────────────────────────
# List of journals to query. Each entry is a named list with three optional
# fields: openalex_id, issn, and name.
#
# Priority order: openalex_id > issn > name
# Fill in only ONE field per journal; set the others to NULL.
#
# TIP: After the first run, the script prints the resolved OpenAlex Source ID
#      for each journal. Copy those IDs into openalex_id for faster future runs.

journals <- list(
  list(openalex_id = NULL, issn = "2397-3374", name = NULL),  # Nature Human Behaviour (2017–present)
  list(openalex_id = NULL, issn = "2662-9992", name = NULL),  # Humanities & Social Sciences Communications (2020–present)
  list(openalex_id = NULL, issn = "2055-1045", name = NULL)   # Palgrave Communications (2014–2020, ceased)
  # Example 1: Using an OpenAlex Source ID directly (fastest, no resolution needed)
  # list(openalex_id = "S137773608", issn = NULL,        name = NULL),


  # Example 2: Using an ISSN (resolved via the OpenAlex sources endpoint)
  # list(openalex_id = NULL,         issn = "0028-0836", name = NULL),


  # Example 3: Using a journal display name (resolved via search — least precise)
  # list(openalex_id = NULL,         issn = NULL,        name = "Science")
)

# ── DATE RANGE ──────────────────────────────────────────────────────────────
# date_from: Start of the download period ("YYYY-MM-DD"). NULL = no start filter.
date_from <- "2026-01-01"

# date_to: End of the download period ("YYYY-MM-DD"). NULL = no end filter.
date_to <- "2026-01-15"

# ── ADDITIONAL FILTERS ──────────────────────────────────────────────────────
# A named list of extra OpenAlex API filter parameters.
# Any valid OpenAlex filter field can be included. All are optional.
extra_filters <- list(
  # type                = "article",
  # "open_access.is_oa" = TRUE,
  # language            = "en"
)

# ── OPTIONS ─────────────────────────────────────────────────────────────────
# dry_run: If TRUE, resolve journals, query matching IDs, report counts,
#          then stop without downloading anything. Useful to validate filters
#          and estimate download size before a long run.
dry_run <- FALSE

# rdata_write_interval: Rewrite the .RData file every N successfully completed
#                       batches. Higher = fewer writes & faster; lower = more
#                       current .RData after a crash. CSV is always appended
#                       after every batch regardless.
rdata_write_interval <- 10

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║                   END OF USER CONFIGURATION                              ║
# ╚═══════════════════════════════════════════════════════════════════════════╝


###############################################################################
# STEP 1 — SETUP: Load packages, validate config, configure openalexR        #
###############################################################################

# Required packages
required_pkgs <- c(

  "openalexR", "dplyr", "tidyr", "purrr", "tibble", "readr", "stringr",

  "lubridate", "janitor", "cli", "jsonlite", "digest", "httr2", "rstudioapi"
)

missing_pkgs <- required_pkgs[!vapply(required_pkgs, requireNamespace,
                                       quietly = TRUE, FUN.VALUE = logical(1))]

if (length(missing_pkgs) > 0) {
  stop(
    "The following required packages are not installed:\n  ",
    paste(missing_pkgs, collapse = ", "), "\n\n",
    "Install them with:\n  install.packages(c(",
    paste0('"', missing_pkgs, '"', collapse = ", "), "))\n",
    call. = FALSE
  )
}

# Load packages
suppressPackageStartupMessages({
  library(openalexR)
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(tibble)
  library(readr)
  library(stringr)
  library(lubridate)
  library(janitor)
  library(cli)
  library(jsonlite)
  library(digest)
  library(httr2)
})

# ── Helper Functions ────────────────────────────────────────────────────────

#' Reconstruct a plain-text abstract from an OpenAlex inverted index
#'
#' @param inv_index A named list where keys are words and values are integer
#'   vectors of positions.
#' @param record_id Optional identifier for warning messages.
#' @return A single character string, or NA_character_ on failure.
reconstruct_abstract <- function(inv_index, record_id = "unknown") {
  # NULL / missing / not a named list → NA

  if (is.null(inv_index) || length(inv_index) == 0 ||
      !is.list(inv_index) || is.null(names(inv_index))) {
    return(NA_character_)
  }

  tryCatch({
    # Build position → word mapping
    words <- character(0)
    positions <- integer(0)
    for (word in names(inv_index)) {
      pos <- as.integer(inv_index[[word]])
      words <- c(words, rep(word, length(pos)))
      positions <- c(positions, pos)
    }
    # Sort by position and join
    paste(words[order(positions)], collapse = " ")
  }, error = function(e) {
    cli::cli_alert_warning(
      "Failed to reconstruct abstract for record {.val {record_id}}: {e$message}"
    )
    NA_character_
  })
}

#' Build a deterministic MD5 fingerprint of the query parameters
#'
#' @param source_ids Character vector of resolved OpenAlex Source IDs.
#' @param date_from Start date string or NULL.
#' @param date_to End date string or NULL.
#' @param extra_filters Named list of additional filters.
#' @return An MD5 hash string.
build_query_fingerprint <- function(source_ids, date_from, date_to, extra_filters) {
  components <- list(
    source_ids   = sort(source_ids),
    date_from    = date_from %||% "NULL",
    date_to      = date_to   %||% "NULL",
    extra_filters = if (length(extra_filters) > 0) extra_filters[order(names(extra_filters))] else list()
  )
  digest::digest(components, algo = "md5")
}

#' Flatten a variable-length list field to a single " | "-separated string
#'
#' @param x A list, character vector, or NULL.
#' @return A single character string with values joined by " | ", or NA_character_.
flatten_list_field <- function(x) {
  if (is.null(x) || length(x) == 0) return(NA_character_)
  vals <- unlist(x, use.names = FALSE)
  vals <- vals[!is.na(vals) & vals != ""]
  if (length(vals) == 0) return(NA_character_)
  paste(vals, collapse = " | ")
}

#' Resolve one journal entry to an OpenAlex Source ID
#'
#' @param journal_entry A named list with fields openalex_id, issn, name.
#' @param index Integer index for logging.
#' @return A character Source ID, or NULL on failure.
resolve_journal_id <- function(journal_entry, index) {
  oa_id <- journal_entry$openalex_id
  issn  <- journal_entry$issn
  jname <- journal_entry$name

  # If openalex_id is provided, use it directly

  if (!is.null(oa_id) && nzchar(trimws(oa_id))) {
    cli::cli_alert_success(
      "Journal {index}: Using provided OpenAlex ID {.val {oa_id}}"
    )
    return(trimws(oa_id))
  }

  # If ISSN is provided, resolve via the sources endpoint
  if (!is.null(issn) && nzchar(trimws(issn))) {
    tryCatch({
      result <- oa_fetch(
        entity = "sources",
        issn = trimws(issn),
        verbose = FALSE
      )
      if (is.null(result) || nrow(result) == 0) {
        cli::cli_alert_warning(
          "Journal {index}: No source found for ISSN {.val {issn}}. Skipping."
        )
        return(NULL)
      }
      resolved_id <- result$id[1]
      cli::cli_alert_success(
        "Journal {index}: ISSN {.val {issn}} resolved to {.val {resolved_id}}"
      )
      cli::cli_alert_info(
        "  Tip: Copy {.val {resolved_id}} into openalex_id for faster future runs."
      )
      return(resolved_id)
    }, error = function(e) {
      cli::cli_alert_warning(
        "Journal {index}: Failed to resolve ISSN {.val {issn}}: {e$message}. Skipping."
      )
      return(NULL)
    })
  }

  # If name is provided, resolve via display name search

  if (!is.null(jname) && nzchar(trimws(jname))) {
    tryCatch({
      result <- oa_fetch(
        entity = "sources",
        search = trimws(jname),
        verbose = FALSE
      )
      if (is.null(result) || nrow(result) == 0) {
        cli::cli_alert_warning(
          "Journal {index}: No source found for name {.val {jname}}. Skipping."
        )
        return(NULL)
      }
      resolved_id <- result$id[1]
      resolved_name <- result$display_name[1]
      cli::cli_alert_success(
        "Journal {index}: Name {.val {jname}} resolved to {.val {resolved_id}} ({resolved_name})"
      )
      cli::cli_alert_info(
        "  Tip: Copy {.val {resolved_id}} into openalex_id for faster future runs."
      )
      return(resolved_id)
    }, error = function(e) {
      cli::cli_alert_warning(
        "Journal {index}: Failed to resolve name {.val {jname}}: {e$message}. Skipping."
      )
      return(NULL)
    })
  }

  # All three fields are NULL

  cli::cli_alert_warning(
    "Journal {index}: All identifier fields are NULL. Skipping."
  )
  return(NULL)
}

#' Flatten a single openalexR works batch into a tidy tibble for CSV export
#'
#' @param batch_raw A tibble as returned by oa_fetch() for works.
#' @return A flattened tibble with " | "-separated combined columns.
flatten_works_batch <- function(batch_raw) {
  n <- nrow(batch_raw)
  cols <- names(batch_raw)

  # Start building the output tibble with mandatory scalar columns
  out <- tibble::tibble(
    openalex_id = batch_raw$id,
    journal_name = purrr::map_chr(seq_len(n), function(i) {
      # Try primary_location$source$display_name first
      pl <- batch_raw$primary_location[[i]] %||% list()
      src <- pl$source %||% list()
      nm <- src$display_name %||% NA_character_
      if (is.na(nm) || !nzchar(nm)) {
        # Fallback: so (source object) if present
        so <- batch_raw$so[i] %||% NA_character_
        if (!is.na(so) && nzchar(so)) return(so)
      }
      nm
    }),
    publication_year = as.integer(batch_raw$publication_year),
    title = as.character(batch_raw$display_name),
    abstract_plain_text = purrr::map_chr(seq_len(n), function(i) {
      ab_inv <- batch_raw$ab[i]
      if (is.list(ab_inv)) ab_inv <- ab_inv[[1]]
      reconstruct_abstract(ab_inv, record_id = batch_raw$id[i])
    }),
    abstract_inverted_index = purrr::map_chr(seq_len(n), function(i) {
      ab_inv <- batch_raw$ab[i]
      if (is.list(ab_inv)) ab_inv <- ab_inv[[1]]
      if (is.null(ab_inv) || length(ab_inv) == 0) return(NA_character_)
      tryCatch(
        jsonlite::toJSON(ab_inv, auto_unbox = TRUE),
        error = function(e) NA_character_
      )
    }),
    downloaded_at = format(
      lubridate::with_tz(Sys.time(), "UTC"),
      "%Y-%m-%d %H:%M:%S"
    )
  )

  # ── Scalar fields: add any top-level atomic columns not already captured ──
  scalar_cols <- cols[vapply(batch_raw, function(col) {
    is.atomic(col) && !is.list(col)
  }, logical(1))]
  # Exclude columns we've already handled
  already_handled <- c("id", "display_name", "publication_year", "ab")
  scalar_cols <- setdiff(scalar_cols, already_handled)


  for (col_name in scalar_cols) {
    out[[col_name]] <- batch_raw[[col_name]]
  }

  # ── Authorship fields: author names, institutions, ORCIDs ─────────────────
  if ("author" %in% cols && is.list(batch_raw$author)) {
    out$authors_names <- purrr::map_chr(batch_raw$author, function(au_list) {
      if (is.null(au_list) || (is.data.frame(au_list) && nrow(au_list) == 0)) {
        return(NA_character_)
      }
      if (is.data.frame(au_list)) {
        nms <- au_list$au_display_name %||% au_list$display_name %||% au_list$au_name
        return(flatten_list_field(nms))
      }
      NA_character_
    })

    out$authors_institutions <- purrr::map_chr(batch_raw$author, function(au_list) {
      if (is.null(au_list) || (is.data.frame(au_list) && nrow(au_list) == 0)) {
        return(NA_character_)
      }
      if (is.data.frame(au_list)) {
        inst <- au_list$institution_display_name %||% au_list$inst_name
        return(flatten_list_field(inst))
      }
      NA_character_
    })

    out$authors_orcids <- purrr::map_chr(batch_raw$author, function(au_list) {
      if (is.null(au_list) || (is.data.frame(au_list) && nrow(au_list) == 0)) {
        return(NA_character_)
      }
      if (is.data.frame(au_list)) {
        orcids <- au_list$au_orcid %||% au_list$orcid
        return(flatten_list_field(orcids))
      }
      NA_character_
    })
  }

  # ── Generic list fields: flatten all remaining list columns ───────────────
  list_cols <- cols[vapply(batch_raw, is.list, logical(1))]
  # Exclude columns we've already handled
  handled_list <- c("author", "ab", "primary_location")
  list_cols <- setdiff(list_cols, handled_list)

  for (col_name in list_cols) {
    out_col_name <- paste0(col_name, "_combined")
    out[[out_col_name]] <- purrr::map_chr(batch_raw[[col_name]], function(x) {
      if (is.null(x)) return(NA_character_)
      if (is.data.frame(x)) {
        # For data frames, concatenate the display_name or first character column
        display_col <- intersect(
          c("display_name", "name", "keyword", "descriptor_name", "value"),
          names(x)
        )
        if (length(display_col) > 0) {
          return(flatten_list_field(x[[display_col[1]]]))
        }
        # Fallback: first character column
        char_cols <- names(x)[vapply(x, is.character, logical(1))]
        if (length(char_cols) > 0) {
          return(flatten_list_field(x[[char_cols[1]]]))
        }
        return(NA_character_)
      }
      if (is.list(x)) {
        # Try to extract display_name or name from each element
        vals <- purrr::map_chr(x, function(el) {
          if (is.list(el)) {
            return(el$display_name %||% el$name %||% NA_character_)
          }
          as.character(el)
        })
        return(flatten_list_field(vals))
      }
      flatten_list_field(x)
    })
  }

  # Sanitise column names
  out <- janitor::clean_names(out)

  out
}


# ── Configure openalexR ────────────────────────────────────────────────────
# Set openalexR options (replaces the deprecated oa_config)
options(openalexR.mailto = email)
if (!is.null(api_key)) options(openalexR.apikey = api_key)

# ── Create output directory ────────────────────────────────────────────────
if (!dir.exists(data_folder)) {
  dir.create(data_folder, recursive = TRUE)
}

# ── File paths ─────────────────────────────────────────────────────────────
csv_path   <- file.path(data_folder, output_csv)
rdata_path <- file.path(data_folder, output_rdata)
checkpoint_path <- file.path(
  data_folder,
  paste0(tools::file_path_sans_ext(output_csv), "_checkpoint.rds")
)

# ── Startup summary ────────────────────────────────────────────────────────
cli::cli_h1("OpenAlex Article Metadata Downloader")

cli::cli_h2("Configuration")
cli::cli_alert_info("Output folder:    {.path {data_folder}}")
cli::cli_alert_info("CSV file:         {.file {output_csv}}")
cli::cli_alert_info("RData file:       {.file {output_rdata}}")
cli::cli_alert_info("Email:            {.val {email}}")
cli::cli_alert_info("API key:          {.val {if (is.null(api_key)) 'not set' else '***'}}")
cli::cli_alert_info("Journals:         {.val {length(journals)}} configured")
cli::cli_alert_info("Date from:        {.val {date_from %||% 'not set'}}")
cli::cli_alert_info("Date to:          {.val {date_to %||% 'not set'}}")
cli::cli_alert_info("Extra filters:    {.val {length(extra_filters)}} active")
cli::cli_alert_info("RData interval:   every {.val {rdata_write_interval}} batches")
cli::cli_alert_info("Dry run:          {.val {dry_run}}")

if (dry_run) {
  cli::cli_alert_info(cli::col_cyan(
    "DRY RUN MODE — will report counts only, no data will be downloaded."
  ))
}


###############################################################################
# STEP 2 — JOURNAL RESOLUTION                                                #
###############################################################################

cli::cli_h1("Step 2: Journal Resolution")

resolved_source_ids <- character(0)
journal_filtering_intended <- length(journals) > 0

if (journal_filtering_intended) {
  for (i in seq_along(journals)) {
    resolved <- resolve_journal_id(journals[[i]], index = i)
    if (!is.null(resolved)) {
      resolved_source_ids <- c(resolved_source_ids, resolved)
    }
  }

  # If journal filtering was intended but all resolutions failed, stop

  if (length(resolved_source_ids) == 0) {
    cli::cli_alert_danger(
      "All journal resolutions failed. Cannot proceed. Check your journal configuration."
    )
    stop("All journal resolutions failed.", call. = FALSE)
  }

  cli::cli_alert_success(
    "Resolved {.val {length(resolved_source_ids)}} of {.val {length(journals)}} journals."
  )
} else {
  cli::cli_alert_info("No journals configured — no journal filter will be applied.")
}


###############################################################################
# STEP 3 — ID PRE-FETCH & PARTIAL DATA DETECTION                            #
###############################################################################

cli::cli_h1("Step 3: Pre-fetching Article IDs")

# ── Build the filter list for the ID pre-fetch ─────────────────────────────
id_filter <- list()

# Journal source filter (OR syntax)
if (length(resolved_source_ids) > 0) {
  id_filter[["primary_location.source.id"]] <- paste(
    resolved_source_ids, collapse = "|"
  )
}

# Date range filters
if (!is.null(date_from)) {
  id_filter[["from_publication_date"]] <- date_from
}
if (!is.null(date_to)) {
  id_filter[["to_publication_date"]] <- date_to
}

# Extra filters
if (length(extra_filters) > 0) {
  for (fname in names(extra_filters)) {
    id_filter[[fname]] <- extra_filters[[fname]]
  }
}

cli::cli_alert_info("Querying OpenAlex for matching article IDs (select=id)...")

# Fetch all matching IDs using cursor paging
all_api_ids <- tryCatch({
  # Build argument list: fixed args + dynamic filter args via do.call
  fetch_args <- c(
    list(entity = "works", options = list(select = "id"),
         per_page = 200, paging = "cursor", verbose = FALSE),
    id_filter
  )
  result <- do.call(oa_fetch, fetch_args)
  if (is.null(result) || nrow(result) == 0) {
    character(0)
  } else {
    as.character(result$id)
  }
}, error = function(e) {
  cli::cli_alert_danger("Failed to pre-fetch IDs: {e$message}")
  stop("ID pre-fetch failed.", call. = FALSE)
})

cli::cli_alert_info("Total articles matching filters on OpenAlex: {.val {length(all_api_ids)}}")

if (length(all_api_ids) == 0) {
  cli::cli_alert_warning("No articles match the current filter configuration. Nothing to do.")
  stop("No matching articles found.", call. = FALSE)
}

# ── Compare with existing local data ──────────────────────────────────────

existing_ids <- character(0)
if (file.exists(csv_path)) {
  cli::cli_alert_info("Found existing CSV: {.path {csv_path}}")
  existing_data <- tryCatch({
    readr::read_csv(csv_path, col_select = "openalex_id",
                    col_types = readr::cols(openalex_id = readr::col_character()),
                    show_col_types = FALSE)
  }, error = function(e) {
    cli::cli_alert_warning("Could not read existing CSV: {e$message}. Starting fresh.")
    tibble::tibble(openalex_id = character(0))
  })
  existing_ids <- unique(existing_data$openalex_id)
  cli::cli_alert_info("Records already downloaded: {.val {length(existing_ids)}}")
}

new_ids <- setdiff(all_api_ids, existing_ids)

# ── Dry run reporting ─────────────────────────────────────────────────────
if (dry_run) {
  cli::cli_h2("Dry Run Report")
  cli::cli_alert_info("Total on OpenAlex:      {.val {length(all_api_ids)}}")
  cli::cli_alert_info("Already downloaded:     {.val {length(existing_ids)}}")
  cli::cli_alert_info("New records available:  {.val {length(new_ids)}}")
  cli::cli_alert_info("Dry run complete. Set dry_run <- FALSE to download.")
  # Stop cleanly
  invisible(NULL)
} else {

  # ── Non-dry-run: decide what to download ─────────────────────────────────

  if (length(new_ids) == 0) {
    cli::cli_alert_success("All {.val {length(all_api_ids)}} records are already downloaded. Nothing to do.")
    # Still ensure RData is current if CSV exists but RData doesn't
    if (file.exists(csv_path) && !file.exists(rdata_path)) {
      cli::cli_alert_info("Generating missing .RData file from CSV...")
    }
    invisible(NULL)
  } else {

    cli::cli_alert_info("Already downloaded: {.val {length(existing_ids)}}")
    cli::cli_alert_info("New to download:    {.val {length(new_ids)}}")
    cli::cli_alert_info("Total expected:     {.val {length(all_api_ids)}}")


    ###########################################################################
    # STEP 4 — CHECKPOINT MANAGEMENT                                          #
    ###########################################################################

    cli::cli_h1("Step 4: Checkpoint Management")

    current_fingerprint <- build_query_fingerprint(
      resolved_source_ids, date_from, date_to, extra_filters
    )

    ids_to_download <- new_ids

    if (file.exists(checkpoint_path)) {
      cli::cli_alert_info("Found checkpoint file: {.path {checkpoint_path}}")
      checkpoint <- readRDS(checkpoint_path)

      if (checkpoint$query_fingerprint == current_fingerprint) {
        # Fingerprint matches — resume from checkpoint
        # Intersect checkpoint remaining with new_ids (in case CSV was updated)
        ids_to_download <- intersect(checkpoint$remaining_ids, new_ids)
        cli::cli_alert_info(
          "Resuming from checkpoint: {.val {length(ids_to_download)}} IDs remaining."
        )
      } else {
        # Fingerprint mismatch — stop and warn
        cli::cli_alert_warning(paste0(
          "Filter parameters have changed since the checkpoint was created.\n",
          "  Resuming with different filters could produce inconsistent data.\n",
          "  To resume with original filters: restore them and re-run.\n",
          "  To start fresh: delete the checkpoint file and re-run.\n",
          "  Checkpoint file: ", checkpoint_path
        ))
        stop("Checkpoint fingerprint mismatch. See message above.", call. = FALSE)
      }
    } else {
      # No checkpoint exists — create one
      checkpoint <- list(
        remaining_ids     = ids_to_download,
        query_fingerprint = current_fingerprint
      )
      saveRDS(checkpoint, checkpoint_path)
      cli::cli_alert_info("Created new checkpoint with {.val {length(ids_to_download)}} IDs.")
    }

    if (length(ids_to_download) == 0) {
      cli::cli_alert_success("All records are downloaded (checkpoint confirmed). Nothing to do.")
      # Clean up checkpoint
      if (file.exists(checkpoint_path)) file.remove(checkpoint_path)
    } else {

      #########################################################################
      # STEP 5 — DOWNLOAD LOOP                                               #
      #########################################################################

      cli::cli_h1("Step 5: Downloading Records")

      # Split IDs into batches of 100
      n_ids <- length(ids_to_download)
      batch_indices <- split(seq_len(n_ids), ceiling(seq_len(n_ids) / 100))
      n_batches <- length(batch_indices)
      batch_counter <- 0
      total_downloaded_this_run <- 0

      # Accumulator for RData (raw, pre-flattened)
      rdata_accumulator <- list()

      # Load existing RData accumulator if the file exists
      if (file.exists(rdata_path)) {
        tryCatch({
          load_env <- new.env()
          load(rdata_path, envir = load_env)
          if ("articles_raw" %in% ls(load_env)) {
            rdata_accumulator <- list(load_env$articles_raw)
          }
        }, error = function(e) {
          cli::cli_alert_warning("Could not load existing .RData: {e$message}. Will rebuild.")
        })
      }

      cli::cli_alert_info("Starting download: {.val {n_batches}} batches of up to 100 records.")

      cli::cli_progress_bar(
        "Downloading",
        total = n_batches,
        format = "{cli::pb_bar} {cli::pb_current}/{cli::pb_total} batches | {cli::pb_percent}"
      )

      for (b in seq_len(n_batches)) {
        batch_ids <- ids_to_download[batch_indices[[b]]]

        batch_result <- tryCatch({
          oa_fetch(
            entity = "works",
            identifier = batch_ids,
            per_page = 200,
            paging = "cursor",
            verbose = FALSE
          )
        }, error = function(e) {
          # Check if this is a rate-limit or transient error that exhausted retries
          if (grepl("429|rate.limit|too.many", tolower(e$message))) {
            cli::cli_alert_danger(paste0(
              "Rate limit exceeded on batch {b} of {n_batches}. ",
              "Re-run the script after the rate limit resets (midnight UTC). ",
              "The checkpoint will allow resuming from this point."
            ))
          } else {
            cli::cli_alert_danger(
              "API error on batch {b} of {n_batches}: {e$message}. ",
              "The checkpoint will allow resuming on re-run."
            )
          }
          stop(e$message, call. = FALSE)
        })

        if (is.null(batch_result) || nrow(batch_result) == 0) {
          cli::cli_alert_warning("Batch {b}: received 0 records. Skipping.")
          cli::cli_progress_update()
          next
        }

        # Store raw (pre-flattened) data for RData
        rdata_accumulator[[length(rdata_accumulator) + 1]] <- batch_result

        # Flatten the batch for CSV
        batch_flat <- tryCatch({
          flatten_works_batch(batch_result)
        }, error = function(e) {
          cli::cli_alert_danger("Error flattening batch {b}: {e$message}")
          stop(e$message, call. = FALSE)
        })

        # Deduplicate within the batch by openalex_id
        batch_flat <- batch_flat |>
          dplyr::distinct(openalex_id, .keep_all = TRUE)

        # Append to CSV: write headers if file doesn't exist, append otherwise
        if (!file.exists(csv_path)) {
          readr::write_csv(batch_flat, csv_path)
        } else {
          readr::write_csv(batch_flat, csv_path, append = TRUE)
        }

        batch_counter <- batch_counter + 1
        total_downloaded_this_run <- total_downloaded_this_run + nrow(batch_flat)

        # Rewrite RData every rdata_write_interval batches
        rdata_msg <- ""
        if (batch_counter %% rdata_write_interval == 0) {
          articles_raw <- dplyr::bind_rows(rdata_accumulator)
          save(articles_raw, file = rdata_path)
          rdata_msg <- " \u2014 .RData updated"
        }

        # Update checkpoint: remove downloaded IDs
        successfully_downloaded <- batch_flat$openalex_id
        checkpoint$remaining_ids <- setdiff(
          checkpoint$remaining_ids, successfully_downloaded
        )
        saveRDS(checkpoint, checkpoint_path)

        # Progress update
        cli::cli_progress_update()
        cli::cli_alert_info(
          "[Batch {b} of {n_batches}] Downloaded {nrow(batch_flat)} records \u2014 total so far: {total_downloaded_this_run}{rdata_msg}"
        )
      }

      cli::cli_progress_done()

      #########################################################################
      # STEP 6 — COMPLETION                                                   #
      #########################################################################

      cli::cli_h1("Step 6: Completion")

      # Final RData write
      articles_raw <- dplyr::bind_rows(rdata_accumulator)
      save(articles_raw, file = rdata_path)
      cli::cli_alert_success(".RData file written with {.val {nrow(articles_raw)}} records.")

      # Count total records now in CSV
      total_in_csv <- tryCatch({
        nrow(readr::read_csv(csv_path, col_select = "openalex_id",
                             col_types = readr::cols(openalex_id = readr::col_character()),
                             show_col_types = FALSE))
      }, error = function(e) {
        total_downloaded_this_run + length(existing_ids)
      })

      cli::cli_alert_success(
        "Download complete! {.val {total_downloaded_this_run}} records downloaded this run."
      )
      cli::cli_alert_success(
        "Total records now in file: {.val {total_in_csv}}"
      )

      # Delete checkpoint
      if (file.exists(checkpoint_path)) {
        file.remove(checkpoint_path)
        cli::cli_alert_info("Checkpoint file deleted.")
      }

      # Print output paths
      cli::cli_h2("Output Files")
      cli::cli_alert_success("CSV:   {.path {normalizePath(csv_path, mustWork = FALSE)}}")
      cli::cli_alert_success("RData: {.path {normalizePath(rdata_path, mustWork = FALSE)}}")
    }
  }
}
