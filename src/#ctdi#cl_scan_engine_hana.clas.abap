class /CTDI/CL_SCAN_ENGINE_HANA definition
  public
  create public .

public section.

  interfaces /CTDI/IF_SCAN_ENGINE .
  PROTECTED SECTION.
  PRIVATE SECTION.
    METHODS fallback_to_universal
      IMPORTING
        !is_params       TYPE /ctdi/if_scan_engine=>ts_scan_params
        !ii_rule         TYPE REF TO /ctdi/if_inspection_rule
      RETURNING
        VALUE(rs_result) TYPE /ctdi/cl_scan_parallel=>ts_result
      RAISING
        cx_static_check .
ENDCLASS.



CLASS /CTDI/CL_SCAN_ENGINE_HANA IMPLEMENTATION.


  METHOD /ctdi/if_scan_engine~execute.
    " Ensure current runtime is indeed SAP HANA
    IF sy-dbsys <> 'HDB'.
      rs_result = fallback_to_universal( is_params = is_params ii_rule = ii_rule ).
      RETURN.
    ENDIF.

    " Check if the rule provides a pushdown SQL predicate
    DATA(lv_rule_filter) = ii_rule->get_db_filter( is_params-fields ).
    IF lv_rule_filter IS INITIAL.
      " Rule requires in-memory evaluation -> safe fallback to universal engine
      rs_result = fallback_to_universal( is_params = is_params ii_rule = ii_rule ).
      RETURN.
    ENDIF.

    " Future in-memory pushdown execution on HANA:
    " Evaluates database predicate and queries only offending rows directly.
    TRY.
        DATA(lt_where) = is_params-where.
        APPEND lv_rule_filter TO lt_where.

        DATA(lo_reader) = NEW /ctdi/cl_table_reader( ).
        DATA: lr_data   TYPE REF TO data,
              lr_struct TYPE REF TO cl_abap_structdescr.

        lo_reader->read(
          EXPORTING
            iv_table  = is_params-table
            iv_max    = is_params-hmax
            it_where  = lt_where
            it_fields = is_params-fields
          IMPORTING
            er_data   = lr_data
            er_struct = lr_struct ).

        FIELD-SYMBOLS <lt_data> TYPE STANDARD TABLE.
        ASSIGN lr_data->* TO <lt_data>.

        rs_result-hits = ii_rule->inspect_table(
                           it_data   = <lt_data>
                           it_fields = is_params-fields
                           it_keys   = is_params-keys ).
        rs_result-rows = lines( <lt_data> ).
      CATCH cx_root.
        " Any DB error during pushdown falls back gracefully to universal parallel engine
        rs_result = fallback_to_universal( is_params = is_params ii_rule = ii_rule ).
    ENDTRY.
  ENDMETHOD.


  METHOD fallback_to_universal.
    DATA(lo_univ) = NEW /ctdi/cl_scan_engine_univ( ).
    rs_result = lo_univ->/ctdi/if_scan_engine~execute(
      is_params = is_params
      ii_rule   = ii_rule ).
  ENDMETHOD.
ENDCLASS.
