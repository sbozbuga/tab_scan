CLASS ltcl_factory DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS .
  PRIVATE SECTION.
    METHODS:
      returns_valid_engine FOR TESTING,
      force_universal_returns_engine FOR TESTING .
ENDCLASS.
CLASS ltcl_factory IMPLEMENTATION.
  METHOD returns_valid_engine.
    DATA(lo_engine) = /ctdi/cl_scan_engine_factory=>get_engine( ).
    cl_abap_unit_assert=>assert_bound(
      act = lo_engine
      msg = 'Factory must return a bound engine instance' ).
  ENDMETHOD.
  METHOD force_universal_returns_engine.
    DATA(lo_engine) = /ctdi/cl_scan_engine_factory=>get_engine( iv_force_universal = abap_true ).
    cl_abap_unit_assert=>assert_bound(
      act = lo_engine
      msg = 'Factory with force_universal must return a bound engine instance' ).
  ENDMETHOD.
ENDCLASS.
