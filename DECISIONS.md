# Decisions

- **Data handling**: `data/raw/` is gitignored per the brief's instruction not to
  commit the dataset; it's regenerated via `generate_dataset.py --scale 1`. Small
  reference CSVs under `data/reference/` ARE committed, since they're tiny
  lookup/dimension tables (not "the dataset" the brief means) and the repo is
  easier to understand with them present.

- **Repo layout**: original assignment brief/docs moved to `docs/assignment/`
  (unmodified) to avoid a naming collision with this repo's own README.md,
  and to make clear which files are the brief vs. the submission.
