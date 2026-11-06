-- Resolve dependencies relative to the style file, not the caller's directory.
local config_dir = osm2pgsql.config_dir or debug.getinfo(1, 'S').source:sub(2):match('^(.*)/') or '.'
package.path = config_dir .. '/?.lua;' .. package.path
local names = require('libs/names')
local json = require('libs/json')
local f = assert(io.open(config_dir .. '/patterns.json', 'r'))
local patterns = json.parse(f:read('*all'))
f:close()

local function area_table(name, extra)
  local columns = {
    { column = 'names', type = 'jsonb' },
    { column = 'geom', type = 'multipolygon', projection = 4326, not_null = true }
  }
  for _, column in ipairs(extra or {}) do columns[#columns + 1] = column end
  -- Stable OSM identity: way IDs are positive, relation IDs are negative.
  return osm2pgsql.define_table({
    name = name, ids = { type = 'area', id_column = 'id' },
    columns = columns
  })
end

local regions = area_table('regions')
local districts = area_table('districts', {{ column = 'region_id', type = 'int8' }})
local cities = area_table('cities', {
  { column = 'district_id', type = 'int8' },
  { column = 'type', type = 'text' },
  { column = 'metadata', type = 'jsonb' }
})
local streets = osm2pgsql.define_table({
  name = 'streets_raw',
  ids = { type = 'way', id_column = 'way_id' },
  columns = {
    { column = 'city_id', type = 'int8' },
    { column = 'type', type = 'text' },
    { column = 'name', type = 'text' },
    { column = 'names', type = 'jsonb' },
    { column = 'metadata', type = 'jsonb' },
    { column = 'geom', type = 'linestring', projection = 4326, not_null = true }
  }
})

local highway_types = {
  motorway=true, trunk=true, primary=true, secondary=true, tertiary=true,
  motorway_link=true, trunk_link=true, primary_link=true, secondary_link=true,
  tertiary_link=true, unclassified=true, residential=true, service=true,
  track=true, pedestrian=true, living_street=true
}
local places = { city=true, town=true, village=true, hamlet=true }

local function metadata(tags)
  local result = {}
  if tags.population then result.population = tonumber((tags.population:gsub('[%s,]', ''))) end
  result.koatuu = tags['ref:KOATUU'] or tags.koatuu
  result.katottg = tags['ref:KATOTTG']
  result.postal_code = tags['addr:postcode'] or tags.postal_code
  return result
end

local function process_area(object, relation)
  local tags = object.tags
  local is_region = tags.boundary == 'administrative' and tags.admin_level == '4'
    and tags['ISO3166-2'] and tags['ISO3166-2']:sub(1, 3) == 'UA-'
  local is_district = tags.boundary == 'administrative' and tags.admin_level == '6'
  if not is_region and not is_district and not places[tags.place] then return end
  local geometry = relation and object:as_multipolygon() or object:as_polygon()
  -- Administrative names must not be normalized as street names. One area can
  -- be both a region and a city (for example Kyiv); do not make these exclusive.
  local translated = names.from_tags(tags, patterns, false)
  if is_region then regions:insert({ names = translated, geom = geometry }) end
  if is_district then districts:insert({ names = translated, geom = geometry }) end
  if places[tags.place] then
    cities:insert({ names = translated, geom = geometry,
      type = tags.place, metadata = metadata(tags) })
  end
end

function osm2pgsql.process_relation(object)
  if object.tags.type == 'multipolygon' or object.tags.type == 'boundary' then
    process_area(object, true)
  end
end

function osm2pgsql.process_way(object)
  if object.is_closed then process_area(object, false) end
  local tags = object.tags
  if not highway_types[tags.highway] or tags.area == 'yes' then return end
  local raw_name = tags.name or tags['name:uk'] or tags['name:en'] or tags['name:ru']
  if not raw_name or raw_name:match('^%s*$') then return end
  local lang = tags.name and 'uk' or (tags['name:uk'] and 'uk' or (tags['name:en'] and 'en' or 'ru'))
  local normalized, classification = names.normalize(raw_name, patterns[lang])
  local info = metadata(tags)
  info.classification = classification
  streets:insert({
    name = normalized, type = tags.highway,
    names = names.from_tags(tags, patterns, true), metadata = info,
    geom = object:as_linestring()
  })
end
