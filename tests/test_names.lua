local root = assert(arg[1], 'project path required')
package.path = root .. '/?.lua;' .. package.path
local names = require('libs/names')
local json = require('libs/json')
local f = assert(io.open(root .. '/patterns.json'))
local patterns = json.parse(f:read('*all')); f:close()
local checks = 0
local function eq(actual, expected)
  checks = checks + 1
  assert(actual == expected, 'expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end
for _, t in ipairs({
  {'  вул.   Шевченка  ', 'uk', 'вулиця Шевченка', 'street'},
  {'Шевченка вулиця', 'uk', 'вулиця Шевченка', 'street'},
  {'пров. Лісовий', 'uk', 'провулок Лісовий', 'lane'},
  {'Лісова площа', 'uk', 'площа Лісова', 'square'},
  {'ул. Пушкина', 'ru', 'улица Пушкина', 'street'},
  {'Мира проспект', 'ru', 'проспект Мира', 'avenue'},
  {'Main st.', 'en', 'Main Street', 'street'},
  {'Main Street', 'en', 'Main Street', 'street'},
  {'Main ave.', 'en', 'Main Avenue', 'avenue'},
  {'St John', 'en', 'St John', 'other'},
  {'Вулична', 'uk', 'Вулична', 'other'},
  {'Острів', 'uk', 'Острів', 'other'},
  {'  Kyiv  ', 'uk', 'Kyiv', 'other'}
}) do
  local normalized, classification = names.normalize(t[1], patterns[t[2]])
  eq(normalized, t[3]); eq(classification, t[4])
  eq(names.normalize(normalized, patterns[t[2]]), normalized)
end
local translated = names.from_tags({name='вул. Default', ['name:uk']='вул. Українська', ['name:en']='Main St.'}, patterns, true)
eq(translated.uk, 'вулиця Українська'); eq(translated.en, 'Main Street')
eq(names.from_tags({name='Main Street'}, patterns, false).uk, 'Main Street')

-- Exercise the real style with a small osm2pgsql API double. This tests
-- transformation logic only; the separate integration test uses the real tool.
local rows, definitions = {}, {}
osm2pgsql = { config_dir=root, define_table=function(definition)
  rows[definition.name] = {}; definitions[definition.name] = definition
  return {insert=function(_, data) table.insert(rows[definition.name], data) end}
end }
dofile(root .. '/main.lua')
local function object(tags, closed)
  return {tags=tags, is_closed=closed, as_multipolygon=function() return 'MULTIPOLYGON' end,
    as_polygon=function() return 'POLYGON' end, as_linestring=function() return 'LINESTRING' end}
end
-- A settlement relation before any road must not depend on a way callback.
osm2pgsql.process_relation(object({type='boundary', place='city', name='Test Street', population='12 345'}))
eq(rows.cities[1].metadata.population, 12345)
eq(rows.cities[1].metadata.classification, nil)
eq(rows.cities[1].names.uk, 'Test Street')
osm2pgsql.process_relation(object({type='boundary', boundary='administrative', admin_level='6', name='District'}))
eq(#rows.districts, 1) -- no unnecessary place=district requirement
osm2pgsql.process_way(object({place='village', name='Village'}, true))
eq(#rows.cities, 2)
osm2pgsql.process_way(object({highway='residential', name='вул. Перша', ['name:uk']='вул. Перша', ['name:en']='First st.', ['addr:postcode']='01001'}))
osm2pgsql.process_way(object({highway='pedestrian', name='пл. Друга'}))
osm2pgsql.process_way(object({highway='residential', name='  '}))
osm2pgsql.process_way(object({highway='residential', name='Area', area='yes'}))
osm2pgsql.process_way(object({highway='footway', name='Path'}))
eq(#rows.streets_raw, 2)
eq(rows.streets_raw[1].metadata.classification, 'street')
eq(rows.streets_raw[1].metadata.postal_code, '01001')
eq(rows.streets_raw[2].metadata.classification, 'square')
eq(definitions.cities.ids.id_column, 'id'); eq(definitions.cities.ids.type, 'area')
eq(definitions.streets_raw.ids.id_column, 'way_id')
osm2pgsql.process_relation(object({type='boundary', boundary='administrative', admin_level='4',
  ['ISO3166-2']='UA-30', place='city', name='Kyiv'}))
eq(#rows.regions, 1); eq(#rows.cities, 3)
print('PASS: ' .. checks .. ' Lua transformation assertions')
