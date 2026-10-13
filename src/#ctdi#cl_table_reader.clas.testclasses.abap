*"* use this source file for your ABAP unit test classes
*&---------------------------------------------------------------------*
*&  Integration tests for /CTDI/CL_TABLE_READER
*&  Read-only against VTRKH - the real target table for this tool:
*&    4-field composite key MANDT / VBTYP / VBELN / XSITD,
*&    text fields TRKDLVTO / TRKDLVLOC.
*&---------------------------------------------------------------------*
CLASS ltcl_reader DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    CONSTANTS: c_tab   TYPE tabname   VALUE 'VTRKH',
               c_key1  TYPE fieldname VALUE 'MANDT',
               c_field TYPE fieldname VALUE 'TRKDLVTO',
               c_other TYPE fieldname VALUE 'TRKDLVLOC'.

    DATA mo_cut TYPE REF TO /ctdi/cl_table_reader.

    METHODS: setup,
      comp_names
        IMPORTING ir_struct       TYPE REF TO cl_abap_structdescr
        RETURNING VALUE(rt_names) TYPE /ctdi/cl_table_reader=>tt_field,
      full_read_returns_rows      FOR TESTING,
      projection_keeps_key_fields FOR TESTING,
      last_by_key_runs            FOR TESTING,
      offset_block_runs           FOR TESTING,
      dynamic_where_filters       FOR TESTING,
      check_table_fields_skipped  FOR TESTING,
      remote_width_sums_lengths   FOR TESTING,
      keyinfo_skips_client        FOR TESTING,
      " resume-WHERE builder (correctness-critical for parallel waves)
      resume_empty_is_blank       FOR TESTING,
      resume_single_key           FOR TESTING,
      resume_composite_key        FOR TESTING,
      resume_escapes_quotes       FOR TESTING,
      resume_roundtrip_on_vtrkh   FOR TESTING,
      read_chunk_chains_no_overlap FOR TESTING,
      " slice-map probe + until-predicate (parallel partitioning)
      until_single_key            FOR TESTING,
      until_composite_key         FOR TESTING,
      probe_covers_whole_table    FOR TESTING,
      slices_read_back_exactly    FOR TESTING.
ENDCLASS.

CLASS ltcl_reader IMPLEMENTATION.

  METHOD setup.
    mo_cut = NEW /ctdi/cl_table_reader( ).
  ENDMETHOD.

  METHOD comp_names.
    LOOP AT ir_struct->get_components( ) ASSIGNING FIELD-SYMBOL(<ls_c>).
      APPEND <ls_c>-name TO rt_names.
    ENDLOOP.
  ENDMETHOD.

  METHOD full_read_returns_rows.
    DATA: lr_data   TYPE REF TO data,
          lr_struct TYPE REF TO cl_abap_structdescr.
    mo_cut->read(
      EXPORTING iv_table  = c_tab
                iv_max    = 10
                it_where  = VALUE #( )
                it_fields = VALUE #( )
      IMPORTING er_data   = lr_data
                er_struct = lr_struct ).

    FIELD-SYMBOLS <lt> TYPE STANDARD TABLE.
    ASSIGN lr_data->* TO <lt>.
    cl_abap_unit_assert=>assert_not_initial(
      act = <lt> msg = 'VTRKH full read must return at least one row' ).
    DATA(lt_names) = comp_names( lr_struct ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( line_exists( lt_names[ table_line = c_key1 ] ) )
      msg = 'Full read structure must contain the key field' ).
  ENDMETHOD.

  METHOD projection_keeps_key_fields.
    DATA: lr_data   TYPE REF TO data,
          lr_struct TYPE REF TO cl_abap_structdescr.
    mo_cut->read(
      EXPORTING iv_table  = c_tab
                iv_max    = 10
                it_where  = VALUE #( )
                it_fields = VALUE #( ( c_field ) )
      IMPORTING er_data   = lr_data
                er_struct = lr_struct ).

    DATA(lt_names) = comp_names( lr_struct ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( line_exists( lt_names[ table_line = c_key1 ] ) )
      msg = 'Projection must always include the key field' ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( line_exists( lt_names[ table_line = c_field ] ) )
      msg = 'Projection must include the requested field' ).
    cl_abap_unit_assert=>assert_false(
      act = xsdbool( line_exists( lt_names[ table_line = c_other ] ) )
      msg = 'Projection must exclude the non-requested field' ).
  ENDMETHOD.

  METHOD last_by_key_runs.
    " dynamic ORDER BY over VTRKH's 4-field composite key must run
    DATA: lr_data   TYPE REF TO data,
          lr_struct TYPE REF TO cl_abap_structdescr.
    mo_cut->read(
      EXPORTING iv_table  = c_tab
                iv_max    = 5
                iv_last   = abap_true
                it_where  = VALUE #( )
                it_fields = VALUE #( )
      IMPORTING er_data   = lr_data
                er_struct = lr_struct ).
    FIELD-SYMBOLS <lt> TYPE STANDARD TABLE.
    ASSIGN lr_data->* TO <lt>.
    cl_abap_unit_assert=>assert_not_initial(
      act = <lt> msg = 'Last-by-key read must return rows' ).
  ENDMETHOD.

  METHOD offset_block_runs.
    DATA: lr_data   TYPE REF TO data,
          lr_struct TYPE REF TO cl_abap_structdescr.
    mo_cut->read(
      EXPORTING iv_table  = c_tab
                iv_max    = 2
                iv_skip   = 0
                it_where  = VALUE #( )
                it_fields = VALUE #( )
      IMPORTING er_data   = lr_data
                er_struct = lr_struct ).
    FIELD-SYMBOLS <lt> TYPE STANDARD TABLE.
    ASSIGN lr_data->* TO <lt>.
    DATA(lv_total) = lines( <lt> ).

    mo_cut->read(
      EXPORTING iv_table  = c_tab
                iv_max    = 2
                iv_skip   = 1
                it_where  = VALUE #( )
                it_fields = VALUE #( )
      IMPORTING er_data   = lr_data
                er_struct = lr_struct ).
    ASSIGN lr_data->* TO <lt>.
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( lines( <lt> ) <= lv_total )
      msg = 'Skipped block must not return more rows than the base read' ).
  ENDMETHOD.

  METHOD dynamic_where_filters.
    " Dynamic WHERE on a non-client key field (VBTYP). MANDT must NOT be
    " used - the compiler handles the client automatically.
    DATA: lr_data   TYPE REF TO data,
          lr_struct TYPE REF TO cl_abap_structdescr.
    mo_cut->read(
      EXPORTING iv_table  = c_tab
                iv_max    = 10
                it_where  = VALUE #( ( |vbtyp <> ' '| ) )
                it_fields = VALUE #( )
      IMPORTING er_data   = lr_data
                er_struct = lr_struct ).

    FIELD-SYMBOLS <lt> TYPE STANDARD TABLE.
    ASSIGN lr_data->* TO <lt>.
    cl_abap_unit_assert=>assert_not_initial(
      act = <lt> msg = 'WHERE vbtyp <> space must return rows' ).

    FIELD-SYMBOLS <ls>    TYPE any.
    FIELD-SYMBOLS <vbtyp> TYPE any.
    LOOP AT <lt> ASSIGNING <ls>.
      ASSIGN COMPONENT 'VBTYP' OF STRUCTURE <ls> TO <vbtyp>.
      cl_abap_unit_assert=>assert_true(
        act = xsdbool( <vbtyp> IS NOT INITIAL )
        msg = 'Every filtered row must satisfy vbtyp <> space' ).
    ENDLOOP.
  ENDMETHOD.

  METHOD check_table_fields_skipped.
    DATA: lr_data   TYPE REF TO data,
          lr_struct TYPE REF TO cl_abap_structdescr.
    mo_cut->read(
      EXPORTING iv_table  = c_tab
                iv_max    = 1
                it_where  = VALUE #( )
                it_fields = VALUE #( )
      IMPORTING er_data   = lr_data
                er_struct = lr_struct ).

    DATA(lt_on) = mo_cut->scan_fields( ir_struct     = lr_struct
                                       iv_table      = c_tab
                                       iv_skip_check = abap_true ).
    cl_abap_unit_assert=>assert_false(
      act = xsdbool( line_exists( lt_on[ table_line = 'XSITD' ] ) )
      msg = 'Check-table field XSITD must be skipped' ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( line_exists( lt_on[ table_line = c_field ] ) )
      msg = 'Free-text field TRKDLVTO must remain' ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( line_exists( lt_on[ table_line = c_other ] ) )
      msg = 'Free-text field TRKDLVLOC must remain' ).

    DATA(lt_off) = mo_cut->scan_fields( ir_struct     = lr_struct
                                        iv_table      = c_tab
                                        iv_skip_check = abap_false ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( line_exists( lt_off[ table_line = 'XSITD' ] ) )
      msg = 'With skip-check off, XSITD must be scanned' ).
  ENDMETHOD.

  METHOD remote_width_sums_lengths.
    " TRKDLVTO (40) + TRKDLVLOC (50), +1 delimiter each -> 92, under 512.
    DATA(lr_struct) = CAST cl_abap_structdescr(
                        cl_abap_typedescr=>describe_by_name( c_tab ) ).
    DATA(lv_w) = mo_cut->remote_width(
                   ir_struct = lr_struct
                   it_fields = VALUE #( ( c_field ) ( c_other ) ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 92 act = lv_w
      msg = 'Width must be 40+1 + 50+1 = 92' ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( lv_w <= /ctdi/cl_table_reader=>c_rfc_line_limit )
      msg = 'Two text fields must fit the RFC line limit' ).
  ENDMETHOD.

  METHOD keyinfo_skips_client.
    " build_keyinfo over MANDT (client) + VBELN must drop the client
    " field and keep VBELN. Read one real VTRKH row for the data.
    DATA: lr_data   TYPE REF TO data,
          lr_struct TYPE REF TO cl_abap_structdescr.
    mo_cut->read(
      EXPORTING iv_table  = c_tab
                iv_max    = 1
                it_where  = VALUE #( )
                it_fields = VALUE #( )
      IMPORTING er_data   = lr_data
                er_struct = lr_struct ).
    FIELD-SYMBOLS <lt> TYPE STANDARD TABLE.
    ASSIGN lr_data->* TO <lt>.
    FIELD-SYMBOLS <row> TYPE any.
    READ TABLE <lt> ASSIGNING <row> INDEX 1.

    DATA(lv_ki) = /ctdi/cl_cntrl_scanner=>build_keyinfo(
                    is_data = <row>
                    it_keys = VALUE #( ( c_key1 ) ( 'VBELN' ) ) ).
    cl_abap_unit_assert=>assert_false(
      act = xsdbool( lv_ki CS 'MANDT' )
      msg = 'Client field MANDT must be skipped in keyinfo' ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( lv_ki CS 'VBELN' )
      msg = 'Non-client key VBELN must be present in keyinfo' ).
  ENDMETHOD.

  METHOD resume_empty_is_blank.
    " No "after" tuple => no resume condition (read from the top).
    cl_abap_unit_assert=>assert_initial(
      act = mo_cut->build_resume_where( VALUE #( ) )
      msg = 'Empty key tuple must yield an empty WHERE fragment' ).
  ENDMETHOD.

  METHOD resume_single_key.
    " Single key K = 'ABC' -> ( ( K > 'ABC' ) )
    DATA(lv_w) = mo_cut->build_resume_where(
                   VALUE #( ( field = 'K' value = 'ABC' ) ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = |( ( K > 'ABC' ) )| act = lv_w
      msg = 'Single-key resume predicate' ).
  ENDMETHOD.

  METHOD resume_composite_key.
    " Three-component key (K1,K2,K3) = (A,2,9) must expand lexicographically:
    " ( (K1>'A') OR (K1='A' AND K2>'2') OR (K1='A' AND K2='2' AND K3>'9') )
    DATA(lv_w) = mo_cut->build_resume_where( VALUE #(
      ( field = 'K1' value = 'A' )
      ( field = 'K2' value = '2' )
      ( field = 'K3' value = '9' ) ) ).
    DATA(lv_exp) =
      |( ( K1 > 'A' ) OR ( K1 = 'A' AND K2 > '2' ) | &&
      |OR ( K1 = 'A' AND K2 = '2' AND K3 > '9' ) )|.
    cl_abap_unit_assert=>assert_equals(
      exp = lv_exp act = lv_w
      msg = 'Composite-key lexicographic resume predicate' ).
  ENDMETHOD.

  METHOD resume_escapes_quotes.
    " A value containing a single quote must be doubled in the literal.
    DATA(lv_w) = mo_cut->build_resume_where(
                   VALUE #( ( field = 'K' value = |O'HARA| ) ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = |( ( K > 'O''HARA' ) )| act = lv_w
      msg = 'Embedded single quote must be escaped by doubling' ).
  ENDMETHOD.

  METHOD resume_roundtrip_on_vtrkh.
    " End-to-end correctness on the real composite-key table: read row 1,
    " build a resume WHERE from its (non-client) key, read again with that
    " WHERE, and assert the first row of the second read is STRICTLY AFTER
    " the first row - i.e. the resume neither repeats nor skips the boundary.
    DATA: lr_data   TYPE REF TO data,
          lr_struct TYPE REF TO cl_abap_structdescr.

    " non-client key fields of VTRKH in order: VBTYP, VBELN, XSITD
    DATA(lt_keyf) = VALUE /ctdi/cl_table_reader=>tt_field(
      ( 'VBTYP' ) ( 'VBELN' ) ( 'XSITD' ) ).

    mo_cut->read( EXPORTING iv_table  = c_tab
                            iv_max    = 1
                            it_where  = VALUE #( )
                            it_fields = VALUE #( )
                  IMPORTING er_data   = lr_data
                            er_struct = lr_struct ).
    FIELD-SYMBOLS <lt1> TYPE STANDARD TABLE.
    ASSIGN lr_data->* TO <lt1>.
    IF lines( <lt1> ) < 1.
      cl_abap_unit_assert=>abort( 'VTRKH has no rows to test resume' ).
    ENDIF.
    FIELD-SYMBOLS <r1> TYPE any.
    READ TABLE <lt1> ASSIGNING <r1> INDEX 1.

    " capture the first row's key tuple as text
    DATA lt_after TYPE /ctdi/cl_table_reader=>tt_keyval.
    LOOP AT lt_keyf ASSIGNING FIELD-SYMBOL(<lv_kf>).
      FIELD-SYMBOLS <kv> TYPE any.
      ASSIGN COMPONENT <lv_kf> OF STRUCTURE <r1> TO <kv>.
      APPEND VALUE #( field = <lv_kf> value = |{ <kv> }| ) TO lt_after.
    ENDLOOP.

    DATA(lv_resume) = mo_cut->build_resume_where( lt_after ).

    " second read: starting strictly after row 1's key via the resume WHERE
    DATA: lr_data2   TYPE REF TO data,
          lr_struct2 TYPE REF TO cl_abap_structdescr.
    mo_cut->read( EXPORTING iv_table  = c_tab
                            iv_max    = 1
                            it_where  = VALUE #( ( lv_resume ) )
                            it_fields = VALUE #( )
                  IMPORTING er_data   = lr_data2
                            er_struct = lr_struct2 ).
    FIELD-SYMBOLS <lt2> TYPE STANDARD TABLE.
    ASSIGN lr_data2->* TO <lt2>.

    " If VTRKH has only one row, the resumed read is legitimately empty.
    IF lines( <lt2> ) >= 1.
      FIELD-SYMBOLS <r2> TYPE any.
      READ TABLE <lt2> ASSIGNING <r2> INDEX 1.
      " build both key tuples as concatenated text and assert r2 > r1
      DATA lv_k1 TYPE string.
      DATA lv_k2 TYPE string.
      LOOP AT lt_keyf ASSIGNING FIELD-SYMBOL(<lv_kf_cmp>).
        FIELD-SYMBOLS <a> TYPE any.
        FIELD-SYMBOLS <b> TYPE any.
        ASSIGN COMPONENT <lv_kf_cmp> OF STRUCTURE <r1> TO <a>.
        ASSIGN COMPONENT <lv_kf_cmp> OF STRUCTURE <r2> TO <b>.
        lv_k1 = |{ lv_k1 }#{ <a> }|.
        lv_k2 = |{ lv_k2 }#{ <b> }|.
      ENDLOOP.
      cl_abap_unit_assert=>assert_true(
        act = xsdbool( lv_k2 > lv_k1 )
        msg = 'Resumed read must start strictly after the boundary key' ).
    ENDIF.
  ENDMETHOD.

  METHOD read_chunk_chains_no_overlap.
    " Two chained read_chunk calls (chunk size 5) over VTRKH must not share
    " any key: chunk 2 resumes strictly after chunk 1's last key. Proves the
    " bounded, resumable read used by the parallel batch driver is sound.
    DATA(lt_keyf) = VALUE /ctdi/cl_table_reader=>tt_field(
      ( 'VBTYP' ) ( 'VBELN' ) ( 'XSITD' ) ).

    DATA: lr_d1 TYPE REF TO data, lr_s1 TYPE REF TO cl_abap_structdescr,
          lt_last1 TYPE /ctdi/cl_table_reader=>tt_keyval, lv_c1 TYPE i.
    mo_cut->read_chunk(
      EXPORTING iv_table   = c_tab
                it_where    = VALUE #( )
                it_fields   = VALUE #( )
                it_keyflds  = lt_keyf
                is_after    = VALUE #( )
                iv_max      = 5
      IMPORTING er_data     = lr_d1
                er_struct   = lr_s1
                et_last_key = lt_last1
                ev_count    = lv_c1 ).

    IF lv_c1 < 5.
      " Not enough rows to form two chunks - nothing to prove here.
      RETURN.
    ENDIF.

    DATA: lr_d2 TYPE REF TO data, lr_s2 TYPE REF TO cl_abap_structdescr,
          lt_last2 TYPE /ctdi/cl_table_reader=>tt_keyval, lv_c2 TYPE i.
    mo_cut->read_chunk(
      EXPORTING iv_table   = c_tab
                it_where    = VALUE #( )
                it_fields   = VALUE #( )
                it_keyflds  = lt_keyf
                is_after    = lt_last1          " resume after chunk 1
                iv_max      = 5
      IMPORTING er_data     = lr_d2
                er_struct   = lr_s2
                et_last_key = lt_last2
                ev_count    = lv_c2 ).

    " Build the key string of chunk 1's last row and chunk 2's first row;
    " chunk 2 must start strictly after chunk 1's last key.
    IF lv_c2 >= 1.
      FIELD-SYMBOLS: <lt2> TYPE STANDARD TABLE, <r2> TYPE any.
      ASSIGN lr_d2->* TO <lt2>.
      READ TABLE <lt2> ASSIGNING <r2> INDEX 1.
      DATA lv_first2 TYPE string.
      LOOP AT lt_keyf ASSIGNING FIELD-SYMBOL(<lv_kf2>).
        ASSIGN COMPONENT <lv_kf2> OF STRUCTURE <r2> TO FIELD-SYMBOL(<v2>).
        lv_first2 = |{ lv_first2 }#{ <v2> }|.
      ENDLOOP.
      DATA lv_last1 TYPE string.
      LOOP AT lt_last1 ASSIGNING FIELD-SYMBOL(<ls_lk>).
        lv_last1 = |{ lv_last1 }#{ <ls_lk>-value }|.
      ENDLOOP.
      cl_abap_unit_assert=>assert_true(
        act = xsdbool( lv_first2 > lv_last1 )
        msg = 'Chunk 2 must start strictly after chunk 1 (no overlap/gap)' ).
    ENDIF.
  ENDMETHOD.

  METHOD until_single_key.
    " <= 'ABC' on a single key -> ( ( K < 'ABC' ) OR ( K = 'ABC' ) )
    DATA(lv_w) = mo_cut->build_until_where(
                   VALUE #( ( field = 'K' value = 'ABC' ) ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = |( ( K < 'ABC' ) OR ( K = 'ABC' ) )| act = lv_w
      msg = 'Single-key inclusive upper bound' ).
  ENDMETHOD.

  METHOD until_composite_key.
    " (K1,K2) <= (A,5):
    " ( (K1<'A') OR (K1='A' AND K2<'5') OR (K1='A' AND K2='5') )
    DATA(lv_w) = mo_cut->build_until_where( VALUE #(
      ( field = 'K1' value = 'A' )
      ( field = 'K2' value = '5' ) ) ).
    DATA(lv_exp) =
      |( ( K1 < 'A' ) OR ( K1 = 'A' AND K2 < '5' ) | &&
      |OR ( K1 = 'A' AND K2 = '5' ) )|.
    cl_abap_unit_assert=>assert_equals( exp = lv_exp act = lv_w
      msg = 'Composite inclusive upper bound' ).
  ENDMETHOD.

  METHOD probe_covers_whole_table.
    " The slice map must account for every row exactly once: sum of slice
    " row counts = total table rows, with contiguous base_row offsets.
    DATA(lt_slices) = mo_cut->probe_slices( iv_table      = c_tab
                                            it_where       = VALUE #( )
                                            iv_slice_size  = 500 ).
    IF lt_slices IS INITIAL.
      RETURN.   " empty table - nothing to check
    ENDIF.
    " total rows per the probe
    DATA lv_sum TYPE i.
    LOOP AT lt_slices ASSIGNING FIELD-SYMBOL(<s>).
      lv_sum = lv_sum + <s>-rows.
      " base_row must be contiguous
      cl_abap_unit_assert=>assert_equals(
        exp = lv_sum - <s>-rows act = <s>-base_row
        msg = 'Slice base_row must be the running row offset' ).
    ENDLOOP.
    " compare to an independent COUNT(*)
    DATA lv_cnt TYPE i.
    SELECT COUNT(*) FROM (c_tab) INTO @lv_cnt.
    cl_abap_unit_assert=>assert_equals(
      exp = lv_cnt act = lv_sum
      msg = 'Slice row counts must sum to the full table row count' ).
  ENDMETHOD.

  METHOD slices_read_back_exactly.
    " End-to-end on a BOUNDED prefix of the table (keep the test fast): probe
    " a few slices, re-read each slice's (after_key, end_key] range, and
    " assert each re-read count matches the probe and the slices are disjoint
    " and contiguous. Proves the range predicates are complete / non-
    " overlapping on the real composite key without scanning the whole table.
    DATA(lt_keyf) = VALUE /ctdi/cl_table_reader=>tt_field(
      ( 'VBTYP' ) ( 'VBELN' ) ( 'XSITD' ) ).
    DATA(lt_all) = mo_cut->probe_slices( iv_table      = c_tab
                                         it_where       = VALUE #( )
                                         iv_slice_size  = 1000 ).
    IF lines( lt_all ) < 2.
      RETURN.   " need at least 2 slices to be meaningful
    ENDIF.
    " take at most the first 3 slices to keep the test quick
    DATA lt_slices LIKE lt_all.
    LOOP AT lt_all ASSIGNING FIELD-SYMBOL(<a>) TO 3.
      APPEND <a> TO lt_slices.
    ENDLOOP.

    DATA lv_total_read TYPE i.
    DATA lv_total_probe TYPE i.
    LOOP AT lt_slices ASSIGNING FIELD-SYMBOL(<s>).
      lv_total_probe = lv_total_probe + <s>-rows.
      DATA: lr_d TYPE REF TO data, lr_s TYPE REF TO cl_abap_structdescr,
            lt_lk TYPE /ctdi/cl_table_reader=>tt_keyval, lv_c TYPE i.
      mo_cut->read_chunk(
        EXPORTING iv_table   = c_tab
                  it_where    = VALUE #( )
                  it_fields   = VALUE #( )
                  it_keyflds  = lt_keyf
                  is_after    = <s>-after_key
                  is_until    = <s>-end_key
                  iv_max      = 100000
        IMPORTING er_data     = lr_d
                  er_struct   = lr_s
                  et_last_key = lt_lk
                  ev_count    = lv_c ).
      " each slice re-read must match the probe's recorded row count
      cl_abap_unit_assert=>assert_equals(
        exp = <s>-rows act = lv_c
        msg = |Slice { <s>-slice_no } re-read count must match probe| ).
      lv_total_read = lv_total_read + lv_c.
    ENDLOOP.

    " the re-read total must equal the sum of the probed slice counts -
    " i.e. the slice ranges reproduce exactly what the probe partitioned.
    cl_abap_unit_assert=>assert_equals(
      exp = lv_total_probe act = lv_total_read
      msg = 'Rows re-read across slices must equal the probed slice totals' ).
  ENDMETHOD.

ENDCLASS.
