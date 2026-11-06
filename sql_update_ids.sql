-- Executed in one transaction by scripts/postprocess.sh. Never drop flex tables.
SELECT pg_advisory_xact_lock(1869835570);
SET LOCAL search_path = public, pg_catalog;
-- Keep the style compatible with osm2pgsql 1.11, which has no unique-id option.
CREATE UNIQUE INDEX IF NOT EXISTS regions_id_unique ON regions (id);
CREATE UNIQUE INDEX IF NOT EXISTS districts_id_unique ON districts (id);
CREATE UNIQUE INDEX IF NOT EXISTS cities_id_unique ON cities (id);
CREATE UNIQUE INDEX IF NOT EXISTS streets_raw_way_unique ON streets_raw (way_id);

UPDATE districts d SET region_id = (
  SELECT r.id FROM regions r
  WHERE ST_Covers(r.geom, ST_PointOnSurface(d.geom))
  ORDER BY ST_Area(r.geom::geography), r.id LIMIT 1
);
UPDATE cities c SET district_id = (
  SELECT d.id FROM districts d
  WHERE ST_Covers(d.geom, ST_PointOnSurface(c.geom))
  ORDER BY ST_Area(d.geom::geography), d.id LIMIT 1
);
UPDATE streets_raw s SET city_id = (
  SELECT c.id FROM cities c
  WHERE ST_Intersects(c.geom, s.geom)
    AND ST_Length(ST_Intersection(c.geom, s.geom)) > 0
  ORDER BY ST_Covers(c.geom, s.geom) DESC,
    ST_Length(ST_Intersection(c.geom, s.geom)::geography) DESC,
    ST_Area(c.geom::geography), c.id
  LIMIT 1
);

CREATE TABLE IF NOT EXISTS streets (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  way_id bigint NOT NULL,
  city_id bigint,
  name text NOT NULL,
  -- Outside mapped cities, do not merge unrelated same-named roads.
  source_key bigint NOT NULL,
  names jsonb NOT NULL,
  metadata jsonb NOT NULL,
  geom geometry(Geometry, 4326) NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS streets_group_key
  ON streets ((COALESCE(city_id, 0)), name, source_key);
CREATE INDEX IF NOT EXISTS streets_geom_idx ON streets USING gist (geom);

CREATE TEMP TABLE street_snapshot ON COMMIT DROP AS
WITH source AS (
  SELECT *, CASE WHEN city_id IS NULL THEN way_id ELSE 0 END AS source_key
  FROM streets_raw
), grouped AS (
  SELECT city_id, name, source_key, min(way_id) AS way_id,
    string_agg(DISTINCT type, ', ' ORDER BY type) AS types,
    ST_LineMerge(ST_Collect(geom ORDER BY way_id)) AS geom
  FROM source GROUP BY city_id, name, source_key
), translated AS (
  SELECT city_id, name, source_key,
    jsonb_object_agg(e.key, e.value ORDER BY way_id DESC) AS names
  FROM source CROSS JOIN LATERAL jsonb_each(names) e
  GROUP BY city_id, name, source_key
), details AS (
  SELECT city_id, name, source_key,
    jsonb_object_agg(e.key, e.value ORDER BY way_id DESC) AS metadata
  FROM source CROSS JOIN LATERAL jsonb_each(metadata) e
  GROUP BY city_id, name, source_key
)
SELECT g.*, COALESCE(t.names, '{}'::jsonb) AS names,
  COALESCE(d.metadata, '{}'::jsonb) || jsonb_build_object('type', g.types) AS metadata
FROM grouped g
LEFT JOIN translated t ON t.city_id IS NOT DISTINCT FROM g.city_id
  AND t.name = g.name AND t.source_key = g.source_key
LEFT JOIN details d ON d.city_id IS NOT DISTINCT FROM g.city_id
  AND d.name = g.name AND d.source_key = g.source_key;

-- Update in place to preserve IDs for unchanged city/name groups, including
-- when a constituent way is changed/deleted. Do not burn identity values on retry.
UPDATE streets s SET way_id = n.way_id, names = n.names,
  metadata = n.metadata, geom = n.geom
FROM street_snapshot n
WHERE s.city_id IS NOT DISTINCT FROM n.city_id
  AND s.name = n.name AND s.source_key = n.source_key;
INSERT INTO streets (way_id, city_id, name, source_key, names, metadata, geom)
SELECT n.way_id, n.city_id, n.name, n.source_key, n.names, n.metadata, n.geom
FROM street_snapshot n
WHERE NOT EXISTS (
  SELECT FROM streets s WHERE s.city_id IS NOT DISTINCT FROM n.city_id
    AND s.name = n.name AND s.source_key = n.source_key
)
ORDER BY n.city_id NULLS LAST, n.name, n.source_key;
DELETE FROM streets s WHERE NOT EXISTS (
  SELECT FROM street_snapshot n WHERE s.city_id IS NOT DISTINCT FROM n.city_id
    AND s.name = n.name AND s.source_key = n.source_key
);

CREATE TABLE IF NOT EXISTS osm_pg_import_meta (key text PRIMARY KEY, value text NOT NULL);
INSERT INTO osm_pg_import_meta VALUES ('schema_version', '2')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
