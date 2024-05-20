

-- Drop the temporary raw table
-- DROP TABLE streets_raw;

UPDATE districts SET region_id = (
  SELECT r.id FROM regions r WHERE ST_Contains(r.geom, districts.geom) LIMIT 1
);

UPDATE cities SET district_id = (
  SELECT d.id FROM districts d WHERE ST_Contains(d.geom, cities.geom) LIMIT 1
);

UPDATE streets_raw SET city_id = (
  SELECT c.id FROM cities c WHERE ST_Contains(c.geom, streets_raw.geom) LIMIT 1
);

-- Create sequence for generating unique IDs for streets
CREATE SEQUENCE streets_id_seq;

-- Create the final streets table with combined geometries
CREATE TABLE streets AS
SELECT
  nextval('streets_id_seq') AS id,
  min(way_id) AS way_id,
  city_id,
  (SELECT value FROM jsonb_array_elements(jsonb_agg(names)) WHERE value IS NOT NULL LIMIT 1) AS names,
  jsonb_build_object('type', string_agg(DISTINCT type, ', ')) AS metadata,
  ST_LineMerge(ST_Collect(geom)) AS geom
FROM streets_raw
GROUP BY city_id, name ORDER BY city_id;

-- Drop the temporary raw table
DROP TABLE streets_raw;
