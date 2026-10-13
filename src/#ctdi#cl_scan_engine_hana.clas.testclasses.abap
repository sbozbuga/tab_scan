CLASS ltcl_hana_engine DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS .
  PRIVATE SECTION.
    METHODS:
      fallback_executes_safely FOR TESTING .
ENDCLASS.
CLASS ltcl_hana_engine IMPLEMENTATION.
  METHOD fallback_executes_safely.
    DATA(lo_engine) = NEW /ctdi/cl_scan_engine_hana( ).
    cl_abap_unit_assert=>assert_bound( act = lo_engine ).
    " When rule does not supply a DB filter, engine falls back safely
    DATA(lo_rule) = NEW /ctdi/cl_cntrl_scanner( ).
    cl_abap_unit_assert=>assert_initial( act = lo_rule->/ctdi/if_inspection_rule~get_db_filter( VALUE #( ) ) ).
  ENDMETHOD.
ENDCLASS.
