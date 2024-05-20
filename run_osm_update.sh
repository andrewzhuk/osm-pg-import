#!/bin/bash

# Parameters for connecting to the database
DB_NAME="ukraine"
DB_USER="andrewzhuk"
DB_HOST="localhost"
DB_PORT="5432" # default port

# Path to the replication directory and URL
REPLICATION_DIR="./replication"
REPLICATION_URL="https://planet.openstreetmap.org/replication/minute"

# Path to the lua style file
LUA_SCRIPT="./osm2pgsql.lua"

# Ensure the replication directory exists
mkdir -p "$REPLICATION_DIR"

# Download the latest state file
wget -O "$REPLICATION_DIR/state.txt" "$REPLICATION_URL/state.txt"

# Apply the diff files
osmosis --read-replication-interval workingDirectory="$REPLICATION_DIR" \
        --simplify-change --write-xml-change "$REPLICATION_DIR/changes.osc.gz"

osm2pgsql -d "$DB_NAME" -U "$DB_USER" -H "$DB_HOST" -P "$DB_PORT" --slim -C 2500 --output=flex --style="$LUA_SCRIPT" --append "$REPLICATION_DIR/changes.osc.gz" -v

# Check if osm2pgsql import was successful
if [ $? -eq 0 ]
then
  echo "osm2pgsql update completed successfully."
else
  echo "Error during osm2pgsql update."
fi
