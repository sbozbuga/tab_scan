CLASS /ctdi/cl_cntrl_scanner DEFINITION
  PUBLIC
  CREATE PUBLIC.

*"* Scans character-like fields of a structure or internal table for
*"* control characters (C0 block, DEL, C1 block) and returns the hits.
*"* Pure and stateless - the caller decides WHICH fields to scan and
*"* passes the field-name list in. Works on any flat structure/table.

  PUBLIC SECTION.
    INTERFACES /ctdi/if_inspection_rule .

    " One control-character finding.
    TYPES: BEGIN OF ts_hit,
             rownum  TYPE i,         " row number within the scanned set
             keyinfo TYPE string,    " key fields of the row, e.g. VBELN=..
             field   TYPE fieldname, " field that holds the control char
             offset  TYPE i,         " 0-based position within the value
             hexcode TYPE string,    " hex code, e.g. 0x0A
             descr   TYPE string,    " readable name, e.g. LF (line feed)
             value   TYPE string,    " full field value, for context
           END OF ts_hit,
           tt_hit TYPE STANDARD TABLE OF ts_hit WITH EMPTY KEY.
    " List of field names to scan.
    TYPES tt_field TYPE STANDARD TABLE OF fieldname WITH EMPTY KEY.
    " A field name together with its (already extracted) value.
    TYPES: BEGIN OF ts_pair,
             field TYPE fieldname,
             value TYPE string,
           END OF ts_pair,
           tt_pair TYPE STANDARD TABLE OF ts_pair WITH EMPTY KEY.

    " Which classes of control characters to scan for. Independent bands -
    " the effective scan set is the UNION of the selected bands plus any
    " explicit extra code points. An INITIAL scope (all flags abap_false and
    " extra_cp empty) means "scan the full set" (backward compatible default).
    "   common   - LF (0x0A), CR (0x0D), TAB (0x09)
    "   c0_other - remaining C0 controls 0x00-0x1F (excluding 09/0A/0D)
    "   c1       - C1 block 0x80-0x9F
    "   special  - NBSP 0x00A0 and zero-width / BOM family (ZWSP 0x200B,
    "              ZWNJ 0x200C, ZWJ 0x200D, BOM/ZWNBSP 0xFEFF) - the same
    "              extra points SANITIZE cleans but is_control_cp does not flag
    "   extra_cp - explicit hex code points / ranges, e.g. '0A 7F 80-9F'
    "              (space or comma separated); the ONLY way to reach DEL 0x7F
    TYPES: BEGIN OF ts_scope,
             common   TYPE abap_bool,
             c0_other TYPE abap_bool,
             c1       TYPE abap_bool,
             special  TYPE abap_bool,
             extra_cp TYPE string,
           END OF ts_scope.

    METHODS constructor
      IMPORTING
        !is_scope TYPE ts_scope OPTIONAL .

    CLASS-METHODS class_constructor.

    "! Scan a list of field name / value pairs directly, without a
    "! structure. Useful for callers that already hold the values as
    "! strings (e.g. a remote read via /SAPDS/RFC_READ_TABLE2 that
    "! returns flat character lines parsed into fields).
    "! @parameter it_pairs | field name / value pairs to inspect
    "! @parameter iv_row   | row number to stamp on the hits
    "! @parameter iv_keyinfo |
    "! @parameter rt_hits  | control-character findings
    CLASS-METHODS scan_pairs
      IMPORTING it_pairs       TYPE tt_pair
                iv_row         TYPE i      DEFAULT 1
                iv_keyinfo     TYPE string OPTIONAL
                is_scope       TYPE ts_scope OPTIONAL
      RETURNING VALUE(rt_hits) TYPE tt_hit.

    "! Scan the given fields of one (flat) structure.
    "! @parameter is_data       | the data row (any flat structure)
    "! @parameter it_fields     | names of the fields to inspect
    "! @parameter it_keys       | key field names - their values are stamped
    "!                            on each hit (keyinfo) to identify the record
    "! @parameter iv_row        | row number to stamp on the hits
    "! @parameter iv_check_clnt | check and skip CLNT fields via RTTI
    "! @parameter rt_hits       | control-character findings
    CLASS-METHODS scan_row
      IMPORTING is_data        TYPE any
                it_fields      TYPE tt_field
                it_keys        TYPE tt_field  OPTIONAL
                iv_row         TYPE i         DEFAULT 1
                iv_check_clnt  TYPE abap_bool DEFAULT abap_true
                is_scope       TYPE ts_scope  OPTIONAL
      RETURNING VALUE(rt_hits) TYPE tt_hit.

    "! Scan the given fields of every row of an internal table.
    "! The row number stamped on each hit is the table index (sy-tabix).
    "! @parameter it_data   | the data table (any flat row type)
    "! @parameter it_fields | names of the fields to inspect
    "! @parameter it_keys   | key field names (stamped as keyinfo per row)
    "! @parameter rt_hits   | control-character findings
    CLASS-METHODS scan_table
      IMPORTING it_data        TYPE ANY TABLE
                it_fields      TYPE tt_field
                it_keys        TYPE tt_field OPTIONAL
                is_scope       TYPE ts_scope OPTIONAL
      RETURNING VALUE(rt_hits) TYPE tt_hit.

    "! Build a "NAME=value NAME=value" string from the given key fields
    "! of a structure. Used to stamp each hit with its record key.
    "!
    "! @parameter is_data |
    "! @parameter it_keys |
    "! @parameter iv_check_clnt |
    "! @parameter rv_keyinfo |
    CLASS-METHODS build_keyinfo
      IMPORTING is_data           TYPE any
                it_keys           TYPE tt_field
                iv_check_clnt     TYPE abap_bool DEFAULT abap_true
      RETURNING VALUE(rv_keyinfo) TYPE string.

    "! Does the given string contain any CONTROL character (C0 below 0x20,
    "! DEL 0x7F, or C1 0x80-0x9F)? Convenience yes/no predicate.
    "! NOTE: this is the strict Unicode-control tier only. It does NOT cover
    "! the "special" points (NBSP 0x00A0, zero-width ZWSP/ZWNJ/ZWJ, BOM) that
    "! SANITIZE also cleans - those are a separate opt-in tier (the special
    "! band / explicit code points of scan_*). So has_control_char is NOT a
    "! complete pre-check for "would sanitize change this value".
    "! @parameter iv_value  | text to test
    "! @parameter rv_result | abap_true if a C0/DEL/C1 control char is present
    CLASS-METHODS has_control_char
      IMPORTING iv_value         TYPE clike
      RETURNING VALUE(rv_result) TYPE abap_bool.

    "! Clean a text value of stray control / whitespace characters so it is
    "! safe to pass on to a BAPI or similar interface. Pure and stateless.
    "! Rule: CR (0x0D), LF (0x0A), TAB (0x09) and NBSP (0x00A0) each collapse
    "! to a single regular space; all other control code points (C0 below 0x20,
    "! DEL 0x7F, C1 0x80-0x9F) and zero-width characters (ZWSP 0x200B,
    "! ZWNJ 0x200C, ZWJ 0x200D, BOM/ZWNBSP 0xFEFF) are deleted; the result is
    "! finally trimmed of leading / trailing spaces.
    "! @parameter iv_value | the raw text value to clean
    "! @parameter rv_value | the cleaned text value
    CLASS-METHODS sanitize
      IMPORTING iv_value        TYPE clike
                iv_rep_char     TYPE clike DEFAULT ` `
      RETURNING VALUE(rv_value) TYPE string.

  PROTECTED SECTION.

  PRIVATE SECTION.
    TYPES tv_cp TYPE x LENGTH 2.
    TYPES tv_x1 TYPE x LENGTH 1.

    " SINGLE SOURCE OF TRUTH for the discrete "special" points (NBSP and the
    " zero-width / BOM family). These are NOT Unicode control characters -
    " is_control_cp / gv_control_chars / has_control_char deliberately do NOT
    " cover them (that tier is C0 / DEL / C1 only). They form the opt-in
    " "special" band and drive sanitize. Each row carries the code point, a
    " readable description, and what sanitize does with it:
    "   action 'S' = collapse to a single space, 'D' = delete.
    " gv_special, cp_descr and sanitize are all built FROM this one table,
    " so a point is defined in exactly one place.
    TYPES: BEGIN OF ts_special,
             cp     TYPE i,
             descr  TYPE string,
             action TYPE c LENGTH 1,   " 'S' = to space, 'D' = delete
           END OF ts_special.
    CLASS-DATA gt_special TYPE STANDARD TABLE OF ts_special WITH EMPTY KEY.

    " Full "control character" set (C0 / DEL / C1) - the strict Unicode-control
    " tier. This is the backward-compatible default scope and what
    " has_control_char tests. It does NOT include the special band above.
    CLASS-DATA gv_control_chars TYPE string.
    " Per-band sets, pre-built once in class_constructor (no per-row rebuild).
    CLASS-DATA gv_common   TYPE string.   " LF, CR, TAB
    CLASS-DATA gv_c0_other TYPE string.   " C0 0x00-0x1F excluding 09/0A/0D
    CLASS-DATA gv_c1       TYPE string.   " C1 0x80-0x9F
    CLASS-DATA gv_special  TYPE string.   " NBSP + zero-width / BOM (from gt_special)

    DATA ms_scope TYPE ts_scope .

    " Resolve a scope into the effective character set used by the CA/NA
    " scans. An initial scope yields the full set (backward compatible).
    CLASS-METHODS build_scan_set
      IMPORTING is_scope        TYPE ts_scope
      RETURNING VALUE(rv_chars) TYPE string.

    " Parse up to 4 hex digits to an integer; -1 on invalid input.
    CLASS-METHODS hex_to_int
      IMPORTING iv_hex         TYPE string
      RETURNING VALUE(rv_int)  TYPE i.

    " Filter out client (CLNT) key fields using RTTI once
    CLASS-METHODS filter_keys
      IMPORTING is_data        TYPE any
                it_keys        TYPE tt_field
      RETURNING VALUE(rt_keys) TYPE tt_field.

    " Scan one row with an ALREADY-RESOLVED character set (hot path): the
    " caller resolves build_scan_set once per table/pairs call instead of
    " once per row. Keyinfo is built lazily - only when the row has a hit.
    CLASS-METHODS scan_row_resolved
      IMPORTING is_data       TYPE any
                it_fields     TYPE tt_field
                it_keys       TYPE tt_field OPTIONAL
                iv_row        TYPE i
                iv_check_clnt TYPE abap_bool DEFAULT abap_true
                iv_chars      TYPE string
      CHANGING  ct_hits       TYPE tt_hit.

    " Append a hit for every control character found in iv_value. iv_chars is
    " the effective control-character set to scan against (CA/NA operand).
    CLASS-METHODS scan_value
      IMPORTING iv_row     TYPE i
                iv_keyinfo TYPE string
                iv_field   TYPE fieldname
                iv_value   TYPE string
                iv_chars   TYPE string
      CHANGING  ct_hits    TYPE tt_hit.

    " True if the Unicode code point is a control character:
    " C0 (below 0x20), DEL (0x7F) or C1 (0x80-0x9F).
    CLASS-METHODS is_control_cp
      IMPORTING iv_cp            TYPE i
      RETURNING VALUE(rv_result) TYPE abap_bool.

    " Fast component-index mapping for scan_table: maps field name to structure position
    TYPES: BEGIN OF ts_comp_map,
             index TYPE i,
             name  TYPE fieldname,
           END OF ts_comp_map,
           tt_comp_map TYPE STANDARD TABLE OF ts_comp_map WITH EMPTY KEY.

    " Scan one row by pre-resolved integer component positions (direct kernel dereference)
    CLASS-METHODS scan_row_by_index
      IMPORTING is_data     TYPE any
                it_comp_map TYPE tt_comp_map
                it_keys     TYPE tt_field OPTIONAL
                iv_row      TYPE i
                iv_chars    TYPE string
      CHANGING  ct_hits     TYPE tt_hit.

    " Readable name for a control code point, e.g. 'LF (line feed)'.
    CLASS-METHODS cp_descr
      IMPORTING iv_cp           TYPE i
      RETURNING VALUE(rv_descr) TYPE string.

ENDCLASS.



CLASS /CTDI/CL_CNTRL_SCANNER IMPLEMENTATION.


  METHOD /ctdi/if_inspection_rule~get_db_filter.
    CLEAR rv_filter.
  ENDMETHOD.


  METHOD /ctdi/if_inspection_rule~get_rule_id.
    rv_id = 'CONTROL_CHARS'.
  ENDMETHOD.


  METHOD /ctdi/if_inspection_rule~inspect_row.
    rt_violations = scan_row( is_data   = is_data
                              it_fields = it_fields
                              it_keys   = it_keys
                              iv_row    = iv_row
                              is_scope  = ms_scope ).
  ENDMETHOD.


  METHOD /ctdi/if_inspection_rule~inspect_table.
    rt_violations = scan_table( it_data   = it_data
                                it_fields = it_fields
                                it_keys   = it_keys
                                is_scope  = ms_scope ).
  ENDMETHOD.


  METHOD build_keyinfo.
    FIELD-SYMBOLS <k> TYPE any.

    LOOP AT it_keys ASSIGNING FIELD-SYMBOL(<key>).
      ASSIGN COMPONENT <key> OF STRUCTURE is_data TO <k>.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      IF iv_check_clnt = abap_true.
        " Skip the client field (datatype CLNT) - always the current client
        " and therefore noise in the key display. get_ddic_field raises the
        " CLASSIC exceptions not_found / no_ddic_type (not class-based), so
        " they must be handled via EXCEPTIONS / sy-subrc.
        TRY.
            DATA(lr_el) = CAST cl_abap_elemdescr(
                            cl_abap_typedescr=>describe_by_data( <k> ) ).
            DATA ls_fld TYPE dfies.
            CALL METHOD lr_el->get_ddic_field
              RECEIVING  p_flddescr   = ls_fld
              EXCEPTIONS not_found    = 1
                         no_ddic_type = 2
                         OTHERS       = 3.
            IF sy-subrc = 0 AND ls_fld-datatype = 'CLNT'.
              CONTINUE.
            ENDIF.
          CATCH cx_root.
            " not a DDIC-typed field - keep it
        ENDTRY.
      ENDIF.
      DATA(lv_val) = condense( CONV string( <k> ) ).
      IF rv_keyinfo IS INITIAL.
        rv_keyinfo = |{ <key> }={ lv_val }|.
      ELSE.
        rv_keyinfo = |{ rv_keyinfo } { <key> }={ lv_val }|.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.


  METHOD build_scan_set.
    " Initial scope (no bands, no extra points) => full set, so existing
    " callers that pass no scope behave exactly as before.
    IF is_scope-common   = abap_false
       AND is_scope-c0_other = abap_false
       AND is_scope-c1       = abap_false
       AND is_scope-special  = abap_false
       AND is_scope-extra_cp IS INITIAL.
      rv_chars = gv_control_chars.
      RETURN.
    ENDIF.

    IF is_scope-common   = abap_true.
      rv_chars = rv_chars && gv_common.
    ENDIF.
    IF is_scope-c0_other = abap_true.
      rv_chars = rv_chars && gv_c0_other.
    ENDIF.
    IF is_scope-c1       = abap_true.
      rv_chars = rv_chars && gv_c1.
    ENDIF.
    IF is_scope-special  = abap_true.
      rv_chars = rv_chars && gv_special.
    ENDIF.

    " Resolve explicit code points / ranges, e.g. '0A 7F 80-9F' or '0A,7F'.
    IF is_scope-extra_cp IS NOT INITIAL.
      DATA lv_norm TYPE string.
      lv_norm = is_scope-extra_cp.
      REPLACE ALL OCCURRENCES OF ',' IN lv_norm WITH ` `.
      SPLIT lv_norm AT ` ` INTO TABLE DATA(lt_tok).
      LOOP AT lt_tok ASSIGNING FIELD-SYMBOL(<tok>).
        DATA(lv_tok) = condense( <tok> ).
        IF lv_tok IS INITIAL.
          CONTINUE.
        ENDIF.
        DATA lv_lo TYPE i.
        DATA lv_hi TYPE i.
        IF lv_tok CA '-'.
          DATA: lv_a TYPE string, lv_b TYPE string.
          SPLIT lv_tok AT '-' INTO lv_a lv_b.
          lv_lo = hex_to_int( lv_a ).
          lv_hi = hex_to_int( lv_b ).
        ELSE.
          lv_lo = hex_to_int( lv_tok ).
          lv_hi = lv_lo.
        ENDIF.
        " Guard against malformed / out-of-range tokens
        IF lv_lo < 0 OR lv_hi < 0 OR lv_lo > lv_hi OR lv_hi > 65535.
          CONTINUE.
        ENDIF.
        WHILE lv_lo <= lv_hi.
          DATA(lv_cp_x) = CONV tv_cp( lv_lo ).
          rv_chars = rv_chars && cl_abap_conv_in_ce=>uccp( uccp = lv_cp_x ).
          lv_lo = lv_lo + 1.
        ENDWHILE.
      ENDLOOP.
    ENDIF.
  ENDMETHOD.


  METHOD class_constructor.
    DATA lv_i TYPE i.

    " C0 block: 0x0000 to 0x001F (0 to 31). Split into the "common" band
    " (TAB 09, LF 0A, CR 0D) and the "c0_other" band (everything else).
    WHILE lv_i < 32.
      DATA(lv_cp_c0) = CONV tv_cp( lv_i ).
      DATA(lv_ch_c0) = cl_abap_conv_in_ce=>uccp( uccp = lv_cp_c0 ).
      gv_control_chars = gv_control_chars && lv_ch_c0.
      IF lv_i = 9 OR lv_i = 10 OR lv_i = 13.
        gv_common = gv_common && lv_ch_c0.
      ELSE.
        gv_c0_other = gv_c0_other && lv_ch_c0.
      ENDIF.
      lv_i = lv_i + 1.
    ENDWHILE.

    " DEL: 0x007F (127) - part of the full set, but reachable per-scope only
    " via the explicit extra_cp input (no dedicated band).
    DATA(lv_cp_del) = CONV tv_cp( 127 ).
    gv_control_chars = gv_control_chars && cl_abap_conv_in_ce=>uccp( uccp = lv_cp_del ).

    " C1 block: 0x0080 to 0x009F (128 to 159)
    lv_i = 128.
    WHILE lv_i <= 159.
      DATA(lv_cp_c1) = CONV tv_cp( lv_i ).
      DATA(lv_ch_c1) = cl_abap_conv_in_ce=>uccp( uccp = lv_cp_c1 ).
      gv_control_chars = gv_control_chars && lv_ch_c1.
      gv_c1 = gv_c1 && lv_ch_c1.
      lv_i = lv_i + 1.
    ENDWHILE.

    " "special" band: NBSP + the zero-width / BOM family. Defined ONCE in
    " gt_special (the single source of truth); gv_special, cp_descr and
    " sanitize all derive from it. NBSP collapses to a space ('S'), the
    " zero-width / BOM points are deleted ('D'). These are NOT in
    " gv_control_chars - they are the opt-in special tier only.
    gt_special = VALUE #(
      ( cp = 160   action = 'S' descr = 'NBSP (no-break space)' )
      ( cp = 8203  action = 'D' descr = 'ZWSP (zero width space)' )
      ( cp = 8204  action = 'D' descr = 'ZWNJ (zero width non-joiner)' )
      ( cp = 8205  action = 'D' descr = 'ZWJ (zero width joiner)' )
      ( cp = 65279 action = 'D' descr = 'BOM / ZWNBSP (0xFEFF)' ) ).
    LOOP AT gt_special ASSIGNING FIELD-SYMBOL(<sp>).
      DATA(lv_cp_sp) = CONV tv_cp( <sp>-cp ).
      gv_special = gv_special && cl_abap_conv_in_ce=>uccp( uccp = lv_cp_sp ).
    ENDLOOP.
  ENDMETHOD.


  METHOD constructor.
    ms_scope = is_scope.
  ENDMETHOD.


  METHOD cp_descr.
    " Special points get their text from the single source gt_special.
    READ TABLE gt_special WITH KEY cp = iv_cp ASSIGNING FIELD-SYMBOL(<sp>).
    IF sy-subrc = 0.
      rv_descr = <sp>-descr.
      RETURN.
    ENDIF.

    CASE iv_cp.
      WHEN 0.
        rv_descr = 'NUL (null)'.
      WHEN 8.
        rv_descr = 'BS (backspace)'.
      WHEN 9.
        rv_descr = 'HT (tab)'.
      WHEN 10.
        rv_descr = 'LF (line feed)'.
      WHEN 11.
        rv_descr = 'VT (vertical tab)'.
      WHEN 12.
        rv_descr = 'FF (form feed)'.
      WHEN 13.
        rv_descr = 'CR (carriage return)'.
      WHEN 27.
        rv_descr = 'ESC (escape)'.
      WHEN 29.
        rv_descr = 'GS (group separator)'.
      WHEN 127.
        rv_descr = 'DEL (delete)'.
      WHEN 133.
        rv_descr = 'NEL (next line, C1)'.
      WHEN 155.
        rv_descr = 'CSI (control seq. intro, C1)'.
      WHEN OTHERS.
        DATA(lv_x) = CONV tv_x1( iv_cp ).
        IF iv_cp < 32.
          rv_descr = |C0 control (0x{ lv_x })|.
        ELSEIF iv_cp >= 128 AND iv_cp <= 159.
          rv_descr = |C1 control (0x{ lv_x })|.
        ELSE.
          rv_descr = 'control char'.
        ENDIF.
    ENDCASE.
  ENDMETHOD.


  METHOD filter_keys.
    FIELD-SYMBOLS <k> TYPE any.

    LOOP AT it_keys ASSIGNING FIELD-SYMBOL(<key>).
      ASSIGN COMPONENT <key> OF STRUCTURE is_data TO <k>.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      " Skip the client field (datatype CLNT). get_ddic_field raises the
      " CLASSIC exceptions not_found / no_ddic_type (not class-based), so
      " they must be handled via EXCEPTIONS / sy-subrc - CATCH cx_root does
      " NOT catch them and a non-DDIC key field would dump (NO_DDIC_TYPE).
      TRY.
          DATA(lr_el) = CAST cl_abap_elemdescr(
                          cl_abap_typedescr=>describe_by_data( <k> ) ).
          DATA ls_fld TYPE dfies.
          CALL METHOD lr_el->get_ddic_field
            RECEIVING  p_flddescr   = ls_fld
            EXCEPTIONS not_found    = 1
                       no_ddic_type = 2
                       OTHERS       = 3.
          IF sy-subrc = 0 AND ls_fld-datatype = 'CLNT'.
            CONTINUE.
          ENDIF.
        CATCH cx_root.
          " not a DDIC-typed field - keep it
      ENDTRY.
      APPEND <key> TO rt_keys.
    ENDLOOP.
  ENDMETHOD.


  METHOD has_control_char.
    rv_result = xsdbool( iv_value CA gv_control_chars ).
  ENDMETHOD.


  METHOD hex_to_int.
    " Parse up to 4 hex digits into an integer. Returns -1 on any invalid
    " character so the caller can skip the token defensively.
    DATA(lv_in) = to_upper( condense( iv_hex ) ).
    rv_int = 0.
    IF lv_in IS INITIAL OR strlen( lv_in ) > 4.
      rv_int = -1.
      RETURN.
    ENDIF.
    DATA lv_k TYPE i.
    DATA(lv_len) = strlen( lv_in ).
    WHILE lv_k < lv_len.
      DATA(lv_d) = lv_in+lv_k(1).
      DATA lv_v TYPE i.
      FIND lv_d IN '0123456789ABCDEF' MATCH OFFSET lv_v.
      IF sy-subrc <> 0.
        rv_int = -1.
        RETURN.
      ENDIF.
      rv_int = rv_int * 16 + lv_v.
      lv_k = lv_k + 1.
    ENDWHILE.
  ENDMETHOD.


  METHOD is_control_cp.
    " Control char =
    "   C0 block : code point < 0x20 (below blank)
    "   DEL      : 0x7F
    "   C1 block : 0x80-0x9F (often Windows-1252 text pasted from Office)
    rv_result = xsdbool(    iv_cp < 32
                         OR iv_cp = 127
                         OR ( iv_cp >= 128 AND iv_cp <= 159 ) ).
  ENDMETHOD.


  METHOD sanitize.
    " CR / LF / TAB collapse to a single space (whitespace controls); the
    " special points (NBSP, zero-width, BOM) use their action from the single
    " source gt_special ('S' = to space, 'D' = delete); all other control
    " code points (C0 / DEL / C1 per is_control_cp) are deleted; everything
    " else is kept. Result is finally condensed.
    CONSTANTS lc_tab TYPE i VALUE 9.
    CONSTANTS lc_lf  TYPE i VALUE 10.
    CONSTANTS lc_cr  TYPE i VALUE 13.

    DATA(lv_str) = CONV string( iv_value ).
    DATA(lv_len) = strlen( lv_str ).
    DATA lv_i TYPE i.

    WHILE lv_i < lv_len.
      DATA(lv_c)   = lv_str+lv_i(1).
      DATA(lv_cp)  = cl_abap_conv_out_ce=>uccp( lv_c ).
      DATA(lv_int) = CONV i( lv_cp ).

      IF lv_int = lc_cr OR lv_int = lc_lf OR lv_int = lc_tab.
        "-- whitespace control: collapse to replacement character
        rv_value = rv_value && iv_rep_char.
      ELSEIF line_exists( gt_special[ cp = lv_int ] ).
        "-- special point: apply its single-source action
        IF gt_special[ cp = lv_int ]-action = 'S'.
          rv_value = rv_value && iv_rep_char.
        ENDIF.
        "-- action 'D': delete (append nothing)
      ELSEIF is_control_cp( lv_int ) = abap_true.
        "-- other control code point (C0 / DEL / C1): delete it
      ELSE.
        rv_value = rv_value && lv_c.
      ENDIF.

      lv_i = lv_i + 1.
    ENDWHILE.

    "-- trim leading / trailing spaces
    rv_value = condense( rv_value ).
  ENDMETHOD.


  METHOD scan_pairs.
    DATA(lv_chars) = build_scan_set( is_scope ).
    LOOP AT it_pairs ASSIGNING FIELD-SYMBOL(<pair>).
      scan_value( EXPORTING iv_row     = iv_row
                            iv_keyinfo = iv_keyinfo
                            iv_field   = <pair>-field
                            iv_value   = <pair>-value
                            iv_chars   = lv_chars
                  CHANGING  ct_hits    = rt_hits ).
    ENDLOOP.
  ENDMETHOD.


  METHOD scan_row.
    " Public single-row entry: resolve the set once, then delegate.
    scan_row_resolved( EXPORTING is_data       = is_data
                                 it_fields     = it_fields
                                 it_keys       = it_keys
                                 iv_row        = iv_row
                                 iv_check_clnt = iv_check_clnt
                                 iv_chars      = build_scan_set( is_scope )
                       CHANGING  ct_hits       = rt_hits ).
  ENDMETHOD.


  METHOD scan_row_by_index.
    DATA lt_row_hits TYPE tt_hit.
    FIELD-SYMBOLS <fld> TYPE any.

    LOOP AT it_comp_map ASSIGNING FIELD-SYMBOL(<comp>).
      ASSIGN COMPONENT <comp>-index OF STRUCTURE is_data TO <fld>.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      IF <fld> NA iv_chars.
        CONTINUE.
      ENDIF.
      scan_value( EXPORTING iv_row     = iv_row
                            iv_keyinfo = ``
                            iv_field   = <comp>-name
                            iv_value   = CONV string( <fld> )
                            iv_chars   = iv_chars
                  CHANGING  ct_hits    = lt_row_hits ).
    ENDLOOP.

    IF lt_row_hits IS INITIAL.
      RETURN.
    ENDIF.

    DATA(lv_keyinfo) = build_keyinfo( is_data       = is_data
                                      it_keys       = it_keys
                                      iv_check_clnt = abap_false ).
    LOOP AT lt_row_hits ASSIGNING FIELD-SYMBOL(<h>).
      <h>-keyinfo = lv_keyinfo.
    ENDLOOP.
    APPEND LINES OF lt_row_hits TO ct_hits.
  ENDMETHOD.


  METHOD scan_row_resolved.
    " Scan all fields into a row-local buffer WITHOUT keyinfo first; only if
    " the row actually has hits do we build keyinfo (once) and stamp it.
    " This avoids the per-row build_keyinfo cost on clean rows (the vast
    " majority) and reuses the pre-resolved iv_chars (no per-row rebuild).
    DATA lt_row_hits TYPE tt_hit.
    FIELD-SYMBOLS <fld> TYPE any.
    LOOP AT it_fields ASSIGNING FIELD-SYMBOL(<field>).
      ASSIGN COMPONENT <field> OF STRUCTURE is_data TO <fld>.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.
      " Hot-path short-circuit: test the raw field with a single kernel NA
      " BEFORE paying for the method call and the CONV string. The vast
      " majority of fields are clean, so this skips ~99% of scan_value calls
      " (the dominant cost at scale). A control char can never be a trailing
      " blank, so NA on the raw field is a safe pre-filter. Only fields that
      " actually contain a control char reach scan_value (which recomputes
      " offsets / hex on the string form).
      IF <fld> NA iv_chars.
        CONTINUE.
      ENDIF.
      scan_value( EXPORTING iv_row     = iv_row
                            iv_keyinfo = ``
                            iv_field   = <field>
                            iv_value   = CONV string( <fld> )
                            iv_chars   = iv_chars
                  CHANGING  ct_hits    = lt_row_hits ).
    ENDLOOP.

    IF lt_row_hits IS INITIAL.
      RETURN.
    ENDIF.

    DATA(lv_keyinfo) = build_keyinfo( is_data       = is_data
                                      it_keys       = it_keys
                                      iv_check_clnt = iv_check_clnt ).
    LOOP AT lt_row_hits ASSIGNING FIELD-SYMBOL(<h>).
      <h>-keyinfo = lv_keyinfo.
    ENDLOOP.
    APPEND LINES OF lt_row_hits TO ct_hits.
  ENDMETHOD.


  METHOD scan_table.
    IF it_data IS INITIAL OR it_fields IS INITIAL.
      RETURN.
    ENDIF.

    " Pre-filter client (CLNT) key fields once to avoid redundant RTTI on each row
    DATA(lt_clean_keys) = it_keys.
    IF lt_clean_keys IS NOT INITIAL.
      LOOP AT it_data ASSIGNING FIELD-SYMBOL(<first_row>).
        lt_clean_keys = filter_keys( is_data = <first_row>
                                     it_keys = it_keys ).
        EXIT.
      ENDLOOP.
    ENDIF.

    " Resolve the effective control-character set ONCE for the whole table
    " (not per row) and reuse it for every row.
    DATA(lv_chars) = build_scan_set( is_scope ).

    " Pre-resolve field names to 1-based integer component positions using the first row.
    " Direct index-based dereference (ASSIGN COMPONENT idx) bypasses string hash lookups.
    DATA lt_comp_map TYPE tt_comp_map.
    LOOP AT it_data ASSIGNING FIELD-SYMBOL(<sample_row>).
      DATA(lr_typedescr) = cl_abap_typedescr=>describe_by_data( <sample_row> ).
      IF lr_typedescr->kind = cl_abap_typedescr=>kind_struct.
        DATA(lr_struct) = CAST cl_abap_structdescr( lr_typedescr ).
        DATA(lt_components) = lr_struct->get_components( ).
        LOOP AT it_fields ASSIGNING FIELD-SYMBOL(<fld_name>). "#EC CI_NESTED
          DATA(lv_fname) = to_upper( <fld_name> ).
          READ TABLE lt_components TRANSPORTING NO FIELDS WITH KEY name = lv_fname.
          IF sy-subrc = 0.
            APPEND VALUE #( index = sy-tabix name = <fld_name> ) TO lt_comp_map.
          ENDIF.
        ENDLOOP.
      ENDIF.
      EXIT.
    ENDLOOP.

    DATA(lv_row) = 0.
    IF lt_comp_map IS NOT INITIAL.
      LOOP AT it_data ASSIGNING FIELD-SYMBOL(<row_idx>).
        lv_row = lv_row + 1.
        scan_row_by_index( EXPORTING is_data     = <row_idx>
                                     it_comp_map = lt_comp_map
                                     it_keys     = lt_clean_keys
                                     iv_row      = lv_row
                                     iv_chars    = lv_chars
                           CHANGING  ct_hits     = rt_hits ).
      ENDLOOP.
    ELSE.
      LOOP AT it_data ASSIGNING FIELD-SYMBOL(<row>).
        lv_row = lv_row + 1.
        scan_row_resolved( EXPORTING is_data       = <row>
                                     it_fields     = it_fields
                                     it_keys       = lt_clean_keys
                                     iv_row        = lv_row
                                     iv_check_clnt = abap_false
                                     iv_chars      = lv_chars
                           CHANGING  ct_hits       = rt_hits ).
      ENDLOOP.
    ENDIF.
  ENDMETHOD.


  METHOD scan_value.

    " Fast-path: if string has no control characters, return immediately
    IF iv_value NA iv_chars.
      RETURN.
    ENDIF.

    DATA(lv_len) = strlen( iv_value ).
    DATA(lv_offset) = 0.

    WHILE lv_offset < lv_len.
      " Use CA on remaining substring: sy-fdpos jumps directly to the next hit
      IF iv_value+lv_offset CA iv_chars.
        DATA(lv_hit_offset) = lv_offset + sy-fdpos.
        DATA(lv_c) = iv_value+lv_hit_offset(1).
        DATA(lv_cp) = cl_abap_conv_out_ce=>uccp( lv_c ).
        DATA(lv_int) = CONV i( lv_cp ).

        " Compact 0xNN for points up to 0xFF (keeps 0x0A/0x7F/0x9B form);
        " full 0xNNNN for higher points (NBSP is 0xA0, but ZWSP..BOM are
        " 0x200B..0xFEFF, whose low byte alone would be misleading).
        DATA(lv_hex) = COND string(
          WHEN lv_int <= 255 THEN |0x{ lv_cp+1(1) }|
          ELSE |0x{ lv_cp }| ).

        APPEND VALUE #( rownum  = iv_row
                        keyinfo = iv_keyinfo
                        field   = iv_field
                        offset  = lv_hit_offset
                        hexcode = lv_hex
                        descr   = cp_descr( lv_int )
                        value   = iv_value ) TO ct_hits.

        " Jump past the found control character
        lv_offset = lv_hit_offset + 1.
      ELSE.
        " No more control characters in the remainder of the string
        EXIT.
      ENDIF.
    ENDWHILE.
  ENDMETHOD.
ENDCLASS.
