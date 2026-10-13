CLASS ltcl_remediator DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS .
  PRIVATE SECTION.
    METHODS:
      simulation_calculates_diffs FOR TESTING .
ENDCLASS.
CLASS ltcl_remediator IMPLEMENTATION.
  METHOD simulation_calculates_diffs.
    DATA lt_hits TYPE /ctdi/if_inspection_rule=>tt_violation.
    APPEND VALUE #(
      rownum  = 1
      keyinfo = 'K=001'
      field   = 'NAME1'
      value   = |First{ cl_abap_char_utilities=>newline }Second| ) TO lt_hits.
    APPEND VALUE #(
      rownum  = 2
      keyinfo = 'K=002'
      field   = 'NAME1'
      value   = 'CleanText' ) TO lt_hits.
    DATA(ls_res) = /ctdi/cl_scan_remediator=>simulate( lt_hits ).
    cl_abap_unit_assert=>assert_true( act = ls_res-simulated ).
    cl_abap_unit_assert=>assert_equals( exp = 2 act = ls_res-total_items ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = ls_res-changed ).
    DATA(ls_diff1) = ls_res-diffs[ 1 ].
    cl_abap_unit_assert=>assert_true( act = ls_diff1-changed ).
    cl_abap_unit_assert=>assert_equals( exp = 'First Second' act = ls_diff1-new_value ).
    DATA(ls_diff2) = ls_res-diffs[ 2 ].
    cl_abap_unit_assert=>assert_false( act = ls_diff2-changed ).
    cl_abap_unit_assert=>assert_equals( exp = 'CleanText' act = ls_diff2-new_value ).
  ENDMETHOD.
ENDCLASS.
*"* use this source file for your ABAP unit test classes
