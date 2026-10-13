# Checkpoint & Resume Scenario Specification

This document details the mechanics, persistence architecture, and execution flow of the **Checkpoint & Resumption Workflow** implemented for the `/CTDI/` Enterprise Table Scanner.

---

## 1. Resume Lifecycle Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    actor User as User / Batch Job
    participant UI as /CTDI/CNTRL_CHECK
    participant Ckpt as /CTDI/CL_SCAN_CHECKPOINT
    participant Partitioner as /CTDI/CL_KEY_PARTITIONER
    participant Engine as Parallel Scan Engine (/CTDI/CL_SCAN_PARALLEL)
    participant DB as SAP Database (INDX & Target Table)

    Note over User,DB: Phase 1: Initial Scan Interruption / Failure
    User->>UI: Run Scan on Table VTRKH (e.g. 5,000,000 rows)
    UI->>Ckpt: create_run('VTRKH')
    Ckpt->>DB: EXPORT ckpt(status='R') TO DATABASE INDX(SC)
    Ckpt->>DB: EXPORT id TO DATABASE INDX(SC) ID 'LAT_VTRKH'
    UI->>Engine: Run parallel slices (50k rows per slice)
    Engine->>Engine: Slices 1..30 complete successfully (1.5M rows)
    Note over Engine: Slice 31 encounters TIME_OUT or Cancelled in SM37
    Engine-->>UI: Abort with partial result (last_end_key = '0015000000')
    UI->>Ckpt: save_checkpoint(status='E', last_end_key='0015000000')
    Ckpt->>DB: Persisted to INDX(SC)

    Note over User,DB: Phase 2: Resumption (p_res = 'X')
    User->>UI: Re-execute with p_res = 'X' (Resume Checkbox)
    UI->>Ckpt: get_latest_for_table('VTRKH')
    Ckpt->>DB: IMPORT id FROM INDX(SC) ID 'LAT_VTRKH'
    Ckpt->>DB: IMPORT ckpt FROM INDX(SC) ID 'RUN_<UUID>'
    Ckpt-->>UI: Returns ls_ckpt (status='E', last_end_key='0015000000')
    
    UI->>Partitioner: build_resume_where(last_end_key)
    Partitioner-->>UI: Returns "VBELN > '0015000000'"
    UI->>UI: Append "VBELN > '0015000000'" to WHERE filter
    
    UI->>Engine: Execute remaining scan (1.5M to 5.0M)
    Engine->>DB: Query slices starting strictly AFTER '0015000000'
    Engine-->>UI: Remaining rows scanned cleanly (zero duplicate work)
    UI->>Ckpt: save_checkpoint(status='C', last_end_key=final_key)
    Ckpt->>DB: Update INDX(SC) with status = 'C' (Completed)
    UI->>User: Displays combined findings in SALV Grid
```

---

## 2. Checkpoint Decision Flowchart

```mermaid
flowchart TD
    Start([User / Batch Execution]) --> CheckParam{"p_res = 'X'?"}
    
    CheckParam -->|No - Fresh Run| CreateRun["Call create_run: Generate UUID & Mark status = 'R'"]
    CheckParam -->|Yes - Resume Mode| ReadLatest["Query get_latest_for_table on INDX"]
    
    ReadLatest --> CheckStatus{"Checkpoint Found & Status in (R, E)?"}
    CheckStatus -->|No Checkpoint| CreateRun
    CheckStatus -->|Valid Checkpoint| HasKey{"last_end_key Present?"}
    
    HasKey -->|No| CreateRun
    HasKey -->|Yes| BuildWhere["Call /CTDI/CL_KEY_PARTITIONER=>build_resume_where"]
    
    BuildWhere --> InjectWhere["Append boundary predicate to lt_where:<br>Single Key: VBELN > '0015000000'<br>Composite: KUNNR > '1000' OR (KUNNR = '1000' AND VKORG > '01')"]
    
    CreateRun --> ExecScan
    InjectWhere --> ExecScan["Execute Scan via Strategy Engine"]
    
    ExecScan --> ScanResult{"Scan Status"}
    ScanResult -->|Interrupted / Timeout| SaveError["save_checkpoint: status = 'E', last_end_key = highest slice key"]
    ScanResult -->|Completed Cleanly| SaveComplete["save_checkpoint: status = 'C', last_end_key = final key"]
    
    SaveError --> Finish([Interrupted State Preserved in INDX])
    SaveComplete --> FinishClean([Run Finalized in INDX])
```

---

## 3. Technical Implementation Details

### 3.1 Persistent Storage Mechanism
All run states and key boundaries are stored in **SAP Cluster Table `INDX`** in relational area **`SC`** (Scan Checkpoint) via [`/CTDI/CL_SCAN_CHECKPOINT`](file:///d:/_Repos/bs_util/src/%23ctdi%23cl_scan_checkpoint.clas.abap):
- **Checkpoint Data**: Exported with ID `RUN_<UUID>`:
  ```abap
  EXPORT ckpt = is_checkpoint TO DATABASE indx(sc) ID lv_id.
  ```
- **Table Index Pointer**: Exported with ID `LAT_<TABNAME>` (e.g. `LAT_VTRKH`) to point to the latest run ID:
  ```abap
  EXPORT id = rv_run_id TO DATABASE indx(sc) ID lv_lat_id.
  ```

### 3.2 State Structure (`ts_checkpoint`)
```abap
TYPES:
  BEGIN OF ts_checkpoint,
    run_id       TYPE sysuuid_c32,                          " 32-character UUID
    tabname      TYPE tabname,                              " Target table name
    last_end_key TYPE /ctdi/cl_key_partitioner=>tt_keyval,  " Last processed key boundary
    rows_scanned TYPE i,                                    " Total rows processed so far
    hits_count   TYPE i,                                    " Violations accumulated so far
    status       TYPE c LENGTH 1,                           " 'R'=Running, 'C'=Completed, 'E'=Error
    tstamp       TYPE timestamp,                            " Last state timestamp
  END OF ts_checkpoint.
```

### 3.3 Dynamic SQL WHERE Clause Construction
When resuming, [`/CTDI/CL_KEY_PARTITIONER=>build_resume_where`](file:///d:/_Repos/bs_util/src/%23ctdi%23cl_key_partitioner.clas.abap) generates an Open SQL lexicographic boundary filter:
- **Single Key Field**:
  ```sql
  VBELN > '0015000000'
  ```
- **Multi-Field Composite Primary Key** (`KUNNR`, `VKORG`, `VTWEG`):
  ```sql
  ( KUNNR > '0000100000' OR 
    ( KUNNR = '0000100000' AND VKORG > '1000' ) OR 
    ( KUNNR = '0000100000' AND VKORG = '1000' AND VTWEG > '10' ) )
  ```

### 3.4 Zero Duplicate I/O Guarantee
Because the generated resume condition is passed into `lo_engine->execute( ... where = lt_where )`:
1. `probe_slices` runs keys-only probes on `WHERE (resume_predicate)`.
2. The database B-Tree / column-store primary key index immediately jumps past all already-processed rows.
3. Worker tasks only fetch and scan uninspected records.
