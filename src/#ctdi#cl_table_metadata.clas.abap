CLASS /ctdi/cl_table_metadata DEFINITION
  PUBLIC
  CREATE PUBLIC .

  PUBLIC SECTION.
    TYPES tt_field TYPE /ctdi/if_inspection_rule=>tt_field .

    "! Display-authorization check for a table (S_TABU_DIS / S_TABU_NAM)
    CLASS-METHODS check_authority
      IMPORTING
        !iv_table TYPE tabname .

    "! The non-client primary key fields of a table, in key order.
    CLASS-METHODS get_key_fields
      IMPORTING
        !iv_table         TYPE tabname
      RETURNING
        VALUE(rt_keyflds) TYPE tt_field .

    "! Resolve character fields (CHAR / STRING) of a structure to scan.
    CLASS-METHODS scan_fields
      IMPORTING
        !ir_struct       TYPE REF TO cl_abap_structdescr
        !iv_table        TYPE tabname
        !iv_start_col    TYPE i DEFAULT 1
        !iv_skip_check   TYPE abap_bool DEFAULT abap_false
      RETURNING
        VALUE(rt_fields) TYPE tt_field .

    "! Combined byte width of fields when concatenated by RFC_READ_TABLE
    CLASS-METHODS remote_width
      IMPORTING
        !ir_struct      TYPE REF TO cl_abap_structdescr
        !it_fields      TYPE tt_field
      RETURNING
        VALUE(rv_width) TYPE i .

    "! Build projected structure and SELECT column clause for table + fields
    CLASS-METHODS build_projection
      IMPORTING
        !iv_table  TYPE tabname
        !it_fields TYPE tt_field
      EXPORTING
        !ev_cols   TYPE string
        !er_struct TYPE REF TO cl_abap_structdescr .

  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.



CLASS /CTDI/CL_TABLE_METADATA IMPLEMENTATION.


  METHOD build_projection.
    DATA lr_full TYPE REF TO cl_abap_structdescr.
    lr_full ?= cl_abap_typedescr=>describe_by_name( iv_table ).

    DATA(lt_ddic) = lr_full->get_ddic_field_list( ).

    DATA: lt_sel  TYPE TABLE OF string,
          lt_comp TYPE cl_abap_structdescr=>component_table.

    IF it_fields IS NOT INITIAL.
      LOOP AT lt_ddic ASSIGNING FIELD-SYMBOL(<ls_k>) WHERE keyflag = abap_true.
        APPEND <ls_k>-fieldname TO lt_sel.
        APPEND VALUE #( name = <ls_k>-fieldname
                        type = CAST cl_abap_datadescr(
                                 lr_full->get_component_type( <ls_k>-fieldname ) ) )
               TO lt_comp.
      ENDLOOP.
      LOOP AT it_fields ASSIGNING FIELD-SYMBOL(<lv_f>).
        DATA(lv_fn) = CONV abap_compname( to_upper( <lv_f> ) ).
        IF NOT line_exists( lt_comp[ name = lv_fn ] ).
          TRY.
              APPEND VALUE #( name = lv_fn
                              type = CAST cl_abap_datadescr(
                                       lr_full->get_component_type( lv_fn ) ) )
                     TO lt_comp.
              APPEND lv_fn TO lt_sel.
            CATCH cx_root.
          ENDTRY.
        ENDIF.
      ENDLOOP.
      er_struct = cl_abap_structdescr=>create( lt_comp ).
    ELSE.
      er_struct = lr_full.
    ENDIF.

    IF lt_sel IS INITIAL.
      ev_cols = '*'.
    ELSE.
      LOOP AT lt_sel ASSIGNING FIELD-SYMBOL(<lv_col>).
        ev_cols = COND #( WHEN ev_cols IS INITIAL THEN <lv_col>
                          ELSE |{ ev_cols }, { <lv_col> }| ).
      ENDLOOP.
    ENDIF.
  ENDMETHOD.


  METHOD check_authority.
    CALL FUNCTION 'VIEW_AUTHORITY_CHECK'
      EXPORTING
        view_action                    = 'S'
        view_name                      = iv_table
      EXCEPTIONS
        invalid_action                 = 1
        no_authority                   = 2
        no_clientindependent_authority = 3
        table_not_found                = 4
        no_linedependent_authority     = 5
        OTHERS                         = 6.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE cx_sy_authorization_error.
    ENDIF.
  ENDMETHOD.


  METHOD get_key_fields.
    DATA(lt_ddic) = CAST cl_abap_structdescr(
                      cl_abap_typedescr=>describe_by_name( iv_table ) )->get_ddic_field_list( ).
    LOOP AT lt_ddic ASSIGNING FIELD-SYMBOL(<df>)
         WHERE keyflag = abap_true AND datatype <> 'CLNT'.
      APPEND <df>-fieldname TO rt_keyflds.
    ENDLOOP.
  ENDMETHOD.


  METHOD remote_width.
    DATA(lt_ddic) = ir_struct->get_ddic_field_list( ).
    LOOP AT it_fields ASSIGNING FIELD-SYMBOL(<sf>).
      READ TABLE lt_ddic ASSIGNING FIELD-SYMBOL(<dw>) WITH KEY fieldname = <sf>."#EC CI_STDSEQ
      IF sy-subrc = 0.
        rv_width = rv_width + <dw>-leng + 1.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD scan_fields.
    DATA lt_check TYPE HASHED TABLE OF fieldname WITH UNIQUE KEY table_line.
    IF iv_skip_check = abap_true.
      DATA(lr_tabdescr) = CAST cl_abap_structdescr(
                            cl_abap_typedescr=>describe_by_name( iv_table ) ).
      LOOP AT lr_tabdescr->get_ddic_field_list( )
           ASSIGNING FIELD-SYMBOL(<ls_dd>) WHERE checktable IS NOT INITIAL.
        INSERT <ls_dd>-fieldname INTO TABLE lt_check.
      ENDLOOP.
    ENDIF.

    DATA(lt_comp) = ir_struct->get_components( ).
    LOOP AT lt_comp ASSIGNING FIELD-SYMBOL(<ls_comp>).
      IF sy-tabix < iv_start_col.
        CONTINUE.
      ENDIF.
      IF iv_skip_check = abap_true AND line_exists( lt_check[ table_line = <ls_comp>-name ] ).
        CONTINUE.
      ENDIF.
      IF <ls_comp>-type->kind <> cl_abap_typedescr=>kind_elem.
        CONTINUE.
      ENDIF.
      DATA(lr_elem) = CAST cl_abap_elemdescr( <ls_comp>-type ).
      IF lr_elem->type_kind = cl_abap_typedescr=>typekind_char
        OR lr_elem->type_kind = cl_abap_typedescr=>typekind_string.
        APPEND <ls_comp>-name TO rt_fields.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.
ENDCLASS.
