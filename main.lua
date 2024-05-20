local json = require("libs/json")

local function read_patterns_from_json(file)
  local f = assert(io.open(file, "r"))
  local content = f:read("*all")
  f:close()
  return json.parse(content)
end

local patterns = read_patterns_from_json("patterns.json")

-- Create tables for regions, districts, cities and streets.
local regions = osm2pgsql.define_area_table('regions', {
  { column = 'id', sql_type = 'serial', create_only = true },
  { column = 'names', type = 'jsonb' }, -- Example: { en: 'Kyiv region', uk: 'Київська область', ru: 'Киевская область' }
  { column = 'geom', type = 'multipolygon', projection = 4326 }
})

local districts = osm2pgsql.define_area_table('districts', {
  { column = 'id', sql_type = 'serial', create_only = true },
  { column = 'region_id', type = 'integer' },
  { column = 'names', type = 'jsonb' }, 
  { column = 'geom', type = 'multipolygon', projection = 4326 }
})

local cities = osm2pgsql.define_area_table('cities', {
  { column = 'id', sql_type = 'serial', create_only = true },
  { column = 'district_id', type = 'integer' },
  { column = 'type', type = 'text' }, -- Example: city, town or village
  { column = 'names', type = 'jsonb' }, -- Example: { en: 'Kyiv', uk: 'Київ', ru: 'Киев',  }
  { column = 'metadata', type = 'jsonb' }, -- Example: { population: 2804000, koatuu: '8000000000', postal_code: '01000' }
  { column = 'geom', type = 'multipolygon', projection = 4326 } -- Example: POLYGON((...))
})

local streets_raw = osm2pgsql.define_way_table('streets_raw', {
  { column = 'id', sql_type = 'serial', create_only = true },
  { column = 'city_id', type = 'integer' },
  { column = 'type', type = 'text' }, -- Example: motorway, trunk, primary, secondary, tertiary, unclassified, residential, pedestrian
  { column = 'name', type = 'text' },
  { column = 'names', type = 'jsonb' }, -- Example: { en: 'Khreshchatyk street', uk: 'вулиця Хрещатик', ru: 'улица Хрещатик',  }
  { column = 'metadata', type = 'jsonb' }, -- Example: { koatuu: '8000000000', postal_code: '01000' }
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
      metadata = make_metadata_jsonb(object.tags),
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

  function make_metadata_jsonb(tags)
    if not tags then
      return
    end

    local metadata = {}
  
    if tags['population'] then metadata['population'] = tonumber(tags['population']) end
    if tags['koatuu'] then metadata['koatuu'] = tags['koatuu'] end
    if tags['postal_code'] then metadata['postal_code'] = tags['postal_code'] end
  
    local classification
  
    if street_name:match("%s*(вулиця|улица|вул%.|street)$") then
      classification = 'street'
    elseif street_name:match("%s*(провулок|проулок|lane)$") then
      classification = 'lane'
    elseif street_name:match("%s*(проспект|проспект|просп%.|avenue)$") then
      classification = 'avenue'
    elseif street_name:match("%s*(площа|площадь|пл%.|square)$") then
      classification = 'square'
    elseif street_name:match("%s*(бульвар|бульвар|бульв%.|boulevard)$") then
      classification = 'boulevard'
    elseif street_name:match("%s*(набережна|набережная|наб%.|embankment)$") then
      classification = 'embankment'
    else
      classification = 'other'
    end
  
    metadata['classification'] = classification
  
    return metadata
  end

  streets_raw:insert({
    type = highway_type,
    name = street_name,
    names = make_names_hstore(object.tags),
    metadata = make_metadata_jsonb(object.tags),
    geom = object:as_linestring()
  })
end

-- Function to create hstore from tags
function make_names_hstore(tags)
  local names = {}

  
  local function clean_street_name(name, lang)
    if not name then return nil end

    -- Check and replace patterns
    local lang_patterns = patterns[lang] or {}
    local position = lang_patterns.position or "postfix"
    local cases = lang_patterns.cases or {}

    local function find_pattern(name, pattern)
      -- Find pattern in the name
      local patterns = {
        "%f[%a]" .. pattern .. "%f[%A]",
        "%s" .. pattern .. "%s",
        "^" .. pattern .. "%s",
        "%s" .. pattern .. "$",
        "^" .. pattern .. "$"
      }
      
      for _, word_pattern in ipairs(patterns) do
        local found_start, found_end = name:find(word_pattern)
        if found_start then
          return found_start, found_end
        end
      end
      return nil
    end

    for _, case in ipairs(cases) do
      for _, pattern in ipairs(case.patterns or {}) do
        local full = case.value
        local found_start, found_end = find_pattern(name, pattern)
        if found_start then
          -- Delete found pattern
          name = name:sub(1, found_start-1) .. name:sub(found_end+1)
          -- Delete extra spaces
          name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
          -- Check if the full value is already present
          local already_present = name:find(full)
          if not already_present then
            -- Move pattern to the beginning or end of the string depending on the position
            if position == "prefix" then
                name = full .. " " .. name
            elseif position == "postfix" then
                name = name .. " " .. full
            end
            -- Delete extra spaces again after adding full
            name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
          end
          break
        end
      end
    end

    -- Delete extra spaces
    return name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
  end

  -- Add names to hstore with order en, uk, ru for Ukraine
  if tags['name:en'] then names['en'] = clean_street_name(tags['name:en'], 'en') end
  if tags['name'] then names['uk'] = clean_street_name(tags['name'], 'uk') end
  if tags['name:ru'] then names['ru'] = clean_street_name(tags['name:ru'], 'ru') end

  return names
end