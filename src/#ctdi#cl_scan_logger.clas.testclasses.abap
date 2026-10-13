CLASS ltcl_logger DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS .
  PRIVATE SECTION.
    METHODS:
      logs_messages_in_memory FOR TESTING .
ENDCLASS.
CLASS ltcl_logger IMPLEMENTATION.
  METHOD logs_messages_in_memory.
    DATA(lo_log) = NEW /ctdi/cl_scan_logger( ).
    lo_log->add_info( 'Starting test run' ).
    lo_log->add_warning( 'Simulated warning' ).
    lo_log->add_error( 'Simulated error' ).
    DATA(lt_msgs) = lo_log->get_messages( ).
    cl_abap_unit_assert=>assert_equals( exp = 3 act = lines( lt_msgs ) ).
    cl_abap_unit_assert=>assert_true( act = xsdbool( lt_msgs[ 1 ] CS 'Starting test run' ) ).
    cl_abap_unit_assert=>assert_true( act = xsdbool( lt_msgs[ 2 ] CS 'Simulated warning' ) ).
    cl_abap_unit_assert=>assert_true( act = xsdbool( lt_msgs[ 3 ] CS 'Simulated error' ) ).
  ENDMETHOD.
ENDCLASS.
