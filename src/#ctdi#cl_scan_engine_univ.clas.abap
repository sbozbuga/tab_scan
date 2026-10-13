CLASS /ctdi/cl_scan_engine_univ DEFINITION
  PUBLIC
  CREATE PUBLIC .

  PUBLIC SECTION.
    INTERFACES /ctdi/if_scan_engine .

  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.



CLASS /ctdi/cl_scan_engine_univ IMPLEMENTATION.

  METHOD /ctdi/if_scan_engine~execute.
    " Delegate to the proven keys-only slice map parallel runner.
    " Works uniformly across AnyDB (Oracle, DB2, MSSQL) and SAP HANA.
    DATA ls_scope TYPE /ctdi/cl_cntrl_scanner=>ts_scope.
    " Default scope (full set) if rule is control characters
    ls_scope = VALUE #( common = abap_true ).

    rs_result = /ctdi/cl_scan_parallel=>run_parallel_scan(
      iv_table         = is_params-table
      it_scanflds      = is_params-fields
      it_keys          = is_params-keys
      it_keyflds       = is_params-keys
      is_scope         = ls_scope
      it_where         = is_params-where
      iv_pkg_size      = is_params-pkg_size
      iv_percentage    = is_params-percentage
      iv_hmax          = is_params-hmax
      iv_group         = is_params-server_group
      iv_total_est     = is_params-total_est ).
  ENDMETHOD.

ENDCLASS.
