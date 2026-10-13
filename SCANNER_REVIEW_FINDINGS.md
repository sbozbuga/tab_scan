# Enterprise Table Scanner — Architecture & Performance Review Findings

This document records the line-by-line architectural, functional, and performance audit of the `/CTDI/` Scanner Framework in `bs_util`.

---

## 1. Executive Summary & Strengths

### Architectural Strengths
- **Separation of Concerns**: Metadata introspection ([`/CTDI/CL_TABLE_METADATA`](src/%23ctdi%23cl_table_metadata.clas.abap)), composite-key partitioning ([`/CTDI/CL_KEY_PARTITIONER`](src/%23ctdi%23cl_key_partitioner.clas.abap)), data access facade ([`/CTDI/CL_TABLE_READER`](src/%23ctdi%23cl_table_reader.clas.abap)), parallel task orchestration ([`/CTDI/CL_SCAN_PARALLEL`](src/%23ctdi%23cl_scan_parallel.clas.abap)), and stateless inspection ([`/CTDI/CL_CNTRL_SCANNER`](src/%23ctdi%23cl_cntrl_scanner.clas.abap)) are cleanly decoupled.
- **Clean Core Compliance**: Uses released function modules (`SPBT_GET_PP_INFO`, `TH_WP_INFO`, `VIEW_AUTHORITY_CHECK`, `BAL_*`) instead of unreleased kernel calls, and binary cluster buffers (`EXPORT/IMPORT ... DATA BUFFER`) instead of XML 1.0 (preserving `0x00` NUL bytes).

### Performance Strengths
- **C-Kernel `NA` / `CA` Fast Path**: [`/CTDI/CL_CNTRL_SCANNER=>scan_row_by_index`](src/%23ctdi%23cl_cntrl_scanner.clas.abap) and `scan_value` test `<fld> NA iv_chars` in the ABAP C-kernel before `CONV string`, and use `CA` (`sy-fdpos`) to jump directly to control characters without character-by-character loops.
- **Pre-Resolved Component Indices & Lazy Key Building**: `scan_table` resolves column names to 1-based structure indices once per table (`ASSIGN COMPONENT <comp>-index`) and only invokes `build_keyinfo` on rows that actually contain violations.
- **Column Projection & Slice-Map Parallelism**: Workers receive lightweight key-range packets (`ts_packet`) rather than serialized row tables, and `SELECT` queries project only primary keys + target character columns (`build_projection`).

---

## 2. Confirmed Bugs & Functional Gaps

### 2.1 Parallel Engine Ignores `ii_rule` and User-Selected Scope (High)
- **Location**: [`src/#ctdi#cl_scan_engine_univ.clas.abap` (Lines 16–35)](src/%23ctdi%23cl_scan_engine_univ.clas.abap)
- **Details**:
  ```abap
  DATA ls_scope TYPE /ctdi/cl_cntrl_scanner=>ts_scope.
  " Default scope (full set) if rule is control characters
  ls_scope = VALUE #( common = abap_true ).
  ```
  Although `/CTDI/CNTRL_CHECK` instantiates `lo_rule = NEW /ctdi/cl_cntrl_scanner( is_scope = ls_scope )` with the user's selected bands (`p_cmn`, `p_c0`, `p_c1`, `p_spc`, `so_cp`) and passes `ii_rule` to `lo_engine->execute()`, `/CTDI/CL_SCAN_ENGINE_UNIV` ignores `ii_rule` and hardcodes `ls_scope = VALUE #( common = abap_true )`. Additionally, `ms_scope` in [`/CTDI/CL_CNTRL_SCANNER` (Line 175)](src/%23ctdi%23cl_cntrl_scanner.clas.abap) is `PRIVATE` with no getter method.
- **Impact**: In **Full Table + Parallel** mode (`p_mful = 'X'` and `p_par = 'X'`), user selections for `p_c0`, `p_c1`, `p_spc`, and `so_cp` are silently ignored—only `common` (`LF`, `CR`, `TAB`) is ever scanned.
- **Recommended Fix**: Add `get_scope( )` to `/CTDI/CL_CNTRL_SCANNER` (or pass `scope` in `ts_scan_params`) and extract it in `/CTDI/CL_SCAN_ENGINE_UNIV=>execute`.

---

### 2.2 Parallel Workers Drop the Caller's `it_where` Clause (High)
- **Location**: [`src/#ctdi#cl_scan_parallel.clas.abap` (Lines 21–31, 154–165, 281–290)](src/%23ctdi%23cl_scan_parallel.clas.abap)
- **Details**:
  `ts_packet` does not include a `where` component, and `do()` calls:
  ```abap
  lo_reader->read_chunk(
    EXPORTING iv_table   = ls_packet-tablename
              it_where    = VALUE #( )
  ```
  While `probe_slices` uses `it_where` to compute slice boundaries `(after_key, end_key]` and `<sl2>-rows`, each worker reads **all** rows inside `(after_key, end_key]` without `it_where` (unlike the single-slice fast path at Line 246, which passes `it_where`).
- **Impact**: Rows excluded by `so_opt` are still read and scanned by workers, reporting false hits outside the user's filter and prematurely hitting `max_rows = <sl2>-rows + 1000` when `so_opt` is selective.
- **Recommended Fix**: Add `where TYPE /ctdi/cl_table_reader=>tt_where` to `ts_packet`, populate it in `run_parallel_scan`, and pass `ls_packet-where` to `lo_reader->read_chunk()` in `do()`.

---

### 2.3 Short Dump `CX_SY_RANGE_OUT_OF_BOUNDS` in `/CTDI/CL_SCAN_LOGGER=>add_msg` (High)
- **Location**: [`src/#ctdi#cl_scan_logger.clas.abap` (Lines 94, 102–117)](src/%23ctdi%23cl_scan_logger.clas.abap)
- **Details**:
  ```abap
  DATA(lv_txt) = CONV string( iv_text ).
  ...
  IF mv_log_handle IS NOT INITIAL.
    ...
    ls_msg-msgv1 = lv_txt(50).
    IF strlen( lv_txt ) > 50.
      ls_msg-msgv2 = lv_txt+50.
    ENDIF.
  ```
  `lv_txt` is a dynamic `TYPE string`. In ABAP, fixed-length substring access `lv_txt(50)` on a `string` whose length is less than 50 characters (e.g. `'Initiating scan for table VTRKH'` = 31 chars) raises a runtime short dump `CX_SY_RANGE_OUT_OF_BOUNDS` (`STRING_LENGTH_TOO_LARGE`).
  *(Note: Unit test `ltcl_logger` only passes on systems where `SLG0` object `/CTDI/SCAN` is not yet configured, because `BAL_LOG_CREATE` fails with `sy-subrc = 1` and leaves `mv_log_handle` initial).*
- **Recommended Fix**: Convert `lv_txt` to a fixed-length character variable (`DATA lv_char TYPE c LENGTH 200. lv_char = lv_txt.`) before slicing `lv_char+0(50)`, `lv_char+50(50)`, `lv_char+100(50)`, `lv_char+150(50)` into `msgv1..msgv4`, or use `BAL_LOG_MSG_ADD_FREE_TEXT`.

---

### 2.4 Live Remediation (`p_rfix`) Is a Stub, Ignores `p_rchr`, and Duplicates Multi-Hit Fields (High)
- **Location**: [`src/#ctdi#cl_scan_remediator.clas.abap` (Lines 61–122)](src/%23ctdi%23cl_scan_remediator.clas.abap), [`src/#ctdi#cntrl_check.prog.abap` (Line 161)](src/%23ctdi%23cntrl_check.prog.abap)
- **Details**:
  1. **No Database Update**: `execute()` acquires `ENQUEUE_E_TABLE`, logs `"Remediating..."`, and immediately calls `DEQUEUE_E_TABLE` and returns `success = abap_true` without executing any `UPDATE (iv_table)` or `COMMIT WORK`.
  2. **Unused Parameter `p_rchr`**: Selection parameter `p_rchr` (replacement character) is never passed to `/CTDI/CL_SCAN_REMEDIATOR` or `/CTDI/CL_CNTRL_SCANNER=>sanitize`.
  3. **Duplicate Field Diffs**: `it_hits` contains one row per control character occurrence. If a single field on a single row contains 4 line feeds, `simulate()` / `execute()` appends 4 duplicate diff entries for the same `(rownum, keyinfo, field)` and inflates `rs_result-changed` by 4x.
- **Recommended Fix**: Deduplicate `it_hits` by `(rownum, keyinfo, field)` before diffing/updating, pass `iv_rep_char = p_rchr` into remediation, and implement key-based dynamic row updates within the lock scope.

---

### 2.5 Checkpoint & Resume (`p_res`) Cannot Resume Interrupted or Errored Runs (High)
- **Location**: [`src/#ctdi#cntrl_check.prog.abap` (Lines 574–594, 708–747, 779–786)](src/%23ctdi%23cntrl_check.prog.abap), [`src/#ctdi#cl_scan_parallel.clas.abap` (Lines 309–318)](src/%23ctdi%23cl_scan_parallel.clas.abap)
- **Details**:
  1. **No Intermediate Checkpoints**: `create_run` writes `status = 'R'` with an empty `last_end_key`. No checkpoints are saved during package streaming or parallel execution, so a `TIME_OUT` dump or cancelled job leaves `last_end_key` empty in `INDX(SC)`.
  2. **Status Mismatch on Soft Error**: When a soft error occurs (`gv_error = abap_true`), Line 785 saves `status = 'E'`. However, resume at Line 576 checks `IF ls_ckpt-status = 'R' AND ls_ckpt-last_end_key IS NOT INITIAL` (ignoring `'E'`).
  3. **Missing `AND` Conjunction with `so_opt`**: At Lines 578–594, `lv_res_where` is appended to `lt_where` and `so_opt-low` is appended directly after it without `AND`, causing a `CX_SY_DYNAMIC_OSQL_SYNTAX` dump when both `p_res` and `so_opt` are used.
  4. **Out-of-Order Parallel Task Failure Overwrites `last_end_key`**: In `/CTDI/CL_SCAN_PARALLEL=>run_parallel_scan` (Lines 309–318), if Slice 2 fails (`<o>-message IS NOT INITIAL -> CONTINUE`) and Slice 10 succeeds, `rs_result-last_end_key` is overwritten with Slice 10's `end_key`, causing resume to permanently skip the failed Slice 2.
  5. **Serial Streaming Never Records `lt_last_key`**: In serial full-table mode (`p_mful = 'X'`, `p_par = ' '`), `lt_last_key` is never populated.

---

### 2.6 Syntax Errors in `/CTDI/CNTRL_CHECK_V2` & XML Textpool Typo (High)
- **Location**: [`src/#ctdi#cntrl_check_v2.prog.abap` (Lines 880–881, 1002, 1035)](src/%23ctdi%23cntrl_check_v2.prog.abap), [`src/#ctdi#cntrl_check.prog.xml` (Line 470)](src/%23ctdi%23cntrl_check.prog.xml)
- **Details**:
  1. Line 880 of `/CTDI/CNTRL_CHECK_V2` contains a JSON-escaped token `cl_abap_typedescr=\u003edescribe_by_data` instead of `=>`.
  2. Line 881 of `/CTDI/CNTRL_CHECK_V2` contains invalid ABAP syntax `DATA(lv_off) TYPE i.` (should be `DATA lv_off TYPE i.`).
  3. Lines 1002 & 1035 of `/CTDI/CNTRL_CHECK_V2` omit `cx_salv_not_found` in `CATCH` (which `get_column` declares as a static exception, properly caught in V1 at Line 1122).
  4. Line 470 of `src/#ctdi#cntrl_check.prog.xml` has `<ID>SO_OPT</ID>` instead of `<ID>S</ID><KEY>SO_OPT</KEY>` in the German `I18N_TPOOL`.

---

### 2.7 HANA Pushdown Engine (`CL_SCAN_ENGINE_HANA`) Row-Limit & Fallback Gaps (Medium)
- **Location**: [`src/#ctdi#cl_scan_engine_hana.clas.abap` (Lines 32–66)](src/%23ctdi%23cl_scan_engine_hana.clas.abap)
- **Details**:
  - `/CTDI/CL_CNTRL_SCANNER=>get_db_filter` currently returns `''`, so `/CTDI/CL_SCAN_ENGINE_HANA` always falls back to the Universal Engine.
  - When a rule does return a non-empty filter, `CL_SCAN_ENGINE_HANA` calls `lo_reader->read( iv_max = is_params-hmax ... )`. Because `hmax` is the **hit ceiling** (default `0` = unlimited) rather than a row limit, `UP TO 0 ROWS` in Open SQL loads all matching rows of the entire table into a single internal table at once instead of streaming in packages.

---

### 2.8 Dead Code & Unused Objects (Low)
- **Dead Variables in Reports**: `lt_fields` and `lv_patterns` in [`src/#ctdi#cntrl_check.prog.abap` (Lines 572, 596–607)](src/%23ctdi%23cntrl_check.prog.abap) and [`src/#ctdi#cntrl_check_v2.prog.abap` (Lines 232, 256–267)](src/%23ctdi%23cntrl_check_v2.prog.abap) are populated and cleared but never read anywhere.
- **Unused Duplicate Interface**: [`src/#ctdi#if_scan_sink01.intf.abap`](src/%23ctdi%23if_scan_sink01.intf.abap) is an unused duplicate of [`src/#ctdi#if_scan_sink.intf.abap`](src/%23ctdi%23if_scan_sink.intf.abap).

---

## 3. Performance Bottlenecks & Optimization Opportunities

1. **Redundant Full-Index Scan (`SELECT COUNT(*)` + `probe_slices`)**
   - In [`/CTDI/CL_SCAN_PARALLEL=>run_parallel_scan` (Lines 201–230)](src/%23ctdi%23cl_scan_parallel.clas.abap), when `iv_total_est = 0` (always true in background jobs `SM37`), it runs `SELECT COUNT(*)` and then immediately runs `probe_slices`, which scans the entire primary key index a second time. Furthermore, on the selection screen ([`/CTDI/CNTRL_CHECK` Line 280](src/%23ctdi%23cntrl_check.prog.abap)), `gv_cnt_rows` is counted without `so_opt`, skewing `calc_sizing` when `so_opt` is selective.
2. **Driver Transfers All Key Rows During `probe_slices`**
   - [`/CTDI/CL_KEY_PARTITIONER=>probe_slices` (Lines 189–221)](src/%23ctdi%23cl_key_partitioner.clas.abap) transfers every key tuple of the table from the database to the application server in packages of `iv_slice_size` just to inspect the last row (`INDEX lv_rows`) of each package before any worker starts.
3. **No Early Termination at Hit Ceiling (`p_hmax`) in Parallel Mode**
   - [`/CTDI/CL_SCAN_PARALLEL=>run_parallel_scan` (Lines 278–325)](src/%23ctdi%23cl_scan_parallel.clas.abap) submits all slices into a single `lo_par->run( p_in_tab = lt_in )` call. Even if `p_hmax = 100` is reached in the first wave, all remaining slices still execute to completion before hits are truncated at Line 323. Dispatching in bounded waves would enable early termination at `p_hmax` as well as incremental `INDX` checkpointing between waves.
4. **Unnecessary `INTO CORRESPONDING FIELDS` Overhead on Pre-Matched Dynamic Structures**
   - [`/CTDI/CL_TABLE_READER` (`read`, `read_in_packages`, `read_chunk`)](src/%23ctdi%23cl_table_reader.clas.abap) uses `INTO CORRESPONDING FIELDS OF TABLE @<lt_data>` even though `build_projection` constructs `er_struct` with the exact same columns and order as `ev_cols`. Using `INTO TABLE @<lt_data>` avoids per-row field mapping overhead across multi-million row scans.
5. **Character-by-Character Loop in `sanitize()`**
   - Unlike `scan_value`, [`/CTDI/CL_CNTRL_SCANNER=>sanitize` (Lines 549–588)](src/%23ctdi%23cl_cntrl_scanner.clas.abap) iterates over every character (`WHILE lv_i < lv_len`) and invokes `cl_abap_conv_out_ce=>uccp` and `line_exists( gt_special[ ... ] )` per character. Adding an upfront `NA` fast-path and copying clean substrings via `CA` offsets will significantly accelerate sanitization.
