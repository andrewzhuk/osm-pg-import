-- Create tables for regions, districts, cities and streets.
local regions = osm2pgsql.define_area_table('regions', {
  { column = 'id', sql_type = 'serial', create_only = true },
  { column = 'names', type = 'hstore' }, -- Example: { uk = 'Київська область', ru = 'Киевская область', en = 'Kyiv region' }
  { column = 'geom', type = 'multipolygon', projection = 4326 }
})

local districts = osm2pgsql.define_area_table('districts', {
  { column = 'id', sql_type = 'serial', create_only = true },
  { column = 'region_id', type = 'integer' },
  { column = 'names', type = 'hstore' }, 
  { column = 'geom', type = 'multipolygon', projection = 4326 }
})

local cities = osm2pgsql.define_area_table('cities', {
  { column = 'id', sql_type = 'serial', create_only = true },
  { column = 'district_id', type = 'integer' },
  { column = 'type', type = 'text' }, -- Example: city, town or village
  { column = 'names', type = 'hstore' }, -- Example: { uk = 'Київ', ru = 'Киев', en = 'Kyiv' }
  { column = 'population', type = 'bigint' },
  { column = 'geom', type = 'multipolygon', projection = 4326 } -- Example: POLYGON((...))
})

local streets = osm2pgsql.define_way_table('streets', {
  { column = 'id', sql_type = 'serial', create_only = true },
  { column = 'city_id', type = 'integer' },
  { column = 'type', type = 'text' }, -- Example: motorway, trunk, primary, secondary, tertiary, unclassified, residential, pedestrian
  { column = 'names', type = 'hstore' }, -- Example: { uk = 'вулиця Хрещатик', ru = 'улица Хрещатик', en = 'Khreshchatyk street' }
  { column = 'geom', type = 'linestring', projection = 4326 }
})

-- Process relations to get regions, districts and cities data.
function osm2pgsql.process_relation(object)
  -- Process regions
  if object.tags.admin_level == '4' and object.tags.boundary == 'administrative' and object.tags['ISO3166-2'] and object.tags['ISO3166-2']:sub(1, 3) == 'UA-' then
    regions:insert({
      names = make_names_hstore(object.tags),
      geom = object:as_multipolygon()
    })
  
  -- Process districts
  elseif object.tags.admin_level == '6' and object.tags.boundary == 'administrative' and object.tags.place == 'district' then
    districts:insert({
      names = make_names_hstore(object.tags),
      geom = object:as_multipolygon()
    })
  
  -- Process cities
  elseif object.tags.place and (object.tags.place == 'city' or object.tags.place == 'town' or object.tags.place == 'village') then
    cities:insert({
      type = object.tags.place, -- city, town or village
      names = make_names_hstore(object.tags),
      population = object.tags.population or 0,
      postal_code = object.tags.postal_code,
      geom = object:as_multipolygon()
    })
  end
end

local get_highway_value = osm2pgsql.make_check_values_func({
  'motorway', 'trunk', 'primary', 'secondary', 'tertiary',
  'motorway_link', 'trunk_link', 'primary_link', 'secondary_link', 'tertiary_link',
  'unclassified', 'residential', 'service', 'track'
})

local inserted_streets = {}

-- Process ways to get streets data.
function osm2pgsql.process_way(object)
  
  local highway_type = get_highway_value(object.tags.highway)
  
  if not highway_type then
    return
  end

  if object.tags.area == 'yes' then
    return
  end
  local street_name = object.tags.name

  if not street_name or street_name == '' then
    return
  end
  
  -- if not inserted_streets[street_name] then
    streets:insert({
      type = highway_type,
      names = make_names_hstore(object.tags),
      geom = object:as_linestring()
    })
  --   inserted_streets[street_name] = true
  -- end
end

-- Function to create hstore from tags
function make_names_hstore(tags)
  local names = {}

  local function clean_street_name(name)
      if not name then return nil end
      -- Deleting words "улица" and "вулиця" from names
      name = name:gsub("улица", ""):gsub("вулиця", "")
      -- Deleting leading and trailing spaces and multiple spaces
      name = name:gsub("^%s*(.-)%s*$", "%1"):gsub("%s+", " ")
      return name
  end

  if tags['name'] then names['uk'] = clean_street_name(tags['name']) end
  if tags['name:ru'] then names['ru'] = clean_street_name(tags['name:ru']) end
  if tags['name:en'] then names['en'] = clean_street_name(tags['name:en']) end

  return names
end
