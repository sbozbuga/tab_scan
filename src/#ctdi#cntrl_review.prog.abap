*&---------------------------------------------------------------------*
*& Report /CTDI/CNTRL_REVIEW
*&---------------------------------------------------------------------*
*& Enterprise Scanner Review & Governed Remediation Console
*& Review findings stored in worklist /CTDI/SCAN_HITS and apply
*& governed, transactional data cleansing with full audit trail.
*&---------------------------------------------------------------------*
REPORT /ctdi/cntrl_review.

" NOTE: no 'TABLES: /ctdi/scan_hits.' - the worklist now has STRING columns
" (KEYINFO/KEY_WHERE/ORIG_VALUE/CLEAN_VALUE), making it a deep structure, so
" a flat table work area is neither allowed nor needed. Component types are
" referenced individually (/ctdi/scan_hits-field) where required.
DATA: gv_stat TYPE c LENGTH 1,
      gv_tab  TYPE tabname.

*&---------------------------------------------------------------------*
*&  SELECTION SCREEN
*&---------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b_sel WITH FRAME TITLE TEXT-001.
PARAMETERS: p_runid TYPE /ctdi/scan_hits-run_id,
            p_tab   TYPE /ctdi/scan_hits-tabname.
SELECT-OPTIONS: so_stat FOR gv_stat DEFAULT 'O'.
PARAMETERS: p_max TYPE i DEFAULT 500.
SELECTION-SCREEN END OF BLOCK b_sel.

SELECTION-SCREEN BEGIN OF BLOCK b_act WITH FRAME TITLE TEXT-002.
PARAMETERS: p_mview RADIOBUTTON GROUP rmd DEFAULT 'X' USER-COMMAND rmdsel,
            p_mappl RADIOBUTTON GROUP rmd,
            p_mskip RADIOBUTTON GROUP rmd.
PARAMETERS: p_simul AS CHECKBOX DEFAULT 'X'.
SELECTION-SCREEN END OF BLOCK b_act.

*&---------------------------------------------------------------------*
*&  LOCAL APPLICATION CONTROLLER DEFINITION
*&---------------------------------------------------------------------*
CLASS lcl_review_app DEFINITION FINAL.
  PUBLIC SECTION.
    CLASS-METHODS f4_run_id.
    CLASS-METHODS f4_table.
    CLASS-METHODS run.
  PRIVATE SECTION.
    TYPES:
      BEGIN OF ts_disp_hit,
        run_id      TYPE /ctdi/scan_hits-run_id,
        item_no     TYPE i,
        status      TYPE /ctdi/scan_hits-status,
        status_txt  TYPE c LENGTH 12,
        tabname     TYPE /ctdi/scan_hits-tabname,
        keyinfo     TYPE /ctdi/scan_hits-keyinfo,
        fieldname   TYPE /ctdi/scan_hits-fieldname,
        codepoint   TYPE /ctdi/scan_hits-codepoint,
        hit_count   TYPE i,
        orig_value  TYPE string,
        clean_value TYPE string,
        message     TYPE /ctdi/scan_hits-message,
        scan_user   TYPE /ctdi/scan_hits-scan_user,
        scan_tstmp  TYPE /ctdi/scan_hits-scan_tstmp,
        apply_user  TYPE /ctdi/scan_hits-apply_user,
        apply_tstmp TYPE /ctdi/scan_hits-apply_tstmp,
      END OF ts_disp_hit.
    TYPES tt_disp_hit TYPE STANDARD TABLE OF ts_disp_hit WITH EMPTY KEY.
    TYPES tt_hits TYPE STANDARD TABLE OF /ctdi/scan_hits.

    CLASS-METHODS display_salv
      IMPORTING
        !it_hits   TYPE tt_disp_hit
        !iv_header TYPE lvc_title.

    CLASS-METHODS map_to_disp
      IMPORTING
        !it_raw        TYPE tt_hits
      RETURNING
        VALUE(rt_disp) TYPE tt_disp_hit.
ENDCLASS.

*&---------------------------------------------------------------------*
*&  LOCAL APPLICATION CONTROLLER IMPLEMENTATION
*&---------------------------------------------------------------------*
CLASS lcl_review_app IMPLEMENTATION.

  METHOD f4_run_id.
    TYPES: BEGIN OF ts_f4,
             run_id     TYPE /ctdi/scan_hits-run_id,
             tabname    TYPE /ctdi/scan_hits-tabname,
             scan_user  TYPE /ctdi/scan_hits-scan_user,
             scan_tstmp TYPE /ctdi/scan_hits-scan_tstmp,
           END OF ts_f4.
    DATA lt_f4 TYPE STANDARD TABLE OF ts_f4.

    SELECT DISTINCT run_id, tabname, scan_user, scan_tstmp
      FROM /ctdi/scan_hits
      INTO CORRESPONDING FIELDS OF TABLE @lt_f4
      ORDER BY scan_tstmp DESCENDING.

    IF lt_f4 IS INITIAL.
      MESSAGE 'No scan runs found in /CTDI/SCAN_HITS' TYPE 'S'.
      RETURN.
    ENDIF.

    CALL FUNCTION 'F4IF_INT_TABLE_VALUE_REQUEST'
      EXPORTING
        retfield        = 'RUN_ID'
        dynpprog        = sy-repid
        dynpnr          = sy-dynnr
        dynprofield     = 'P_RUNID'
        value_org       = 'S'
      TABLES
        value_tab       = lt_f4
      EXCEPTIONS
        parameter_error = 1
        no_values_found = 2
        OTHERS          = 3.
  ENDMETHOD.

  METHOD f4_table.
    DATA ls_shlp TYPE  shlp_descr.
    DATA lt_ret TYPE STANDARD TABLE OF ddshretval.
    CALL FUNCTION 'F4IF_GET_SHLP_DESCR'
      EXPORTING
        shlpname = 'DD_DBTB_16'
      IMPORTING
        shlp     = ls_shlp.

    CALL FUNCTION 'F4IF_START_VALUE_REQUEST'
      EXPORTING
        shlp          = ls_shlp
      TABLES
        return_values = lt_ret.

    IF line_exists( lt_ret[ 1 ] ).
      p_tab = lt_ret[ 1 ]-fieldval.
    ENDIF.
  ENDMETHOD.

  METHOD map_to_disp.
    LOOP AT it_raw ASSIGNING FIELD-SYMBOL(<r>).
      DATA(lv_st_txt) = SWITCH string( <r>-status
        WHEN 'O' THEN 'Open'
        WHEN 'C' THEN 'Cleaned'
        WHEN 'S' THEN 'Skipped'
        WHEN 'E' THEN 'Error'
        ELSE <r>-status ).

      APPEND VALUE ts_disp_hit(
        run_id      = <r>-run_id
        item_no     = <r>-item_no
        status      = <r>-status
        status_txt  = lv_st_txt
        tabname     = <r>-tabname
        keyinfo     = <r>-keyinfo
        fieldname   = <r>-fieldname
        codepoint   = <r>-codepoint
        hit_count   = <r>-hit_count
        orig_value  = <r>-orig_value
        clean_value = <r>-clean_value
        message     = <r>-message
        scan_user   = <r>-scan_user
        scan_tstmp  = <r>-scan_tstmp
        apply_user  = <r>-apply_user
        apply_tstmp = <r>-apply_tstmp ) TO rt_disp.
    ENDLOOP.
  ENDMETHOD.

  METHOD display_salv.
    DATA lo_salv TYPE REF TO cl_salv_table.
    DATA lt_data TYPE tt_disp_hit.
    lt_data = it_hits.

    TRY.
        cl_salv_table=>factory(
          IMPORTING
            r_salv_table = lo_salv
          CHANGING
            t_table      = lt_data ).

        DATA(lo_cols) = lo_salv->get_columns( ).
        lo_cols->set_optimize( abap_true ).

        lo_cols->get_column( 'RUN_ID' )->set_short_text( 'Run ID' ).
        lo_cols->get_column( 'ITEM_NO' )->set_short_text( 'Item' ).
        lo_cols->get_column( 'STATUS' )->set_visible( abap_false ).
        lo_cols->get_column( 'STATUS_TXT' )->set_short_text( 'Status' ).
        lo_cols->get_column( 'TABNAME' )->set_short_text( 'Table' ).
        lo_cols->get_column( 'KEYINFO' )->set_short_text( 'Key' ).
        lo_cols->get_column( 'KEYINFO' )->set_medium_text( 'Record key' ).
        lo_cols->get_column( 'FIELDNAME' )->set_short_text( 'Field' ).
        lo_cols->get_column( 'CODEPOINT' )->set_short_text( 'Hex' ).
        lo_cols->get_column( 'HIT_COUNT' )->set_short_text( 'Hits' ).
        lo_cols->get_column( 'ORIG_VALUE' )->set_medium_text( 'Original Value' ).
        lo_cols->get_column( 'CLEAN_VALUE' )->set_medium_text( 'Cleaned Value' ).
        lo_cols->get_column( 'MESSAGE' )->set_short_text( 'Message' ).
        lo_cols->get_column( 'MESSAGE' )->set_medium_text( 'Result message' ).
        lo_cols->get_column( 'SCAN_USER' )->set_short_text( 'Scanned By' ).
        lo_cols->get_column( 'SCAN_TSTMP' )->set_medium_text( 'Scan Timestamp' ).
        lo_cols->get_column( 'APPLY_USER' )->set_short_text( 'Applied By' ).
        lo_cols->get_column( 'APPLY_TSTMP' )->set_medium_text( 'Apply Timestamp' ).

        lo_salv->get_functions( )->set_all( abap_true ).
        lo_salv->get_display_settings( )->set_list_header( iv_header ).
        lo_salv->display( ).
      CATCH cx_salv_msg cx_salv_not_found INTO DATA(lx_salv).
        MESSAGE lx_salv->get_text( ) TYPE 'S' DISPLAY LIKE 'E'.
    ENDTRY.
  ENDMETHOD.

  METHOD run.
    DATA lt_raw TYPE STANDARD TABLE OF /ctdi/scan_hits.

    SELECT * FROM /ctdi/scan_hits

      WHERE ( ( @p_runid IS NULL OR run_id = @p_runid )
          AND ( @p_tab IS NULL   OR tabname = @p_tab )
          AND status IN @so_stat )
      ORDER BY run_id, item_no      INTO TABLE @lt_raw UP TO @p_max ROWS
.

    IF lt_raw IS INITIAL.
      MESSAGE 'No findings matching selection criteria found in /CTDI/SCAN_HITS.' TYPE 'S'.
      RETURN.
    ENDIF.

    IF p_mview = abap_true.
      " ---- Review / Display Findings (Read-Only) --------------------
      DATA(lt_disp) = map_to_disp( lt_raw ).
      display_salv(
        it_hits   = lt_disp
        iv_header = |Review Findings: { lines( lt_disp ) } items loaded from /CTDI/SCAN_HITS| ).

    ELSEIF p_mappl = abap_true.
      " ---- Governed Apply (Write-back or Simulation) ----------------
      IF p_simul = abap_false AND sy-batch = abap_false.
        DATA lv_ans TYPE c LENGTH 1.
        CALL FUNCTION 'POPUP_TO_CONFIRM'
          EXPORTING
            titlebar              = 'Confirm Live Write-Back'
            text_question         = |Do you want to update { lines( lt_raw ) } records in database table(s)?|
            text_button_1         = 'Yes, Apply'
            text_button_2         = 'Cancel'
            default_button        = '2'
            display_cancel_button = 'X'
          IMPORTING
            answer                = lv_ans
          EXCEPTIONS
            OTHERS                = 0.
        IF lv_ans <> '1'.
          MESSAGE 'Write-back cancelled by user' TYPE 'S'.
          RETURN.
        ENDIF.
      ENDIF.

      DATA(lo_logger) = NEW /ctdi/cl_scan_logger(
        iv_object    = '/CTDI/SCAN'
        iv_subobject = 'REMEDY'
        iv_extnumber = |Apply_{ sy-datum }_{ sy-uzeit }| ).

      DATA lv_success TYPE i.
      DATA lv_errors  TYPE i.

      LOOP AT lt_raw ASSIGNING FIELD-SYMBOL(<h>).
        DATA(ls_res) = /ctdi/cl_scan_remediator=>apply_row(
          is_hit        = <h>
          iv_simulation = p_simul
          io_logger     = lo_logger ).

        IF ls_res-success = abap_true.
          lv_success = lv_success + 1.
        ELSE.
          lv_errors = lv_errors + 1.
        ENDIF.
      ENDLOOP.

      lo_logger->save( ).

      SELECT * FROM /ctdi/scan_hits
        WHERE ( ( @p_runid IS NULL OR run_id = @p_runid )
            AND ( @p_tab IS NULL   OR tabname = @p_tab ) )
        ORDER BY run_id, item_no INTO TABLE @lt_raw  UP TO @p_max ROWS.

      DATA(lt_res_disp) = map_to_disp( lt_raw ).
      DATA(lv_mode_txt) = COND string( WHEN p_simul = abap_true THEN 'SIMULATION' ELSE 'LIVE WRITE-BACK' ).
      display_salv(
        it_hits   = lt_res_disp
        iv_header = |Apply Results ({ lv_mode_txt }): { lv_success } OK, { lv_errors } Failed| ).

      MESSAGE |Apply { lv_mode_txt } complete: { lv_success } success, { lv_errors } errors| TYPE 'S'.

    ELSEIF p_mskip = abap_true.
      " ---- Mark Selected Items as Skipped --------------------------
      LOOP AT lt_raw ASSIGNING FIELD-SYMBOL(<s_hit>).
        /ctdi/cl_scan_remediator=>skip_row( <s_hit> ).
      ENDLOOP.

      MESSAGE |Marked { lines( lt_raw ) } records as Skipped in /CTDI/SCAN_HITS| TYPE 'S'.
    ENDIF.
  ENDMETHOD.

ENDCLASS.

*&---------------------------------------------------------------------*
*&  SELECTION SCREEN EVENTS
*&---------------------------------------------------------------------*
AT SELECTION-SCREEN OUTPUT.
  LOOP AT SCREEN.
    IF screen-name = 'P_SIMUL' AND p_mappl = abap_false.
      screen-input = 0.
      MODIFY SCREEN.
    ENDIF.
  ENDLOOP.

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_runid.
  lcl_review_app=>f4_run_id( ).

AT SELECTION-SCREEN ON VALUE-REQUEST FOR p_tab.
  lcl_review_app=>f4_table( ).

*&---------------------------------------------------------------------*
*&  START-OF-SELECTION
*&---------------------------------------------------------------------*
START-OF-SELECTION.
  lcl_review_app=>run( ).
