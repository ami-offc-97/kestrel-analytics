# Feed Contracts

Kestrel Provisions data platform. Landing zone documentation.

> **Status.** Partial. Maintained by the data analyst who left in March. Several fields are undocumented, one or more statements below are known to be wrong, and nobody has reviewed it since. Where this document and the data disagree, the data wins. Verify anything you intend to rely on.

---

## Landing zone layout

```
data/
  raw/
    pos_transactions/ingest_date=YYYY-MM-DD/part-*.parquet
    reefer_telemetry/dt=YYYY-MM-DD/part-*.parquet
    wms_scan_events/dt=YYYY-MM-DD/part-*.parquet
    erp_cdc/outlet_master/extract_date=YYYY-MM-DD/part-*.parquet
    erp_cdc/product_master/extract_date=YYYY-MM-DD/part-*.parquet
    erp_cdc/sales_order_header/extract_date=YYYY-MM-DD/part-*.parquet
  reference/
  _manifest/expected_partitions.csv
```

Partitions contain one or more part files. The number of part files per partition is a function of the ingestion job's parallelism and carries no business meaning.

---

## 1. `pos_transactions`

Point of sale lines from modern trade and e-commerce partners. Delivered nightly as newline JSON, converted to Parquet on landing. Partitioned by **ingest date**, which is the date the file landed, not the date the sale happened.

| Field | Notes |
|---|---|
| `txn_id`, `txn_line_no` | Together identify a line |
| `basket_id` | Groups lines into one shopper transaction |
| `outlet_code` | Joins to outlet master |
| `channel` | As captured at the till |
| `sku_code` | Joins to product master |
| `event_ts` | Timestamp of the sale |
| `qty` | Quantity sold |
| `unit_price` | Price per unit, exclusive of tax |
| `discount_amount`, `tax_amount` | Line level |
| `payment_mode`, `till_id`, `cashier_id` | Undocumented |
| `promo_code` | Nullable |
| `source_file` | Originating file name |

**Analyst note.** The partner collector guarantees at-least-once delivery. Finance were told about this in 2025 and the nightly script was never changed.

**Analyst note.** The feed layout changed in the fourth quarter of 2025 when the partner upgraded their platform. Consult the vendor release note, which nobody can now find.

## 2. `reefer_telemetry`

Temperature and location telemetry from refrigerated vehicles. Two device vendors, `THERMLOG` and `COLDEYE`, onboarded at different times under different contracts.

| Field | Notes |
|---|---|
| `device_id`, `vehicle_registration` | Device and vehicle |
| `telemetry_vendor` | `THERMLOG` or `COLDEYE` |
| `firmware_version` | Device firmware |
| `route_code`, `warehouse_code` | Assignment at time of reading |
| `gateway_id` | Ingestion gateway the reading arrived through |
| `reading_ts` | Device clock |
| `temp_value` | Temperature reading |
| `temp_unit` | Unit of `temp_value`. Populated by both vendors |
| `humidity_pct`, `door_open_flag`, `battery_pct` | Sensor state |
| `gps_lat`, `gps_lon` | Position |

Target band for chilled product is 2 to 8 degrees Celsius. An excursion is any reading above the band.

**Analyst note.** There was a known issue with one firmware line reporting an offset clock. It was believed to be fixed.

## 3. `wms_scan_events`

Handling scans from the warehouse management system. One row per scan.

| Field | Notes |
|---|---|
| `scan_id` | Unique per scan |
| `warehouse_code` | Site |
| `event_type` | `RECEIVE`, `PUTAWAY`, `PICK`, `PACK`, `STAGE`, `DISPATCH` |
| `order_number` | Joins to sales order header |
| `sku_code`, `batch_id`, `qty_cases` | What was handled |
| `pallet_id`, `dock_door` | Location |
| `operator_id`, `handheld_device` | Who and on what |
| `event_ts` | Scan time, site local |

**Analyst note.** Handhelds buffer scans when they lose signal in the chilled chambers and occasionally drop the buffer. Cycle time calculations should be treated as indicative.

## 4. `erp_cdc/*`

Change data capture from the ERP. One directory per source table. Every record carries three control columns.

| Field | Notes |
|---|---|
| `__op` | `I` insert, `U` update, `D` delete |
| `__op_ts` | Time the change was committed in the source |
| `__seq` | Monotonic sequence number assigned by the capture agent |
| `extract_date` | Partition. The date the extract file was produced |

**Analyst note.** Files are produced daily. Records within a file are not sorted. Taking the last record per key from the most recent file gives you current state.

### `outlet_master`
`outlet_code` is the primary key. Attributes include name, channel, format, city, route, warehouse, credit limit, credit terms, GST number, status. Attributes change over the life of an outlet.

### `product_master`
`sku_code` is the primary key. Attributes include name, category, brand, case pack, MRP, list price, GST rate, shelf life, chilled flag.

### `sales_order_header`
`order_number` is the primary key. An order is inserted once and updated as it moves through its lifecycle. Values include `order_value_gross`, `discount_amount`, `tax_amount` and `source_system`.

**Analyst note.** Finance raised a ticket in 2025 that order values from one of the three source systems do not agree with the invoiced amount. It was never closed out.

---

## 5. `reference/`

| File | Contents |
|---|---|
| `uom_conversion.csv` | SKU to eaches per case |
| `warehouse_master.csv` | Site attributes, region, timezone |
| `carrier_master.csv` | Carrier attributes and SLA hours |
| `fiscal_calendar.csv` | Kestrel's fiscal calendar. The financial year runs April to March |
| `legacy_finance_weekly_report.csv` | The weekly report published to the board today |

---

## 6. `_manifest/expected_partitions.csv`

Row counts and byte sizes per partition, as recorded by the ingestion job at write time. Intended for reconciliation. It has never actually been used for that.

---

## Open tickets at handover

- KP-3104: partner collector emits duplicates. Not remediated.
- KP-3119: partner feed schema changed. Downstream not updated.
- KP-3140: two telemetry vendors, different conventions. No normalisation layer.
- KP-3155: no point-in-time view of outlet attributes. Historical reporting uses today's values.
- KP-3168: nightly Finance script has no reconciliation step of any kind.
- KP-3172: gateway outages are invisible. Missing data looks like low volume.

Anything not on this list you will have to find yourself.
