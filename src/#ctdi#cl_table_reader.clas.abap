class /CTDI/CL_TABLE_READER definition
  public
  create public .

*"* Reads a (database) table dynamically - locally via Open SQL or
*"* remotely via RFC_READ_TABLE - and resolves which character fields
*"* should be scanned for control characters. Pairs with the scanner
*"* class /CTDI/CL_CNTRL_SCANNER.
public section.

  types TT_FIELD type /CTDI/CL_CNTRL_SCANNER=>TT_FIELD .
  types:                                                    " field-name list
    tt_where TYPE STANDARD TABLE OF string WITH EMPTY KEY .

  " One key field and its (character) value, used to resume a keyed read
  " after a given row. The value is the field's current content as text.
  types: BEGIN OF ts_keyval,
           field TYPE fieldname,
           value TYPE string,
         END OF ts_keyval .
  " An ordered key tuple (position order of the non-client key fields).
  types tt_keyval TYPE STANDARD TABLE OF ts_keyval WITH EMPTY KEY .

  " One slice of a table for parallel processing: the key range it covers
  " (resume STRICTLY AFTER after_key, up to and INCLUDING end_key), plus the
  " row count and the absolute base-row offset. Produced by a cheap keys-only
  " probe (probe_slices); each slice is handed to a worker that reads+scans
  " only its own range, so the heavy row reads run in parallel.
  types: BEGIN OF ts_slice,
           slice_no  TYPE i,
           after_key TYPE tt_keyval,   " resume strictly after this (empty = from start)
           end_key   TYPE tt_keyval,   " last key in the slice (inclusive upper bound)
           rows      TYPE i,
           base_row  TYPE i,
         END OF ts_slice .
  types tt_slice TYPE STANDARD TABLE OF ts_slice WITH EMPTY KEY .

  constants C_RFC_LINE_LIMIT type I value 512 ##NO_TEXT. " RFC_READ_TABLE row width

    "! Read a table locally via dynamic Open SQL.
    "! iv_last = X orders by primary key DESCENDING (last block by key).
    "! iv_skip greater than 0 is a block offset: reads skip+max rows
    "! ordered, then drops the first skip rows (OFFSET combined with a
    "! dynamic ORDER BY is rejected by the strict parser on this release).
    "! Returns the data table (REF) and the structure actually used.
  methods READ
    importing
      !IV_TABLE type TABNAME
      !IV_MAX type I
      !IV_SKIP type I default 0
      !IV_LAST type ABAP_BOOL default ABAP_FALSE
      !IT_WHERE type TT_WHERE
      !IT_FIELDS type TT_FIELD
    exporting
      !ER_DATA type ref to DATA
      !ER_STRUCT type ref to CL_ABAP_STRUCTDESCR
    raising
      CX_SY_DYNAMIC_OSQL_ERROR
      CX_SY_CREATE_DATA_ERROR .
    "! Stream a LOCAL table in packages via an open cursor, so memory stays
    "! bounded regardless of table size (for big-table / full scans). The
    "! sink receives each package and accumulates hits; it may stop the
    "! sweep early. Rows are read in PRIMARY KEY order. This is the local
    "! path only - the RFC read path is unchanged.
    "! @parameter iv_table    | table to read
    "! @parameter it_where     | free WHERE fragments
    "! @parameter it_fields    | fields to project (empty = all columns)
    "! @parameter ii_sink      | package sink (handle_package per block)
    "! @parameter iv_pkg_size  | rows per package (PACKAGE SIZE)
    "! @parameter er_struct    | the (projected) structure actually used
  methods READ_IN_PACKAGES
    importing
      !IV_TABLE    type TABNAME
      !IT_WHERE    type TT_WHERE
      !IT_FIELDS   type TT_FIELD
      !II_SINK     type ref to /CTDI/IF_SCAN_SINK
      !IV_PKG_SIZE type I default 50000
    exporting
      !ER_STRUCT   type ref to CL_ABAP_STRUCTDESCR
    raising
      CX_SY_DYNAMIC_OSQL_ERROR
      CX_SY_CREATE_DATA_ERROR .
    "! Read ONE ordered chunk of up to iv_max rows, starting STRICTLY AFTER
    "! the given key tuple (is_after; empty = from the top). Rows come back
    "! ordered by the non-client key fields (it_keyflds) so chunks can be
    "! chained across parallel waves with no gap / overlap. Also returns the
    "! last row's key tuple (et_last_key) to seed the next chunk, and the row
    "! count. The caller combines its own WHERE (it_where) with the resume
    "! condition. This is the bounded, resumable read used by the parallel
    "! batch driver; it opens and closes its cursor within the call (no open
    "! cursor is held across the later parallel RUN).
    "! @parameter iv_table    | table to read
    "! @parameter it_where     | caller WHERE fragments (ANDed with resume)
    "! @parameter it_fields    | fields to project (empty = all columns)
    "! @parameter it_keyflds   | non-client key fields, in order (resume key)
    "! @parameter is_after     | last key tuple already read (empty = start)
    "! @parameter iv_max       | max rows to read in this chunk
    "! @parameter er_data      | REF to the chunk data table
    "! @parameter er_struct    | the (projected) structure used
    "! @parameter et_last_key  | key tuple of the LAST row read (next seed)
    "! @parameter ev_count     | number of rows actually read
  methods READ_CHUNK
    importing
      !IV_TABLE    type TABNAME
      !IT_WHERE    type TT_WHERE
      !IT_FIELDS   type TT_FIELD
      !IT_KEYFLDS  type TT_FIELD
      !IS_AFTER    type TT_KEYVAL
      !IV_MAX      type I
      !IS_UNTIL    type TT_KEYVAL optional   " inclusive upper key bound (slice end)
    exporting
      !ER_DATA     type ref to DATA
      !ER_STRUCT   type ref to CL_ABAP_STRUCTDESCR
      !ET_LAST_KEY type TT_KEYVAL
      !EV_COUNT    type I
    raising
      CX_SY_DYNAMIC_OSQL_ERROR
      CX_SY_CREATE_DATA_ERROR .
    "! The non-client primary key fields of a table, in key order. These are
    "! the resume / slice key for parallel processing (client is excluded as
    "! it is always the current client).
    "! @parameter iv_table    | table
    "! @parameter rt_keyflds  | non-client key field names, in position order
  methods GET_KEY_FIELDS
    importing
      !IV_TABLE   type TABNAME
    returning
      value(RT_KEYFLDS) type TT_FIELD .
    "! Cheap keys-only probe that partitions a table into balanced slices of
    "! iv_slice_size rows each. Reads ONLY the key fields in PRIMARY KEY order
    "! (BYPASSING BUFFER) and records each package boundary as a slice with
    "! its after_key (resume strictly after) and end_key (inclusive). The
    "! resulting slice map lets workers read+scan their own key range in
    "! parallel - the heavy row reads are NOT done here. Far cheaper than a
    "! full read (keys only). The caller's it_where is honoured.
    "! @parameter iv_table      | table to probe
    "! @parameter it_where       | caller WHERE fragments
    "! @parameter iv_slice_size  | rows per slice
    "! @parameter rt_slices      | the slice map (ordered, non-overlapping)
  methods PROBE_SLICES
    importing
      !IV_TABLE      type TABNAME
      !IT_WHERE      type TT_WHERE
      !IV_SLICE_SIZE type I default 50000
    returning
      value(RT_SLICES) type TT_SLICE
    raising
      CX_SY_DYNAMIC_OSQL_ERROR
      CX_SY_CREATE_DATA_ERROR .
    "! Resolve the character fields (CHAR / STRING) of a structure to
    "! scan, in position order, from the 1-based iv_start_col onward.
    "! iv_skip_check = X skips fields with a check table / foreign key.
    "! iv_table supplies the DDIC metadata for the check-table test.
  methods SCAN_FIELDS
    importing
      !IR_STRUCT type ref to CL_ABAP_STRUCTDESCR
      !IV_TABLE type TABNAME
      !IV_START_COL type I default 1
      !IV_SKIP_CHECK type ABAP_BOOL default ABAP_FALSE
    returning
      value(RT_FIELDS) type TT_FIELD .
    "! Read the given fields of a REMOTE table (RFC_READ_TABLE) and return
    "! control-character hits directly. iv_skip / iv_max map to ROWSKIPS /
    "! ROWCOUNT. Self-guards against the 512-byte row limit.
  methods READ_REMOTE
    importing
      !IV_DEST type RFCDEST
      !IV_TABLE type TABNAME
      !IT_FIELDS type TT_FIELD
      !IT_KEYS type TT_FIELD optional
      !IT_WHERE type TT_WHERE
      !IV_SKIP type I default 0
      !IV_MAX type I default 1000
    returning
      value(RT_HITS) type /CTDI/CL_CNTRL_SCANNER=>TT_HIT
    raising
      CX_SY_DYN_CALL_ILLEGAL_FUNC .
    "! Combined byte width of the given fields when concatenated by
    "! RFC_READ_TABLE (DDIC length + 1 delimiter each). Compare against
    "! c_rfc_line_limit before a remote read to fail fast with a clear
    "! message instead of hitting DATA_BUFFER_EXCEEDED.
  methods REMOTE_WIDTH
    importing
      !IR_STRUCT type ref to CL_ABAP_STRUCTDESCR
      !IT_FIELDS type TT_FIELD
    returning
      value(RV_WIDTH) type I .
    "! Build a dynamic WHERE fragment that selects rows STRICTLY AFTER the
    "! given key tuple, in key order - the lexicographic greater-than
    "! tuple expansion used to resume a keyed read between parallel waves.
    "! Term per component: (k1 EQ v1 AND ... AND ki GT vi), all ORed.
    "! Values are rendered as quoted character literals with embedded quotes
    "! escaped. An EMPTY tuple yields an empty fragment (start from the top).
    "! This is correctness-critical: the strict greater-than on the last
    "! component plus equality on the preceding ones guarantees every row is read exactly
    "! once across waves (no gap, no overlap), independent of distribution.
    "! @parameter it_after  | the last key tuple already processed (in order)
    "! @parameter rv_where  | WHERE fragment (without the leading AND), or empty
  methods BUILD_RESUME_WHERE
    importing
      !IT_AFTER      type TT_KEYVAL
    returning
      value(RV_WHERE) type STRING .
    "! Build a WHERE fragment that selects rows up to and INCLUDING the given
    "! key tuple (the lexicographic less-than-or-equal expansion). Used as the
    "! upper bound of a slice. Empty tuple yields an empty fragment.
  methods BUILD_UNTIL_WHERE
    importing
      !IT_UNTIL      type TT_KEYVAL
    returning
      value(RV_WHERE) type STRING .
    "! Build the projected structure and the SELECT column clause for a
    "! table + optional field list. With a field list, selects the key
    "! fields plus the requested fields; otherwise '*' / full structure.
    "! Public so the parallel worker can rebuild the exact row type the
    "! driver read with, to deserialize a shipped package.
  methods BUILD_PROJECTION
    importing
      !IV_TABLE  type TABNAME
      !IT_FIELDS type TT_FIELD
    exporting
      !EV_COLS   type STRING
      !ER_STRUCT type ref to CL_ABAP_STRUCTDESCR .
  PROTECTED SECTION.

  PRIVATE SECTION.
    " Display-authorization check for a table (S_TABU_DIS / S_TABU_NAM via
    " VIEW_AUTHORITY_CHECK). Raises cx_sy_authorization_error when the user
    " is not allowed to read the table. Called before every LOCAL read so
    " the row count cannot be used as an answer channel against tables the
    " user may not see. (The RFC path is covered by RFC_READ_TABLE itself.)
    methods CHECK_AUTHORITY
      importing !IV_TABLE type TABNAME .

    " Render a value as a quoted Open SQL char literal (doubling quotes).
    methods QUOTE_LITERAL
      importing !IV_VALUE     type STRING
      returning value(RV_LIT) type STRING .

ENDCLASS.



CLASS /CTDI/CL_TABLE_READER IMPLEMENTATION.


  METHOD build_projection.
    /ctdi/cl_table_metadata=>build_projection(
      EXPORTING iv_table  = iv_table
                it_fields = it_fields
      IMPORTING ev_cols   = ev_cols
                er_struct = er_struct ).
  ENDMETHOD.


  METHOD build_resume_where.
    rv_where = /ctdi/cl_key_partitioner=>build_resume_where( it_after ).
  ENDMETHOD.


  METHOD build_until_where.
    rv_where = /ctdi/cl_key_partitioner=>build_until_where( it_until ).
  ENDMETHOD.


  METHOD check_authority.
    /ctdi/cl_table_metadata=>check_authority( iv_table ).
  ENDMETHOD.


  METHOD get_key_fields.
    rt_keyflds = /ctdi/cl_table_metadata=>get_key_fields( iv_table ).
  ENDMETHOD.


  METHOD probe_slices.
    rt_slices = /ctdi/cl_key_partitioner=>probe_slices(
      iv_table      = iv_table
      it_where      = it_where
      iv_slice_size = iv_slice_size ).
  ENDMETHOD.


  METHOD quote_literal.
    rv_lit = /ctdi/cl_key_partitioner=>quote_literal( iv_value ).
  ENDMETHOD.


  METHOD read.
    check_authority( iv_table ).

    DATA(lt_ddic) = CAST cl_abap_structdescr(
                      cl_abap_typedescr=>describe_by_name( iv_table ) )->get_ddic_field_list( ).

    build_projection( EXPORTING iv_table  = iv_table
                                it_fields = it_fields
                      IMPORTING ev_cols   = DATA(lv_cols)
                                er_struct = er_struct ).

    " Dynamic internal table matching the (projected) structure
    DATA(lr_tab) = cl_abap_tabledescr=>create( er_struct ).
    CREATE DATA er_data TYPE HANDLE lr_tab.
    FIELD-SYMBOLS <lt_data> TYPE STANDARD TABLE.
    ASSIGN er_data->* TO <lt_data>.

    " ORDER BY as ONE comma-separated clause (a multi-row token table
    " trips the strict parser on multi-key tables).
    "   iv_last = X -> key DESCENDING ; iv_skip > 0 -> key ASCENDING
    DATA: lv_order TYPE string,
          lv_dir   TYPE string.
    IF iv_last = abap_true.
      lv_dir = 'DESCENDING'.
    ELSEIF iv_skip > 0.
      lv_dir = 'ASCENDING'.
    ENDIF.
    IF lv_dir IS NOT INITIAL.
      LOOP AT lt_ddic ASSIGNING FIELD-SYMBOL(<ls_o>) WHERE keyflag = abap_true.
        IF lv_order IS INITIAL.
          lv_order = |{ <ls_o>-fieldname } { lv_dir }|.
        ELSE.
          lv_order = |{ lv_order }, { <ls_o>-fieldname } { lv_dir }|.
        ENDIF.
      ENDLOOP.
    ENDIF.

    DATA(lv_skip) = COND i( WHEN iv_skip > 0 THEN iv_skip ELSE 0 ).

    " For an offset block, read (skip + max) rows ordered, then drop the
    " first skip rows in ABAP (dynamic ORDER BY + OFFSET is rejected by
    " the strict SQL parser on this release).
    DATA(lv_fetch) = COND i( WHEN lv_skip > 0 THEN lv_skip + iv_max
                                              ELSE iv_max ).

    IF lv_order IS INITIAL.
      SELECT (lv_cols) FROM (iv_table)
        INTO CORRESPONDING FIELDS OF TABLE @<lt_data>
        UP TO @iv_max ROWS
        WHERE (it_where).
    ELSE.
      SELECT (lv_cols) FROM (iv_table)
        INTO CORRESPONDING FIELDS OF TABLE @<lt_data>
        UP TO @lv_fetch ROWS
        WHERE (it_where)
        ORDER BY (lv_order).
      IF lv_skip > 0.
        DELETE <lt_data> FROM 1 TO lv_skip.
      ENDIF.
    ENDIF.
  ENDMETHOD.


  METHOD read_chunk.
    check_authority( iv_table ).

    build_projection( EXPORTING iv_table  = iv_table
                                it_fields = it_fields
                      IMPORTING ev_cols   = DATA(lv_cols)
                                er_struct = er_struct ).

    DATA(lr_tab) = cl_abap_tabledescr=>create( er_struct ).
    CREATE DATA er_data TYPE HANDLE lr_tab.
    FIELD-SYMBOLS <lt_data> TYPE STANDARD TABLE.
    ASSIGN er_data->* TO <lt_data>.

    " Combine the caller's WHERE with the resume (rows strictly after
    " is_after) and the optional upper bound (rows up to and including
    " is_until - the slice end). Dynamic WHERE lines are concatenated with a
    " blank, so each extra condition carries an explicit leading AND when it
    " follows an existing condition (otherwise two "(...)" collide and the
    " strict parser rejects them).
    DATA(lt_where) = it_where.
    DATA(lv_resume) = build_resume_where( is_after ).
    IF lv_resume IS NOT INITIAL.
      APPEND COND string( WHEN lt_where IS INITIAL THEN lv_resume
                          ELSE |AND { lv_resume }| ) TO lt_where.
    ENDIF.
    DATA(lv_until) = build_until_where( is_until ).
    IF lv_until IS NOT INITIAL.
      APPEND COND string( WHEN lt_where IS INITIAL THEN lv_until
                          ELSE |AND { lv_until }| ) TO lt_where.
    ENDIF.

    " ORDER BY the non-client key fields, in order, as one clause - this is
    " the ordering the resume predicate relies on. (Not PRIMARY KEY, because
    " the client field is excluded from the resume key.)
    DATA lv_order TYPE string.
    LOOP AT it_keyflds ASSIGNING FIELD-SYMBOL(<kf>).
      lv_order = COND #( WHEN lv_order IS INITIAL THEN |{ <kf> } ASCENDING|
                         ELSE |{ lv_order }, { <kf> } ASCENDING| ).
    ENDLOOP.

    IF lv_order IS INITIAL.
      " No key fields given - fall back to primary-key order.
      SELECT (lv_cols) FROM (iv_table) "#EC CI_SEL_NESTED
        INTO CORRESPONDING FIELDS OF TABLE @<lt_data>
        UP TO @iv_max ROWS
        WHERE (lt_where)
        ORDER BY PRIMARY KEY.
    ELSE.
      SELECT (lv_cols) FROM (iv_table) "#EC CI_SEL_NESTED
        INTO CORRESPONDING FIELDS OF TABLE @<lt_data>
        UP TO @iv_max ROWS
        WHERE (lt_where)
        ORDER BY (lv_order).
    ENDIF.

    ev_count = lines( <lt_data> ).

    " Extract the last row's key tuple to seed the next chunk.
    CLEAR et_last_key.
    IF ev_count > 0.
      FIELD-SYMBOLS <last> TYPE any.
      READ TABLE <lt_data> ASSIGNING <last> INDEX ev_count.
      DATA lv_key_str TYPE string.
      LOOP AT it_keyflds ASSIGNING FIELD-SYMBOL(<kf2>).
        ASSIGN COMPONENT <kf2> OF STRUCTURE <last> TO FIELD-SYMBOL(<kv>).
        IF sy-subrc = 0.
          lv_key_str = <kv>.
          APPEND VALUE #( field = <kf2> value = lv_key_str ) TO et_last_key.
        ENDIF.
      ENDLOOP.
    ENDIF.
  ENDMETHOD.


  METHOD read_in_packages.
    check_authority( iv_table ).

    build_projection( EXPORTING iv_table  = iv_table
                                it_fields = it_fields
                      IMPORTING ev_cols   = DATA(lv_cols)
                                er_struct = er_struct ).

    " One reusable package table matching the (projected) structure.
    DATA(lr_tab) = cl_abap_tabledescr=>create( er_struct ).
    DATA lr_pkg TYPE REF TO data.
    CREATE DATA lr_pkg TYPE HANDLE lr_tab.
    FIELD-SYMBOLS <lt_pkg> TYPE STANDARD TABLE.
    ASSIGN lr_pkg->* TO <lt_pkg>.

    " Open-cursor package sweep in PRIMARY KEY order: memory stays bounded
    " to one package; deep offsets are NOT re-read (unlike the block read).
    DATA lv_base TYPE i.
    SELECT (lv_cols) FROM (iv_table)
      INTO CORRESPONDING FIELDS OF TABLE @<lt_pkg> PACKAGE SIZE @iv_pkg_size
      WHERE (it_where)
      ORDER BY PRIMARY KEY.

      DATA(lv_continue) = ii_sink->handle_package( ir_data     = lr_pkg
                                                   iv_base_row = lv_base ).
      lv_base = lv_base + lines( <lt_pkg> ).

      IF lv_continue = abap_false.
        " Sink asked to stop (e.g. hit ceiling reached) - close the cursor.
        EXIT.
      ENDIF.
    ENDSELECT.
  ENDMETHOD.


  METHOD read_remote.
    DATA: lt_options TYPE TABLE OF rfc_db_opt,
          lt_fields  TYPE TABLE OF rfc_db_fld,
          lt_data    TYPE TABLE OF tab512.   " generic RFC_READ_TABLE output

    LOOP AT it_where ASSIGNING FIELD-SYMBOL(<w>).
      APPEND VALUE #( text = <w> ) TO lt_options.
    ENDLOOP.

    " requested fields (names only; the FM fills offset/length/type).
    " RFC_READ_TABLE concatenates them into a 512-byte line - scanning
    " only the text fields keeps us inside that.
    LOOP AT it_fields ASSIGNING FIELD-SYMBOL(<f>).
      APPEND VALUE #( fieldname = <f> ) TO lt_fields.
    ENDLOOP.

    CALL FUNCTION 'RFC_READ_TABLE'
      DESTINATION iv_dest
      EXPORTING
        query_table          = iv_table
        rowskips             = iv_skip
        rowcount             = iv_max
      TABLES
        options              = lt_options
        fields               = lt_fields
        data                 = lt_data
      EXCEPTIONS
        table_not_available  = 1
        table_without_data   = 2
        option_not_valid     = 3
        field_not_valid      = 4
        not_authorized       = 5
        data_buffer_exceeded = 6
        OTHERS               = 7.
    IF sy-subrc <> 0.
      RAISE EXCEPTION TYPE cx_sy_dyn_call_illegal_func.
    ENDIF.

    " Parse each line into field/value pairs using the offset/length the
    " FM reported in FIELDS, and scan them.
    LOOP AT lt_data ASSIGNING FIELD-SYMBOL(<row>).
      DATA(lv_row)  = sy-tabix.
      DATA(lv_line) = CONV string( <row>-wa ).
      DATA lt_pairs TYPE /ctdi/cl_cntrl_scanner=>tt_pair.
      CLEAR lt_pairs.
      LOOP AT lt_fields ASSIGNING FIELD-SYMBOL(<fld>). "#EC CI_NESTED
        DATA(lv_off) = <fld>-offset.
        DATA(lv_len) = <fld>-length.
        IF lv_off + lv_len <= strlen( lv_line ).
          APPEND VALUE #( field = <fld>-fieldname
                          value = lv_line+lv_off(lv_len) ) TO lt_pairs.
        ENDIF.
      ENDLOOP.
      " key info for this row: "NAME=value" of the key fields among pairs
      DATA lv_keyinfo TYPE string.
      CLEAR lv_keyinfo.
      LOOP AT it_keys ASSIGNING FIELD-SYMBOL(<key>). "#EC CI_NESTED
        READ TABLE lt_pairs ASSIGNING FIELD-SYMBOL(<kp>) WITH KEY field = <key>. "#EC CI_STDSEQ
        IF sy-subrc = 0.
          DATA(lv_kv) = condense( <kp>-value ).
          lv_keyinfo = COND #( WHEN lv_keyinfo IS INITIAL
                               THEN |{ <key> }={ lv_kv }|
                               ELSE |{ lv_keyinfo } { <key> }={ lv_kv }| ).
        ENDIF.
      ENDLOOP.
      APPEND LINES OF /ctdi/cl_cntrl_scanner=>scan_pairs( it_pairs   = lt_pairs
                                                          iv_row     = lv_row
                                                          iv_keyinfo = lv_keyinfo )
             TO rt_hits.
    ENDLOOP.
  ENDMETHOD.


  METHOD remote_width.
    rv_width = /ctdi/cl_table_metadata=>remote_width(
      ir_struct = ir_struct
      it_fields = it_fields ).
  ENDMETHOD.


  METHOD scan_fields.
    rt_fields = /ctdi/cl_table_metadata=>scan_fields(
      ir_struct     = ir_struct
      iv_table      = iv_table
      iv_start_col  = iv_start_col
      iv_skip_check = iv_skip_check ).
  ENDMETHOD.
ENDCLASS.
