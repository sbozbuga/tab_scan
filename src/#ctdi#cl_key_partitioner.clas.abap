CLASS /ctdi/cl_key_partitioner DEFINITION
  PUBLIC
  CREATE PUBLIC .

  PUBLIC SECTION.

    TYPES:
      BEGIN OF ts_keyval,
        field TYPE fieldname,
        value TYPE string,
      END OF ts_keyval .
    TYPES:
      tt_keyval TYPE STANDARD TABLE OF ts_keyval WITH EMPTY KEY .
    TYPES:
      BEGIN OF ts_slice,
        slice_no  TYPE i,
        after_key TYPE tt_keyval,
        end_key   TYPE tt_keyval,
        rows      TYPE i,
        base_row  TYPE i,
      END OF ts_slice .
    TYPES:
      tt_slice TYPE STANDARD TABLE OF ts_slice WITH EMPTY KEY .

    "! Render a value as a single-quoted Open SQL character literal
    CLASS-METHODS quote_literal
      IMPORTING
        !iv_value     TYPE string
      RETURNING
        VALUE(rv_lit) TYPE string .
    "! Build WHERE fragment selecting rows strictly after given key tuple
    CLASS-METHODS build_resume_where
      IMPORTING
        !it_after       TYPE tt_keyval
      RETURNING
        VALUE(rv_where) TYPE string .
    "! Build WHERE fragment selecting rows up to and including key tuple
    CLASS-METHODS build_until_where
      IMPORTING
        !it_until       TYPE tt_keyval
      RETURNING
        VALUE(rv_where) TYPE string .
    "! Cheap keys-only probe partitioning table into balanced slices
    CLASS-METHODS probe_slices
      IMPORTING
        !iv_table        TYPE tabname
        !it_where        TYPE /ctdi/cl_table_reader=>tt_where
        !iv_slice_size   TYPE i DEFAULT 50000
      RETURNING
        VALUE(rt_slices) TYPE tt_slice
      RAISING
        cx_sy_dynamic_osql_error
        cx_sy_create_data_error .
  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.



CLASS /CTDI/CL_KEY_PARTITIONER IMPLEMENTATION.


  METHOD build_resume_where.
    IF it_after IS INITIAL.
      RETURN.
    ENDIF.

    DATA lt_terms TYPE STANDARD TABLE OF string.
    DATA lv_i     TYPE i.
    DATA(lv_n)    = lines( it_after ).

    lv_i = 1.
    WHILE lv_i <= lv_n.
      DATA lv_term TYPE string.
      CLEAR lv_term.
      DATA lv_j TYPE i.
      lv_j = 1.
      WHILE lv_j < lv_i.
        DATA(ls_eq) = it_after[ lv_j ].
        DATA(lv_eq) = |{ ls_eq-field } = { quote_literal( ls_eq-value ) }|.
        lv_term = COND #( WHEN lv_term IS INITIAL THEN lv_eq
                          ELSE |{ lv_term } AND { lv_eq }| ).
        lv_j = lv_j + 1.
      ENDWHILE.
      DATA(ls_gt) = it_after[ lv_i ].
      DATA(lv_gt) = |{ ls_gt-field } > { quote_literal( ls_gt-value ) }|.
      lv_term = COND #( WHEN lv_term IS INITIAL THEN lv_gt
                        ELSE |{ lv_term } AND { lv_gt }| ).
      APPEND |( { lv_term } )| TO lt_terms.
      lv_i = lv_i + 1.
    ENDWHILE.

    LOOP AT lt_terms ASSIGNING FIELD-SYMBOL(<t>).
      rv_where = COND #( WHEN rv_where IS INITIAL THEN <t>
                         ELSE |{ rv_where } OR { <t> }| ).
    ENDLOOP.
    rv_where = |( { rv_where } )|.
  ENDMETHOD.


  METHOD build_until_where.
    IF it_until IS INITIAL.
      RETURN.
    ENDIF.

    DATA lt_terms TYPE STANDARD TABLE OF string.
    DATA(lv_n)    = lines( it_until ).
    DATA lv_i     TYPE i.

    lv_i = 1.
    WHILE lv_i <= lv_n.
      DATA lv_term TYPE string.
      CLEAR lv_term.
      DATA lv_j TYPE i.
      lv_j = 1.
      WHILE lv_j < lv_i.
        DATA(ls_eq) = it_until[ lv_j ].
        DATA(lv_eq) = |{ ls_eq-field } = { quote_literal( ls_eq-value ) }|.
        lv_term = COND #( WHEN lv_term IS INITIAL THEN lv_eq
                          ELSE |{ lv_term } AND { lv_eq }| ).
        lv_j = lv_j + 1.
      ENDWHILE.
      DATA(ls_c) = it_until[ lv_i ].
      DATA(lv_c) = |{ ls_c-field } < { quote_literal( ls_c-value ) }|.
      lv_term = COND #( WHEN lv_term IS INITIAL THEN lv_c
                        ELSE |{ lv_term } AND { lv_c }| ).
      APPEND |( { lv_term } )| TO lt_terms.
      lv_i = lv_i + 1.
    ENDWHILE.

    CLEAR lv_term.
    LOOP AT it_until ASSIGNING FIELD-SYMBOL(<e>).
      DATA(lv_e) = |{ <e>-field } = { quote_literal( <e>-value ) }|.
      lv_term = COND #( WHEN lv_term IS INITIAL THEN lv_e
                        ELSE |{ lv_term } AND { lv_e }| ).
    ENDLOOP.
    APPEND |( { lv_term } )| TO lt_terms.

    LOOP AT lt_terms ASSIGNING FIELD-SYMBOL(<t>).
      rv_where = COND #( WHEN rv_where IS INITIAL THEN <t>
                         ELSE |{ rv_where } OR { <t> }| ).
    ENDLOOP.
    rv_where = |( { rv_where } )|.
  ENDMETHOD.


  METHOD probe_slices.
    /ctdi/cl_table_metadata=>check_authority( iv_table ).

    DATA(lt_keyflds) = /ctdi/cl_table_metadata=>get_key_fields( iv_table ).
    IF lt_keyflds IS INITIAL.
      RETURN.
    ENDIF.

    DATA lv_cols  TYPE string.
    DATA lv_order TYPE string.
    LOOP AT lt_keyflds ASSIGNING FIELD-SYMBOL(<kf>).
      lv_cols = COND #( WHEN lv_cols IS INITIAL THEN <kf>
                        ELSE |{ lv_cols }, { <kf> }| ).
      lv_order = COND #( WHEN lv_order IS INITIAL THEN |{ <kf> } ASCENDING|
                         ELSE |{ lv_order }, { <kf> } ASCENDING| ).
    ENDLOOP.

    DATA lr_full TYPE REF TO cl_abap_structdescr.
    lr_full ?= cl_abap_typedescr=>describe_by_name( iv_table ).
    DATA lt_comp TYPE cl_abap_structdescr=>component_table.
    LOOP AT lt_keyflds ASSIGNING FIELD-SYMBOL(<kf2>).
      APPEND VALUE #( name = <kf2>
                      type = CAST cl_abap_datadescr( lr_full->get_component_type( <kf2> ) ) )
             TO lt_comp.
    ENDLOOP.
    DATA(lr_tab) = cl_abap_tabledescr=>create( cl_abap_structdescr=>create( lt_comp ) ).
    DATA lr_pkg TYPE REF TO data.
    CREATE DATA lr_pkg TYPE HANDLE lr_tab.
    FIELD-SYMBOLS <lt_pkg> TYPE STANDARD TABLE.
    ASSIGN lr_pkg->* TO <lt_pkg>.

    DATA lv_after TYPE tt_keyval.
    DATA lv_base  TYPE i.
    DATA lv_no    TYPE i.

    SELECT (lv_cols) FROM (iv_table)
      INTO TABLE @<lt_pkg>
      PACKAGE SIZE @iv_slice_size
      BYPASSING BUFFER
      WHERE (it_where)
      ORDER BY (lv_order).

      DATA(lv_rows) = lines( <lt_pkg> ).
      IF lv_rows = 0.
        CONTINUE.
      ENDIF.
      lv_no = lv_no + 1.

      DATA lt_end TYPE tt_keyval.
      CLEAR lt_end.
      FIELD-SYMBOLS <last> TYPE any.
      READ TABLE <lt_pkg> ASSIGNING <last> INDEX lv_rows.
      DATA lv_end_str TYPE string.
      LOOP AT lt_keyflds ASSIGNING FIELD-SYMBOL(<kf3>).  "#EC CI_NESTED
        ASSIGN COMPONENT <kf3> OF STRUCTURE <last> TO FIELD-SYMBOL(<kv>).
        lv_end_str = <kv>.
        APPEND VALUE #( field = <kf3> value = lv_end_str ) TO lt_end.
      ENDLOOP.

      APPEND VALUE ts_slice( slice_no  = lv_no
                             after_key = lv_after
                             end_key   = lt_end
                             rows      = lv_rows
                             base_row  = lv_base ) TO rt_slices.

      lv_base  = lv_base + lv_rows.
      lv_after = lt_end.
    ENDSELECT.
  ENDMETHOD.


  METHOD quote_literal.
    DATA(lv_v) = iv_value.
    REPLACE ALL OCCURRENCES OF |'| IN lv_v WITH |''|.
    rv_lit = |'{ lv_v }'|.
  ENDMETHOD.
ENDCLASS.
