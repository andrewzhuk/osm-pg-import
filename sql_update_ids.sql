UPDATE districts SET region_id = (
    SELECT r.id FROM regions r
    WHERE ST_Contains(r.geom, districts.geom)
    LIMIT 1
);

UPDATE cities SET district_id = (
    SELECT d.id FROM districts d
    WHERE ST_Contains(d.geom, cities.geom)
    LIMIT 1
);

UPDATE streets SET city_id = (
    SELECT c.id FROM cities c
    WHERE ST_Contains(c.geom, streets.geom)
    LIMIT 1
);
