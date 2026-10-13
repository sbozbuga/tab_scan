class /CTDI/CL_SCAN_PARALLEL definition
  public
  inheriting from CL_ABAP_PARALLEL
  create public .

*"* Parallel worker for the control-character scan (batched-wave model).
*"* The DRIVER reads one package of rows and ships it here as an XSTRING
*"* packet; this worker (running in a separate work process via
*"* CL_ABAP_PARALLEL->RUN) deserializes the rows, SCANS them with
*"* /CTDI/CL_CNTRL_SCANNER, and ships the hits back as XSTRING. The worker
*"* does NOT read the database - reading stays in the driver so there is no
*"* key partitioning and no per-worker DB cursor.
public section.

  types:
    " The scan work packet shipped driver -> worker. In the SLICE-MAP model
    " the packet carries only a KEY RANGE (after_key, end_key] - NOT the rows.
    " Each worker READS its own slice (bounded by that range) and scans it, so
    " the heavy row reads run in parallel and nothing but tiny key tuples and
    " the hit list cross the work-process boundary.
    BEGIN OF ts_packet,
             tablename TYPE tabname,
             fields    TYPE /ctdi/cl_cntrl_scanner=>tt_field,   " char fields to scan
             keys      TYPE /ctdi/cl_cntrl_scanner=>tt_field,   " key fields for keyinfo
             keyflds   TYPE /ctdi/cl_cntrl_scanner=>tt_field,   " non-client key order
             after_key TYPE /ctdi/cl_table_reader=>tt_keyval,  " resume strictly after
             end_key   TYPE /ctdi/cl_table_reader=>tt_keyval,  " inclusive upper bound
             scope     TYPE /ctdi/cl_cntrl_scanner=>ts_scope,
             base_row  TYPE i,
             max_rows  TYPE i,                                  " safety cap for the read
           END OF ts_packet .
    " Result of a parallel scan run.
    TYPES: BEGIN OF ts_result,
             hits         TYPE /ctdi/cl_cntrl_scanner=>tt_hit,
             rows         TYPE i,            " total rows scanned
             truncated    TYPE abap_bool,    " stopped early at the hit ceiling
             errors       TYPE string_table, " per-task error messages (if any)
             last_end_key TYPE /ctdi/cl_table_reader=>tt_keyval, " last key reached
           END OF ts_result .

    "! Drive a full-table control-char scan in PARALLEL, batched-wave model
    "! (local path only). Each wave reads up to iv_pkgs_per_wave packages of
    "! iv_pkg_size rows via READ_CHUNK (resuming by key, cursor closed before
    "! the parallel RUN), ships them to worker processes to SCAN, and merges
    "! the hits. Repeats until the table is exhausted or the hit ceiling is
    "! reached. Reading is serial in this process; scanning is parallel.
  class-methods RUN_PARALLEL_SCAN
    importing
      !IV_TABLE         type TABNAME
      !IT_SCANFLDS      type /CTDI/CL_CNTRL_SCANNER=>TT_FIELD
      !IT_KEYS          type /CTDI/CL_CNTRL_SCANNER=>TT_FIELD
      !IT_KEYFLDS       type /CTDI/CL_CNTRL_SCANNER=>TT_FIELD
      !IS_SCOPE         type /CTDI/CL_CNTRL_SCANNER=>TS_SCOPE
      !IT_WHERE         type /CTDI/CL_TABLE_READER=>TT_WHERE optional
      !IV_PKG_SIZE      type I default 50000
      !IV_PKGS_PER_WAVE type I default 12
      !IV_PERCENTAGE    type I default 50
      !IV_HMAX          type I default 0
      !IV_TOTAL_EST     type I default 0   " known row estimate (0 = count here)
      !IV_GROUP         type rzlli_apcl optional
    returning
      value(RS_RESULT)  type TS_RESULT .

    "! Pick an adaptive package size + packages-per-wave from the total row
    "! estimate and the ACTUAL parallel width. Policy (measured on DA1A):
    "!  - target pack size ~50k, kept inside the band 40k..60k (smaller
    "!    packs overlap better; the band gives the balancer room);
    "!  - total pack count rounded to a multiple of the width W so every
    "!    wave is full (no stranded work processes on the last wave);
    "!  - when N is too small to fill a wave at the min pack size, accept
    "!    one partial wave. Pure / deterministic (unit-tested).
    "! @parameter iv_total   | estimated total rows to scan (positive)
    "! @parameter iv_width   | actual parallel width W (WPs per wave, min 1)
    "! @parameter ev_pkgsize | chosen package size (rows), in the 40k..60k band
    "! @parameter ev_perwave | packages per wave (= iv_width, min 1)
    CLASS-METHODS calc_sizing
      IMPORTING iv_total   TYPE i
                iv_width   TYPE i
      EXPORTING ev_pkgsize TYPE i
                ev_perwave TYPE i.

    "! The ACTUAL parallel width CL_ABAP_PARALLEL would use for a given
    "! percentage: percentage * free dialog WPs / 100, at least 1. Sizing to
    "! this (not the requested per-wave count) avoids waves that strand WPs
    "! because fewer were free than asked for.
    CLASS-METHODS calc_width
      IMPORTING iv_percentage   TYPE i DEFAULT 50
                iv_group        TYPE rzlli_apcl OPTIONAL
      RETURNING VALUE(rv_width) TYPE i.

    " Serialize a packet to the XSTRING that RUN transports (driver side).
  class-methods SERIALIZE_PACKET
    importing
      !IS_PACKET type TS_PACKET
    returning
      value(RV_XML) type XSTRING .
    " Deserialize the hit table from a worker result XSTRING (driver side).
  class-methods DESERIALIZE_HITS
    importing
      !IV_XML type XSTRING
    returning
      value(RT_HITS) type /CTDI/CL_CNTRL_SCANNER=>TT_HIT .

    " The parallel entry point, run in a separate work process (redefines
    " the abstract CL_ABAP_PARALLEL->DO on this release - no IF_ABAP_PARALLEL).
  methods DO
    redefinition .
  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.



CLASS /CTDI/CL_SCAN_PARALLEL IMPLEMENTATION.


  METHOD calc_sizing.
    CONSTANTS: lc_min    TYPE i VALUE 40000,
               lc_target TYPE i VALUE 50000,
               lc_max    TYPE i VALUE 60000.

    DATA(lv_w) = COND i( WHEN iv_width < 1 THEN 1 ELSE iv_width ).
    ev_perwave = lv_w.

    " Degenerate / unknown total: fall back to the measured sweet spot.
    IF iv_total <= 0.
      ev_pkgsize = lc_target.
      RETURN.
    ENDIF.

    " NOTE: ABAP '/' ROUNDS (half-up), it does not truncate. For a correct
    " ceiling we must use DIV (integer truncating division): ceil(a/b) =
    " (a + b - 1) DIV b.
    " Ideal number of ~target-sized packs (at least 1).
    DATA(lv_ideal) = ( iv_total + lc_target - 1 ) DIV lc_target. " ceil
    IF lv_ideal < 1.
      lv_ideal = 1.
    ENDIF.

    " Round the pack count UP to a whole number of full waves, so no wave
    " strands work processes. waves = ceil(ideal / W); packs = waves * W.
    DATA(lv_waves) = ( lv_ideal + lv_w - 1 ) DIV lv_w.
    IF lv_waves < 1.
      lv_waves = 1.
    ENDIF.
    DATA(lv_packs) = lv_waves * lv_w.

    " Rebalance pack size to fill those packs evenly.
    ev_pkgsize = ( iv_total + lv_packs - 1 ) DIV lv_packs.        " ceil

    " Keep the pack size inside the [min,max] band. If it is too large,
    " add whole waves (more, smaller packs) until it fits or we stop
    " helping; if too small, drop whole waves (fewer, bigger packs) but
    " never below one wave.
    WHILE ev_pkgsize > lc_max.
      lv_waves  = lv_waves + 1.
      lv_packs  = lv_waves * lv_w.
      ev_pkgsize = ( iv_total + lv_packs - 1 ) DIV lv_packs.
    ENDWHILE.

    WHILE ev_pkgsize < lc_min AND lv_waves > 1.
      lv_waves  = lv_waves - 1.
      lv_packs  = lv_waves * lv_w.
      ev_pkgsize = ( iv_total + lv_packs - 1 ) DIV lv_packs.
    ENDWHILE.

    " Final safety clamp (small-N case can still land below min with one
    " wave - that is an accepted partial wave; just cap at the band edges).
    IF ev_pkgsize > lc_max.
      ev_pkgsize = lc_max.
    ENDIF.
    IF ev_pkgsize < 1.
      ev_pkgsize = 1.
    ENDIF.
  ENDMETHOD.


  METHOD calc_width.
    " Determine available work processes using SPBT_INITIALIZE (for an RFC
    " server group) or TH_COUNT_WPS (free dialog WPs on the local server).
    " NOTE: SPBT_GET_PP_INFO and TH_WP_INFO do NOT exist on this system and
    " previously caused CALL_FUNCTION_NOT_FOUND dumps.
    DATA lv_free TYPE i.
    DATA lv_max  TYPE i.
    IF iv_group IS NOT INITIAL.
      " SPBT_INITIALIZE validates the server group and returns the free/max
      " parallel work processes for it. (The old SPBT_GET_PP_INFO does not
      " exist on this system - it caused a CALL_FUNCTION_NOT_FOUND dump.)
      " PBT_ENV_ALREADY_INITIALIZED is benign: on repeated calls (e.g. the
      " selection-screen live preview) the environment is already set up for
      " this group, so we treat subrc 2 as success as well.
      CALL FUNCTION 'SPBT_INITIALIZE'
        EXPORTING
          group_name                     = iv_group
        IMPORTING
          max_pbt_wps                    = lv_max
          free_pbt_wps                   = lv_free
        EXCEPTIONS
          invalid_group_name             = 1
          internal_error                 = 2
          pbt_env_already_initialized    = 3
          currently_no_resources_avail   = 4
          no_pbt_resources_found         = 5
          cant_init_different_pbt_groups = 6
          OTHERS                         = 7.
      " Any non-zero subrc (including 'already initialized', where the counts
      " are not returned) means no usable figure from this FM, so fall back
      " to the local TH_WP_INFO count below.
      IF sy-subrc <> 0.
        lv_free = 0.
      ENDIF.
    ENDIF.

    IF lv_free <= 0.
      " TH_COUNT_WPS returns the free dialog WPs on the current server directly,
      " so no manual WP-list loop is needed.
      CALL FUNCTION 'TH_COUNT_WPS'
        IMPORTING
          free_dia_wps = lv_free
        EXCEPTIONS
          failed       = 1
          OTHERS       = 2.
      IF sy-subrc <> 0.
        lv_free = 0.
      ENDIF.
    ENDIF.

    rv_width = iv_percentage * lv_free / 100.
    IF rv_width < 1.
      rv_width = 1.
    ENDIF.
  ENDMETHOD.


  METHOD deserialize_hits.
    TRY.
        IMPORT hits = rt_hits FROM DATA BUFFER iv_xml.
        IF sy-subrc <> 0.
          CALL TRANSFORMATION id SOURCE XML iv_xml
                                 RESULT hits = rt_hits.
        ENDIF.
      CATCH cx_root.
        CALL TRANSFORMATION id SOURCE XML iv_xml
                               RESULT hits = rt_hits.
    ENDTRY.
  ENDMETHOD.


  METHOD do.
    " --- runs in a separate work process (slice-map model) -------------
    " 1) deserialize the tiny packet (key range only, no rows)
    DATA ls_packet TYPE ts_packet.
    TRY.
        IMPORT packet = ls_packet FROM DATA BUFFER p_in.
        IF sy-subrc <> 0.
          CALL TRANSFORMATION id SOURCE XML p_in
                                 RESULT packet = ls_packet.
        ENDIF.
      CATCH cx_root.
        CALL TRANSFORMATION id SOURCE XML p_in
                               RESULT packet = ls_packet.
    ENDTRY.

    " 2) READ this worker's own slice: rows strictly after after_key, up to
    "    and including end_key, projected to the scanned fields (+ keys).
    "    This is where the heavy row read happens - in parallel, per worker.
    DATA(lo_reader) = NEW /ctdi/cl_table_reader( ).
    DATA: lr_data   TYPE REF TO data,
          lr_struct TYPE REF TO cl_abap_structdescr,
          lt_last   TYPE /ctdi/cl_table_reader=>tt_keyval,
          lv_count  TYPE i.
    lo_reader->read_chunk(
      EXPORTING iv_table   = ls_packet-tablename
                it_where    = VALUE #( )
                it_fields   = ls_packet-fields
                it_keyflds  = ls_packet-keyflds
                is_after    = ls_packet-after_key
                is_until    = ls_packet-end_key
                iv_max      = ls_packet-max_rows
      IMPORTING er_data     = lr_data
                er_struct   = lr_struct
                et_last_key = lt_last
                ev_count    = lv_count ).
    FIELD-SYMBOLS <lt> TYPE STANDARD TABLE.
    ASSIGN lr_data->* TO <lt>.

    " 3) scan the slice (reuse the stateless scanner, with scope)
    DATA(lt_hits) = /ctdi/cl_cntrl_scanner=>scan_table(
                      it_data   = <lt>
                      it_fields = ls_packet-fields
                      it_keys   = ls_packet-keys
                      is_scope  = ls_packet-scope ).

    " 4) shift per-slice row numbers to absolute, serialize hits back
    LOOP AT lt_hits ASSIGNING FIELD-SYMBOL(<h>).
      <h>-rownum = <h>-rownum + ls_packet-base_row.
    ENDLOOP.
    EXPORT hits = lt_hits TO DATA BUFFER p_out.
  ENDMETHOD.


  METHOD run_parallel_scan.
    DATA(lo_reader) = NEW /ctdi/cl_table_reader( ).

    " ---- resolve effective slice size + concurrency ceiling -----------
    " iv_pkg_size <= 0 means AUTO: derive from the row estimate and the
    " actual parallel width. A positive iv_pkg_size is an explicit override
    " (adaptive is skipped, caller's wave count is honoured).
    DATA lv_pkgsize TYPE i.
    DATA lv_perwave TYPE i.
    IF iv_pkg_size > 0.
      lv_pkgsize = iv_pkg_size.
      lv_perwave = iv_pkgs_per_wave.
    ELSE.
      " Row estimate: reuse the caller's known total (e.g. the selection
      " screen already counted and cached it) to avoid a second expensive
      " COUNT(*). Only count here when no estimate was supplied, and guard
      " it (a failing / slow COUNT must not break the scan).
      DATA lv_total TYPE i.
      IF iv_total_est > 0.
        lv_total = iv_total_est.
      ELSE.
        TRY.
            IF it_where IS INITIAL.
              SELECT COUNT(*) FROM (iv_table) INTO @lv_total.
            ELSE.
              SELECT COUNT(*) FROM (iv_table) INTO @lv_total WHERE (it_where).
            ENDIF.
          CATCH cx_root.
            lv_total = 0.
        ENDTRY.
      ENDIF.
      DATA(lv_width) = calc_width( iv_percentage = iv_percentage
                                   iv_group      = iv_group ).
      calc_sizing( EXPORTING iv_total   = lv_total
                             iv_width   = lv_width
                   IMPORTING ev_pkgsize = lv_pkgsize
                             ev_perwave = lv_perwave ).
    ENDIF.

    " ---- PHASE 1: cheap keys-only probe -> slice map ------------------
    " Probe at the target dispatch size: keys-only, so slicing is cheap, and
    " each probe boundary becomes one dispatch slice directly (uniform size).
    DATA(lt_slices) = lo_reader->probe_slices(
                      iv_table      = iv_table
                      it_where       = COND #( WHEN it_where IS SUPPLIED THEN it_where ELSE VALUE #( ) )
                      iv_slice_size  = lv_pkgsize ).
    rs_result-rows = REDUCE i( INIT s = 0 FOR <sf> IN lt_slices NEXT s = s + <sf>-rows ).

    IF lt_slices IS INITIAL.
      RETURN.   " nothing to scan (empty table or no usable key)
    ENDIF.

    " ---- Fast path: SINGLE slice runs directly in-process -------------
    " Avoids aRFC dispatch, XML serialization, and WP context switches for small tables
    IF lines( lt_slices ) = 1.
      ASSIGN lt_slices[ 1 ] TO FIELD-SYMBOL(<sl_single>).
      DATA: lr_data_single   TYPE REF TO data,
            lr_struct_single TYPE REF TO cl_abap_structdescr,
            lt_last_single   TYPE /ctdi/cl_table_reader=>tt_keyval,
            lv_count_single  TYPE i.
      lo_reader->read_chunk(
        EXPORTING iv_table    = iv_table
                  it_where    = COND #( WHEN it_where IS SUPPLIED THEN it_where ELSE VALUE #( ) )
                  it_fields   = it_scanflds
                  it_keyflds  = it_keyflds
                  is_after    = <sl_single>-after_key
                  is_until    = <sl_single>-end_key
                  iv_max      = <sl_single>-rows + 1000
        IMPORTING er_data     = lr_data_single
                  er_struct   = lr_struct_single
                  et_last_key = lt_last_single
                  ev_count    = lv_count_single ).
      FIELD-SYMBOLS <lt_single> TYPE STANDARD TABLE.
      ASSIGN lr_data_single->* TO <lt_single>.
      rs_result-hits = /ctdi/cl_cntrl_scanner=>scan_table(
                         it_data   = <lt_single>
                         it_fields = it_scanflds
                         it_keys   = it_keys
                         is_scope  = is_scope ).
      IF iv_hmax > 0 AND lines( rs_result-hits ) >= iv_hmax.
        DELETE rs_result-hits FROM iv_hmax + 1.
        rs_result-truncated = abap_true.
      ENDIF.
      rs_result-last_end_key = lt_last_single.
      RETURN.
    ENDIF.

    " ---- PHASE 2: queue ALL slices into ONE RUN ----------------------
    " CL_ABAP_PARALLEL->RUN keeps up to lv_perwave tasks in flight and, the
    " instant any task finishes (END_TASK drops it below the ceiling), it
    " dispatches the NEXT queued slice to that freed work process. Handing it
    " the WHOLE slice list at once therefore gives a continuous sliding
    " window - no wave barriers, no idle WPs - instead of lock-step waves.
    " Each packet is tiny (a key range), so queuing them all costs nothing.
    DATA lt_in TYPE cl_abap_parallel=>t_in_tab.
    LOOP AT lt_slices ASSIGNING FIELD-SYMBOL(<sl2>).
      DATA(lv_max_cap) = <sl2>-rows + 1000.  " generous cap guards against dropping concurrent inserts
      APPEND serialize_packet( VALUE ts_packet(
               tablename = iv_table
               fields    = it_scanflds
               keys      = it_keys
               keyflds   = it_keyflds
               after_key = <sl2>-after_key
               end_key   = <sl2>-end_key
               scope     = is_scope
               base_row  = <sl2>-base_row
               max_rows  = lv_max_cap ) ) TO lt_in.
    ENDLOOP.

    " Concurrency ceiling = parallel width (lv_perwave from sizing / caller).
    " NOTE: standard CL_ABAP_PARALLEL dispatches the parallel RFC without a
    " GROUP clause (DESTINATION IN GROUP is commented out there), so it always
    " uses the system default server group. iv_group only feeds calc_width for
    " sizing the parallel width; it cannot be injected into the task dispatch.
    DATA(lo_par) = NEW /ctdi/cl_scan_parallel(
                         p_num_tasks  = lv_perwave
                         p_percentage = iv_percentage ).

    DATA lt_out TYPE cl_abap_parallel=>t_out_tab.
    lo_par->run( EXPORTING p_in_tab  = lt_in
                 IMPORTING p_out_tab = lt_out ).

    " Collect hits from every slice (p_out_tab mirrors p_in_tab order).
    LOOP AT lt_out ASSIGNING FIELD-SYMBOL(<o>).
      IF <o>-message IS NOT INITIAL.
        APPEND |Task { <o>-index }: { <o>-message }| TO rs_result-errors.
        CONTINUE.
      ENDIF.
      APPEND LINES OF deserialize_hits( <o>-result ) TO rs_result-hits.
      IF <o>-index <= lines( lt_slices ).
        rs_result-last_end_key = lt_slices[ <o>-index ]-end_key.
      ENDIF.
    ENDLOOP.

    " Hit ceiling: truncate exactly (all slices already ran - this just caps
    " the reported/displayed hits; it cannot stop work mid-flight here).
    IF iv_hmax > 0 AND lines( rs_result-hits ) >= iv_hmax.
      DELETE rs_result-hits FROM iv_hmax + 1.
      rs_result-truncated = abap_true.
    ENDIF.
  ENDMETHOD.


  METHOD serialize_packet.
    EXPORT packet = is_packet TO DATA BUFFER rv_xml.
  ENDMETHOD.
ENDCLASS.
