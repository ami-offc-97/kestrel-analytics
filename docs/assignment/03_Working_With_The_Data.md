# Working With The Data

Practical notes. Nothing here is a hint about what to build.

---

## Size and shape

Approximately 10.3 million rows at `--scale 1`, around 516 MB on disk as zstd Parquet.

| Feed | Rows |
|---|---|
| `pos_transactions` | 4,084,000 |
| `reefer_telemetry` | 3,714,871 |
| `wms_scan_events` | 1,496,000 |
| `erp_cdc/sales_order_header` | 963,307 |
| `erp_cdc/outlet_master` | 8,774 |
| `erp_cdc/product_master` | 3,536 |

Eighteen months, 1 January 2025 to 30 June 2026.

---

## Reading it

Anything that reads Parquet will work. DuckDB is the shortest path on a laptop.

```sql
INSTALL httpfs; -- not needed, everything is local

-- one partition
SELECT * FROM read_parquet('data/raw/pos_transactions/ingest_date=2026-03-15/*.parquet') LIMIT 10;

-- the whole feed, with the partition column materialised from the path
SELECT count(*) FROM read_parquet(
  'data/raw/pos_transactions/*/*.parquet',
  hive_partitioning = true
);
```

If a whole-feed read fails, read the error rather than reaching for a wider glob. It is telling you something.

Polars, Spark, pandas with pyarrow, or a Postgres load all work equally well. Pick what you can defend.

---

## Regenerating and rescaling

```bash
pip install numpy pandas pyarrow

# reproduce the shipped dataset exactly (fixed seed)
python3 generate_dataset.py --scale 1 --out data

# ten times the volume
python3 generate_dataset.py --scale 10 --out data_10x

# bound peak memory on a small machine
python3 generate_dataset.py --scale 10 --out data_10x --slice-rows 200000
```

Generation is sliced, so memory stays flat as scale rises. Scale 1 takes a few minutes on one core.

The seed is fixed. Two runs at the same scale produce identical bytes.

---

## Reconciliation

`data/_manifest/expected_partitions.csv` records what the ingestion job believes it wrote: feed, partition, file count, row count, bytes.

`data/reference/legacy_finance_weekly_report.csv` is what the business publishes today. The CFO has asked you to reconcile to it. Read section 2 of the assignment brief again before deciding what reconciling means.

---

## Timezones

`warehouse_master.csv` carries a `timezone` column for every site. Feeds do not all agree on what their timestamps mean. Check rather than assume.

---

## A note on scope

Ten million rows is not big data. It is deliberately small enough to work on a laptop and deliberately shaped like data that is not: partitioned, multi-file, multi-source, schema-inconsistent, late-arriving, and duplicated at source.

The interesting question is not whether your pipeline runs. It is whether the way you have built it would still be the right shape at a hundred times the volume, and whether you know which parts would not be.
