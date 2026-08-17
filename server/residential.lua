MZFurnitureResidential = MZFurnitureResidential or {}

local Sessions = {}
local ViewSessions = {}

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}
  for key, nested in pairs(value) do result[key] = copy(nested) end
  return result
end

local function currentHouseCode(source)
  local player = Player(tonumber(source))
  local state = player and player.state or nil
  local code = state and trim(state.mzHouseCode) or ''
  return code ~= '' and code or nil
end

local function revalidate(source, houseCode)
  source = tonumber(source)
  houseCode = trim(houseCode)
  if MZFurnitureConfig.ResidentialAuthorityEnabled ~= true then
    return false, 'residential_authority_disabled'
  end
  if not source or source <= 0 or houseCode == '' then return false, 'invalid_residential_context' end
  if GetResourceState('mz_houses') ~= 'started' then return false, 'houses_unavailable' end

  local callOk, allowed, result = pcall(function()
    return exports['mz_houses']:CanDecorateProperty(source, houseCode)
  end)
  if not callOk then return false, 'houses_authority_failed' end
  if allowed ~= true or type(result) ~= 'table' then return false, result or 'decoration_denied' end

  local context = copy(result)
  context.source = source
  context.houseCode = houseCode
  context.validatedAt = os.time()
  Sessions[source] = context
  return true, copy(context)
end

local function revalidateViewer(source, houseCode)
  source = tonumber(source)
  houseCode = trim(houseCode)
  if not source or source <= 0 or houseCode == '' then
    return false, 'invalid_residential_context'
  end
  if GetResourceState('mz_houses') ~= 'started' then return false, 'houses_unavailable' end
  local callOk, allowed, result = pcall(function()
    return exports['mz_houses']:CanViewPropertyFurniture(source, houseCode)
  end)
  if not callOk then return false, 'houses_view_authority_failed' end
  if allowed ~= true or type(result) ~= 'table' then
    return false, result or 'furniture_view_denied'
  end
  local context = copy(result)
  context.source = source
  context.houseCode = houseCode
  context.validatedAt = os.time()
  ViewSessions[source] = context
  return true, copy(context)
end

function MZFurnitureResidential.Get(source)
  source = tonumber(source)
  if not source or source <= 0 then return false, 'invalid_source' end
  local active = Sessions[source]
  local houseCode = active and active.houseCode or currentHouseCode(source)
  if not houseCode then
    Sessions[source] = nil
    return false, 'not_inside_property'
  end
  local ok, result = revalidate(source, houseCode)
  if not ok then Sessions[source] = nil end
  return ok, result
end

function MZFurnitureResidential.GetViewer(source)
  source = tonumber(source)
  if not source or source <= 0 then return false, 'invalid_source' end
  local active = ViewSessions[source]
  local houseCode = active and active.houseCode or currentHouseCode(source)
  if not houseCode then
    ViewSessions[source] = nil
    return false, 'not_inside_property'
  end
  local ok, result = revalidateViewer(source, houseCode)
  if not ok then ViewSessions[source] = nil end
  return ok, result
end

function MZFurnitureResidential.ListViewers(propertyId, bucket)
  propertyId = tonumber(propertyId)
  bucket = tonumber(bucket)
  local viewers = {}
  for source, context in pairs(ViewSessions) do
    if GetPlayerName(source)
      and tonumber(context.propertyId) == propertyId
      and tonumber(context.bucket) == bucket
      and GetPlayerRoutingBucket(source) == bucket then
      viewers[#viewers + 1] = source
    end
  end
  return viewers
end

function MZFurnitureResidential.InvalidateProperty(propertyId)
  propertyId = tonumber(propertyId)
  if not propertyId then return 0 end
  local affected = {}
  for source, context in pairs(Sessions) do
    if tonumber(context.propertyId) == propertyId then
      Sessions[source] = nil
      affected[source] = true
    end
  end
  for source, context in pairs(ViewSessions) do
    if tonumber(context.propertyId) == propertyId then
      ViewSessions[source] = nil
      affected[source] = true
    end
  end
  local count = 0
  for source in pairs(affected) do
    count = count + 1
    TriggerClientEvent('mz_furniture:client:clearProperty', source)
  end
  return count
end

function MZFurnitureResidential.ValidateOffset(source, offset, footprintRadius)
  local allowed, context = MZFurnitureResidential.Get(source)
  if not allowed then return false, context end
  if GetResourceState('mz_interiors') ~= 'started' then return false, 'interiors_unavailable' end
  local callOk, valid, result = pcall(function()
    return exports['mz_interiors']:ValidateFurniturePlacement(
      context.shell,
      offset,
      footprintRadius
    )
  end)
  if not callOk then return false, 'interiors_validation_failed' end
  if valid ~= true then return false, result or 'invalid_furniture_placement' end
  result.houseCode = context.houseCode
  result.propertyId = context.propertyId
  result.citizenid = context.citizenid
  result.bucket = context.bucket
  return true, result
end

AddEventHandler('mz_houses:server:interiorSessionConfirmed', function(source, session)
  session = type(session) == 'table' and session or {}
  local code = trim(session.code)
  if code == '' then return end
  local canView = revalidateViewer(source, code)
  if canView then
    TriggerEvent('mz_furniture:server:viewerReady', tonumber(source))
  else
    ViewSessions[tonumber(source)] = nil
  end
  local ok = revalidate(source, code)
  if not ok then Sessions[tonumber(source)] = nil end
end)

AddEventHandler('mz_houses:server:interiorSessionEnded', function(source)
  Sessions[tonumber(source)] = nil
  ViewSessions[tonumber(source)] = nil
  TriggerClientEvent('mz_furniture:client:clearProperty', tonumber(source))
end)

AddEventHandler('mz_houses:server:propertyAccessChanged', function(code)
  code = trim(code)
  for source, session in pairs(Sessions) do
    if session.houseCode == code then
      local ok = revalidate(source, code)
      if not ok then Sessions[source] = nil end
    end
  end
  for source, session in pairs(ViewSessions) do
    if session.houseCode == code then
      local ok = revalidateViewer(source, code)
      if not ok then
        ViewSessions[source] = nil
        TriggerClientEvent('mz_furniture:client:clearProperty', source)
      end
    end
  end
end)

AddEventHandler('playerDropped', function()
  Sessions[source] = nil
  ViewSessions[source] = nil
end)

AddEventHandler('onResourceStop', function(resource)
  if resource == 'mz_houses' or resource == GetCurrentResourceName() then
    Sessions = {}
    ViewSessions = {}
  end
end)

exports('GetResidentialContext', function(source)
  return MZFurnitureResidential.Get(source)
end)

exports('ValidateResidentialOffset', function(source, offset, footprintRadius)
  return MZFurnitureResidential.ValidateOffset(source, offset, footprintRadius)
end)

exports('GetResidentialViewerContext', function(source)
  return MZFurnitureResidential.GetViewer(source)
end)
