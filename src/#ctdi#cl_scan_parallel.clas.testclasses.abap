*"* use this source file for your ABAP unit test classes
*&---------------------------------------------------------------------*
*&  Tests for the parallel worker's SERIALIZATION, which is the real risk:
*&  CL_ABAP_PARALLEL ships packages as XSTRING via CALL TRANSFORMATION id
*&  (XML). XML 1.0 cannot represent most C0 control characters (NUL etc.) -
*&  exactly what this tool scans for. These tests round-trip rows that
*&  contain control chars and assert the scan result is UNCHANGED by the
*&  serialization. If XML drops/mangles a control char, these fail - which
*&  is the signal to switch the row transport to a binary-safe form.
*&---------------------------------------------------------------------*
CLASS ltcl_parallel DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    TYPES: BEGIN OF ts_row,
             id    TYPE n LENGTH 4,
             name1 TYPE c LENGTH 40,
             text  TYPE string,
           END OF ts_row,
           tt_row TYPE STANDARD TABLE OF ts_row WITH EMPTY KEY.

    METHODS fields
      RETURNING VALUE(rt) TYPE /ctdi/cl_cntrl_scanner=>tt_field.
    METHODS: rows_roundtrip_keeps_hits FOR TESTING,
             nul_survives_transport    FOR TESTING,
             packet_binary_roundtrip   FOR TESTING,
             hits_binary_roundtrip_with_nul FOR TESTING,
             legacy_xml_hits_fallback  FOR TESTING,
             calc_width_non_zero       FOR TESTING,
             " adaptive sizing (pure, deterministic)
             sizing_1m_exact_50k        FOR TESTING,
             sizing_rounds_to_full_wave FOR TESTING,
             sizing_stays_in_band       FOR TESTING,
             sizing_small_n_partial     FOR TESTING,
             sizing_unknown_total       FOR TESTING,
             sizing_width_floor         FOR TESTING.
ENDCLASS.

CLASS ltcl_parallel IMPLEMENTATION.

  METHOD fields.
    rt = VALUE #( ( 'NAME1' ) ( 'TEXT' ) ).
  ENDMETHOD.

  METHOD rows_roundtrip_keeps_hits.
    " Build rows containing LF, a C1 char (0x9B) and NBSP, scan them
    " directly, then serialize->deserialize via CALL TRANSFORMATION id and
    " scan again. The two hit lists must be identical.
    DATA(lv_c1)   = cl_abap_conv_in_ce=>uccp( uccp = '009B' ).
    DATA(lv_nbsp) = cl_abap_conv_in_ce=>uccp( uccp = '00A0' ).
    DATA lt_rows TYPE tt_row.
    APPEND VALUE #( id = '0001'
                    name1 = |a{ cl_abap_char_utilities=>newline }b|
                    text  = |x{ lv_c1 }y| ) TO lt_rows.
    APPEND VALUE #( id = '0002' name1 = 'clean' text = |p{ lv_nbsp }q| ) TO lt_rows.

    DATA(lt_direct) = /ctdi/cl_cntrl_scanner=>scan_table(
                        it_data   = lt_rows
                        it_fields = fields( )
                        is_scope  = VALUE #( common = abap_true
                                             c1 = abap_true special = abap_true ) ).

    DATA lv_xml TYPE xstring.
    CALL TRANSFORMATION id SOURCE rows = lt_rows RESULT XML lv_xml.
    DATA lt_back TYPE tt_row.
    CALL TRANSFORMATION id SOURCE XML lv_xml RESULT rows = lt_back.

    DATA(lt_rt) = /ctdi/cl_cntrl_scanner=>scan_table(
                    it_data   = lt_back
                    it_fields = fields( )
                    is_scope  = VALUE #( common = abap_true
                                         c1 = abap_true special = abap_true ) ).

    cl_abap_unit_assert=>assert_equals(
      exp = lines( lt_direct ) act = lines( lt_rt )
      msg = 'Serialization must not change the number of hits' ).
    cl_abap_unit_assert=>assert_equals(
      exp = lt_direct act = lt_rt
      msg = 'Serialized round-trip must yield identical hits' ).
  ENDMETHOD.

  METHOD nul_survives_transport.
    " The sharpest case: NUL (0x00) is INVALID in XML 1.0 content. If CALL
    " TRANSFORMATION id cannot carry it, this test dumps or the hit is lost.
    DATA(lv_nul) = cl_abap_conv_in_ce=>uccp( uccp = '0000' ).
    DATA lt_rows TYPE tt_row.
    APPEND VALUE #( id = '0001' name1 = 'clean' text = |a{ lv_nul }b| ) TO lt_rows.

    DATA(lt_direct) = /ctdi/cl_cntrl_scanner=>scan_table(
                        it_data   = lt_rows
                        it_fields = fields( )
                        is_scope  = VALUE #( c0_other = abap_true ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 1 act = lines( lt_direct )
      msg = 'Direct scan must find the NUL' ).

    DATA lv_xml TYPE xstring.
    TRY.
        CALL TRANSFORMATION id SOURCE rows = lt_rows RESULT XML lv_xml.
        DATA lt_back TYPE tt_row.
        CALL TRANSFORMATION id SOURCE XML lv_xml RESULT rows = lt_back.
      CATCH cx_root INTO DATA(lx).
        cl_abap_unit_assert=>fail(
          msg = |CALL TRANSFORMATION id cannot carry NUL: { lx->get_text( ) }| ).
    ENDTRY.

    DATA(lt_rt) = /ctdi/cl_cntrl_scanner=>scan_table(
                    it_data   = lt_back
                    it_fields = fields( )
                    is_scope  = VALUE #( c0_other = abap_true ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 1 act = lines( lt_rt )
      msg = 'NUL must survive the XML round-trip (else switch transport)' ).
    cl_abap_unit_assert=>assert_equals(
      exp = '0x00' act = lt_rt[ 1 ]-hexcode
      msg = 'The surviving hit must still be NUL (0x00)' ).
  ENDMETHOD.

  METHOD sizing_1m_exact_50k.
    " 1,000,000 rows, width 5 -> 20 packs of exactly 50,000 (4 full waves).
    DATA lv_size TYPE i.
    DATA lv_wave TYPE i.
    /ctdi/cl_scan_parallel=>calc_sizing(
      EXPORTING iv_total = 1000000 iv_width = 5
      IMPORTING ev_pkgsize = lv_size ev_perwave = lv_wave ).
    cl_abap_unit_assert=>assert_equals( exp = 50000 act = lv_size ).
    cl_abap_unit_assert=>assert_equals( exp = 5     act = lv_wave ).
  ENDMETHOD.

  METHOD sizing_rounds_to_full_wave.
    " 1,150,000 / width 5: pack count must be a multiple of 5 (full waves)
    " and the pack size must stay in the 40k..60k band.
    DATA lv_size TYPE i.
    DATA lv_wave TYPE i.
    /ctdi/cl_scan_parallel=>calc_sizing(
      EXPORTING iv_total = 1150000 iv_width = 5
      IMPORTING ev_pkgsize = lv_size ev_perwave = lv_wave ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( lv_size >= 40000 AND lv_size <= 60000 )
      msg = 'pack size must stay in the 40k..60k band' ).
    " total packs = ceil(N/size) must be a multiple of width.
    " Use DIV (truncating) for the ceil - ABAP '/' rounds.
    DATA(lv_packs) = ( 1150000 + lv_size - 1 ) DIV lv_size.
    cl_abap_unit_assert=>assert_equals(
      exp = 0 act = lv_packs MOD lv_wave
      msg = 'pack count must be a whole number of full waves' ).
  ENDMETHOD.

  METHOD sizing_stays_in_band.
    " A spread of totals must all yield a pack size within [40k,60k].
    DATA lv_size TYPE i.
    DATA lv_wave TYPE i.
    DATA lt_totals TYPE STANDARD TABLE OF i.
    lt_totals = VALUE #( ( 300000 ) ( 777777 ) ( 1234567 ) ( 5000000 ) ( 9999999 ) ).
    LOOP AT lt_totals ASSIGNING FIELD-SYMBOL(<lv_n>).
      /ctdi/cl_scan_parallel=>calc_sizing(
        EXPORTING iv_total = <lv_n> iv_width = 5
        IMPORTING ev_pkgsize = lv_size ev_perwave = lv_wave ).
      cl_abap_unit_assert=>assert_true(
        act = xsdbool( lv_size >= 40000 AND lv_size <= 60000 )
        msg = |pack size out of band for N={ <lv_n> }: { lv_size }| ).
    ENDLOOP.
  ENDMETHOD.

  METHOD sizing_small_n_partial.
    " Small N (< one full wave at min pack): accept a partial wave, pack
    " size clamped to the band max, never zero/negative.
    DATA lv_size TYPE i.
    DATA lv_wave TYPE i.
    /ctdi/cl_scan_parallel=>calc_sizing(
      EXPORTING iv_total = 130000 iv_width = 5
      IMPORTING ev_pkgsize = lv_size ev_perwave = lv_wave ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( lv_size > 0 AND lv_size <= 60000 )
      msg = 'small-N pack size must be positive and within the band cap' ).
    cl_abap_unit_assert=>assert_equals( exp = 5 act = lv_wave ).
  ENDMETHOD.

  METHOD sizing_unknown_total.
    " Unknown / non-positive total -> fall back to the target sweet spot.
    DATA lv_size TYPE i.
    DATA lv_wave TYPE i.
    /ctdi/cl_scan_parallel=>calc_sizing(
      EXPORTING iv_total = 0 iv_width = 5
      IMPORTING ev_pkgsize = lv_size ev_perwave = lv_wave ).
    cl_abap_unit_assert=>assert_equals( exp = 50000 act = lv_size ).
  ENDMETHOD.

  METHOD sizing_width_floor.
    " Width below 1 is treated as 1 (never zero -> no divide-by-zero).
    DATA lv_size TYPE i.
    DATA lv_wave TYPE i.
    /ctdi/cl_scan_parallel=>calc_sizing(
      EXPORTING iv_total = 100000 iv_width = 0
      IMPORTING ev_pkgsize = lv_size ev_perwave = lv_wave ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lv_wave ).
    cl_abap_unit_assert=>assert_true( act = xsdbool( lv_size > 0 ) ).
  ENDMETHOD.

  METHOD packet_binary_roundtrip.
    DATA ls_packet TYPE /ctdi/cl_scan_parallel=>ts_packet.
    ls_packet-tablename = 'VTRKH'.
    ls_packet-base_row  = 100.
    ls_packet-max_rows  = 50000.
    ls_packet-scope     = VALUE #( common = abap_true c0_other = abap_true ).

    DATA(lv_raw) = /ctdi/cl_scan_parallel=>serialize_packet( ls_packet ).
    cl_abap_unit_assert=>assert_not_initial(
      act = lv_raw msg = 'Serialized packet must not be empty' ).

    DATA ls_back TYPE /ctdi/cl_scan_parallel=>ts_packet.
    IMPORT packet = ls_back FROM DATA BUFFER lv_raw.
    cl_abap_unit_assert=>assert_equals(
      exp = ls_packet act = ls_back msg = 'Binary packet round-trip must match' ).
  ENDMETHOD.

  METHOD hits_binary_roundtrip_with_nul.
    DATA lt_hits TYPE /ctdi/cl_cntrl_scanner=>tt_hit.
    APPEND VALUE #( rownum = 1 keyinfo = 'K=1' field = 'F1' offset = 2
                    hexcode = '0x00' descr = 'NUL' ) TO lt_hits.

    DATA lv_raw TYPE xstring.
    EXPORT hits = lt_hits TO DATA BUFFER lv_raw.

    DATA(lt_back) = /ctdi/cl_scan_parallel=>deserialize_hits( lv_raw ).
    cl_abap_unit_assert=>assert_equals(
      exp = lt_hits act = lt_back msg = 'Binary hits roundtrip must preserve NUL hit' ).
  ENDMETHOD.

  METHOD legacy_xml_hits_fallback.
    DATA lt_hits TYPE /ctdi/cl_cntrl_scanner=>tt_hit.
    APPEND VALUE #( rownum = 1 keyinfo = 'K=2' field = 'F2' offset = 0
                    hexcode = '0x0A' descr = 'LF' ) TO lt_hits.

    DATA lv_xml TYPE xstring.
    CALL TRANSFORMATION id SOURCE hits = lt_hits RESULT XML lv_xml.

    DATA(lt_back) = /ctdi/cl_scan_parallel=>deserialize_hits( lv_xml ).
    cl_abap_unit_assert=>assert_equals(
      exp = lt_hits act = lt_back msg = 'Legacy XML hits must still deserialize' ).
  ENDMETHOD.

  METHOD calc_width_non_zero.
    DATA(lv_w) = /ctdi/cl_scan_parallel=>calc_width( iv_percentage = 50 ).
    cl_abap_unit_assert=>assert_true(
      act = xsdbool( lv_w >= 1 ) msg = 'calc_width must always return at least 1' ).
  ENDMETHOD.

ENDCLASS.
