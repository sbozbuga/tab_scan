class /CTDI/CL_SCAN_REMEDIATOR definition
  public
  final
  create public .

public section.

  types:
    BEGIN OF ts_diff,
        rownum    TYPE i,
        keyinfo   TYPE string,
        field     TYPE fieldname,
        old_value TYPE string,
        new_value TYPE string,
        changed   TYPE abap_bool,
      END OF ts_diff .
  types:
    tt_diff TYPE STANDARD TABLE OF ts_diff WITH EMPTY KEY .
  types:
    BEGIN OF ts_remedy_result,
        total_items TYPE i,
        changed     TYPE i,
        diffs       TYPE tt_diff,
        simulated   TYPE abap_bool,
        success     TYPE abap_bool,
        message     TYPE string,
      END OF ts_remedy_result .
  types:
    BEGIN OF ts_apply_result,
        success TYPE abap_bool,
        changed TYPE abap_bool,
        message TYPE string,
      END OF ts_apply_result .

    "! Parse keyinfo ('K1=V1 K2=V2') into dynamic SQL WHERE ('K1 = ''V1'' AND K2 = ''V2''')
  class-methods PARSE_KEYINFO_TO_WHERE
    importing
      !IV_KEYINFO type STRING
    returning
      value(RV_WHERE) type STRING .
    "! Persist deduplicated scan violations to worklist table /CTDI/SCAN_HITS
  class-methods PERSIST_HITS
    importing
      !IV_RUN_ID type SYSUUID_C22
      !IV_TABLE type TABNAME
      !IT_HITS type /CTDI/IF_INSPECTION_RULE=>TT_VIOLATION
      !IV_REP_CHAR type CLIKE default ` `
      !IO_LOGGER type ref to /CTDI/CL_SCAN_LOGGER optional
    returning
      value(RV_COUNT) type I .
    "! Apply remediation write-back for a single worklist item
  class-methods APPLY_ROW
    importing
      !IS_HIT type /CTDI/SCAN_HITS
      !IV_SIMULATION type ABAP_BOOL default ABAP_FALSE
      !IO_LOGGER type ref to /CTDI/CL_SCAN_LOGGER optional
    returning
      value(RS_RESULT) type TS_APPLY_RESULT .
    "! Mark a worklist item as skipped
  class-methods SKIP_ROW
    importing
      !IS_HIT type /CTDI/SCAN_HITS .
    "! Simulate remediation (calculate diffs without database writes)
  class-methods SIMULATE
    importing
      !IT_HITS type /CTDI/IF_INSPECTION_RULE=>TT_VIOLATION
      !IV_REP_CHAR type CLIKE default ` `
    returning
      value(RS_RESULT) type TS_REMEDY_RESULT .
    "! Legacy execute remediation method
  class-methods EXECUTE
    importing
      !IV_TABLE type TABNAME
      !IT_HITS type /CTDI/IF_INSPECTION_RULE=>TT_VIOLATION
      !IV_SIMULATION type ABAP_BOOL default ABAP_TRUE
      !IO_LOGGER type ref to /CTDI/CL_SCAN_LOGGER optional
    returning
      value(RS_RESULT) type TS_REMEDY_RESULT .
  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.



CLASS /CTDI/CL_SCAN_REMEDIATOR IMPLEMENTATION.


  METHOD apply_row.
    IF is_hit-mandt IS NOT INITIAL AND is_hit-mandt <> sy-mandt.
      rs_result-success = abap_false.
      rs_result-message = |Cross-client apply prohibited (Hit client: { is_hit-mandt }, Current client: { sy-mandt })|.
      RETURN.
    ENDIF.

    IF is_hit-status = 'C'.
      rs_result-success = abap_true.
      rs_result-message = 'Item is already cleaned.'.
      RETURN.
    ENDIF.

    IF is_hit-tabname IS INITIAL OR is_hit-key_where IS INITIAL OR is_hit-fieldname IS INITIAL.
      rs_result-success = abap_false.
      rs_result-message = 'Missing table, key or field in hit record.'.
      RETURN.
    ENDIF.

    " Authorization check for updating target table
    CALL FUNCTION 'VIEW_AUTHORITY_CHECK'
      EXPORTING
        view_action                    = 'U'
        view_name                      = is_hit-tabname
      EXCEPTIONS
        no_authority                   = 1
        no_clientindependent_authority = 2
        OTHERS                         = 3.
    IF sy-subrc <> 0.
      rs_result-success = abap_false.
      rs_result-message = |No authorization to modify table { is_hit-tabname } (sy-subrc = { sy-subrc })|.
      IF io_logger IS BOUND.
        io_logger->add_error( rs_result-message ).
      ENDIF.
      RETURN.
    ENDIF.

    " Simulation mode: only verify that row exists without mutating data
    IF iv_simulation = abap_true.
      TRY.
          DATA lv_count TYPE i.
          SELECT COUNT(*) FROM (is_hit-tabname) INTO @lv_count WHERE (is_hit-key_where). "#EC CI_SEL_NESTED
          IF lv_count = 1.
            rs_result-success = abap_true.
            rs_result-changed = abap_true.
            rs_result-message = 'Simulation OK: Exactly 1 target row matched and can be updated.'.
          ELSEIF lv_count > 1.
            rs_result-success = abap_false.
            rs_result-message = |Simulation warning: WHERE clause matches { lv_count } rows! Key ambiguity.|.
          ELSE.
            rs_result-success = abap_false.
            rs_result-message = 'Simulation failed: Target row not found on database.'.
          ENDIF.
        CATCH cx_root INTO DATA(lx_sim).
          rs_result-success = abap_false.
          rs_result-message = |Simulation SQL error: { lx_sim->get_text( ) }|.
      ENDTRY.
      RETURN.
    ENDIF.

    " Real write-back: Lock table row
    CALL FUNCTION 'ENQUEUE_E_TABLE'
      EXPORTING
        tabname        = is_hit-tabname
        varkey         = is_hit-keyinfo
      EXCEPTIONS
        foreign_lock   = 1
        system_failure = 2
        OTHERS         = 3.
    IF sy-subrc <> 0.
      rs_result-success = abap_false.
      rs_result-message = |Lock failed: { is_hit-tabname } row is currently locked by another process.|.
      IF io_logger IS BOUND.
        io_logger->add_error( rs_result-message ).
      ENDIF.
      RETURN.
    ENDIF.

    DATA lv_db_ok TYPE abap_bool VALUE abap_false.
    DATA lv_err_msg TYPE string.
    DATA(lv_quoted_val) = /ctdi/cl_key_partitioner=>quote_literal( is_hit-clean_value ).
    DATA(lv_set_clause) = |{ is_hit-fieldname } = { lv_quoted_val }|.

    TRY.
        UPDATE (is_hit-tabname)
          SET (lv_set_clause)
          WHERE (is_hit-key_where).
        IF sy-subrc = 0.
          IF sy-dbcnt = 1.
            lv_db_ok = abap_true.
          ELSE.
            ROLLBACK WORK.
            lv_err_msg = |Safety abort: WHERE clause matched { sy-dbcnt } rows instead of exactly 1! Rolled back.|.
          ENDIF.
        ELSE.
          lv_err_msg = |UPDATE failed: target record not found (sy-subrc = { sy-subrc })|.
        ENDIF.
      CATCH cx_root INTO DATA(lx_upd).
        lv_err_msg = |UPDATE error: { lx_upd->get_text( ) }|.
    ENDTRY.

    DATA lv_now TYPE timestamp.
    GET TIME STAMP FIELD lv_now.

    IF lv_db_ok = abap_true.
      UPDATE /ctdi/scan_hits
        SET status      = 'C',
            apply_user  = @sy-uname,
            apply_tstmp = @lv_now,
            message     = 'Successfully cleaned'
        WHERE run_id  = @is_hit-run_id
          AND item_no = @is_hit-item_no.
      COMMIT WORK.
      rs_result-success = abap_true.
      rs_result-changed = abap_true.
      rs_result-message = 'Successfully updated on database and marked Cleaned.'.
      IF io_logger IS BOUND.
        io_logger->add_info( |Updated { is_hit-tabname } { is_hit-fieldname } for { is_hit-keyinfo }| ).
      ENDIF.
    ELSE.
      ROLLBACK WORK.
      UPDATE /ctdi/scan_hits
        SET status  = 'E',
            message = @lv_err_msg
        WHERE run_id  = @is_hit-run_id
          AND item_no = @is_hit-item_no.
      COMMIT WORK.
      rs_result-success = abap_false.
      rs_result-message = lv_err_msg.
      IF io_logger IS BOUND.
        io_logger->add_error( |Failed update for { is_hit-tabname } ({ lv_err_msg })| ).
      ENDIF.
    ENDIF.

    CALL FUNCTION 'DEQUEUE_E_TABLE'
      EXPORTING
        tabname = is_hit-tabname
        varkey  = is_hit-keyinfo.
  ENDMETHOD.


  METHOD execute.
    rs_result-simulated   = iv_simulation.
    rs_result-total_items = lines( it_hits ).

    LOOP AT it_hits ASSIGNING FIELD-SYMBOL(<h>).
      DATA(lv_cleaned) = /ctdi/cl_cntrl_scanner=>sanitize( <h>-value ).
      DATA(lv_chg)     = xsdbool( lv_cleaned <> <h>-value ).

      APPEND VALUE ts_diff(
        rownum    = <h>-rownum
        keyinfo   = <h>-keyinfo
        field     = <h>-field
        old_value = <h>-value
        new_value = lv_cleaned
        changed   = lv_chg ) TO rs_result-diffs.

      IF lv_chg = abap_true.
        rs_result-changed = rs_result-changed + 1.
      ENDIF.
    ENDLOOP.

    IF iv_simulation = abap_true OR rs_result-changed = 0 OR iv_table IS INITIAL.
      rs_result-success = abap_true.
      rs_result-message = |Simulation completed: { rs_result-changed } of { rs_result-total_items } records have cleansable defects.|.
      IF io_logger IS BOUND.
        io_logger->add_info( rs_result-message ).
      ENDIF.
      RETURN.
    ENDIF.

    rs_result-success = abap_true.
    rs_result-message = |For governed write-back, use /CTDI/CNTRL_REVIEW on worklist /CTDI/SCAN_HITS.|.
  ENDMETHOD.


  METHOD parse_keyinfo_to_where.
    IF iv_keyinfo IS INITIAL.
      RETURN.
    ENDIF.

    DATA lt_tokens TYPE STANDARD TABLE OF string.
    SPLIT iv_keyinfo AT ` ` INTO TABLE lt_tokens.
    LOOP AT lt_tokens ASSIGNING FIELD-SYMBOL(<tok>).
      DATA(lv_token) = condense( <tok> ).
      IF lv_token IS INITIAL OR lv_token NA '='.
        CONTINUE.
      ENDIF.
      DATA: lv_fld TYPE string, lv_val TYPE string.
      SPLIT lv_token AT '=' INTO lv_fld lv_val.
      IF lv_fld IS INITIAL.
        CONTINUE.
      ENDIF.
      REPLACE ALL OCCURRENCES OF |'| IN lv_val WITH |''|.
      DATA(lv_expr) = |{ to_upper( lv_fld ) } = '{ lv_val }'|.
      rv_where = COND #( WHEN rv_where IS INITIAL THEN lv_expr
                         ELSE |{ rv_where } AND { lv_expr }| ).
    ENDLOOP.
  ENDMETHOD.


  METHOD persist_hits.
    IF it_hits IS INITIAL OR iv_table IS INITIAL.
      RETURN.
    ENDIF.

    TYPES: BEGIN OF ts_cell,
             keyinfo   TYPE string,
             field     TYPE fieldname,
             value     TYPE string,
             codepoint TYPE c LENGTH 4,   " 4-digit hex code point for /CTDI/SCAN_HITS-CODEPOINT (CHAR4)
             hit_count TYPE i,
           END OF ts_cell.
    DATA lt_cells TYPE STANDARD TABLE OF ts_cell WITH EMPTY KEY.

    LOOP AT it_hits ASSIGNING FIELD-SYMBOL(<h>).
      ASSIGN lt_cells[ keyinfo = <h>-keyinfo field = <h>-field ] TO FIELD-SYMBOL(<c>).
      IF sy-subrc = 0.
        <c>-hit_count = <c>-hit_count + 1.
      ELSE.
        " ts_violation carries the code as a string hexcode like '0x0A'. The
        " worklist stores a bare 4-digit hex code point (CHAR4), so strip any
        " '0x'/'0X' prefix and right-align to 4 with leading zeros.
        DATA(lv_hx) = to_upper( <h>-hexcode ).
        REPLACE ALL OCCURRENCES OF '0X' IN lv_hx WITH ''.
        DATA(lv_cp4) = |{ lv_hx WIDTH = 4 ALIGN = RIGHT PAD = '0' }|.
        APPEND VALUE ts_cell(
          keyinfo   = <h>-keyinfo
          field     = <h>-field
          value     = <h>-value
          codepoint = lv_cp4
          hit_count = 1 ) TO lt_cells.
      ENDIF.
    ENDLOOP.

    DATA lt_records TYPE STANDARD TABLE OF /ctdi/scan_hits.
    DATA lv_now TYPE timestamp.
    GET TIME STAMP FIELD lv_now.
    DATA lv_item TYPE i VALUE 0.

    LOOP AT lt_cells ASSIGNING FIELD-SYMBOL(<cell>).
      lv_item = lv_item + 1.
      DATA(lv_cleaned) = /ctdi/cl_cntrl_scanner=>sanitize( iv_value = <cell>-value iv_rep_char = iv_rep_char ).
      DATA(lv_where)   = parse_keyinfo_to_where( <cell>-keyinfo ).

      APPEND VALUE /ctdi/scan_hits(
        mandt       = sy-mandt
        run_id      = iv_run_id
        item_no     = lv_item
        tabname     = iv_table
        keyinfo     = <cell>-keyinfo
        key_where   = lv_where
        fieldname   = <cell>-field
        codepoint   = <cell>-codepoint
        hit_count   = <cell>-hit_count
        orig_value  = <cell>-value
        clean_value = lv_cleaned
        status      = 'O'
        scan_user   = sy-uname
        scan_tstmp  = lv_now ) TO lt_records.
    ENDLOOP.

    INSERT /ctdi/scan_hits FROM TABLE @lt_records ACCEPTING DUPLICATE KEYS.
    rv_count = lines( lt_records ).

    IF io_logger IS BOUND.
      io_logger->add_info( |Persisted { rv_count } findings for { iv_table } into worklist /CTDI/SCAN_HITS (Run { iv_run_id })| ).
    ENDIF.
  ENDMETHOD.


  METHOD simulate.
    rs_result = execute( iv_table      = ''
                         it_hits       = it_hits
                         iv_simulation = abap_true ).
  ENDMETHOD.


  METHOD skip_row.
    DATA lv_now TYPE timestamp.
    GET TIME STAMP FIELD lv_now.
    UPDATE /ctdi/scan_hits
      SET status      = 'S',
          apply_user  = @sy-uname,
          apply_tstmp = @lv_now,
          message     = 'Skipped by reviewer'
      WHERE run_id  = @is_hit-run_id
        AND item_no = @is_hit-item_no.
    COMMIT WORK.
  ENDMETHOD.
ENDCLASS.
