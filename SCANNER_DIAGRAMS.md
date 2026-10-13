# Enterprise Table Scanner - Architecture & UML Diagrams

This document contains the complete UML diagram specifications for the `/CTDI/` Table Scanner Architecture Modernization in `bs_util`.

---

## 1. UML Class Diagram (Domain Model & Design Patterns)

The architecture leverages the **Strategy Pattern** for database adaptability, the **Factory Pattern** for engine resolution, and **Separation of Concerns** across data inspection, partitioning, and governance.

```mermaid
classDiagram
    direction TB

    class IF_SCAN_ENGINE["/CTDI/IF_SCAN_ENGINE"] {
        <<interface>>
        +execute(is_params, ii_rule) ts_result
    }

    class CL_SCAN_ENGINE_FACTORY["/CTDI/CL_SCAN_ENGINE_FACTORY"] {
        +get_engine(iv_force_univ) IF_SCAN_ENGINE$
    }

    class CL_SCAN_ENGINE_UNIV["/CTDI/CL_SCAN_ENGINE_UNIV"] {
        +execute(is_params, ii_rule) ts_result
    }

    class CL_SCAN_ENGINE_HANA["/CTDI/CL_SCAN_ENGINE_HANA"] {
        +execute(is_params, ii_rule) ts_result
    }

    IF_SCAN_ENGINE <|.. CL_SCAN_ENGINE_UNIV : Realizes
    IF_SCAN_ENGINE <|.. CL_SCAN_ENGINE_HANA : Realizes
    CL_SCAN_ENGINE_FACTORY ..> IF_SCAN_ENGINE : Creates

    class IF_INSPECTION_RULE["/CTDI/IF_INSPECTION_RULE"] {
        <<interface>>
        +get_rule_id() string
        +inspect_row(is_data, it_fields, it_keys) tt_violation
        +inspect_table(it_data, it_fields, it_keys) tt_violation
        +get_db_filter(it_fields) string
    }

    class CL_CNTRL_SCANNER["/CTDI/CL_CNTRL_SCANNER"] {
        +scan_table(it_data, it_fields, it_keys, is_scope) tt_hit$
        +scan_pairs(it_pairs, is_scope) tt_hit$
        +sanitize(iv_val: string) string$
        +inspect_row(is_data, it_fields, it_keys) tt_violation
        +inspect_table(it_data, it_fields, it_keys) tt_violation
        +get_db_filter(it_fields) string
    }

    IF_INSPECTION_RULE <|.. CL_CNTRL_SCANNER : Realizes

    class CL_TABLE_METADATA["/CTDI/CL_TABLE_METADATA"] {
        +scan_fields(ir_struct, iv_table, iv_start_col, iv_skip_check) tt_field
        +key_fields(ir_struct) tt_field
        +remote_width(ir_struct, it_fields) i
    }

    class CL_KEY_PARTITIONER["/CTDI/CL_KEY_PARTITIONER"] {
        +build_resume_where(is_after) string$
        +build_until_where(is_before) string$
        +probe_slices(iv_table, it_keyflds, iv_slices) tt_slice$
    }

    class CL_TABLE_READER["/CTDI/CL_TABLE_READER"] {
        -mo_metadata: CL_TABLE_METADATA
        -mo_partitioner: CL_KEY_PARTITIONER
        +read(iv_table, iv_max, iv_skip, iv_last, it_where, it_fields)
        +read_in_packages(iv_table, it_where, it_fields, ii_sink, iv_pkg_size)
        +read_remote(iv_dest, iv_table, it_fields, it_keys, it_where)
        +build_resume_where(is_after) string
        +probe_slices(iv_table, it_keyflds, iv_slices) tt_slice
    }

    CL_TABLE_READER *-- CL_TABLE_METADATA : Delegates
    CL_TABLE_READER *-- CL_KEY_PARTITIONER : Delegates

    class CL_SCAN_LOGGER["/CTDI/CL_SCAN_LOGGER"] {
        -mv_log_handle: balloghndl
        +constructor(iv_object, iv_subobject, iv_extnumber)
        +add_info(iv_text)
        +add_warning(iv_text)
        +add_error(iv_text)
        +save() abap_bool
    }

    class CL_SCAN_CHECKPOINT["/CTDI/CL_SCAN_CHECKPOINT"] {
        +create_run(iv_table) sysuuid_c32$
        +save_checkpoint(is_checkpoint)$
        +get_latest_for_table(iv_table) ts_checkpoint$
        +clear_checkpoint(iv_run_id)$
    }

    class CL_SCAN_REMEDIATOR["/CTDI/CL_SCAN_REMEDIATOR"] {
        +simulate(it_hits) ts_remedy_result$
        +execute(iv_table, it_hits, iv_simulation, io_logger) ts_remedy_result$
    }

    class CL_SCAN_PARALLEL["/CTDI/CL_SCAN_PARALLEL"] {
        +run_parallel_scan(iv_table, it_scanflds, it_keys, it_where, iv_pkg_size, iv_percentage, iv_group) ts_result$
        +calc_width(iv_percentage, iv_group) i$
        +serialize_packet(is_packet) xstring$
        +deserialize_hits(iv_raw) tt_hit$
    }

    CL_SCAN_ENGINE_UNIV --> CL_SCAN_PARALLEL : Drives
    CL_SCAN_ENGINE_UNIV --> CL_KEY_PARTITIONER : Partitions
    CL_SCAN_ENGINE_HANA --> CL_SCAN_ENGINE_UNIV : Fallback
```

---

## 2. UML Sequence Diagram: End-to-End Execution Flow

This diagram illustrates the lifecycle of a scan request initiated by a user or background job through `/CTDI/CNTRL_CHECK`.

```mermaid
sequenceDiagram
    autonumber
    actor User as User / Batch Job
    participant UI as "/CTDI/CNTRL_CHECK"
    participant Log as "/CTDI/CL_SCAN_LOGGER"
    participant Ckpt as "/CTDI/CL_SCAN_CHECKPOINT"
    participant Factory as "/CTDI/CL_SCAN_ENGINE_FACTORY"
    participant Engine as "/CTDI/IF_SCAN_ENGINE (Univ/HANA)"
    participant Driver as "/CTDI/CL_SCAN_PARALLEL"
    participant Worker as "Parallel DIA Tasks (RFC)"
    participant Rem as "/CTDI/CL_SCAN_REMEDIATOR"

    User->>UI: Execute (p_tab, p_par, p_log, p_res, p_rscan/p_rsim/p_rfix)
    
    opt p_log = abap_true
        UI->>Log: NEW(iv_extnumber = p_tab)
        Log-->>UI: Logger instance (SLG1 handle created)
    end

    opt p_res = abap_true (Resume Request)
        UI->>Ckpt: get_latest_for_table(p_tab)
        Ckpt-->>UI: Return last checkpoint (last_end_key)
        UI->>UI: Append build_resume_where(last_end_key) to lt_where
    end

    UI->>Ckpt: create_run(p_tab)
    Ckpt-->>UI: rv_run_id

    UI->>Factory: get_engine()
    Factory-->>UI: Engine instance (HANA or Universal based on sy-dbsys)

    UI->>Engine: execute(is_params, ii_rule)
    
    alt Database = SAP HANA (In-Memory Engine)
        Engine->>Engine: Evaluate rule->get_db_filter()
        opt Direct Pushdown Supported
            Engine->>Engine: SELECT keys WHERE filter (Column store RAM)
        end
    else Database = AnyDB (Universal Engine)
        Engine->>Driver: run_parallel_scan(...)
        Driver->>Driver: calc_width() via SPBT_GET_PP_INFO / TH_WP_INFO
        Driver->>Driver: probe_slices() via key partitioner
        
        loop For each wave of slices
            Driver->>Driver: serialize_packet() -> EXPORT TO DATA BUFFER
            Driver->>Worker: CALL FUNCTION ... STARTING NEW TASK
            Worker->>Worker: IMPORT FROM DATA BUFFER
            Worker->>Worker: Rule->inspect_table()
            Worker->>Worker: EXPORT hits TO DATA BUFFER
            Worker-->>Driver: Return task results
            Driver->>Driver: deserialize_hits()
        end
        Driver-->>Engine: Merged scan results
    end
    Engine-->>UI: Scan findings (hits, rows, status)

    UI->>Ckpt: save_checkpoint(run_id, status='C', hits, rows)
    opt p_log = abap_true
        UI->>Log: add_info("Scan complete")
        UI->>Log: save() (DB commit to BALHDR/BALDAT)
    end

    alt p_rsim = abap_true (Simulation Mode)
        UI->>Rem: simulate(gt_hits)
        Rem-->>UI: Before/after diffs
        UI->>UI: display_remediation_diffs() (SALV grid)
    else p_rfix = abap_true (Live Remediation)
        UI->>User: Confirmation popup (POPUP_TO_CONFIRM)
        User-->>UI: Confirmed
        UI->>Rem: execute(p_tab, gt_hits, iv_simulation=abap_false)
        Rem->>Rem: ENQUEUE_E_TABLE(p_tab)
        Rem->>Rem: Update cleansed database rows
        Rem->>Rem: DEQUEUE_E_TABLE(p_tab)
        Rem-->>UI: Remediation results
    else Default (Scan Only)
        UI->>UI: display_salv() (Standard hit list)
    end
```

---

## 3. UML Activity Diagram: Observability, Checkpointing & Remediation Workflow

```mermaid
flowchart TD
    Start([User / Batch Run]) --> CheckRFC{RFC or Local?}
    
    CheckRFC -->|Remote RFC| ExecRFC["Classic RFC_READ_TABLE Read"]
    CheckRFC -->|Local| InitLog["Initialize /CTDI/CL_SCAN_LOGGER"]

    InitLog --> CheckResume{p_res = 'X'?}
    CheckResume -->|Yes| FetchCkpt["Query /CTDI/CL_SCAN_CHECKPOINT"]
    FetchCkpt --> HasCkpt{Checkpoint Active?}
    HasCkpt -->|Yes| InjectResume["Inject Key Resume Predicate into WHERE"]
    HasCkpt -->|No| InitRun["Create New Run ID"]
    CheckResume -->|No| InitRun
    InjectResume --> ResolveEngine

    InitRun --> ResolveEngine["Call /CTDI/CL_SCAN_ENGINE_FACTORY"]
    ResolveEngine --> CheckHDB{sy-dbsys = 'HDB'?}
    
    CheckHDB -->|Yes| HanaEng["Run /CTDI/CL_SCAN_ENGINE_HANA"]
    CheckHDB -->|No| UnivEng["Run /CTDI/CL_SCAN_ENGINE_UNIV"]

    HanaEng --> HanaSuccess{Pushdown Succeeded?}
    HanaSuccess -->|No - Fallback| UnivEng
    HanaSuccess -->|Yes| ScanDone["Collect Findings"]
    UnivEng --> ScanDone

    ScanDone --> SaveCkpt["Save Final Checkpoint in INDX"]
    SaveCkpt --> SaveLog["Commit Application Log to SLG1"]

    SaveLog --> AnyHits{Violations Found?}
    AnyHits -->|No| ShowClean["Display Table Clean Message"]
    AnyHits -->|Yes| CheckMode{Selected Action Mode}

    CheckMode -->|p_rscan: Scan Only| ShowHits["Display Findings in SALV Grid"]
    CheckMode -->|p_rsim: Simulation| SimRem["Calculate Clean Diff Matrix"]
    SimRem --> ShowDiffGrid["Display Proposed Diffs in Dedicated SALV"]

    CheckMode -->|p_rfix: Live Fix| DialogCheck{Running in Dialog?}
    DialogCheck -->|Yes| Confirm["Display POPUP_TO_CONFIRM"]
    Confirm --> UserApproved{User Answer = Yes?}
    UserApproved -->|No| Cancel["Abort Remediation"]
    UserApproved -->|Yes| LockTable
    DialogCheck -->|No - Batch| LockTable["Call ENQUEUE_E_TABLE"]

    LockTable --> ApplyUpdate["Execute Sanitized Table UPDATE"]
    ApplyUpdate --> UnlockTable["Call DEQUEUE_E_TABLE"]
    UnlockTable --> LogAudit["Audit Log Remediation Count"]
    LogAudit --> Finish([Done])
    ShowClean --> Finish
    ShowHits --> Finish
    ShowDiffGrid --> Finish
    Cancel --> Finish
```

---

## 4. UML Component & Layered Architecture Diagram

```mermaid
graph TB
    subgraph UI_Layer["Presentation & Orchestration Layer"]
        Report["Report: /CTDI/CNTRL_CHECK"]
        Dynpro["Selection Screen & RZ12 F4"]
        SALV["SALV Grid: Hit List & Diff Viewer"]
    end

    subgraph Strategy_Layer["Strategy & Abstraction Layer"]
        Factory["/CTDI/CL_SCAN_ENGINE_FACTORY"]
        IEngine["«interface»<br>/CTDI/IF_SCAN_ENGINE"]
        IRule["«interface»<br>/CTDI/IF_INSPECTION_RULE"]
        ScannerRule["/CTDI/CL_CNTRL_SCANNER"]
    end

    subgraph Engine_Layer["Execution Engines"]
        UnivEngine["/CTDI/CL_SCAN_ENGINE_UNIV<br>(AnyDB + Universal)"]
        HanaEngine["/CTDI/CL_SCAN_ENGINE_HANA<br>(In-Memory Accelerator)"]
    end

    subgraph Access_Layer["Data Access & Partitioning Layer"]
        Metadata["/CTDI/CL_TABLE_METADATA"]
        Partitioner["/CTDI/CL_KEY_PARTITIONER"]
        Reader["/CTDI/CL_TABLE_READER (Facade)"]
    end

    subgraph IPC_Layer["Concurrency & IPC Layer"]
        ParallelDriver["/CTDI/CL_SCAN_PARALLEL"]
        BinaryBuffer["Binary Buffer IPC<br>(EXPORT/IMPORT DATA BUFFER)"]
        SPBT["SPBT Quota & DIA Process Monitoring"]
    end

    subgraph Gov_Layer["Governance & Observability Layer"]
        Logger["/CTDI/CL_SCAN_LOGGER<br>(SLG1 / BAL_*)"]
        Checkpoint["/CTDI/CL_SCAN_CHECKPOINT<br>(INDX Cluster Database)"]
        Remediator["/CTDI/CL_SCAN_REMEDIATOR<br>(ENQUEUE / Cleanse)"]
    end

    Report --> Factory
    Report --> Logger
    Report --> Checkpoint
    Report --> Remediator
    Report --> SALV
    Report --> Dynpro

    Factory --> IEngine
    UnivEngine -.->|Realizes| IEngine
    HanaEngine -.->|Realizes| IEngine
    HanaEngine -.->|Fallback| UnivEngine

    UnivEngine --> ParallelDriver
    UnivEngine --> Partitioner
    UnivEngine --> Metadata

    ParallelDriver --> BinaryBuffer
    ParallelDriver --> SPBT
    ParallelDriver --> ScannerRule
    ScannerRule -.->|Implements| IRule

    Reader --> Metadata
    Reader --> Partitioner
```

---

## 5. Checkpoint State Machine Diagram

```mermaid
stateDiagram-v2
    [*] --> Uninitialized

    Uninitialized --> Running : create_run(iv_table)
    note right of Running
        State persisted to INDX table.
        Stores RUN_ID, TABNAME, LAST_END_KEY.
    end note

    Running --> Running : save_checkpoint (wave update)
    Running --> Completed : Scan finishes cleanly (status = 'C')
    Running --> Error : Scan encounters abort/timeout (status = 'E')

    Error --> Resumed : User restarts with p_res = 'X'
    Resumed --> Running : Injects LAST_END_KEY resume WHERE

    Completed --> [*] : Run archived / cleared
```
