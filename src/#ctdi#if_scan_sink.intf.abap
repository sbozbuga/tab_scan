interface /CTDI/IF_SCAN_SINK
  public .

  "! Receives one streamed package of rows during a full-table scan.
  "! The reader opens a cursor and calls this once per PACKAGE SIZE block;
  "! the implementer scans the block and accumulates hits. Returning
  "! rv_continue = abap_false tells the reader to stop the sweep early
  "! (e.g. a hit ceiling was reached).
  "!
  "! IMPORTANT - handle_package runs INSIDE AN OPEN DATABASE CURSOR
  "! (SELECT ... PACKAGE SIZE ... ENDSELECT). While it runs, the
  "! implementation MUST NOT do anything that commits the database LUW or
  "! yields the work process, or the next fetch dumps with
  "! DBIF_RSQL_INVALID_CURSOR. In particular, do NOT:
  "!   - COMMIT WORK / ROLLBACK WORK (explicit or implicit),
  "!   - synchronous or background RFC (CALL FUNCTION ... DESTINATION),
  "!   - SAPGUI_PROGRESS_INDICATOR / cl_progress_indicator in dialog,
  "!   - WAIT, or information / warning messages (MESSAGE 'I'/'W').
  "! Keep the handler to pure in-memory work (scan + accumulate).
  "! @parameter ir_data     | REF to the package data table (reader-owned,
  "!                          valid only for the duration of the call)
  "! @parameter iv_base_row | number of rows already processed before this
  "!                          package, so the handler can stamp an ABSOLUTE
  "!                          row number (iv_base_row + relative index)
  "! @parameter rv_continue | abap_true = keep streaming, abap_false = stop
  methods handle_package
    importing
      !ir_data           type ref to data
      !iv_base_row       type i
    returning
      value(rv_continue) type abap_bool.

endinterface.
