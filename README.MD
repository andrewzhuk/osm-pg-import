<p align="center">
  <img src="/.github/logo.png" alt="OSM-PG" width="200px">
</p>

**OSM Data Integration Tool** is a tool for automated downloading and updating of OpenStreetMap (OSM) data into a local PostgreSQL database. The project utilizes [osm2pgsql](https://osm2pgsql.org) and [Lua](https://www.lua.org) scripts to transform OSM data, ensuring the accuracy and uniqueness of geographic information about features like streets and roads.

### Key Features

* **OSM Data Import:** The tool automatically loads data from OSM PBF files into a PostgreSQL database using [osm2pgsql](https://osm2pgsql.org).
* **Data Processing and Transformation:** Data is filtered and transformed using [Lua](https://www.lua.org) scripts, including the removal of unnecessary elements and normalization of street names.
* **Uniqueness Management:** A system of unique identifiers is used to prevent data duplication during reloads.
* **Automation of Updates:** Bash scripts provide automation of the data loading sequence and subsequent SQL queries for updating and maintaining the data in a current state.

### Technologies

**osm2pgsql:** A tool for importing [OpenStreetMap](https://www.openstreetmap.org) data into PostgreSQL databases using a cartographic schema.

**PostgreSQL/PostGIS:** A powerful combination of an object-relational database and a geographic information system for managing spatial data.

**Lua:** A scripting language used for writing transformation scripts in [osm2pgsql](https://osm2pgsql.org).

### Getting Started

To start using the **OSM Data Integration Tool**, clone the repository and follow the instructions in the README.md file to set up and run the tools.

#### Clone repository

```bash
git clone https://github.com/andrewzhuk/osm-data-integration-tool.git
cd osm-data-integration-tool
```
#### Run on terminal

```bush
bash ./run_osm_import.sh
```

# Update the data

```bush
bash ./run_osm_update.sh
```


### Motivation

The **OSM Data Integration Tool** was created to simplify the process of importing and updating OpenStreetMap data in a PostgreSQL database. For creating delivery services, it is essential to have accurate and up-to-date geographic information about streets and roads. This tool automates the process of downloading and updating OSM data, ensuring that the data is always current and accurate.

### Contributing

Contributions are welcome! If you would like to contribute to the project, please create a pull request with your changes.

### Support

If you have any questions or need help with the project, please contact with me by submitting an issue.

### License
This project is distributed under the MIT License, allowing free use, modification, and distribution of the code.