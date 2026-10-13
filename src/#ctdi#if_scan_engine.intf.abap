INTERFACE /ctdi/if_scan_engine
  PUBLIC .

  TYPES:
    BEGIN OF ts_scan_params,
      table        TYPE tabname,
      fields       TYPE /ctdi/if_inspection_rule=>tt_field,
      keys         TYPE /ctdi/if_inspection_rule=>tt_field,
      where        TYPE /ctdi/cl_table_reader=>tt_where,
      pkg_size     TYPE i,
      percentage   TYPE i,
      server_group TYPE rzlli_apcl,
      hmax         TYPE i,
      total_est    TYPE i,
    END OF ts_scan_params .

  "! Execute inspection on the requested table
  METHODS execute
    IMPORTING
      !is_params       TYPE ts_scan_params
      !ii_rule         TYPE REF TO /ctdi/if_inspection_rule
    RETURNING
      VALUE(rs_result) TYPE /ctdi/cl_scan_parallel=>ts_result
    RAISING
      cx_static_check .

ENDINTERFACE.
