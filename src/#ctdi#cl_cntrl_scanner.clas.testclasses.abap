*"* use this source file for your ABAP unit test classes
CLASS ltcl_scanner DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS.

  PRIVATE SECTION.
    TYPES: BEGIN OF ts_row,
             id     TYPE n LENGTH 4,
             name1  TYPE c LENGTH 40,
             name2  TYPE c LENGTH 40,
             remark TYPE string,
           END OF ts_row,
           tt_row TYPE STANDARD TABLE OF ts_row WITH EMPTY KEY.

    CONSTANTS c_all TYPE string VALUE 'NAME1,NAME2,REMARK'.

    METHODS: all_fields
               RETURNING VALUE(rt) TYPE /ctdi/cl_cntrl_scanner=>tt_field,
             " tests
             clean_row_no_hits          FOR TESTING,
             newline_detected           FOR TESTING,
             tab_in_string_detected     FOR TESTING,
             c1_detected                FOR TESTING,
             field_subset_limits        FOR TESTING,
             scan_table_stamps_rownum   FOR TESTING,
             has_control_char_predicate FOR TESTING,
             scan_pairs_detects         FOR TESTING,
             keyinfo_stamped_on_hit     FOR TESTING,
             " scope / band tests
             common_only_ignores_c1     FOR TESTING,
             c1_only_ignores_common     FOR TESTING,
             c0_other_excludes_common   FOR TESTING,
             extra_cp_picks_point       FOR TESTING,
             initial_scope_equals_full  FOR TESTING,
             special_band_nbsp_zw       FOR TESTING,
             " single-source / sanitize tier tests
             sanitize_control_and_special FOR TESTING,
             has_control_excludes_special FOR TESTING,
             " extra_cp parsing (ranges, separators, malformed, out of range)
             extra_cp_range_and_commas    FOR TESTING,
             extra_cp_malformed_ignored   FOR TESTING,
             scan_table_matches_row_scan  FOR TESTING,
             rule_interface_inspects      FOR TESTING.
ENDCLASS.

CLASS ltcl_scanner IMPLEMENTATION.

  METHOD all_fields.
    rt = VALUE #( ( 'NAME1' ) ( 'NAME2' ) ( 'REMARK' ) ).
  ENDMETHOD.

  METHOD clean_row_no_hits.
    DATA(ls) = VALUE ts_row( id = '0001' name1 = 'Clean' remark = 'ok' ).
    cl_abap_unit_assert=>assert_initial(
      act = /ctdi/cl_cntrl_scanner=>scan_row( is_data   = ls
                                              it_fields = all_fields( ) )
      msg = 'Clean row must produce no hits' ).
  ENDMETHOD.

  METHOD newline_detected.
    DATA(ls) = VALUE ts_row(
      id = '0002'
      name1 = |First{ cl_abap_char_utilities=>newline }Second| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row( is_data   = ls
                                                 it_fields = all_fields( ) ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( lt ) ).
    cl_abap_unit_assert=>assert_equals( exp = 'NAME1' act = lt[ 1 ]-field ).
    cl_abap_unit_assert=>assert_equals( exp = '0x0A'  act = lt[ 1 ]-hexcode ).
  ENDMETHOD.

  METHOD tab_in_string_detected.
    DATA(ls) = VALUE ts_row(
      id = '0003'
      remark = |a{ cl_abap_char_utilities=>horizontal_tab }b| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row( is_data   = ls
                                                 it_fields = all_fields( ) ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( lt ) ).
    cl_abap_unit_assert=>assert_equals( exp = 'REMARK' act = lt[ 1 ]-field ).
    cl_abap_unit_assert=>assert_equals( exp = '0x09'   act = lt[ 1 ]-hexcode ).
  ENDMETHOD.

  METHOD c1_detected.
    DATA(lv_c1) = cl_abap_conv_in_ce=>uccp( uccp = '009B' ).  " CSI
    DATA(ls) = VALUE ts_row( id = '0004' name1 = |pre{ lv_c1 }post| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row( is_data   = ls
                                                 it_fields = all_fields( ) ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( lt ) ).
    cl_abap_unit_assert=>assert_equals( exp = '0x9B' act = lt[ 1 ]-hexcode ).
  ENDMETHOD.

  METHOD field_subset_limits.
    " newline in both NAME1 and REMARK; scanning only REMARK -> one hit
    DATA(ls) = VALUE ts_row(
      id = '0005'
      name1  = |x{ cl_abap_char_utilities=>newline }y|
      remark = |a{ cl_abap_char_utilities=>newline }b| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row(
                 is_data   = ls
                 it_fields = VALUE #( ( 'REMARK' ) ) ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( lt ) ).
    cl_abap_unit_assert=>assert_equals( exp = 'REMARK' act = lt[ 1 ]-field ).
  ENDMETHOD.

  METHOD scan_table_stamps_rownum.
    DATA lt_data TYPE tt_row.
    APPEND VALUE #( id = '0001' name1 = 'clean' ) TO lt_data.
    APPEND VALUE #( id = '0002'
                    name1 = |a{ cl_abap_char_utilities=>newline }b| ) TO lt_data.
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_table( it_data   = lt_data
                                                   it_fields = all_fields( ) ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( lt ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 2 act = lt[ 1 ]-rownum
      msg = 'Row number must be the table index of the offending row' ).
  ENDMETHOD.

  METHOD has_control_char_predicate.
    cl_abap_unit_assert=>assert_false(
      act = /ctdi/cl_cntrl_scanner=>has_control_char( 'plain text' ) ).
    cl_abap_unit_assert=>assert_true(
      act = /ctdi/cl_cntrl_scanner=>has_control_char(
              |x{ cl_abap_char_utilities=>newline }y| ) ).
  ENDMETHOD.

  METHOD scan_pairs_detects.
    " field/value pairs as a remote reader would hand them over
    DATA(lt_pairs) = VALUE /ctdi/cl_cntrl_scanner=>tt_pair(
      ( field = 'NAME1'  value = 'clean' )
      ( field = 'REMARK' value = |a{ cl_abap_char_utilities=>newline }b| ) ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_pairs( it_pairs = lt_pairs
                                                   iv_row   = 7 ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( lt ) ).
    cl_abap_unit_assert=>assert_equals( exp = 'REMARK' act = lt[ 1 ]-field ).
    cl_abap_unit_assert=>assert_equals( exp = '0x0A'   act = lt[ 1 ]-hexcode ).
    cl_abap_unit_assert=>assert_equals( exp = 7        act = lt[ 1 ]-rownum ).
  ENDMETHOD.

  METHOD keyinfo_stamped_on_hit.
    " ID is the key; a hit must carry keyinfo "ID=0002" to identify it.
    DATA lt_data TYPE tt_row.
    APPEND VALUE #( id = '0002'
                    name1 = |a{ cl_abap_char_utilities=>newline }b| ) TO lt_data.
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_table(
                 it_data   = lt_data
                 it_fields = all_fields( )
                 it_keys   = VALUE #( ( 'ID' ) ) ).
    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( lt ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 'ID=0002' act = lt[ 1 ]-keyinfo
      msg = 'Hit must carry the record key' ).
  ENDMETHOD.

  METHOD common_only_ignores_c1.
    " Value holds a C1 char (0x9B) AND a LF; scope=common only -> only LF.
    DATA(lv_c1) = cl_abap_conv_in_ce=>uccp( uccp = '009B' ).
    DATA(ls) = VALUE ts_row(
      id = '0010'
      name1 = |x{ lv_c1 }y{ cl_abap_char_utilities=>newline }z| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row(
                 is_data   = ls
                 it_fields = all_fields( )
                 is_scope  = VALUE #( common = abap_true ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 1 act = lines( lt )
      msg = 'common-only must ignore the C1 char and report only the LF' ).
    cl_abap_unit_assert=>assert_equals( exp = '0x0A' act = lt[ 1 ]-hexcode ).
  ENDMETHOD.

  METHOD c1_only_ignores_common.
    " Value holds LF AND a C1 char (0x9B); scope=c1 only -> only the C1 char.
    DATA(lv_c1) = cl_abap_conv_in_ce=>uccp( uccp = '009B' ).
    DATA(ls) = VALUE ts_row(
      id = '0011'
      name1 = |a{ cl_abap_char_utilities=>newline }b{ lv_c1 }c| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row(
                 is_data   = ls
                 it_fields = all_fields( )
                 is_scope  = VALUE #( c1 = abap_true ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 1 act = lines( lt )
      msg = 'c1-only must ignore the LF and report only the C1 char' ).
    cl_abap_unit_assert=>assert_equals( exp = '0x9B' act = lt[ 1 ]-hexcode ).
  ENDMETHOD.

  METHOD c0_other_excludes_common.
    " Value holds LF (0x0A, common) AND NUL (0x00, c0_other); scope=c0_other
    " -> only NUL reported, LF ignored (LF lives in 'common', not 'c0_other').
    DATA(lv_nul) = cl_abap_conv_in_ce=>uccp( uccp = '0000' ).
    DATA(ls) = VALUE ts_row(
      id = '0012'
      name1 = |a{ cl_abap_char_utilities=>newline }b{ lv_nul }c| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row(
                 is_data   = ls
                 it_fields = all_fields( )
                 is_scope  = VALUE #( c0_other = abap_true ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 1 act = lines( lt )
      msg = 'c0_other must report NUL but not the LF' ).
    cl_abap_unit_assert=>assert_equals( exp = '0x00' act = lt[ 1 ]-hexcode ).
  ENDMETHOD.

  METHOD extra_cp_picks_point.
    " No bands; extra_cp = '7F' -> DEL is found, a LF in the same value is not.
    DATA(lv_del) = cl_abap_conv_in_ce=>uccp( uccp = '007F' ).
    DATA(ls) = VALUE ts_row(
      id = '0013'
      name1 = |a{ cl_abap_char_utilities=>newline }b{ lv_del }c| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row(
                 is_data   = ls
                 it_fields = all_fields( )
                 is_scope  = VALUE #( extra_cp = '7F' ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 1 act = lines( lt )
      msg = 'extra_cp 7F must find DEL only, not the LF' ).
    cl_abap_unit_assert=>assert_equals( exp = '0x7F' act = lt[ 1 ]-hexcode ).
  ENDMETHOD.

  METHOD initial_scope_equals_full.
    " An explicitly INITIAL scope must behave like no scope (full set):
    " a C1 char is found.
    DATA(lv_c1) = cl_abap_conv_in_ce=>uccp( uccp = '009B' ).
    DATA(ls) = VALUE ts_row( id = '0014' name1 = |pre{ lv_c1 }post| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row(
                 is_data   = ls
                 it_fields = all_fields( )
                 is_scope  = VALUE #( ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 1 act = lines( lt )
      msg = 'Initial scope must fall back to the full set' ).
    cl_abap_unit_assert=>assert_equals( exp = '0x9B' act = lt[ 1 ]-hexcode ).
  ENDMETHOD.

  METHOD special_band_nbsp_zw.
    " special band detects NBSP (0xA0) and the zero-width/BOM family, which
    " the standard is_control_cp bands do NOT cover. A plain LF in the same
    " value is ignored (common band is off), proving band isolation. Also
    " checks the hexcode format: 0xA0 (<=FF) compact, 0x200B full 4-digit.
    DATA(lv_nbsp) = cl_abap_conv_in_ce=>uccp( uccp = '00A0' ).
    DATA(lv_zwsp) = cl_abap_conv_in_ce=>uccp( uccp = '200B' ).
    DATA(ls) = VALUE ts_row(
      id = '0015'
      name1 = |a{ cl_abap_char_utilities=>newline }b{ lv_nbsp }c{ lv_zwsp }d| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row(
                 is_data   = ls
                 it_fields = all_fields( )
                 is_scope  = VALUE #( special = abap_true ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 2 act = lines( lt )
      msg = 'special band must find NBSP + ZWSP, ignore the LF' ).
    cl_abap_unit_assert=>assert_equals( exp = '0xA0'   act = lt[ 1 ]-hexcode ).
    cl_abap_unit_assert=>assert_equals( exp = '0x200B' act = lt[ 2 ]-hexcode ).
  ENDMETHOD.

  METHOD sanitize_control_and_special.
    " sanitize derives special handling from the single-source gt_special:
    " CR/LF/TAB and NBSP collapse to one space; zero-width/BOM and C0/C1
    " controls are deleted; the result is condensed.
    DATA(lv_nbsp) = cl_abap_conv_in_ce=>uccp( uccp = '00A0' ).
    DATA(lv_zwsp) = cl_abap_conv_in_ce=>uccp( uccp = '200B' ).
    DATA(lv_c1)   = cl_abap_conv_in_ce=>uccp( uccp = '009B' ).
    " "A<TAB>B" -> single space ; NBSP -> space ; ZWSP + C1 are DELETED, so
    " the C and D around them become adjacent -> "CD".
    DATA(lv_in) = |A{ cl_abap_char_utilities=>horizontal_tab }B| &&
                  |{ lv_nbsp }C{ lv_zwsp }{ lv_c1 }D|.
    cl_abap_unit_assert=>assert_equals(
      exp = 'A B CD'
      act = /ctdi/cl_cntrl_scanner=>sanitize( lv_in )
      msg = 'sanitize must space CR/LF/TAB+NBSP and delete ZW/BOM/C0/C1' ).
  ENDMETHOD.

  METHOD has_control_excludes_special.
    " Tier B contract: has_control_char covers C0/DEL/C1 only, NOT the
    " special points. A value whose only oddity is NBSP must test FALSE,
    " while a C1 control tests TRUE.
    DATA(lv_nbsp) = cl_abap_conv_in_ce=>uccp( uccp = '00A0' ).
    DATA(lv_c1)   = cl_abap_conv_in_ce=>uccp( uccp = '009B' ).
    cl_abap_unit_assert=>assert_false(
      act = /ctdi/cl_cntrl_scanner=>has_control_char( |x{ lv_nbsp }y| )
      msg = 'NBSP is special, not a control char - must be FALSE' ).
    cl_abap_unit_assert=>assert_true(
      act = /ctdi/cl_cntrl_scanner=>has_control_char( |x{ lv_c1 }y| )
      msg = 'C1 is a control char - must be TRUE' ).
  ENDMETHOD.

  METHOD extra_cp_range_and_commas.
    " extra_cp accepts a range (80-9F) and comma/space separated points.
    " Value has a C1 char 0x9B (inside 80-9F) and DEL 0x7F (listed as 7F);
    " both must be found, a plain LF must NOT (no band, 7F/range only).
    DATA(lv_c1)  = cl_abap_conv_in_ce=>uccp( uccp = '009B' ).
    DATA(lv_del) = cl_abap_conv_in_ce=>uccp( uccp = '007F' ).
    DATA(ls) = VALUE ts_row(
      id = '0020'
      name1 = |a{ cl_abap_char_utilities=>newline }b{ lv_c1 }c{ lv_del }d| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row(
                 is_data   = ls
                 it_fields = all_fields( )
                 is_scope  = VALUE #( extra_cp = '7F, 80-9F' ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 2 act = lines( lt )
      msg = 'extra_cp 7F + range 80-9F must find DEL and the C1 char, not LF' ).
    " order follows position in the value: C1 (0x9B) before DEL (0x7F)
    cl_abap_unit_assert=>assert_equals( exp = '0x9B' act = lt[ 1 ]-hexcode ).
    cl_abap_unit_assert=>assert_equals( exp = '0x7F' act = lt[ 2 ]-hexcode ).
  ENDMETHOD.

  METHOD extra_cp_malformed_ignored.
    " Malformed / reversed / out-of-range tokens are skipped defensively
    " (no dump); the one valid token (0A) still works.
    DATA(ls) = VALUE ts_row(
      id = '0021'
      name1 = |a{ cl_abap_char_utilities=>newline }b| ).
    DATA(lt) = /ctdi/cl_cntrl_scanner=>scan_row(
                 is_data   = ls
                 it_fields = all_fields( )
                 is_scope  = VALUE #( extra_cp = 'ZZ 9F-80 0A GARBAGE' ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = 1 act = lines( lt )
      msg = 'malformed/reversed tokens ignored; valid 0A still detected' ).
    cl_abap_unit_assert=>assert_equals( exp = '0x0A' act = lt[ 1 ]-hexcode ).
  ENDMETHOD.

  METHOD scan_table_matches_row_scan.
    " Index-based scan_table must produce identical results to scan_row
    DATA lt_data TYPE tt_row.
    APPEND VALUE #( id = '0010' name1 = 'clean' name2 = |first{ cl_abap_char_utilities=>newline }field| ) TO lt_data.
    APPEND VALUE #( id = '0011' name1 = |second{ cl_abap_char_utilities=>horizontal_tab }field| remark = 'clean' ) TO lt_data.

    DATA(lt_table_hits) = /ctdi/cl_cntrl_scanner=>scan_table(
                            it_data   = lt_data
                            it_fields = all_fields( ) ).

    DATA lt_row_hits TYPE /ctdi/cl_cntrl_scanner=>tt_hit.
    DATA lv_idx TYPE i.
    LOOP AT lt_data ASSIGNING FIELD-SYMBOL(<row>).
      lv_idx = lv_idx + 1.
      DATA(lt_hits) = /ctdi/cl_cntrl_scanner=>scan_row(
                        is_data   = <row>
                        it_fields = all_fields( )
                        iv_row    = lv_idx ).
      APPEND LINES OF lt_hits TO lt_row_hits.
    ENDLOOP.

    cl_abap_unit_assert=>assert_equals(
      exp = lt_row_hits act = lt_table_hits
      msg = 'Index-resolved scan_table must produce identical hits to scan_row' ).
  ENDMETHOD.

  METHOD rule_interface_inspects.
    DATA lo_rule TYPE REF TO /ctdi/if_inspection_rule.
    lo_rule = NEW /ctdi/cl_cntrl_scanner( is_scope = VALUE #( common = abap_true ) ).

    cl_abap_unit_assert=>assert_equals(
      exp = 'CONTROL_CHARS' act = lo_rule->get_rule_id( ) ).

    DATA lt_data TYPE tt_row.
    APPEND VALUE #( id = '0001' name1 = 'clean' ) TO lt_data.
    APPEND VALUE #( id = '0002' name1 = |a{ cl_abap_char_utilities=>newline }b| ) TO lt_data.

    DATA(lt_hits) = lo_rule->inspect_table(
      it_data   = lt_data
      it_fields = all_fields( )
      it_keys   = VALUE #( ( 'ID' ) ) ).

    cl_abap_unit_assert=>assert_equals( exp = 1 act = lines( lt_hits ) ).
    cl_abap_unit_assert=>assert_equals( exp = 'NAME1' act = lt_hits[ 1 ]-field ).
    cl_abap_unit_assert=>assert_equals( exp = 'ID=0002' act = lt_hits[ 1 ]-keyinfo ).
  ENDMETHOD.

ENDCLASS.
