# AIDE Take-Home Assignment Pack

**Kestrel Provisions: Analytical Foundation and Metric Layer**

## Contents

| File | Read order |
|---|---|
| `01_Assignment_Brief.docx` | 1. Start here |
| `01_Assignment_Brief.md` | Same brief, markdown |
| `02_Feed_Contracts.md` | 2. Source documentation. Partial, and partly wrong |
| `03_Working_With_The_Data.md` | 3. Sizes, reading, regenerating, rescaling |
| `generate_dataset.py` | The generator that produced the dataset |
| `data/raw/` | Four raw feeds, partitioned Parquet, ~10.3M rows |
| `data/reference/` | UOM, warehouse, carrier, fiscal calendar, legacy Finance report |
| `data/_manifest/` | Expected partition and row counts |

## Quick start

```bash
pip install duckdb pyarrow

duckdb -c "SELECT count(*) FROM read_parquet('data/raw/pos_transactions/*/*.parquet', union_by_name=true)"
```

## Regenerating

```bash
pip install numpy pandas pyarrow
python3 generate_dataset.py --scale 1  --out data      # reproduces the shipped data exactly
python3 generate_dataset.py --scale 10 --out data_10x  # ten times the volume
```

Seed is fixed at 20260811. Two runs at the same scale produce identical bytes.

All data is synthetic and generated for assessment purposes. Kestrel Provisions
and all named individuals are fictional.
