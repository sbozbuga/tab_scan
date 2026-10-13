class /CTDI/CL_SCAN_LOGGER definition
  public
  create public .

public section.

  constants C_DEFAULT_OBJECT type BALOBJ_D value '/CTDI/SCAN' ##NO_TEXT.
  constants C_DEFAULT_SUBOBJECT type BALSUBOBJ value 'RUN' ##NO_TEXT.

    "! Create or open an Application Log instance
  methods CONSTRUCTOR
    importing
      !IV_OBJECT type BALOBJ_D default C_DEFAULT_OBJECT
      !IV_SUBOBJECT type BALSUBOBJ default C_DEFAULT_SUBOBJECT
      !IV_EXTNUMBER type BALNREXT optional .
    "! Add informational message to log
  methods ADD_INFO
    importing
      !IV_TEXT type CSEQUENCE .
    "! Add warning message to log
  methods ADD_WARNING
    importing
      !IV_TEXT type CSEQUENCE .
    "! Add error message to log
  methods ADD_ERROR
    importing
      !IV_TEXT type CSEQUENCE .
    "! Save the application log to the database
  methods SAVE
    returning
      value(RV_SAVED) type ABAP_BOOL .
    "! Return in-memory formatted log lines
  methods GET_MESSAGES
    returning
      value(RT_MESSAGES) type STRING_TABLE .
  PROTECTED SECTION.
  PRIVATE SECTION.
    DATA mv_log_handle TYPE balloghndl .
    DATA mt_messages   TYPE string_table .

    METHODS add_msg
      IMPORTING
        !iv_msgty TYPE symsgty
        !iv_text  TYPE csequence .
ENDCLASS.



CLASS /CTDI/CL_SCAN_LOGGER IMPLEMENTATION.


  METHOD add_error.
    add_msg( iv_msgty = 'E' iv_text = iv_text ).
  ENDMETHOD.


  METHOD add_info.
    add_msg( iv_msgty = 'I' iv_text = iv_text ).
  ENDMETHOD.


  METHOD add_msg.
    DATA(lv_txt) = CONV string( iv_text ).
    APPEND |[{ iv_msgty }] { lv_txt }| TO mt_messages.

    " When running as background job, also stream to SM37 job log
    IF sy-batch = abap_true.
      MESSAGE lv_txt TYPE 'I'.
    ENDIF.

    IF mv_log_handle IS NOT INITIAL.
      DATA ls_msg TYPE bal_s_msg.
      ls_msg-msgty = iv_msgty.
      ls_msg-msgid = 'BL'.
      ls_msg-msgno = '001'.
      ls_msg-msgv1 = lv_txt(50).
      IF strlen( lv_txt ) > 50.
        ls_msg-msgv2 = lv_txt+50.
      ENDIF.
      CALL FUNCTION 'BAL_LOG_MSG_ADD'
        EXPORTING
          i_log_handle = mv_log_handle
          i_s_msg      = ls_msg
        EXCEPTIONS
          OTHERS       = 0.
    ENDIF.
  ENDMETHOD.


  METHOD add_warning.
    add_msg( iv_msgty = 'W' iv_text = iv_text ).
  ENDMETHOD.


  METHOD constructor.
    DATA ls_log TYPE bal_s_log.
    ls_log-object    = iv_object.
    ls_log-subobject = iv_subobject.
    ls_log-extnumber = COND #( WHEN iv_extnumber IS NOT INITIAL
                               THEN iv_extnumber
                               ELSE |Scan_{ sy-datum }_{ sy-uzeit }| ).
    ls_log-aldate    = sy-datum.
    ls_log-altime    = sy-uzeit.
    ls_log-aluser    = sy-uname.
    ls_log-alprog    = sy-repid.

    CALL FUNCTION 'BAL_LOG_CREATE'  "#EC "#EC CI_SUBRC
      EXPORTING
        i_s_log      = ls_log
      IMPORTING
        e_log_handle = mv_log_handle
      EXCEPTIONS
        OTHERS       = 1.
  ENDMETHOD.


  METHOD get_messages.
    rt_messages = mt_messages.
  ENDMETHOD.


  METHOD save.
    IF mv_log_handle IS INITIAL.
      rv_saved = abap_false.
      RETURN.
    ENDIF.

    DATA lt_handles TYPE bal_t_logh.
    INSERT mv_log_handle INTO TABLE lt_handles.

    CALL FUNCTION 'BAL_DB_SAVE'
      EXPORTING
        i_t_log_handle = lt_handles
      EXCEPTIONS
        OTHERS         = 1.

    rv_saved = xsdbool( sy-subrc = 0 ).
  ENDMETHOD.
ENDCLASS.
