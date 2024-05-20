#!/bin/bash

# Parameters for connecting to the database
DB_NAME="ukraine"
DB_USER="andrewzhuk"
DB_HOST="localhost"
DB_PORT="5432"  # default port

# Path to the OSM file, lua style file and SQL script
OSM_FILE="./ukraine-latest.osm.pbf"
LUA_SCRIPT="./main.lua"
SQL_SCRIPT="./sql_update_ids.sql"

# Create database
echo "Creating database..."
createdb -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME"

# Create postgis extension and hstore
echo "Creating postgis and hstore extensions..."
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "CREATE EXTENSION postgis; CREATE EXTENSION hstore;"


# Download OSM file if it doesn't exist
if [ ! -f "$OSM_FILE" ]
then
  echo "Downloading OSM file..."
  wget "https://download.geofabrik.de/europe/ukraine-latest.osm.pbf"
fi

# Import OSM data
echo "Starting osm2pgsql import..."
osm2pgsql -d "$DB_NAME" -U "$DB_USER" -H "$DB_HOST" -P "$DB_PORT" --slim -C 2500 --output=flex --style="$LUA_SCRIPT" "$OSM_FILE" -v

# Check if osm2pgsql import was successful
if [ $? -eq 0 ]
then
  echo "osm2pgsql import completed successfully."
  echo "Starting post-import SQL updates..."

  # Run SQL updates
  psql -d "$DB_NAME" -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -a -f "$SQL_SCRIPT"

  # Check if SQL updates were successful
  if [ $? -eq 0 ]
  then
    echo "SQL updates completed successfully."
  else
    echo "Error during SQL updates."
  fi
else
  echo "Error during osm2pgsql import."
fi
