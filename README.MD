**OSM Data Integration Tool** is a tool for automated downloading and updating of OpenStreetMap (OSM) data into a local PostgreSQL database. The project utilizes [osm2pgsql](https://osm2pgsql.org) and [Lua](https://www.lua.org) scripts to transform OSM data, ensuring the accuracy and uniqueness of geographic information about features like streets and roads.

### Key Features

* **OSM Data Import:** The tool automatically loads data from OSM PBF files into a PostgreSQL database using [osm2pgsql](https://osm2pgsql.org).
* **Data Processing and Transformation:** Data is filtered and transformed using [Lua](https://www.lua.org) scripts, including the removal of unnecessary elements and normalization of street names.
* **Uniqueness Management:** A system of unique identifiers is used to prevent data duplication during reloads.
* **Automation of Updates:** Bash scripts use `osm2pgsql-replication` to apply OSM changes and run SQL queries to keep the imported data up to date.

### Technologies

**osm2pgsql:** A tool for importing [OpenStreetMap](https://www.openstreetmap.org) data into PostgreSQL databases using a cartographic schema.

**PostgreSQL/PostGIS:** A powerful combination of an object-relational database and a geographic information system for managing spatial data.

**Lua:** A scripting language used for writing transformation scripts in [osm2pgsql](https://osm2pgsql.org).

### Getting Started

Install Bash, PostgreSQL/PostGIS, and osm2pgsql 1.11+ with Lua support.
For updates, install `osm2pgsql-replication` with its PyOsmium and psycopg2/psycopg dependencies. Osmosis is no longer required.

To start using the **OSM Data Integration Tool**, clone the repository and follow the instructions in the README.md file to set up and run the tools.

#### Clone repository

```bash
git clone https://github.com/andrewzhuk/osm-pg-import.git
cd osm-pg-import
```
#### Run on terminal

Import an existing OSM file:

```bash
DB_NAME=ukraine_osm DB_USER=postgres \
  OSM_FILE=/path/to/ukraine-latest.osm.pbf bash ./run_osm_import.sh
```

To download the Ukraine extract before importing, explicitly enable downloading:

```bash
DOWNLOAD_OSM=1 DB_NAME=ukraine_osm DB_USER=postgres bash ./run_osm_import.sh
```

Downloads are disabled by default. The importer creates a new database or uses an empty one; it will not overwrite existing user tables. The PostgreSQL role must be able to create the database and enable PostGIS, or use an empty database with PostGIS already installed.

#### Update the data

Initialize replication once after importing:

```bash
DB_NAME=ukraine_osm DB_USER=postgres bash ./run_osm_update.sh --init
```

Then apply updates:

```bash
DB_NAME=ukraine_osm DB_USER=postgres bash ./run_osm_update.sh
```

Use the same database settings for import and updates. `DB_HOST` and `DB_PORT` default to `localhost` and `5432`; authentication uses standard PostgreSQL settings such as `.pgpass`.

The default replication source is Geofabrik's Ukraine update stream. For another extract, set `REPLICATION_URL` to its matching regional update service when initializing. Do not initialize again on every update.

After each batch, SQL refreshes the street data. If SQL fails, the replication checkpoint is not advanced and the update can be retried.

Existing databases created by the old scripts require a fresh import into a new database because the schema and ID handling have changed. Existing databases are not automatically migrated or deleted.

#### Tests

Run the local Lua/Python checks without downloading map data:

```bash
bash tests/run.sh
```

For the integration test, provide a disposable PostgreSQL/PostGIS server and installed osm2pgsql/replication tools:

```bash
PGHOST=/var/run/postgresql PGUSER=postgres python3 tests/integration.py
```

The integration test generates a tiny local OSM dataset and a local replication server, and creates and removes only its own temporary test database.

### Motivation

The **OSM Data Integration Tool** was created to simplify the process of importing and updating OpenStreetMap data in a PostgreSQL database. For creating delivery services, it is essential to have accurate and up-to-date geographic information about streets and roads. This tool automates the process of downloading and updating OSM data, ensuring that the data is always current and accurate.

### Contributing

Contributions are welcome! If you would like to contribute to the project, please create a pull request with your changes.

### Support

If you have any questions or need help with the project, please contact with me by submitting an issue.

### License
This project is distributed under the MIT License, allowing free use, modification, and distribution of the code.
