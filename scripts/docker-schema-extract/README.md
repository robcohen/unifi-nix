# UniFi Docker Schema Extraction

Extract MongoDB schema directly from a running UniFi Network Application container.

## Overview

This tool spins up UniFi Network Application in Docker, waits for it to initialize
its MongoDB database, then extracts the schema including:

- Collection names
- Field types for each collection
- Example documents from key collections
- Enum values discovered in data
- Default site configuration

## Requirements

- Docker with Compose support
- `jq` for JSON processing
- ~2GB RAM for UniFi container

## Usage

```bash
# Extract from latest version
./extract-from-docker.sh

# Extract from specific version
./extract-from-docker.sh 8.6.9

# Specify custom output directory
./extract-from-docker.sh latest ../custom-schemas
```

## Output

Schema is saved to `../../schemas/<version>/`:

```
schemas/
  8.6.9/
    collections.json       # List of all collections
    field-schemas.json     # Field names and types per collection
    mongodb-examples.json  # Example documents from key collections
    enums.json             # Discovered enum values
    site-defaults.json     # Default site and settings
    version                # Version string
```

## How It Works

1. Starts MongoDB 7.0 container with initialization script
1. Starts UniFi Network Application (linuxserver.io image)
1. Waits for UniFi to create its database collections (~2-5 min)
1. Runs mongosh queries to extract schema information
1. Saves JSON files to output directory
1. Cleans up containers automatically

## Version Discovery

The script auto-detects the actual UniFi version from the `version_history`
collection, so even when using `latest` tag you get accurate versioning.

## CI Integration

For automated schema extraction on new releases:

```yaml
# .github/workflows/schema-extract.yml
on:
  schedule:
    - cron: "0 0 * * 0" # Weekly
  workflow_dispatch:

jobs:
  extract:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Extract schema
        run: ./scripts/docker-schema-extract/extract-from-docker.sh
      - name: Commit changes
        run: |
          git add schemas/
          git diff --staged --quiet || git commit -m "chore: update UniFi schema"
```

## Troubleshooting

**Container fails to start**: Check Docker memory limits, UniFi needs ~1GB.

**Schema extraction incomplete**: UniFi may need more time to initialize.
The script waits up to 5 minutes, but a fresh install creates minimal data.

**MongoDB connection refused**: Ensure port 27017 isn't already in use.
