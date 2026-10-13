INTERFACE /ctdi/if_inspection_rule
  PUBLIC .

  TYPES tt_field TYPE STANDARD TABLE OF fieldname WITH EMPTY KEY .

  " One violation finding (compatible with /ctdi/cl_cntrl_scanner=>ts_hit)
  TYPES:
    BEGIN OF ts_violation,
      rownum  TYPE i,         " row number within the scanned set
      keyinfo TYPE string,    " key fields of the row, e.g. VBELN=..
      field   TYPE fieldname, " field that holds the violation
      offset  TYPE i,         " 0-based position within the value
      hexcode TYPE string,    " hex or violation code, e.g. 0x0A
      descr   TYPE string,    " readable description, e.g. LF (line feed)
      value   TYPE string,    " full field value, for context
    END OF ts_violation .
  TYPES
    tt_violation TYPE STANDARD TABLE OF ts_violation WITH EMPTY KEY .

  "! Unique rule identifier (e.g. 'CONTROL_CHARS', 'REGEX', 'PII')
  METHODS get_rule_id
    RETURNING
      VALUE(rv_id) TYPE string .

  "! Inspect character fields of one (flat) structure
  METHODS inspect_row
    IMPORTING
      !is_data             TYPE any
      !it_fields           TYPE tt_field
      !it_keys             TYPE tt_field OPTIONAL
      !iv_row              TYPE i DEFAULT 1
    RETURNING
      VALUE(rt_violations) TYPE tt_violation .

  "! Inspect character fields of an internal table
  METHODS inspect_table
    IMPORTING
      !it_data             TYPE ANY TABLE
      !it_fields           TYPE tt_field
      !it_keys             TYPE tt_field OPTIONAL
    RETURNING
      VALUE(rt_violations) TYPE tt_violation .

  "! Optional: compiles rule into an Open SQL / HANA SQL filter fragment
  "! to filter rows directly on the database when pushdown is supported.
  "! Returns empty string if rule requires application-server evaluation.
  METHODS get_db_filter
    IMPORTING
      !it_fields       TYPE tt_field
    RETURNING
      VALUE(rv_filter) TYPE string .

ENDINTERFACE.
