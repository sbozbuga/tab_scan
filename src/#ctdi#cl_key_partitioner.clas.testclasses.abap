CLASS ltcl_partitioner DEFINITION FINAL FOR TESTING
  DURATION SHORT
  RISK LEVEL HARMLESS .
  PRIVATE SECTION.
    METHODS:
      quote_escapes_single_quotes FOR TESTING,
      resume_single_key           FOR TESTING,
      resume_composite_key        FOR TESTING,
      until_composite_key         FOR TESTING .
ENDCLASS.
CLASS ltcl_partitioner IMPLEMENTATION.
  METHOD quote_escapes_single_quotes.
    DATA(lv_q) = /ctdi/cl_key_partitioner=>quote_literal( |O'HARA| ).
    cl_abap_unit_assert=>assert_equals(
      exp = |'O''HARA'| act = lv_q
      msg = 'Single quotes must be doubled in SQL literal' ).
  ENDMETHOD.
  METHOD resume_single_key.
    DATA(lv_w) = /ctdi/cl_key_partitioner=>build_resume_where(
                   VALUE #( ( field = 'VBELN' value = '0000000010' ) ) ).
    cl_abap_unit_assert=>assert_equals(
      exp = |( ( VBELN > '0000000010' ) )| act = lv_w
      msg = 'Single key resume tuple predicate' ).
  ENDMETHOD.
  METHOD resume_composite_key.
    DATA(lv_w) = /ctdi/cl_key_partitioner=>build_resume_where( VALUE #(
      ( field = 'K1' value = 'A' )
      ( field = 'K2' value = '2' ) ) ).
    DATA(lv_exp) = |( ( K1 > 'A' ) OR ( K1 = 'A' AND K2 > '2' ) )|.
    cl_abap_unit_assert=>assert_equals(
      exp = lv_exp act = lv_w
      msg = 'Composite key lexicographic expansion' ).
  ENDMETHOD.
  METHOD until_composite_key.
    DATA(lv_w) = /ctdi/cl_key_partitioner=>build_until_where( VALUE #(
      ( field = 'K1' value = 'A' )
      ( field = 'K2' value = '5' ) ) ).
    DATA(lv_exp) = |( ( K1 < 'A' ) OR ( K1 = 'A' AND K2 < '5' ) OR ( K1 = 'A' AND K2 = '5' ) )|.
    cl_abap_unit_assert=>assert_equals(
      exp = lv_exp act = lv_w
      msg = 'Composite key inclusive upper bound expansion' ).
  ENDMETHOD.
ENDCLASS.
