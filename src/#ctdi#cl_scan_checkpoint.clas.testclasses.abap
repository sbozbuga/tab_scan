CLASS ltcl_checkpoint DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS .
  PRIVATE SECTION.
    METHODS:
      checkpoint_roundtrip FOR TESTING .
ENDCLASS.
CLASS ltcl_checkpoint IMPLEMENTATION.
  METHOD checkpoint_roundtrip.
    DATA(lv_tab) = CONV tabname( 'TEST_TAB' ).
    DATA(lv_run) = /ctdi/cl_scan_checkpoint=>create_run( lv_tab ).
    cl_abap_unit_assert=>assert_not_initial( act = lv_run ).
    DATA ls_ckpt TYPE /ctdi/cl_scan_checkpoint=>ts_checkpoint.
    ls_ckpt-run_id       = lv_run.
    ls_ckpt-tabname      = lv_tab.
    ls_ckpt-rows_scanned = 50000.
    ls_ckpt-hits_count   = 12.
    ls_ckpt-last_end_key = VALUE #( ( field = 'VBELN' value = '001000' ) ) .
    ls_ckpt-status       = 'R'.
    GET TIME STAMP FIELD ls_ckpt-tstamp.
    /ctdi/cl_scan_checkpoint=>save_checkpoint( ls_ckpt ).
    DATA(ls_read) = /ctdi/cl_scan_checkpoint=>get_checkpoint( lv_run ).
    cl_abap_unit_assert=>assert_equals( exp = 50000 act = ls_read-rows_scanned ).
    cl_abap_unit_assert=>assert_equals( exp = 12 act = ls_read-hits_count ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( ls_read-last_end_key ) ).
    DATA(ls_lat) = /ctdi/cl_scan_checkpoint=>get_latest_for_table( lv_tab ).
    cl_abap_unit_assert=>assert_equals( exp = lv_run act = ls_lat-run_id ).
    /ctdi/cl_scan_checkpoint=>clear_checkpoint( lv_run ).
    DATA(ls_cleared) = /ctdi/cl_scan_checkpoint=>get_checkpoint( lv_run ).
    cl_abap_unit_assert=>assert_initial( act = ls_cleared-run_id ).
  ENDMETHOD.
ENDCLASS.
