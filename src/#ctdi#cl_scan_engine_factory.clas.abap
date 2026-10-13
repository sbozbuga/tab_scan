class /CTDI/CL_SCAN_ENGINE_FACTORY definition
  public
  final
  create private .

public section.

    "! Resolve and instantiate the appropriate scanner engine strategy.
    "! Today (ECC 7.50 AnyDB): Returns Universal Parallel Engine.
    "! Future (SAP HANA): Resolves HANA Pushdown engine when sy-dbsys = 'HDB'.
  class-methods GET_ENGINE
    importing
      !IV_FORCE_UNIVERSAL type ABAP_BOOL default ABAP_FALSE
    returning
      value(RO_ENGINE) type ref to /CTDI/IF_SCAN_ENGINE .
  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.



CLASS /CTDI/CL_SCAN_ENGINE_FACTORY IMPLEMENTATION.


  METHOD get_engine.
    " 1. Explicit override (e.g. unit testing or troubleshooting)
    IF iv_force_universal = abap_true.
      ro_engine = NEW /ctdi/cl_scan_engine_univ( ).
      RETURN.
    ENDIF.

    " 2. Dynamic resolution for SAP HANA (active when migrating next year)
    IF sy-dbsys = 'HDB'.
      TRY.
          DATA lv_hana_cls TYPE seoclsname VALUE '/CTDI/CL_SCAN_ENGINE_HANA'.
          DATA lr_obj TYPE REF TO object.
          CREATE OBJECT lr_obj TYPE (lv_hana_cls).
          ro_engine ?= lr_obj.
          RETURN.
        CATCH cx_root.
          " Safe fallback to universal engine if HANA engine is not yet deployed
      ENDTRY.
    ENDIF.

    " 3. Standard Universal Engine for AnyDB (Oracle, DB2, MSSQL, ASE)
    ro_engine = NEW /ctdi/cl_scan_engine_univ( ).
  ENDMETHOD.
ENDCLASS.
