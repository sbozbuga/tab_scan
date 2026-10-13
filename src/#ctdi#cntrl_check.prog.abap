" -----------------------------------------------------------------------
" Report  /CTDI/CNTRL_CHECK
"
" -----------------------------------------------------------------------
" Transaction                                                          -
" Date         08.10.2026                                              -
" -----------------------------------------------------------------------
" Company             CTDI GmbH Malsch Headquarter                     -
"                                                                      -
" Description:   1.) Scans the character-like fields of any table for  -
"                    control characters (newline, tab, CR, DEL, C0/C1  -
"                    block) and lists every offending row and field    -
"                    together with the hex code found.                 -
"                2.) Generic via RTTI; local dynamic SELECT or remote  -
"                    read via RFC_READ_TABLE.                           -
"                3.) Uses the reusable global classes                  -
"                    /CTDI/CL_TABLE_READER (read + field resolution)   -
"                    and /CTDI/CL_CNTRL_SCANNER (control-char scan).    -
"                                                                      -
" -----------------------------------------------------------------------
" Requested by:                                                        -
" Ticket......:                                                        -
" Concept.....:                                                        -
" Support.....: Application Development                                -
" -----------------------------------------------------------------------
" Developer...: NHS003381                                              -
"                                                                      -
" -----------------------------------------------------------------------

" -----------------------------------------------------------------------
" !!! ATTENTION, PLEASE NOTE !!! ---------------------
" -----------------------------------------------------------------------
" !!!      No corrections or enhancements without prior agreement  !!! -
" !!!      with Application Development                            !!! -
" -----------------------------------------------------------------------
" !!! No correction/enhancement without documentation in history   !!! -
" -----------------------------------------------------------------------
" Change history                                                       -
"                                                                      -
" Date       Developer   Remark                                        -
" 08.10.2026 NHS003381   Standard header filled; scanner class moved   -
"                        to CA/NA fast path (performance), CLNT filter  -
"                        once per scan, NO_DDIC_TYPE fix.               -
" 09.10.2026 NHS003381   Selectable control-char bands + explicit code  -
"                        points (F4); special band (NBSP/zero-width);   -
"                        read-mode radio (First/Last/Full-stream);       -
"                        package-streamed local full-table scan via      -
"                        /CTDI/CL_TABLE_READER + /CTDI/IF_SCAN_SINK;     -
"                        projection to scanned fields, empty-field and   -
"                        p_pkg/p_hmax guards, hit-ceiling truncation,    -
"                        partial-result on error, truncated indicator.   -
" -----------------------------------------------------------------------
REPORT /ctdi/cntrl_check.

*&---------------------------------------------------------------------*
*& Scans the character-like fields of a given table for control
*& characters (newline, tab, carriage return, DEL, etc.) and lists
*& every offending row and field together with the hex code found.
*& Generic: works for any table via RTTI.
*&
*& Built from two reusable global classes (each with its own tests):
*&   /CTDI/CL_TABLE_READER  - local dynamic SELECT / remote RFC read +
*&                            field resolution
*&   /CTDI/CL_CNTRL_SCANNER - control-character detection
*& This report drives the selection screen and presents the result.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*&  The control-character scan logic now lives in the reusable global
*&  class /CTDI/CL_CNTRL_SCANNER (with its own ABAP Unit tests). This
*&  report only resolves which fields to scan and feeds the data in.
*&---------------------------------------------------------------------*

*&---------------------------------------------------------------------*
*&  Reading (local dynamic SELECT and remote RFC_READ_TABLE) and field
*&  resolution now live in the reusable global class
*&  /CTDI/CL_TABLE_READER (with its own ABAP Unit tests). This report
*&  only drives the selection screen, calls the reader + scanner, and
*&  presents the result.
*&---------------------------------------------------------------------*
" (reader + field resolution extracted to /CTDI/CL_TABLE_READER)

*&---------------------------------------------------------------------*
*&  Selection screen
*&---------------------------------------------------------------------*
" Reference fields for the SELECT-OPTIONS below
DATA gv_optline TYPE rfc_db_opt-text. " 72-char WHERE fragment (like RFC_READ_TABLE)
DATA gv_fldname TYPE fieldname.

DATA gv_cpref TYPE c LENGTH 4.

*&---------------------------------------------------------------------*
*&  ZONE 1: TARGET DATASET & SELECTION CRITERIA
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b_data WITH FRAME TITLE gv_tdata.
PARAMETERS: p_tab TYPE tabname OBLIGATORY,
            p_rfc TYPE rfcdest.              " RFC dest (empty = local)
SELECTION-SCREEN SKIP 1.
PARAMETERS: p_schk AS CHECKBOX DEFAULT 'X',   " skip fields with a check table / foreign key
            p_cols TYPE i DEFAULT 1.          " 1-based start column (scan from here on)
SELECT-OPTIONS: so_fld FOR gv_fldname,        " Fields to scan (empty = all char fields)
                so_opt FOR gv_optline LOWER CASE. " WHERE condition fragments
SELECTION-SCREEN END OF BLOCK b_data.

*&---------------------------------------------------------------------*
*&  ZONE 2: EXECUTION ENGINE & CAPACITY (LOCAL PATH)
*&  Read mode, block/stream sizing, and the parallel capacity controls.
*&  Fields grey out by MODIF ID group (BLK/FUL/PAR/RFC) in PBO.
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b_eng WITH FRAME TITLE gv_teng.
PARAMETERS: p_mfst RADIOBUTTON GROUP mod
                   USER-COMMAND modsel MODIF ID rfc,     " First block
            p_mlst RADIOBUTTON GROUP mod MODIF ID rfc,   " Last block by key
            p_mful RADIOBUTTON GROUP mod DEFAULT 'X' MODIF ID rfc. " Full table (stream) - default
SELECTION-SCREEN SKIP 1.
PARAMETERS: p_max  TYPE i DEFAULT 1000 MODIF ID blk,     " block size (rows to read)
            p_skip TYPE i DEFAULT 0    MODIF ID blk.     " rows to skip (block offset)
PARAMETERS: p_pkg  TYPE i DEFAULT 50000 MODIF ID ful,    " package size (Full)
            p_hmax TYPE i DEFAULT 0     MODIF ID ful.    " stop after N hits (0 = all)
SELECTION-SCREEN SKIP 1.
PARAMETERS: p_par  AS CHECKBOX DEFAULT 'X' USER-COMMAND parsel MODIF ID ful, " parallel scan (Full) - default on
            p_auto AS CHECKBOX DEFAULT 'X' MODIF ID par,         " auto pack sizing (parallel)
            p_pct  TYPE i DEFAULT 50       MODIF ID par,         " % of dialog WPs (parallel)
            p_grp  TYPE rzlli_apcl DEFAULT 'parallel_generators' MODIF ID par. " RFC server group
" Live preview: rows, chosen pack size, packs/waves, and inline warnings
" (hit ceiling, WP clamp, dialog time-out, live-update caution).
SELECTION-SCREEN COMMENT /1(79) gv_sinf1.
SELECTION-SCREEN COMMENT /1(79) gv_sinf2.
SELECTION-SCREEN COMMENT /1(79) gv_sinf3.
SELECTION-SCREEN END OF BLOCK b_eng.

*&---------------------------------------------------------------------*
*&  ZONE 3: INSPECTION RULES & DEFECT SCOPE
*&  Independent control-character bands + explicit code points (hex).
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b_rule WITH FRAME TITLE gv_trule.
PARAMETERS: p_cmn AS CHECKBOX DEFAULT 'X',  " Line breaks & tab (LF, CR, TAB)
            p_c0  AS CHECKBOX,              " Other C0 controls (0x00-0x1F)
            p_c1  AS CHECKBOX,              " C1 block (0x80-0x9F)
            p_spc AS CHECKBOX.              " NBSP & zero-width / BOM family
SELECTION-SCREEN SKIP 1.
SELECT-OPTIONS so_cp FOR gv_cpref.          " Explicit code points (hex, e.g. 7F or 80-9F)
SELECTION-SCREEN END OF BLOCK b_rule.

*&---------------------------------------------------------------------*
*&  ZONE 4: ACTION, OUTPUT & GOVERNANCE
*&  Remediation mode (scan / simulate / apply), output and observability.
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b_act WITH FRAME TITLE gv_tact.
PARAMETERS: p_rscan RADIOBUTTON GROUP rmd DEFAULT 'X' USER-COMMAND rmdsel, " Scan only
            p_rsim  RADIOBUTTON GROUP rmd.                                  " Simulate remediation (diffs)
PARAMETERS: p_rchr  TYPE c LENGTH 1 DEFAULT ' ' MODIF ID rem.               " Replacement character
SELECTION-SCREEN SKIP 1.
PARAMETERS: p_save AS CHECKBOX DEFAULT 'X',   " Persist findings to /CTDI/SCAN_HITS worklist
            p_alv  AS CHECKBOX DEFAULT 'X',   " output as ALV grid (SALV)
            p_log AS CHECKBOX DEFAULT 'X',   " Log execution in SLG1 / batch log
            p_res AS CHECKBOX.               " Resume from last checkpoint if interrupted
SELECTION-SCREEN END OF BLOCK b_act.

DATA gt_hits      TYPE /ctdi/cl_cntrl_scanner=>tt_hit.
DATA gv_rows      TYPE i.
DATA gv_error TYPE abap_bool.   " a read/scan error was reported (partial result)
DATA gv_truncated TYPE abap_bool.   " full sweep stopped early at the hit ceiling

" Selection-screen AUTO-sizing preview: cached row count (per table).
" gv_sinf1 / gv_sinf2 are declared implicitly by the SELECTION-SCREEN
" COMMENT statements, so they must NOT be declared here (redeclaration).
DATA gv_cnt_tab TYPE tabname.      " table the cached count belongs to
DATA gv_cnt_rows TYPE i.            " cached COUNT(*) for gv_cnt_tab

*&---------------------------------------------------------------------*
*&  Package sink for the full-table (streamed) local scan. Scans each
*&  package the reader hands over, stamps ABSOLUTE row numbers via the
*&  base-row offset, accumulates hits, and asks the reader to stop once
*&  the hit ceiling is reached (iv_hmax = 0 means unlimited).
*&---------------------------------------------------------------------*
CLASS lcl_scan_sink DEFINITION.
  PUBLIC SECTION.
    INTERFACES /ctdi/if_scan_sink.
    METHODS constructor
      IMPORTING iv_fields TYPE /ctdi/cl_cntrl_scanner=>tt_field
                it_keys   TYPE /ctdi/cl_cntrl_scanner=>tt_field
                is_scope  TYPE /ctdi/cl_cntrl_scanner=>ts_scope
                iv_hmax   TYPE i.
    METHODS get_hits RETURNING VALUE(rt_hits) TYPE /ctdi/cl_cntrl_scanner=>tt_hit.
    METHODS get_rows RETURNING VALUE(rv_rows) TYPE i.
    METHODS is_truncated RETURNING VALUE(rv_trunc) TYPE abap_bool.
  PRIVATE SECTION.
    DATA mt_fields  TYPE /ctdi/cl_cntrl_scanner=>tt_field.
    DATA mt_keys    TYPE /ctdi/cl_cntrl_scanner=>tt_field.
    DATA ms_scope   TYPE /ctdi/cl_cntrl_scanner=>ts_scope.
    DATA mv_hmax    TYPE i.
    DATA mt_hits    TYPE /ctdi/cl_cntrl_scanner=>tt_hit.
    DATA mv_rows    TYPE i.
    DATA mv_trunc   TYPE abap_bool.
ENDCLASS.

CLASS lcl_scan_sink IMPLEMENTATION.
  METHOD constructor.
    mt_fields = iv_fields.
    mt_keys   = it_keys.
    ms_scope  = is_scope.
    mv_hmax   = iv_hmax.
  ENDMETHOD.

  METHOD /ctdi/if_scan_sink~handle_package.
    FIELD-SYMBOLS <lt_pkg> TYPE STANDARD TABLE.
    ASSIGN ir_data->* TO <lt_pkg>.

    DATA(lt_hits) = /ctdi/cl_cntrl_scanner=>scan_table( it_data   = <lt_pkg>
                                                        it_fields = mt_fields
                                                        it_keys   = mt_keys
                                                        is_scope  = ms_scope ).
    " scan_table stamps a per-package row index (1..n); shift to an absolute
    " row number by adding the rows already processed before this package.
    LOOP AT lt_hits ASSIGNING FIELD-SYMBOL(<h>).
      <h>-rownum = <h>-rownum + iv_base_row.
    ENDLOOP.
    APPEND LINES OF lt_hits TO mt_hits.
    mv_rows = mv_rows + lines( <lt_pkg> ).

    " Hit ceiling (mv_hmax > 0 = active, 0 = unlimited): truncate the
    " accumulated hits EXACTLY at the ceiling so a late package cannot
    " overshoot it, flag the truncation, and stop the sweep.
    IF mv_hmax > 0 AND lines( mt_hits ) >= mv_hmax.
      DELETE mt_hits FROM mv_hmax + 1.
      mv_trunc    = abap_true.
      rv_continue = abap_false.
    ELSE.
      rv_continue = abap_true.
    ENDIF.
  ENDMETHOD.

  METHOD get_hits.
    rt_hits = mt_hits.
  ENDMETHOD.

  METHOD get_rows.
    rv_rows = mv_rows.
  ENDMETHOD.

  METHOD is_truncated.
    rv_trunc = mv_trunc.
  ENDMETHOD.
ENDCLASS.

INITIALIZATION.
  gv_tdata = 'Target dataset & selection criteria'(010).
  gv_teng  = 'Execution engine & capacity (local path)'(011).
  gv_trule = 'Inspection rules & defect scope'(012).
  gv_tact  = 'Action, output & governance'(013).

*&---------------------------------------------------------------------*
*&  Grey out the start column when an explicit FIELDS list is entered -
*&  FIELDS and start column are alternative ways to pick fields, so the
*&  start column is inactive once FIELDS is filled.
*&---------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.
  " ---- AUTO-sizing preview (parallel + Full + local) ----------------
  " Show the user what AUTO will do: row count, chosen pack size, packs
  " and waves. The COUNT(*) is cached per table (recomputed only when the
  " table name changes) so it does not run on every screen refresh; the
  " sizing arithmetic is cheap and recomputed each PBO.
  CLEAR: gv_sinf1, gv_sinf2, gv_sinf3.
  " Skip the preview on the EXECUTE round-trip (sy-ucomm = 'ONLI') - it is
  " purely informational, and recomputing it (incl. the COUNT) right before
  " the run just adds startup latency. Only compute it while the user is
  " interacting with the screen, and only on the local path with a table set.
  IF sy-ucomm <> 'ONLI' AND p_rfc IS INITIAL AND p_tab IS NOT INITIAL.
    " (re)count only when the table changed - COUNT(*) is the expensive part.
    IF p_tab <> gv_cnt_tab.
      TRY.
          SELECT COUNT(*) FROM (p_tab) INTO @gv_cnt_rows.
        CATCH cx_root.
          gv_cnt_rows = 0.
      ENDTRY.
      gv_cnt_tab = p_tab.
    ENDIF.

    IF p_mful = abap_true AND p_par = abap_true AND p_auto = abap_true.
      " Full parallel + AUTO: show the derived pack size, packs and waves.
      DATA(lv_w)  = /ctdi/cl_scan_parallel=>calc_width( iv_percentage = p_pct
                                                        iv_group      = p_grp ).
      DATA lv_ps TYPE i.
      DATA lv_pw TYPE i.
      /ctdi/cl_scan_parallel=>calc_sizing( EXPORTING iv_total   = gv_cnt_rows
                                                     iv_width   = lv_w
                                           IMPORTING ev_pkgsize = lv_ps
                                                     ev_perwave = lv_pw ).
      DATA(lv_packs) = COND i( WHEN lv_ps > 0 THEN ( gv_cnt_rows + lv_ps - 1 ) DIV lv_ps ELSE 0 ).
      DATA(lv_waves) = COND i( WHEN lv_pw > 0 THEN ( lv_packs + lv_pw - 1 ) DIV lv_pw ELSE 0 ).
      gv_sinf1 = |Rows ~{ gv_cnt_rows }  Pack size { lv_ps }  (auto, band 40k-60k)|.
      gv_sinf2 = |{ lv_packs } packs in { lv_waves } waves of { lv_pw } | &&
                 |(width from { p_pct }% of free WPs)|.
      " Inline warning: requested share exceeds the free WPs actually available,
      " so the real width was clamped down - tell the user the effective width.
      IF lv_w > 0 AND lv_pw < ( p_pct * lv_w / 100 ).
        gv_sinf3 = |Note: parallel width clamped to { lv_pw } by free work processes|.
      ENDIF.
    ELSEIF p_mful = abap_true.
      " Full serial (or AUTO off): a whole-table sweep in fixed packages.
      DATA(lv_fpacks) = COND i( WHEN p_pkg > 0 THEN ( gv_cnt_rows + p_pkg - 1 ) DIV p_pkg ELSE 0 ).
      gv_sinf1 = |Rows ~{ gv_cnt_rows }  Full sweep in { lv_fpacks } packages of { p_pkg }|.
    ELSE.
      " Block modes (First / Last): we read at most p_max rows.
      DATA(lv_read) = COND i( WHEN gv_cnt_rows > 0 AND gv_cnt_rows < p_max THEN gv_cnt_rows ELSE p_max ).
      gv_sinf1 = |Rows ~{ gv_cnt_rows }  Reading up to { lv_read } rows | &&
                 COND #( WHEN p_mlst = abap_true THEN |(last block by key)| ELSE |(from offset { p_skip })| ).
    ENDIF.

    " Hit-ceiling hint on a full sweep: 0 = unlimited, so the whole table is scanned.
    IF p_mful = abap_true AND p_hmax = 0 AND gv_sinf3 IS INITIAL.
      gv_sinf3 = |No hit ceiling: the full ~{ gv_cnt_rows } rows will be scanned|.
    ENDIF.
  ENDIF.

  " Live-update caution always wins the warning line - this path writes to
  " the table, so make it loud regardless of the sizing hints above.


  " The read-mode radio group and the control-character SCOPE are LOCAL-path
  " features. The RFC path (read_remote) always does a first-block read with
  " the full legacy control set, so on RFC we force First mode and disable
  " the local-only controls to keep the screen honest about what will run.
  IF p_rfc IS NOT INITIAL AND p_mfst = abap_false.
    p_mful = abap_false.
    p_mlst = abap_false.
    p_mfst = abap_true.
  ENDIF.

  " Field enable/disable. Driven by MODIF ID groups set in the declaration:
  "   RFC - read-mode radios (local-path only)
  "   BLK - block-read size/offset (First/Last modes)
  "   FUL - full-stream fields incl. the parallel toggle
  "   PAR - parallel-only fields (auto / share / server group)
  "   REM - remediation replacement character
  LOOP AT SCREEN.
    " start column is inactive once an explicit FIELDS list is given
    IF screen-name = 'P_COLS' AND so_fld[] IS NOT INITIAL.
      screen-input = 0.
      MODIFY SCREEN.
    ENDIF.
    " On the RFC path, read-mode / stream / parallel and the scope + remediation
    " controls do not apply - the remote read is always a first-block scan with
    " the full legacy control set. Disable everything local-only so the screen
    " stays honest about what will actually run remotely.
    IF p_rfc IS NOT INITIAL
       AND (    screen-group1 = 'RFC' OR screen-group1 = 'BLK'
             OR screen-group1 = 'FUL' OR screen-group1 = 'PAR'
             OR screen-group1 = 'REM'
             OR screen-name = 'P_CMN'  OR screen-name = 'P_C0'
             OR screen-name = 'P_C1'   OR screen-name = 'P_SPC'
             OR screen-name = 'P_RES'  OR screen-name = 'P_RSCAN'
             OR screen-name = 'P_RSIM' OR screen-name = 'P_SAVE' ).
      screen-input = 0.
      MODIFY SCREEN.
      CONTINUE.
    ENDIF.
    " Full-stream fields (incl. the parallel toggle) apply only to Full mode.
    IF screen-group1 = 'FUL' AND p_mful = abap_false.
      screen-input = 0.
      MODIFY SCREEN.
    ENDIF.
    " Parallel-only fields need both Full mode AND the parallel toggle on.
    IF screen-group1 = 'PAR' AND ( p_mful = abap_false OR p_par = abap_false ).
      screen-input = 0.
      MODIFY SCREEN.
    ENDIF.
    " Explicit package size is inactive when auto sizing is on (parallel).
    IF screen-name = 'P_PKG' AND p_mful = abap_true
       AND p_par = abap_true AND p_auto = abap_true.
      screen-input = 0.
      MODIFY SCREEN.
    ENDIF.
    " Block read size / offset apply only to the block modes (First / Last).
    IF screen-group1 = 'BLK' AND p_mful = abap_true.
      screen-input = 0.
      MODIFY SCREEN.
    ENDIF.
    " Block offset (skip) is meaningless for the Last-block mode.
    IF screen-name = 'P_SKIP' AND p_mlst = abap_true.
      screen-input = 0.
      MODIFY SCREEN.
    ENDIF.
    " Replacement character only applies when remediating (sim or apply).
    IF screen-group1 = 'REM' AND p_rscan = abap_true.
      screen-input = 0.
      MODIFY SCREEN.
    ENDIF.
  ENDLOOP.

*&---------------------------------------------------------------------*
*&  Scope guard: at least one control-character class or an explicit
*&  code point must be selected - otherwise there is nothing to scan.
*&---------------------------------------------------------------------*
AT SELECTION-SCREEN.

  IF p_cmn = abap_false AND p_c0 = abap_false AND p_c1 = abap_false
     AND p_spc = abap_false AND so_cp[] IS INITIAL.
    MESSAGE 'Select at least one control-character class or enter a code point'
            TYPE 'E'.
  ENDIF.

  " Full-table streaming parameters must be sane: a non-positive package
  " size would reach the Open SQL PACKAGE SIZE clause (dump / unbounded),
  " and a negative hit ceiling is meaningless (0 = unlimited is allowed).
  IF p_mful = abap_true.
    " Package size only matters when it is actually used: serial Full, or
    " parallel with AUTO sizing OFF. With parallel + AUTO the size is derived
    " internally, so p_pkg is irrelevant (and its field is greyed out).
    IF NOT ( p_par = abap_true AND p_auto = abap_true ).
      IF p_pkg <= 0.
        MESSAGE 'Package size must be greater than 0' TYPE 'E'.
      ENDIF.
    ENDIF.
    IF p_hmax < 0.
      MESSAGE 'Hit ceiling must be 0 (unlimited) or greater' TYPE 'E'.
    ENDIF.
    IF p_par = abap_true AND ( p_pct < 1 OR p_pct > 100 ).
      MESSAGE 'Parallel process share must be between 1 and 100 percent' TYPE 'E'.
    ENDIF.
    " A whole-table sweep on a big table can exceed rdisp/max_wprun_time in
    " a dialog work process (TIME_OUT) and tie up the WP throughout. Warn
    " when not running in background so the user can switch to a batch job.
    " 'W' lets the user acknowledge and proceed (e.g. small table) rather
    " than hard-blocking. sy-ucomm = 'ONLI' is the Execute command.
    IF sy-batch = abap_false AND sy-ucomm = 'ONLI'.
      MESSAGE 'Full-table scan in dialog may time out on big tables; ' &&
              'prefer a background job' TYPE 'W'.
    ENDIF.
  ENDIF.

  " Validate the explicit code points: only Include EQ (single) or BT
  " (range) are supported; each bound must be 1-4 hex digits and, for a
  " range, low <= high. Reject anything else with a message rather than
  " silently scanning a different (or empty) set.
  LOOP AT so_cp ASSIGNING FIELD-SYMBOL(<ls_cpv>).
    IF <ls_cpv>-sign <> 'I'.
      MESSAGE 'Code points: only Include (I) entries are supported' TYPE 'E'.
    ENDIF.
    IF <ls_cpv>-option <> 'EQ' AND <ls_cpv>-option <> 'BT'.
      MESSAGE 'Code points: only single values (EQ) or ranges (BT) are supported'
              TYPE 'E'.
    ENDIF.
    IF <ls_cpv>-low CN '0123456789ABCDEFabcdef' OR strlen( <ls_cpv>-low ) > 4.
      MESSAGE |Invalid hex code point: { <ls_cpv>-low }| TYPE 'E'.
    ENDIF.
    IF <ls_cpv>-option = 'BT'.
      IF <ls_cpv>-high CN '0123456789ABCDEFabcdef' OR strlen( <ls_cpv>-high ) > 4.
        MESSAGE |Invalid hex code point: { <ls_cpv>-high }| TYPE 'E'.
      ENDIF.
      " compare as hex: zero-pad to 4 and compare the strings in upper case
      DATA(lv_lo4) = |{ to_upper( <ls_cpv>-low ) WIDTH = 4 ALIGN = RIGHT PAD = '0' }|.
      DATA(lv_hi4) = |{ to_upper( <ls_cpv>-high ) WIDTH = 4 ALIGN = RIGHT PAD = '0' }|.
      IF lv_lo4 > lv_hi4.
        MESSAGE |Code-point range low > high: { <ls_cpv>-low }-{ <ls_cpv>-high }| TYPE 'E'.
      ENDIF.
    ENDIF.
  ENDLOOP.

*&---------------------------------------------------------------------*
*&  F4 value help for the additional code points: pick a named control
*&  character by name instead of memorising its hex code.
*&---------------------------------------------------------------------*
AT SELECTION-SCREEN ON VALUE-REQUEST FOR so_cp-low.
  PERFORM f4_codepoint USING 'SO_CP-LOW'.

AT SELECTION-SCREEN ON VALUE-REQUEST FOR so_cp-high.
  PERFORM f4_codepoint USING 'SO_CP-HIGH'.

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_grp.
  PERFORM f4_server_group.

*&---------------------------------------------------------------------*
*&  F4 value help for the FIELDS select-option: list the columns of
*&  the table currently entered in P_TAB.
*&---------------------------------------------------------------------*
AT SELECTION-SCREEN ON VALUE-REQUEST FOR so_fld-low.
  DATA lt_dynp  TYPE TABLE OF dynpread.
  DATA ls_dynp  TYPE dynpread.
  DATA lv_tabnm TYPE tabname.

  " Read the value currently typed into P_TAB (may be uncommitted)
  ls_dynp-fieldname = 'P_TAB'.
  APPEND ls_dynp TO lt_dynp.
  CALL FUNCTION 'DYNP_VALUES_READ'
    EXPORTING
      dyname     = sy-repid
      dynumb     = sy-dynnr
    TABLES
      dynpfields = lt_dynp
    EXCEPTIONS
      OTHERS     = 0.
  READ TABLE lt_dynp INTO ls_dynp INDEX 1.
  IF sy-subrc <> 0.
    RETURN.
  ENDIF.
  lv_tabnm = to_upper( ls_dynp-fieldvalue ).

  IF lv_tabnm IS INITIAL.
    MESSAGE 'Please enter a table name first' TYPE 'S' DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.

  " Field list of that table (name + short description)
  DATA lt_dfies TYPE TABLE OF dfies.
  CALL FUNCTION 'DDIF_FIELDINFO_GET'
    EXPORTING
      tabname        = lv_tabnm
      langu          = sy-langu
    TABLES
      dfies_tab      = lt_dfies
    EXCEPTIONS
      not_found      = 1
      internal_error = 2
      OTHERS         = 3.
  IF sy-subrc <> 0.
    MESSAGE |Table { lv_tabnm } not found| TYPE 'S' DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.

  " Build a slim 2-column value table (field name + description) so the
  " popup shows only those columns instead of all of DFIES's attributes.
  TYPES: BEGIN OF ts_f4,
           fieldname TYPE dfies-fieldname,
           datatype  TYPE dfies-datatype,
           leng      TYPE dfies-leng,
           text      TYPE dfies-fieldtext,
         END OF ts_f4.
  DATA lt_f4 TYPE STANDARD TABLE OF ts_f4.
  LOOP AT lt_dfies ASSIGNING FIELD-SYMBOL(<ls_dfies>).
    APPEND VALUE #( fieldname = <ls_dfies>-fieldname
                    datatype  = <ls_dfies>-datatype
                    leng      = <ls_dfies>-leng
                    text      = <ls_dfies>-fieldtext ) TO lt_f4.
  ENDLOOP.

  " Value help showing FIELDNAME + description. MULTIPLE_CHOICE lets the
  " user tick several fields; every pick comes back in RETURN_TAB.
  DATA lt_ret TYPE TABLE OF ddshretval.
  CALL FUNCTION 'F4IF_INT_TABLE_VALUE_REQUEST'
    EXPORTING
      retfield        = 'FIELDNAME'
      dynpprog        = sy-repid
      dynpnr          = sy-dynnr
      dynprofield     = 'SO_FLD-LOW'
      value_org       = 'S'
      multiple_choice = 'X'
      window_title    = 'Select one or more fields'
    TABLES
      value_tab       = lt_f4
      return_tab      = lt_ret
    EXCEPTIONS
      parameter_error = 1
      no_values_found = 2
      OTHERS          = 3.

  IF sy-subrc = 0 AND lt_ret IS NOT INITIAL.
    " Replace the current FIELDS range with the chosen field names
    CLEAR so_fld[].
    LOOP AT lt_ret ASSIGNING FIELD-SYMBOL(<ls_ret>).
      so_fld-sign   = 'I'.
      so_fld-option = 'EQ'.
      so_fld-low    = <ls_ret>-fieldval.
      APPEND so_fld TO so_fld.
    ENDLOOP.
    CLEAR so_fld.
  ENDIF.

*&---------------------------------------------------------------------*
*&  Main processing
*&---------------------------------------------------------------------*
START-OF-SELECTION.
  DATA lr_data   TYPE REF TO data.
  DATA lr_struct TYPE REF TO cl_abap_structdescr.
  FIELD-SYMBOLS <lt_data> TYPE STANDARD TABLE.

  DATA lo_logger TYPE REF TO /ctdi/cl_scan_logger.
  DATA lv_run_id TYPE SYSUUID_C22.
  IF p_log = abap_true.
    lo_logger = NEW /ctdi/cl_scan_logger( iv_extnumber = CONV #( p_tab ) ).
    lo_logger->add_info( |Initiating scan for table { p_tab }| ).
  ENDIF.

  " Collect selection-screen input into plain tables for the reader.
  " OPTIONS: free WHERE fragments.  FIELDS: explicit field names only
  " (patterns like CP cannot map to columns -> treated as "all columns").
  DATA lt_where  TYPE /ctdi/cl_table_reader=>tt_where.
  DATA lt_fields TYPE /ctdi/cl_table_reader=>tt_field.

  IF p_res = abap_true.
    DATA(ls_ckpt) = /ctdi/cl_scan_checkpoint=>get_latest_for_table( p_tab ).
    IF ls_ckpt-status = 'R' AND ls_ckpt-last_end_key IS NOT INITIAL.
      lv_run_id = ls_ckpt-run_id.
      DATA(lv_res_where) = /ctdi/cl_key_partitioner=>build_resume_where( ls_ckpt-last_end_key ).
      IF lv_res_where IS NOT INITIAL.
        APPEND lv_res_where TO lt_where.
      ENDIF.
      IF lo_logger IS BOUND.
        lo_logger->add_info( |Resuming scan run { lv_run_id }| ).
      ENDIF.
      MESSAGE |Resuming run { lv_run_id }| TYPE 'S'.
    ENDIF.
  ENDIF.
  IF lv_run_id IS INITIAL.
    lv_run_id = /ctdi/cl_scan_checkpoint=>create_run( p_tab ).
  ENDIF.

  LOOP AT so_opt ASSIGNING FIELD-SYMBOL(<ls_opt>) WHERE sign = 'I' AND option = 'EQ'.
    APPEND <ls_opt>-low TO lt_where.
  ENDLOOP.

  DATA lv_patterns TYPE abap_bool VALUE abap_false.
  LOOP AT so_fld ASSIGNING FIELD-SYMBOL(<ls_fsel>).
    IF <ls_fsel>-option <> 'EQ' OR <ls_fsel>-sign <> 'I'.
      lv_patterns = abap_true.
    ELSE.
      APPEND <ls_fsel>-low TO lt_fields.
    ENDIF.
  ENDLOOP.
  " If any pattern was used, don't project - scan all columns instead
  IF lv_patterns = abap_true.
    CLEAR lt_fields.
  ENDIF.

  DATA(lo_reader) = NEW /ctdi/cl_table_reader( ).

  " Resolve the character fields to scan from the LOCAL table definition
  " (the DDIC structure is the same whether we read local or remote).
  " FIELDS and start column are alternative ways to pick fields: when an
  " explicit FIELDS list is given it wins, and the start column is ignored.
  DATA lr_struct_f TYPE REF TO cl_abap_structdescr.
  TRY.
      lr_struct_f ?= cl_abap_typedescr=>describe_by_name( p_tab ).
    CATCH cx_root INTO DATA(lx_desc).
      WRITE: / 'Table/structure not found:', p_tab, ':', lx_desc->get_text( ).
      RETURN.
  ENDTRY.
  DATA(lv_startcol) = COND i( WHEN so_fld[] IS INITIAL THEN p_cols ELSE 1 ).
  DATA(lt_scanflds) = lo_reader->scan_fields( ir_struct     = lr_struct_f
                                              iv_table      = p_tab
                                              iv_start_col  = lv_startcol
                                              iv_skip_check = p_schk ).
  IF so_fld[] IS NOT INITIAL.
    DELETE lt_scanflds WHERE table_line NOT IN so_fld.
  ENDIF.

  " Key fields of the table - stamped on each hit so the offending
  " record can be identified (the reader already reads the keys).
  " The client field (datatype CLNT) is skipped - it is always the
  " current client and only clutters the key display.
  DATA lt_keys TYPE /ctdi/cl_table_reader=>tt_field.
  LOOP AT lr_struct_f->get_ddic_field_list( )
       ASSIGNING FIELD-SYMBOL(<kf>)
       WHERE keyflag = abap_true AND datatype <> 'CLNT'.
    APPEND <kf>-fieldname TO lt_keys.
  ENDLOOP.

  IF p_rfc IS NOT INITIAL.
    " ---- Remote read via RFC (RFC_READ_TABLE) ----------------------
    " Guardrail: RFC_READ_TABLE concatenates the selected fields into a
    " 512-byte line. Refuse up front if the selection is too wide.
    DATA(lv_width) = lo_reader->remote_width( ir_struct = lr_struct_f
                                              it_fields = lt_scanflds ).
    IF lv_width > /ctdi/cl_table_reader=>c_rfc_line_limit.
      MESSAGE |Selection too wide for RFC_READ_TABLE: { lv_width } > | &&
              |{ /ctdi/cl_table_reader=>c_rfc_line_limit } bytes. | &&
              |Reduce the fields (FIELDS) to scan remotely.| TYPE 'E'.
      RETURN.
    ENDIF.

    TRY.
        gt_hits = lo_reader->read_remote( iv_dest   = p_rfc
                                          iv_table  = p_tab
                                          it_fields = lt_scanflds
                                          it_keys   = lt_keys
                                          it_where  = lt_where
                                          iv_skip   = p_skip
                                          iv_max    = p_max ).
      CATCH cx_root INTO DATA(lx_rfc).
        WRITE: / 'Error reading', p_tab, 'via', p_rfc, ':', lx_rfc->get_text( ).
        RETURN.
    ENDTRY.
    " row count is not separately reported by the RFC read
    gv_rows = p_max.

  ELSE.
    " ---- Local read via dynamic SELECT ------------------------------
    " Nothing to scan if no character fields were resolved - reading the
    " whole table only to scan nothing would print a misleading "clean".
    IF lt_scanflds IS INITIAL.
      MESSAGE |No character fields to scan in { p_tab } | &&
              |(check FIELDS, start column and the skip-check option)| TYPE 'E'.
    ENDIF.

    " Scope is needed by both read modes - build it once.
    DATA ls_scope TYPE /ctdi/cl_cntrl_scanner=>ts_scope.
    DATA lt_last_key TYPE /ctdi/cl_table_reader=>tt_keyval.
    PERFORM build_scope CHANGING ls_scope.

    IF p_mful = abap_true AND p_par = abap_true.
      " ---- Full table, PARALLEL: batched-wave read + parallel scan ----
      " Driver reads waves of packages (resuming by key) and ships each to
      " a worker process to scan; hits are merged. lt_keys are the non-client
      " key fields - reused here as the resume key order.
      TRY.
          DATA(lo_engine) = /ctdi/cl_scan_engine_factory=>get_engine( ).
          DATA(lo_rule)   = NEW /ctdi/cl_cntrl_scanner( is_scope = ls_scope ).
          DATA(ls_pres)   = lo_engine->execute(
            is_params = VALUE #(
              table        = p_tab
              fields       = lt_scanflds
              keys         = lt_keys
              where        = lt_where
              pkg_size     = COND #( WHEN p_auto = abap_true THEN 0 ELSE p_pkg )
              percentage   = p_pct
              server_group = p_grp
              hmax         = p_hmax
              total_est    = gv_cnt_rows )
            ii_rule   = lo_rule ).
        CATCH cx_root INTO DATA(lx_par).
          gv_error = abap_true.
          WRITE: / 'Error (parallel scan)', p_tab, ':', lx_par->get_text( ).
      ENDTRY.
      gt_hits      = ls_pres-hits.
      gv_rows      = ls_pres-rows.
      gv_truncated = ls_pres-truncated.
      lt_last_key  = ls_pres-last_end_key.
      " surface any per-task errors as a partial-result flag
      IF ls_pres-errors IS NOT INITIAL.
        gv_error = abap_true.
        LOOP AT ls_pres-errors ASSIGNING FIELD-SYMBOL(<lv_perr>).
          WRITE: / 'Parallel task error:', <lv_perr>.
        ENDLOOP.
      ENDIF.

    ELSEIF p_mful = abap_true.
      " ---- Full table, SERIAL: stream in packages (bounded memory) ----
      " A sink scans each package and accumulates hits, stopping early
      " once the hit ceiling (p_hmax, 0 = unlimited) is reached.
      DATA(lo_sink) = NEW lcl_scan_sink( iv_fields = lt_scanflds
                                         it_keys   = lt_keys
                                         is_scope  = ls_scope
                                         iv_hmax   = p_hmax ).
      TRY.
          " Project to the scanned fields (+ keys), NOT the raw FIELDS list,
          " so a full sweep does not transfer every column of a wide table.
          lo_reader->read_in_packages( EXPORTING iv_table    = p_tab
                                                 it_where    = lt_where
                                                 it_fields   = lt_scanflds
                                                 ii_sink     = lo_sink
                                                 iv_pkg_size = p_pkg
                                       IMPORTING er_struct   = lr_struct ).
        CATCH cx_root INTO DATA(lx_pkg).
          " Keep whatever was found before the error - do NOT discard and
          " report a false "clean". Flag the error so END-OF-SELECTION
          " shows a partial result instead of "no control characters".
          gv_error = abap_true.
          WRITE: / 'Error streaming', p_tab, '(partial result):', lx_pkg->get_text( ).
      ENDTRY.
      gt_hits         = lo_sink->get_hits( ).
      gv_rows         = lo_sink->get_rows( ).
      gv_truncated    = lo_sink->is_truncated( ).

    ELSE.
      " ---- First / Last block: single read (classic block) ----------
      TRY.
          lo_reader->read( EXPORTING iv_table  = p_tab
                                     iv_max    = p_max
                                     iv_skip   = p_skip
                                     iv_last   = p_mlst
                                     it_where  = lt_where
                                     it_fields = lt_scanflds
                           IMPORTING er_data   = lr_data
                                     er_struct = lr_struct ).
        CATCH cx_root INTO DATA(lx).
          gv_error = abap_true.
          WRITE: / 'Error reading', p_tab, ':', lx->get_text( ).
          RETURN.
      ENDTRY.

      ASSIGN lr_data->* TO <lt_data>.
      IF <lt_data> IS INITIAL.
        WRITE: / 'No data selected from', p_tab.
        RETURN.
      ENDIF.

      gt_hits = /ctdi/cl_cntrl_scanner=>scan_table( it_data   = <lt_data>
                                                    it_fields = lt_scanflds
                                                    it_keys   = lt_keys
                                                    is_scope  = ls_scope ).
      gv_rows = lines( <lt_data> ).
    ENDIF.
  ENDIF.

  /ctdi/cl_scan_checkpoint=>save_checkpoint( VALUE #(
    run_id       = lv_run_id
    tabname      = p_tab
    last_end_key = lt_last_key
    rows_scanned = gv_rows
    hits_count   = lines( gt_hits )
    status       = COND #( WHEN gv_error = abap_true THEN 'E' ELSE 'C' )
  ) ).

  IF lo_logger IS BOUND.
    lo_logger->add_info( |Scan finished for { p_tab }: { gv_rows } rows, { lines( gt_hits ) } hits| ).
    lo_logger->save( ).
  ENDIF.

END-OF-SELECTION.
  IF gt_hits IS INITIAL.
    " Only claim "clean" when the scan actually completed without error -
    " an error path must NOT be reported as a clean table.
    IF gv_error = abap_true.
      MESSAGE |Scan of { p_tab } ended with an error - result is incomplete| TYPE 'S'
              DISPLAY LIKE 'W'.
      IF p_alv = abap_false.
        WRITE / 'Scan incomplete (see error above); no hits collected so far.'.
      ENDIF.
    ELSE.
      MESSAGE |No control characters found in { p_tab } ({ gv_rows } rows scanned)| TYPE 'S'.
      IF p_alv = abap_false.
        WRITE / 'No control characters found in character fields.'.
      ENDIF.
    ENDIF.
    RETURN.
  ENDIF.

  " Persist findings to worklist table /CTDI/SCAN_HITS if requested
  IF gt_hits IS NOT INITIAL AND p_save = abap_true.
    DATA(lv_persisted) = /ctdi/cl_scan_remediator=>persist_hits(
      iv_run_id   = lv_run_id
      iv_table    = p_tab
      it_hits     = CORRESPONDING #( gt_hits )
      iv_rep_char = p_rchr
      io_logger   = lo_logger ).
    IF lv_persisted > 0.
      MESSAGE |{ lv_persisted } findings saved to worklist /CTDI/SCAN_HITS (Run ID: { lv_run_id }). Review & apply in /CTDI/CNTRL_REVIEW|
        TYPE 'S'.
    ENDIF.
  ENDIF.

  " Remediation simulation check
  IF p_rsim = abap_true.
    DATA lt_viols TYPE /ctdi/if_inspection_rule=>tt_violation.
    lt_viols = CORRESPONDING #( gt_hits ).
    DATA(ls_sim_res) = /ctdi/cl_scan_remediator=>simulate(
      it_hits     = lt_viols
      iv_rep_char = p_rchr ).
    PERFORM display_remediation_diffs USING ls_sim_res-diffs.
    RETURN.
  ENDIF.

  " Make a partial / truncated result visible rather than silently showing
  " it as if it were a complete scan.
  IF gv_error = abap_true.
    MESSAGE |Partial result for { p_tab }: scan ended with an error| TYPE 'S'
            DISPLAY LIKE 'W'.
  ELSEIF gv_truncated = abap_true.
    MESSAGE |Result truncated at the hit ceiling ({ lines( gt_hits ) } hits) | &&
            |- more may exist in { p_tab }| TYPE 'S' DISPLAY LIKE 'W'.
  ENDIF.

  IF p_alv = abap_true.
    PERFORM display_salv.
  ELSE.
    " classic list fallback
    DATA(lv_note) = COND string(
      WHEN gv_error     = abap_true THEN ' (PARTIAL - error)'
      WHEN gv_truncated = abap_true THEN ' (TRUNCATED at hit ceiling)'
      ELSE '' ).
    WRITE: / 'Table:', p_tab, '  Rows scanned:', gv_rows, lv_note.
    WRITE: / 'Control-character hits:', lines( gt_hits ).
    ULINE.
    FORMAT COLOR COL_HEADING.
    WRITE: /(8) 'Row', (45) 'Key', (30) 'Field', (6) 'Ofs', (8) 'Hex',
            (28) 'Control char', (40) 'Value'.
    FORMAT COLOR OFF.
    LOOP AT gt_hits ASSIGNING FIELD-SYMBOL(<ls_hit>).
      WRITE: /(8)  <ls_hit>-rownum,
              (45) <ls_hit>-keyinfo,
              (30) <ls_hit>-field,
              (6)  <ls_hit>-offset,
              (8)  <ls_hit>-hexcode,
              (28) <ls_hit>-descr,
              (40) <ls_hit>-value.
    ENDLOOP.
  ENDIF.

*&---------------------------------------------------------------------*
*&      Form  build_scope
*&      Map the selection-screen band checkboxes and the explicit code
*&      points (so_cp) onto the scanner scope. Each so_cp line becomes a
*&      token: low-only -> "code", low+high -> "low-high" range.
*&---------------------------------------------------------------------*
FORM build_scope CHANGING cs_scope TYPE /ctdi/cl_cntrl_scanner=>ts_scope.
  cs_scope-common   = p_cmn.
  cs_scope-c0_other = p_c0.
  cs_scope-c1       = p_c1.
  cs_scope-special  = p_spc.
  LOOP AT so_cp ASSIGNING FIELD-SYMBOL(<ls_cp>) WHERE sign = 'I'.
    DATA lv_tok TYPE string.
    IF <ls_cp>-option = 'BT' AND <ls_cp>-high IS NOT INITIAL.
      lv_tok = |{ <ls_cp>-low }-{ <ls_cp>-high }|.
    ELSE.
      lv_tok = <ls_cp>-low.
    ENDIF.
    cs_scope-extra_cp = COND #( WHEN cs_scope-extra_cp IS INITIAL THEN lv_tok
                                ELSE |{ cs_scope-extra_cp } { lv_tok }| ).
  ENDLOOP.
ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  f4_codepoint
*&      Shared value help for the explicit code-point select-option.
*&      Lists named control characters (hex code + name) and writes the
*&      chosen hex code back into the triggering screen field (LOW or
*&      HIGH), so the user can build a single point or a low-high range.
*&---------------------------------------------------------------------*
FORM f4_codepoint USING pv_dynprofield TYPE help_info-dynprofld.
  TYPES: BEGIN OF ts_cpf4,
           code TYPE c LENGTH 4,
           name TYPE c LENGTH 40,
         END OF ts_cpf4.
  DATA lt_cpf4 TYPE STANDARD TABLE OF ts_cpf4.
  lt_cpf4 = VALUE #(
    ( code = '0000' name = 'NUL (null)' )
    ( code = '0008' name = 'BS (backspace)' )
    ( code = '0009' name = 'HT (tab)' )
    ( code = '000A' name = 'LF (line feed)' )
    ( code = '000B' name = 'VT (vertical tab)' )
    ( code = '000C' name = 'FF (form feed)' )
    ( code = '000D' name = 'CR (carriage return)' )
    ( code = '001B' name = 'ESC (escape)' )
    ( code = '007F' name = 'DEL (delete)' )
    ( code = '001D' name = 'GS (group separator)' )
    ( code = '0085' name = 'NEL (next line, C1)' )
    ( code = '009B' name = 'CSI (control seq. intro, C1)' )
    ( code = '0080' name = 'C1 block start (range 0080-009F)' )
    ( code = '00A0' name = 'NBSP (no-break space)' )
    ( code = '200B' name = 'ZWSP (zero width space)' )
    ( code = '200C' name = 'ZWNJ (zero width non-joiner)' )
    ( code = '200D' name = 'ZWJ (zero width joiner)' )
    ( code = 'FEFF' name = 'BOM / ZWNBSP (0xFEFF)' ) ).

  " FIELD_TAB column layout must match the ACTUAL (Unicode) memory layout of
  " the value structure, so derive offset/intlen via RTTI (a C(4) is 8 bytes
  " on a Unicode system - hard-coded offsets misalign the columns).
  DATA lt_cpfld TYPE TABLE OF dfies.
  DATA(lo_cpstr) = CAST cl_abap_structdescr(
                     cl_abap_typedescr=>describe_by_data( lt_cpf4[ 1 ] ) ).
  DATA lv_off TYPE i.
  LOOP AT lo_cpstr->get_components( ) ASSIGNING FIELD-SYMBOL(<c>).
    DATA(lo_el) = CAST cl_abap_elemdescr( <c>-type ).
    DATA(lv_len) = lo_el->length.
    APPEND VALUE dfies(
      tabname   = 'SO_CP'
      fieldname = <c>-name
      position  = sy-tabix
      offset    = lv_off
      intlen    = lv_len
      leng      = lo_el->output_length
      outputlen = lo_el->output_length
      datatype  = 'CHAR'
      inttype   = 'C'
      scrtext_m = COND #( WHEN <c>-name = 'CODE' THEN 'Code' ELSE 'Control character' )
      fieldtext = COND #( WHEN <c>-name = 'CODE' THEN 'Hex code' ELSE 'Control character' )
      reptext   = COND #( WHEN <c>-name = 'CODE' THEN 'Code' ELSE 'Control character' )
    ) TO lt_cpfld.
    lv_off = lv_off + lv_len.
  ENDLOOP.

  DATA lt_cpret TYPE TABLE OF ddshretval.
  CALL FUNCTION 'F4IF_INT_TABLE_VALUE_REQUEST'
    EXPORTING
      retfield        = 'CODE'
      dynpprog        = sy-repid
      dynpnr          = sy-dynnr
      dynprofield     = pv_dynprofield
      value_org       = 'S'
      window_title    = 'Select a control character'
    TABLES
      field_tab       = lt_cpfld
      value_tab       = lt_cpf4
      return_tab      = lt_cpret
    EXCEPTIONS
      parameter_error = 1
      no_values_found = 2
      OTHERS          = 3.
  IF sy-subrc <> 0 OR lt_cpret IS INITIAL.
    RETURN.
  ENDIF.

  READ TABLE lt_cpret ASSIGNING FIELD-SYMBOL(<ls_cpret>) INDEX 1.
  " Write the chosen hex code back into the triggering screen field.
  DATA lt_upd TYPE TABLE OF dynpread.
  APPEND VALUE #( fieldname  = pv_dynprofield
                  fieldvalue = <ls_cpret>-fieldval ) TO lt_upd.
  CALL FUNCTION 'DYNP_VALUES_UPDATE'
    EXPORTING
      dyname     = sy-repid
      dynumb     = sy-dynnr
    TABLES
      dynpfields = lt_upd
    EXCEPTIONS
      OTHERS     = 0.
ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  f4_server_group
*&      Value help for RFC Server Groups (table RZ12).
*&---------------------------------------------------------------------*
FORM f4_server_group.
  TYPES: BEGIN OF ts_grp,
           classname TYPE rzllitab-classname,
         END OF ts_grp.
  DATA lt_groups TYPE TABLE OF ts_grp.

  " RFC server groups live in table RZLLITAB (RZ12 is the maintenance
  " transaction, not a table). One row per group x application server, so
  " DISTINCT on CLASSNAME collapses it to one entry per group for the F4.
  SELECT DISTINCT classname
    FROM rzllitab
    INTO TABLE @lt_groups
    ORDER BY classname.                                  "#EC CI_BYPASS

  IF sy-subrc <> 0 OR lt_groups IS INITIAL.
    RETURN.
  ENDIF.

  DATA lt_ret TYPE TABLE OF ddshretval.
  CALL FUNCTION 'F4IF_INT_TABLE_VALUE_REQUEST'
    EXPORTING
      retfield     = 'CLASSNAME'
      dynpprog     = sy-repid
      dynpnr       = sy-dynnr
      dynprofield  = 'P_GRP'
      value_org    = 'S'
      window_title = 'Select RFC Server Group'
    TABLES
      value_tab    = lt_groups
      return_tab   = lt_ret
    EXCEPTIONS
      OTHERS       = 0.

  IF sy-subrc = 0 AND lt_ret IS NOT INITIAL.
    READ TABLE lt_ret ASSIGNING FIELD-SYMBOL(<ret>) INDEX 1.
    p_grp = <ret>-fieldval.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  display_salv
*&      Shows the hit list in a SALV grid. Because CL_SALV_TABLE does
*&      not support STRING columns, the value is copied into a fixed
*&      CHAR field for display.
*&---------------------------------------------------------------------*
FORM display_salv.
  TYPES: BEGIN OF ts_disp,
           rownum  TYPE i,
           keyinfo TYPE c LENGTH 100,
           field   TYPE c LENGTH 40,
           offset  TYPE i,
           hexcode TYPE c LENGTH 8,
           descr   TYPE c LENGTH 30,
           value   TYPE c LENGTH 132,
         END OF ts_disp.
  DATA lt_disp TYPE STANDARD TABLE OF ts_disp WITH EMPTY KEY.

  LOOP AT gt_hits ASSIGNING FIELD-SYMBOL(<ls_hit>).
    APPEND VALUE #( rownum  = <ls_hit>-rownum
                    keyinfo = <ls_hit>-keyinfo
                    field   = <ls_hit>-field
                    offset  = <ls_hit>-offset
                    hexcode = <ls_hit>-hexcode
                    descr   = <ls_hit>-descr
                    value   = <ls_hit>-value ) TO lt_disp.
  ENDLOOP.

  DATA lo_salv TYPE REF TO cl_salv_table.
  TRY.
      cl_salv_table=>factory( IMPORTING r_salv_table = lo_salv
                              CHANGING  t_table      = lt_disp ).

      " column captions
      DATA(lo_cols) = lo_salv->get_columns( ).
      " set_optimize scans EVERY row to auto-fit column widths - it is O(rows)
      " and becomes the dominant cost on large result sets (e.g. ~84s for 40k
      " rows). Only optimise for modest lists; for large ones keep default
      " widths so the grid renders immediately.
      lo_cols->set_optimize( COND #( WHEN lines( lt_disp ) <= 2000
                                     THEN abap_true ELSE abap_false ) ).
      lo_cols->get_column( 'ROWNUM'  )->set_short_text( 'Row' ).
      lo_cols->get_column( 'KEYINFO' )->set_short_text( 'Key' ).
      lo_cols->get_column( 'KEYINFO' )->set_medium_text( 'Record key' ).
      lo_cols->get_column( 'FIELD'   )->set_short_text( 'Field' ).
      lo_cols->get_column( 'OFFSET'  )->set_short_text( 'Offset' ).
      lo_cols->get_column( 'HEXCODE' )->set_short_text( 'Hex' ).
      lo_cols->get_column( 'DESCR'   )->set_short_text( 'Char' ).
      lo_cols->get_column( 'DESCR'   )->set_medium_text( 'Control char' ).
      lo_cols->get_column( 'VALUE'   )->set_short_text( 'Value' ).

      " functions (sort/filter/export toolbar)
      lo_salv->get_functions( )->set_all( abap_true ).

      " header
      DATA(lo_disp) = lo_salv->get_display_settings( ).
      DATA(lv_hdr_note) = COND string(
        WHEN gv_error     = abap_true THEN ` (PARTIAL - error)`
        WHEN gv_truncated = abap_true THEN ` (TRUNCATED at hit ceiling)`
        ELSE `` ).
      lo_disp->set_list_header( |{ p_tab }: { lines( gt_hits ) } hits in { gv_rows } rows{ lv_hdr_note }| ).

      lo_salv->display( ).
    CATCH cx_salv_msg
          cx_salv_not_found INTO DATA(lx_salv).
      MESSAGE lx_salv->get_text( ) TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.
ENDFORM.

*&---------------------------------------------------------------------*
*&      Form  display_remediation_diffs
*&      Displays remediation simulation diffs in a SALV grid.
*&---------------------------------------------------------------------*
FORM display_remediation_diffs USING it_diff TYPE /ctdi/cl_scan_remediator=>tt_diff.
  TYPES: BEGIN OF ts_disp_diff,
           rownum    TYPE i,
           keyinfo   TYPE c LENGTH 100,
           field     TYPE c LENGTH 40,
           old_value TYPE c LENGTH 132,
           new_value TYPE c LENGTH 132,
           changed   TYPE c LENGTH 1,
         END OF ts_disp_diff.
  DATA lt_disp_diff TYPE STANDARD TABLE OF ts_disp_diff WITH EMPTY KEY.

  LOOP AT it_diff ASSIGNING FIELD-SYMBOL(<ls_d>).
    APPEND VALUE #(
      rownum    = <ls_d>-rownum
      keyinfo   = <ls_d>-keyinfo
      field     = <ls_d>-field
      old_value = <ls_d>-old_value
      new_value = <ls_d>-new_value
      changed   = <ls_d>-changed ) TO lt_disp_diff.
  ENDLOOP.

  DATA lo_salv TYPE REF TO cl_salv_table.
  TRY.
      cl_salv_table=>factory( IMPORTING r_salv_table = lo_salv
                              CHANGING  t_table      = lt_disp_diff ).

      DATA(lo_cols) = lo_salv->get_columns( ).
      lo_cols->set_optimize( COND #( WHEN lines( lt_disp_diff ) <= 2000
                                     THEN abap_true ELSE abap_false ) ).
      lo_cols->get_column( 'ROWNUM'    )->set_short_text( 'Row' ).
      lo_cols->get_column( 'KEYINFO'   )->set_short_text( 'Key' ).
      lo_cols->get_column( 'FIELD'     )->set_short_text( 'Field' ).
      lo_cols->get_column( 'OLD_VALUE' )->set_medium_text( 'Original Value' ).
      lo_cols->get_column( 'NEW_VALUE' )->set_medium_text( 'Cleaned Value' ).
      lo_cols->get_column( 'CHANGED'   )->set_short_text( 'Changed' ).

      lo_salv->get_functions( )->set_all( abap_true ).
      lo_salv->get_display_settings( )->set_list_header(
        |Remediation Simulation: { lines( lt_disp_diff ) } fields to clean in { p_tab }| ).

      lo_salv->display( ).
    CATCH cx_salv_msg
          cx_salv_not_found INTO DATA(lx_salv_diff).
      MESSAGE lx_salv_diff->get_text( ) TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.
ENDFORM.

*&---------------------------------------------------------------------*
*&  All unit tests now live with the global classes:
*&    /CTDI/CL_CNTRL_SCANNER  - scan logic
*&    /CTDI/CL_TABLE_READER   - read + field resolution
*&  This report is thin orchestration and has no local tests.
*&---------------------------------------------------------------------*
