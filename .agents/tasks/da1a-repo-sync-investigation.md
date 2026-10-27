# DA1A repository synchronization investigation

## Summary answer

The mapped ABAP repository content is synchronized with the active objects found in SAP system **DA1A**, client 100 (ECC/SAP_BASIS 750), with the verification limits stated below.

- **19 mapped SAP entries found and matching:** 17 code objects (3 interfaces, 3 reports, 11 classes), table `/CTDI/SCAN_HITS`, and package `/CTDI/BS_SCAN`.
- **Source differences found:** 0.
- **Mapped objects missing in DA1A:** 0.
- **Activation/active DDIC evidence:** all retrieved OO metadata has `STATE = 1`; the table is active (`AS4LOCAL = A`, `CONTFLAG = A`). Active source line totals match the local source line totals for all 17 code objects.
- **Transport/version state:** the objects are currently locked in transport `DA1K991659` (description `SBO20261006 RL Problems in Exports for SQL 2610-175`). Version history shows recent active versions, mostly dated 12–13 October 2026, across transports `DA1K991659`, `DA1K991660`, and `DA1K991700`.
- **Not independently comparable through the available ABAP FS source APIs:** the namespace serializer metadata (`#ctdi#.nspc.xml`), the nine separate local ABAP Unit test-include files, the repository root `abapgit.xml`, and `test.txt`. These are not evidence of a DA1A source mismatch; they are either auxiliary/non-SAP files or metadata/source facets not exposed by the read-only object-source calls.

The conclusion is therefore **in sync for the mapped active ABAP objects and represented metadata**, not a claim that every byte of every abapGit serializer artifact (especially program text-pool long texts and namespace licensing fields) was independently round-tripped through ABAP FS.

## Scope and local inventory

Repository root: `C:\TEMP\repos\tab_scan`  
ABAP source root: `C:\TEMP\repos\tab_scan\src`  
Repository configuration in `C:\TEMP\repos\tab_scan\abapgit.xml` sets `STARTING_FOLDER` to `/src/` and `FOLDER_LOGIC` to `PREFIX`.

The local inventory contains 47 files:

- 17 main ABAP object sources: 3 interfaces, 3 executable programs, and 11 classes.
- 9 class test includes: reader, remediator, parallel, logger, HANA engine, factory, checkpoint, key partitioner, and scanner.
- 20 XML files: 17 object metadata files, table metadata, package metadata, and namespace metadata.
- 1 auxiliary `test.txt` file.

Filename-to-object mapping follows the abapGit serializers and the XML names. Examples are explicit in the repository:

- `C:\TEMP\repos\tab_scan\src\#ctdi#if_scan_sink.intf.abap` -> `/CTDI/IF_SCAN_SINK`, type `INTF`.
- `C:\TEMP\repos\tab_scan\src\#ctdi#cntrl_check.prog.abap` -> `/CTDI/CNTRL_CHECK`, type `PROG`.
- `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_parallel.clas.abap` -> `/CTDI/CL_SCAN_PARALLEL`, type `CLAS`.
- `C:\TEMP\repos\tab_scan\src\#ctdi#scan_hits.tabl.xml` explicitly names `/CTDI/SCAN_HITS` in `DD02V-TABNAME`.
- `C:\TEMP\repos\tab_scan\src\package.devc.xml` is the package serializer; DA1A search resolves it to `/CTDI/BS_SCAN`.
- `C:\TEMP\repos\tab_scan\src\#ctdi#.nspc.xml` explicitly names namespace `/CTDI/`.

The README inventory is broader than the actual `src` file set in places (for example, it mentions additional reports and function groups that are not present under `src`); those README-only names were not included in this scope because the request was all files actually under `src`.

## Evidence and comparison method

### DA1A connection and object resolution

ABAP FS reported DA1A as:

- System type: ECC
- Release: 750
- Client: 100 (`CTDI ERP 6.04 Produktion`)
- Time zone: CET

DA1A object search and object information resolved every mapped code object to package `/CTDI/BS_SCAN`. `/CTDI/BS_SCAN` itself exists as `DEVC/K`; `/CTDI/SCAN_HITS` exists as `TABL/DT`.

For every code object, ABAP FS active source was retrieved or its authoritative active object source/version information was queried. The local line totals were obtained from the files read under `src`; DA1A line totals came from `abapfs_get_object_info` and `abapfs_get_object_source`. The totals are identical for every mapped main source file. The active source opening lines were also checked for the interfaces, reports, classes, and the key classes. No source mismatch was observed.

DA1A inactive-source requests returned the same source lengths and opening lines as active requests. The ABAP FS documentation notes that inactive falls back to active when no inactive version exists, so this establishes that no separate inactive difference surfaced, but it cannot prove the absence of a hidden inactive version beyond what the API exposes.

### Per-object source status

All rows below are **in sync** for active source. `DA1A lines` is the authoritative SAP object-source total; `Local lines` is the corresponding local file total. The matching totals are useful evidence, but SAP did not expose a repository-file SHA-256 through the read-only calls.

| Local file | SAP object/type | Local lines | DA1A lines | Status and evidence |
|---|---|---:|---:|---|
| `C:\TEMP\repos\tab_scan\src\#ctdi#if_scan_sink.intf.abap` | `/CTDI/IF_SCAN_SINK` / `INTF/OI` | 33 | 33 | **in sync**; live source contains `handle_package`, matching the local interface contract. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#if_scan_engine.intf.abap` | `/CTDI/IF_SCAN_ENGINE` / `INTF/OI` | 27 | 27 | **in sync**; live source contains `ts_scan_params` and `execute`. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#if_inspection_rule.intf.abap` | `/CTDI/IF_INSPECTION_RULE` / `INTF/OI` | 53 | 53 | **in sync**; live source contains `ts_violation`, `inspect_row`, `inspect_table`, and `get_db_filter`. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cntrl_review.prog.abap` | `/CTDI/CNTRL_REVIEW` / `PROG/P` | 321 | 321 | **in sync**; active source begins with the same report header and worklist-console definition. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cntrl_check_v2.prog.abap` | `/CTDI/CNTRL_CHECK_V2` / `PROG/P` | 1062 | 1062 | **in sync**; active source contains the four-zone selection flow and scanner integration. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cntrl_check.prog.abap` | `/CTDI/CNTRL_CHECK` / `PROG/P` | 1177 | 1177 | **in sync**; active source contains the local/RFC read paths, scope validation, persistence, and output flow. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cl_table_reader.clas.abap` | `/CTDI/CL_TABLE_READER` / `CLAS/OC` | 548 | 548 | **in sync**; live source contains `READ`, `READ_IN_PACKAGES`, `READ_CHUNK`, `PROBE_SLICES`, and RFC handling. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cl_table_metadata.clas.abap` | `/CTDI/CL_TABLE_METADATA` / `CLAS/OC` | 170 | 170 | **in sync**; live source contains DDIC projection, authorization, key, and scan-field methods. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_remediator.clas.abap` | `/CTDI/CL_SCAN_REMEDIATOR` / `CLAS/OC` | 378 | 378 | **in sync**; live source contains `PERSIST_HITS`, `APPLY_ROW`, `SIMULATE`, and `SKIP_ROW`. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_parallel.clas.abap` | `/CTDI/CL_SCAN_PARALLEL` / `CLAS/OC` | 448 | 448 | **in sync**; live source contains binary packet serialization, slice execution, and adaptive sizing. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_logger.clas.abap` | `/CTDI/CL_SCAN_LOGGER` / `CLAS/OC` | 139 | 139 | **in sync**; live source contains application-log construction, message methods, and `SAVE`. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_engine_univ.clas.abap` | `/CTDI/CL_SCAN_ENGINE_UNIV` / `CLAS/OC` | 37 | 37 | **in sync**; live source delegates through `/CTDI/IF_SCAN_ENGINE~EXECUTE`. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_engine_hana.clas.abap` | `/CTDI/CL_SCAN_ENGINE_HANA` / `CLAS/OC` | 81 | 81 | **in sync**; live source contains HDB detection, rule-filter handling, and universal fallback. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_engine_factory.clas.abap` | `/CTDI/CL_SCAN_ENGINE_FACTORY` / `CLAS/OC` | 48 | 48 | **in sync**; live source contains forced-universal and HANA dynamic-resolution branches. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_checkpoint.clas.abap` | `/CTDI/CL_SCAN_CHECKPOINT` / `CLAS/OC` | 136 | 136 | **in sync**; live source contains INDX checkpoint create/save/read/clear methods. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cl_key_partitioner.clas.abap` | `/CTDI/CL_KEY_PARTITIONER` / `CLAS/OC` | 223 | 223 | **in sync**; live source contains resume/until predicates and keys-only `PROBE_SLICES`. |
| `C:\TEMP\repos\tab_scan\src\#ctdi#cl_cntrl_scanner.clas.abap` | `/CTDI/CL_CNTRL_SCANNER` / `CLAS/OC` | 802 | 802 | **in sync**; live source contains scope construction, control-character scanning, and sanitization. |

No row is classified as **differs** or **missing in DA1A**.

### DDIC table comparison

`C:\TEMP\repos\tab_scan\src\#ctdi#scan_hits.tabl.xml` was compared with authoritative DA1A DDIC data using read-only ABAP SQL queries:

- `DD02V` matched: `/CTDI/SCAN_HITS`, language E, `TRANSP`, client-dependent `X`, description `Scanner Findings and Remediation Worklist`, master language E, `CONTFLAG = A`, `EXCLASS = 1`.
- `DD09L` matched: `AS4LOCAL = A`, `TABKAT = 2`, `TABART = APPL0`, `BUFALLOW = N`.
- `DD03L` returned 17 active fields in the same order as the XML. The three key fields are `MANDT`, `RUN_ID`, and `ITEM_NO`; all rollnames and null/key attributes matched the XML. The remaining fields are `TABNAME`, `KEYINFO`, `KEY_WHERE`, `FIELDNAME`, `CODEPOINT`, `HIT_COUNT`, `ORIG_VALUE`, `CLEAN_VALUE`, `STATUS`, `MESSAGE`, `SCAN_USER`, `SCAN_TSTMP`, `APPLY_USER`, and `APPLY_TSTMP`.
- `DD02T` matched both local language texts: E `Scanner Findings and Remediation Worklist`; D `Scanner-Befunde und Bereinigungsvorrat`.

Table status: **in sync**, active. ABAP FS transport-status lookup is not supported for `TABL/DT`, so no transport-lock result is asserted for the table.

### Object XML metadata comparison

#### Interfaces

The three interface XML files under `src` contain the expected `VSEOINTERF` records. DA1A `VSEOINTERF` queried for all three matched the local `CLSNAME`, language E, descriptions, exposure 2, state 1, and Unicode X. Status: **in sync** for the exposed metadata.

#### Classes

DA1A `VSEOCLASS` was queried for all 11 classes. The following local XML fields matched live values: `CLSNAME`, `LANGU`, `DESCRIPT`, `STATE`, `CLSCCINCL`, `FIXPT`, `UNICODE`, and `WITH_UNIT_TESTS`.

Notable exact unit-test metadata matches:

- `WITH_UNIT_TESTS = X`: reader, remediator, parallel, logger, HANA engine, factory, checkpoint, key partitioner, and scanner.
- `WITH_UNIT_TESTS` initial: universal engine and table metadata.

This agrees with the nine separate local `*.clas.testclasses.abap` files and the two classes without test includes. Class XML status: **in sync** for the queried serializer fields. The extra `DESCRIPTIONS_SUB` entries in `#ctdi#cl_key_partitioner.clas.xml` were not independently exposed by the read-only ABAP FS metadata query.

#### Programs

DA1A `PROGDIR` matched the local XML for all three reports: `DBAPL = S`, `SUBC = 1`, `FIXPT = X`, and `UCCHECK = X`. Active source line totals also matched exactly.

The detailed `TPOOL` and `LONGTEXTS` records in the two check-report XML files were not independently returned by the available ABAP FS object-source or SQL endpoints (`D010T` was not available in this system). They are therefore **not independently verified byte-for-byte** here. No discrepancy was observed in the active program source or core `PROGDIR` metadata.

#### Table

The table XML is fully covered by the DDIC comparison above and is **in sync**.

#### Package

`C:\TEMP\repos\tab_scan\src\package.devc.xml` contains package text `Table scan` and component `HLB0009083`. DA1A package `/CTDI/BS_SCAN` exists; `TDEVCT` returned English text `Table scan`, and `TDEVC` returned component `HLB0009083`, namespace `/CTDI/`, parent `/CTDI/BS_UTIL`, delivery unit `HOME`, and software component `ZDA1`. The represented local package fields match. Package status: **in sync** for represented metadata.

#### Namespace and repository-root metadata

`C:\TEMP\repos\tab_scan\src\#ctdi#.nspc.xml` correctly declares namespace `/CTDI/`, and all mapped DA1A objects resolve under that namespace. ABAP FS object search/source APIs used here do not expose an `NSPC` object or the namespace replacement-license serializer fields, so this file is **unable to verify completely**, not a reported difference.

`C:\TEMP\repos\tab_scan\abapgit.xml` is repository configuration, not a SAP object. It was read and validated for the `/src/` prefix but has no DA1A object mapping. Status: **not applicable**.

### Local test includes and auxiliary file

The nine local test includes are:

- `C:\TEMP\repos\tab_scan\src\#ctdi#cl_table_reader.clas.testclasses.abap`
- `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_remediator.clas.testclasses.abap`
- `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_parallel.clas.testclasses.abap`
- `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_logger.clas.testclasses.abap`
- `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_engine_hana.clas.testclasses.abap`
- `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_engine_factory.clas.testclasses.abap`
- `C:\TEMP\repos\tab_scan\src\#ctdi#cl_scan_checkpoint.clas.testclasses.abap`
- `C:\TEMP\repos\tab_scan\src\#ctdi#cl_key_partitioner.clas.testclasses.abap`
- `C:\TEMP\repos\tab_scan\src\#ctdi#cl_cntrl_scanner.clas.testclasses.abap`

ABAP FS exposes the class main source through `source/main`, not the separate abapGit test-include stream. Searching the live main sources found no `ltcl_` test classes, which is expected for a separate test include and is not evidence that the tests are absent in SAP. The class `WITH_UNIT_TESTS` metadata matches the local XML. These nine files are therefore **unable to verify independently as separate source files**, while their owning class metadata is in sync.

`C:\TEMP\repos\tab_scan\src\test.txt` contains `test` and has no SAP object/type mapping. Status: **not applicable**.

## Activation, versions, and transport state

- All 11 class metadata records returned `STATE = 1`; all three interface metadata records returned `STATE = 1`.
- `/CTDI/SCAN_HITS` is active in `DD02V`/`DD09L` (`CONTFLAG = A`, `AS4LOCAL = A`).
- Active and inactive source requests returned equal source totals and matching opening lines for every code object. Because the API may return active source when no inactive version exists, no separate inactive change was established.
- Version histories were available for all 17 code objects. Examples of latest active version evidence include `/CTDI/CL_TABLE_READER` on 13 October 2026 14:11, `/CTDI/CL_SCAN_REMEDIATOR` on 13 October 2026 14:19, `/CTDI/CL_KEY_PARTITIONER` on 13 October 2026 14:10, and `/CTDI/CNTRL_REVIEW` on 13 October 2026 14:19. The remaining objects have latest versions dated 12 October 2026, with the transport/title information shown in DA1A version history.
- Read-only transport-status checks for all 17 code objects and `/CTDI/BS_SCAN` returned `locked` with transport `DA1K991659`. This is a current SAP workbench lock, not a local-vs-SAP content difference. The table transport-status operation was explicitly unsupported by the ABAP FS endpoint.

## Conclusions

1. The local ABAP implementation represented by the 17 main source files is present in DA1A and matches the active SAP source totals and inspected source content. There is no evidence of local source drift, missing SAP objects, or active DDIC drift.
2. `/CTDI/SCAN_HITS` is fully synchronized at the field, key, table-class, technical-setting, activation, and English/German text levels.
3. Core interface, class, program, and package metadata matches DA1A. The only unresolved areas are serializer facets that the available read-only APIs do not expose: namespace replacement-license metadata, separate test-include source streams, detailed program text-pool/long-text records, and repository-only configuration.
4. All mapped code objects are currently locked by SAP transport `DA1K991659`; any future synchronization operation should account for that lock and must not overwrite or activate objects without the appropriate transport decision.

## Recommendations

- If byte-for-byte audit evidence is required, export the active SAP source and serializer metadata through an approved read-only abapGit/ADT export, normalize line endings/encoding, and compare SHA-256 hashes against the local files. The current ABAP FS source response does not provide a SAP-side hash.
- Separately verify program `TPOOL`/`LONGTEXTS`, namespace `REPLICENSE`/namespace texts, and the nine test includes using a read-only abapGit export or the corresponding SAP repository views. This is a completeness enhancement, not a corrective action indicated by this investigation.
- Do not edit, activate, transport, or restart anything based solely on this report; the investigation made no SAP or code changes.
