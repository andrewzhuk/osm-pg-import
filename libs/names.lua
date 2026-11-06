local M = {}
local classifications = {
  ['вулиця']='street', ['улица']='street', Street='street',
  ['провулок']='lane', ['переулок']='lane', Lane='lane',
  ['проспект']='avenue', Avenue='avenue',
  ['площа']='square', ['площадь']='square', Square='square',
  ['бульвар']='boulevard', Boulevard='boulevard',
  ['набережна']='embankment', ['набережная']='embankment', Embankment='embankment'
}
local function trim(value)
  return (value:gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' '))
end

function M.normalize(value, config)
  if not value then return nil, 'other' end
  value = trim(value)
  if not config then return value, 'other' end
  for _, case in ipairs(config.cases or {}) do
    for _, pattern in ipairs(case.patterns or {}) do
      -- Lua patterns have no regexp alternation. Match complete edge tokens,
      -- without consuming the adjacent name or using byte-based %a on UTF-8.
      local suffix = value:match('^(.+)%s+' .. pattern .. '$')
      local prefix = value:match('^' .. pattern .. '%s+(.+)$')
      -- English St at the start can mean Saint, so only accept English suffixes.
      local rest = suffix or (config.position == 'prefix' and prefix)
      if rest then
        rest = trim(rest)
        local normalized = config.position == 'prefix'
          and (case.value .. ' ' .. rest) or (rest .. ' ' .. case.value)
        return normalized, classifications[case.value] or 'other'
      end
    end
  end
  return value, 'other'
end

function M.from_tags(tags, patterns, normalize)
  local result = {}
  local values = { en=tags['name:en'], uk=tags['name:uk'] or tags.name, ru=tags['name:ru'] }
  for lang, value in pairs(values) do
    if normalize then
      result[lang] = M.normalize(value, patterns[lang])
    else
      result[lang] = value
    end
  end
  return result
end
return M
