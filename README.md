# Kestrel Provisions — Analytical Foundation

## Prerequisites
- Python 3.x (conda environment recommended)
- Dependencies: duckdb, pyarrow, numpy, pandas

## Setup
1. Create and activate a Python environment (conda or venv)
2. Install dependencies:
   pip install duckdb pyarrow numpy pandas
3. Generate the raw dataset (not committed to this repo):
   python3 generate_dataset.py --scale 1 --out data
4. [pipeline run command — added in a later step]

## Repository structure
(to be filled in as the pipeline is built)

## Architecture

Medallion-style layered pipeline: raw -> staging -> marts, with reporting views on top.

```mermaid
flowchart TB
    subgraph RAW["RAW (Bronze)"]
        R1[pos_transactions]
        R2[reefer_telemetry]
        R3[wms_scan_events]
        R4[erp_cdc/outlet_master]
        R5[erp_cdc/product_master]
        R6[erp_cdc/sales_order_header]
        R7[reference/*.csv]
    end

    subgraph STG["STAGING (Silver) - cleaned, deduped, defect-corrected"]
        S1[stg_pos_transactions]
        S2[stg_reefer_telemetry]
        S3[stg_wms_scan_events]
        S4[stg_outlet_history]
        S5[stg_product_history]
        S6[stg_sales_order_header]
    end

    subgraph MARTS["MARTS (Gold) - star schema"]
        F1[fct_sales]
        F2[fct_cold_chain_readings]
        F3[fct_warehouse_cycle_time]
        F4[fct_orders]
        D1[dim_outlet]
        D2[dim_product]
        D3[dim_warehouse]
        D4[dim_carrier]
        D5[dim_calendar]
    end

    subgraph RPT["REPORTING VIEWS"]
        V1[rpt_sales_flat]
        V2[KPI query library]
    end

    R1 --> S1 --> F1
    R2 --> S2 --> F2
    R3 --> S3 --> F3
    R4 --> S4 --> D1
    R5 --> S5 --> D2
    R6 --> S6 --> F4
    R7 --> D3
    R7 --> D4
    R7 --> D5

    D1 --> F1
    D2 --> F1
    D1 -.-> V1
    D2 -.-> V1
    F1 -.-> V1
    F1 --> V2
    F2 --> V2
    F3 --> V2
    F4 --> V2
```

**Design principles:**
- Each staging table maps to exactly one raw source; defect-specific fixes (L1-L18) are documented as inline comments in the corresponding staging SQL scripts, not duplicated here
- Fact tables reference dimensions by key; joins happen at query time, not pre-baked into storage
- dim_outlet/dim_product are point-in-time (versioned), so historical reporting reflects attributes *as of* the event date, not today's values
- Reporting views (dashed lines) are convenience layers on top of the star schema - always in sync, never a separate source of truth
