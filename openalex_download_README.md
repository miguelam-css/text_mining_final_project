# OpenAlex Article Metadata Downloader — README

## What This Script Does

This R script bulk-downloads academic article metadata from [OpenAlex](https://openalex.org/) — an open, free index of hundreds of millions of scholarly works. It saves everything to local files on your computer so you can analyse it offline.

**In practical terms, you can use it to:**

-   Download every article ever published in one or more journals.
-   Download articles from a date range (e.g. 2020–2024).
-   Filter by type, language, open-access status, or any other OpenAlex field.
-   Combine all of the above (e.g. "all open-access English-language articles in *Nature Human Behaviour* and *Humanities & Social Sciences Communications* from 2020 onwards").

The script produces two output files:

| File | Format | Purpose |
|------------------------|------------------------|------------------------|
| `articles.csv` | Comma-separated values | Human-readable flat table. Opens in Excel, Google Sheets, Python, R, etc. |
| `articles.RData` | Native R binary | Lossless archive preserving all nested data structures exactly as the API returned them. Best for further analysis in R. |

It is designed to be **safe to interrupt and re-run**. If your computer crashes, your internet drops, or the API rate limit is reached, simply run the script again — it picks up exactly where it left off.

------------------------------------------------------------------------

## Requirements

### Software

-   **R** (version 4.1 or later, for native pipe `|>` support).
-   **RStudio** (any recent version). The script uses `rstudioapi` to find its own location on disk.

### R Packages

The script needs the following packages. If any are missing it will stop immediately and tell you exactly what to install.

``` r
install.packages(c(
  "openalexR", "dplyr", "tidyr", "purrr", "tibble", "readr", "stringr",
  "lubridate", "janitor", "cli", "jsonlite", "digest", "httr2", "rstudioapi"
))
```

**Important:** The script requires `openalexR` version 2.0.0 or later. If you have an older version, update it with `install.packages("openalexR")`.

### OpenAlex API Key (Required)

As of February 2025, the OpenAlex API requires an API key for all requests. Without a key you are limited to 100 credits per day (testing only). With a free key you get 100,000 credits per day.

**Get your free key at:** [openalex.org/settings/api](https://openalex.org/settings/api)

Then enter it in the script's configuration block:

``` r
api_key <- "YOUR_KEY_HERE"
```

### Email (Recommended)

Providing your email gives you access to OpenAlex's "polite pool" — faster, more reliable responses. No sign-up required; just enter any valid email.

------------------------------------------------------------------------

## Quick Start

1.  **Save the script** — put `openalex_download.R` in any folder on your computer.
2.  **Open it in RStudio** — double-click the file or use File → Open.
3.  **Edit the configuration block** at the top (see details below). At minimum:
    -   Set your `email`.
    -   Set your `api_key`.
    -   Uncomment and fill in at least one journal in the `journals` list.
4.  **Set `dry_run <- TRUE`** and **source the script** (`Ctrl+Shift+S` / `Cmd+Shift+S`). This previews how many articles match your filters without downloading anything.
5.  If the numbers look right, **set `dry_run <- FALSE`** and source again. The download begins.
6.  When it finishes, your files are in the `data/` subfolder next to the script.

------------------------------------------------------------------------

## Configuration Reference

The configuration block is at the very top of the script, between the two box-drawing borders. **This is the only part you need to edit.** Every setting is explained below.

### OUTPUT

``` r
data_folder <- file.path(
  dirname(rstudioapi::getSourceEditorContext()$path), "data"
)
output_csv   <- "articles.csv"
output_rdata <- "articles.RData"
```

| Variable | What it controls | Default |
|------------------------|------------------------|------------------------|
| `data_folder` | The folder where all output files are saved. Created automatically if it doesn't exist. | A folder called `data/` next to the script. |
| `output_csv` | File name for the CSV output. | `"articles.csv"` |
| `output_rdata` | File name for the RData output. | `"articles.RData"` |

You can change `data_folder` to any absolute path, e.g. `"/home/me/research/openalex_data"`.

### CREDENTIALS

``` r
email   <- "your.email@example.com"
api_key <- NULL
```

| Variable | What it controls |
|------------------------------------|------------------------------------|
| `email` | Your email address, sent to OpenAlex so they can contact you if your queries cause problems. Strongly recommended. |
| `api_key` | Your OpenAlex API key (character string in quotes). Get a free one at [openalex.org/settings/api](https://openalex.org/settings/api). Leave as `NULL` only for quick testing (100 credits/day). |

### JOURNALS

This is where you specify which journals to download articles from. Each journal is a `list(...)` with three fields — you only need to fill in **one** of them.

``` r
journals <- list(
  list(openalex_id = "https://openalex.org/S2764866340", issn = NULL, name = NULL),
  list(openalex_id = NULL, issn = "2662-9992", name = NULL),
  list(openalex_id = NULL, issn = NULL, name = "Science")
)
```

**The three ways to identify a journal:**

| Field | What to enter | Speed | Precision |
|------------------|------------------|------------------|------------------|
| `openalex_id` | The OpenAlex Source ID (e.g. `"https://openalex.org/S2764866340"`). Find it on [OpenAlex.org](https://openalex.org/) by searching for the journal, or copy it from the script's output after a first run. | Fastest (no lookup needed) | Exact |
| `issn` | The journal's ISSN (print or electronic). Find it on the journal's website or on [portal.issn.org](https://portal.issn.org/). | Fast (one API lookup) | Exact |
| `name` | The journal's display name (e.g. `"Nature"`). | Slower (search query) | May match the wrong journal if the name is ambiguous |

**Tips:**

-   After the first run, the script prints the resolved OpenAlex Source ID for every journal. Copy those IDs into the `openalex_id` field to skip the lookup on future runs.
-   If you leave the `journals` list completely empty (`journals <- list()`), no journal filter is applied and the script searches across *all* of OpenAlex.
-   To download from a single journal, just include one entry.

**Handling journals that changed names:**

Some journals have been renamed over time. For example, *Humanities & Social Sciences Communications* (ISSN `2662-9992`, 2020–present) was previously published as *Palgrave Communications* (ISSN `2055-1045`, 2014–2020). These are indexed separately in OpenAlex.

If you want complete coverage including articles under the old title, add both ISSNs:

``` r
journals <- list(
  list(openalex_id = NULL, issn = "2662-9992", name = NULL),  # Current title (2020–present)
  list(openalex_id = NULL, issn = "2055-1045", name = NULL)   # Former title (2014–2020)
)
```

You can verify journal ISSNs and title changes at [portal.issn.org](https://portal.issn.org/).

### DATE RANGE

``` r
date_from <- NULL
date_to   <- NULL
```

| Variable    | Format         | Example        | Effect if NULL      |
|-------------|----------------|----------------|---------------------|
| `date_from` | `"YYYY-MM-DD"` | `"2020-01-01"` | No start date limit |
| `date_to`   | `"YYYY-MM-DD"` | `"2024-12-31"` | No end date limit   |

**Example — articles from March 2025 only:**

``` r
date_from <- "2025-03-01"
date_to   <- "2025-03-31"
```

### ADDITIONAL FILTERS

``` r
extra_filters <- list(
  # type                = "article",
  # "open_access.is_oa" = TRUE,
  # language            = "en"
)
```

This is a catch-all for any OpenAlex filter parameter. Uncomment the lines you want, or add your own. The full list of available filters is in the [OpenAlex API documentation](https://docs.openalex.org/api-entities/works/filter-works).

**Common examples:**

``` r
extra_filters <- list(
  type                = "article",      # Only journal articles (excludes reviews, editorials, etc.)
  "open_access.is_oa" = TRUE,           # Only open-access articles
  language            = "en"            # Only English-language articles
)
```

You can combine as many filters as you like. Leave the list empty (no uncommented lines) to apply no extra filters.

### OPTIONS

``` r
dry_run              <- FALSE
rdata_write_interval <- 10
```

| Variable | What it controls | Default |
|------------------------|------------------------|------------------------|
| `dry_run` | If `TRUE`, the script resolves journals, counts how many articles match your filters, reports how many you've already downloaded and how many are new — then **stops without downloading anything**. Use this to preview before committing to a long download. | `FALSE` |
| `rdata_write_interval` | How often the `.RData` file is rewritten, measured in batches (each batch = up to 200 articles). The CSV is always saved after every single batch. Higher values mean faster runs; lower values mean the `.RData` file stays more up-to-date if the script crashes mid-run. | `10` |

------------------------------------------------------------------------

## How to Use It: Step by Step

### First Run

1.  Open the script in RStudio and fill in the configuration.

2.  **Set `dry_run <- TRUE`** and source the script. It will report something like:

    ```         
    ℹ Total on OpenAlex:      210
    ℹ Already downloaded:     0
    ℹ New records available:  210
    ℹ Dry run complete. Set dry_run <- FALSE to download.
    ```

3.  If the numbers look right, **set `dry_run <- FALSE`** and source again. The download begins.

4.  Watch the progress messages in the console:

    ```         
    ℹ Starting download: 3 batches of up to 100 records.
    ℹ [Batch 1 of 3] Downloaded 100 records — total so far: 100
    ℹ [Batch 2 of 3] Downloaded 100 records — total so far: 200
    ℹ [Batch 3 of 3] Downloaded 10 records — total so far: 210
    ```

5.  When it finishes, your files are in the `data/` folder.

### Resuming After a Crash or Interruption

Simply source the script again with the same configuration. The script:

1.  Reads the existing CSV to see which articles are already downloaded.
2.  Reads the checkpoint file (if one exists) to see where it left off.
3.  Downloads only the missing records.

No data is lost and no duplicates are created.

### Updating an Existing Dataset

If time has passed and new articles have been published, source the script again. It will detect the new articles and download only those, appending them to the existing files.

**Important:** If you change the journal list, date range, or extra filters between runs, the checkpoint system will detect the mismatch and stop with a warning. You must either: - Restore the original filters to resume the previous download, or - Delete the checkpoint file (path shown in the error message) to start a fresh download with the new filters.

The CSV is never deleted automatically — old data is preserved.

### Downloading from Multiple Journals

Just add more entries to the `journals` list. All articles from all listed journals are combined into a single download. The `journal_name` column in the CSV tells you which journal each article came from.

------------------------------------------------------------------------

## Output Files Explained

### The CSV File (`articles.csv`)

A flat table where every row is one article. Key columns include:

| Column | Description |
|------------------------------------|------------------------------------|
| `openalex_id` | The unique OpenAlex Work ID (e.g. `https://openalex.org/W2741809807`). |
| `journal_name` | Display name of the source journal. |
| `publication_year` | Year of publication (integer). |
| `title` | Article title. |
| `abstract_plain_text` | The full abstract as readable text, reconstructed from OpenAlex's inverted index. `NA` if no abstract is available. |
| `abstract_inverted_index` | The raw inverted index as a JSON string (for programmatic use). |
| `downloaded_at` | UTC timestamp of when this row was downloaded. |
| `authors_names` | All author names, separated by `\|`. |
| `authors_institutions` | All author institution names, separated by `\|`. |
| `authors_orcids` | All author ORCID identifiers, separated by `\|`. |
| `doi` | The article's DOI. |
| `cited_by_count` | Number of citations at download time. |
| `type` | Work type (article, review, etc.). |
| `language` | Language code (en, fr, de, etc.). |

Every other field returned by the API is also included as additional columns.

**Multi-value fields** (authors, keywords, concepts, topics, etc.) are stored as pipe-separated strings. For example:

```         
authors_names: "Alice Smith | Bob Jones | Carol Lee"
```

To split them back into individual values in R:

``` r
library(tidyr)
articles |>
  separate_rows(authors_names, sep = " \\| ")
```

### The RData File (`articles.RData`)

Contains the same data but in R's native format with all nested structures intact (list-columns, data frames inside data frames, etc.). Load it with:

``` r
load("data/articles.RData")
# The tibble is now available as `articles_raw`
```

This is the best format for advanced analysis in R because no information is lost to flattening.

### The Checkpoint File (`articles_checkpoint.rds`)

A temporary file that tracks download progress. It is: - Created when a download begins. - Updated after every batch. - Deleted automatically when the download completes successfully.

If this file exists, it means a previous download was interrupted. The script will resume from it automatically.

**You should only need to interact with this file if** you want to change your filters mid-download. In that case, delete it manually to start fresh.

------------------------------------------------------------------------

## Understanding Console Output

The script uses coloured, structured output. Here's what the symbols mean:

| Symbol | Meaning |
|------------------------------------|------------------------------------|
| `✔` (green) | Success — a step completed. |
| `ℹ` (blue) | Information — status update. |
| `!` (yellow) | Warning — something non-fatal was skipped or needs attention. |
| `✖` (red) | Error — something failed. Read the message for instructions. |

A typical successful run looks like this:

```         
── OpenAlex Article Metadata Downloader ──────────────────────────

── Configuration ──
ℹ Output folder:    data/
ℹ Journals:         3 configured
ℹ Date from:        "2025-03-01"
ℹ Date to:          "2025-03-31"
...

── Step 2: Journal Resolution ──
✔ Journal 1: ISSN "2397-3374" resolved to "https://openalex.org/S2764866340"
  ℹ Tip: Copy "https://openalex.org/S2764866340" into openalex_id for faster future runs.
✔ Journal 2: ISSN "2662-9992" resolved to "https://openalex.org/S4210206302"
✔ Journal 3: ISSN "2055-1045" resolved to "https://openalex.org/S2737936280"
✔ Resolved 3 of 3 journals.

── Step 3: Pre-fetching Article IDs ──
ℹ Total articles matching filters on OpenAlex: 210
ℹ Already downloaded: 0
ℹ New to download:    210

── Step 4: Checkpoint Management ──
ℹ Created new checkpoint with 210 IDs.

── Step 5: Downloading Records ──
ℹ Starting download: 3 batches of up to 100 records.
ℹ [Batch 3 of 3] Downloaded 10 records — total so far: 210

── Step 6: Completion ──
✔ .RData file written with 210 records.
✔ Download complete! 210 records downloaded this run.
✔ Total records now in file: 210
ℹ Checkpoint file deleted.

── Output Files ──
✔ CSV:   /home/you/project/data/articles.csv
✔ RData: /home/you/project/data/articles.RData
```

### About the Warnings

After a run you may see a message like `There were 50 or more warnings (use warnings() to see the first 50)`. These are almost always from the abstract reconstruction step — many articles on OpenAlex simply don't have abstracts, and each missing one generates a warning. This is normal and expected; the `abstract_plain_text` column will be `NA` for those articles.

You may also see a one-time message from `openalexR` v2.0.0 about column name changes. This is informational and does not affect the script's operation. It only appears once every 8 hours.

------------------------------------------------------------------------

``` r
library(readr)
articles <- read_csv("data/articles.csv") |>
  select(openalex_id, title, publication_year, doi, authors_names, cited_by_count)
```

### Abstracts are NA for many articles

Not all articles on OpenAlex have abstracts. This is a data availability issue, not a script error. The `abstract_plain_text` column will be `NA` for any article where OpenAlex has no abstract data.

------------------------------------------------------------------------

## License and Attribution

This script uses the [OpenAlex](https://openalex.org/) API, which is free and open. If you use OpenAlex data in a publication, please cite it per their [guidelines](https://docs.openalex.org/).

The script itself is provided as-is for research use.

This script was developed by Miguel Agenjo, Noah Fürup, Eva Lambistos, and Alicia Miras, in the context of the *Text Mining* course in the *Masters in Computational Social Science* of Universidad Carlos III of Madrid, using Claude Sonnet 4.6.

This script is released under the MIT License. You are free to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the software, provided the original copyright notice and this permission notice are included in all copies or substantial portions of the software.

Copyright (c) 2025 Miguel Agenjo, Noah Fürup, Eva Lambistos, and Alicia Miras.


