local function read(path)
  local file = assert(io.open(path, 'rb'))
  local content = file:read('*a')
  file:close()
  return content
end

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local housesMain = read('mz_houses/server/main.lua')
local housesService = read('mz_houses/server/service.lua')
local residential = read('mz_furniture/server/residential.lua')
local placementServer = read('mz_furniture/server/placement.lua')
local placementClient = read('mz_furniture/client/placement.lua')
local config = read('mz_furniture/shared/config.lua')

expect(housesMain:find("exports('CanViewPropertyFurniture'", 1, true),
  'confirmed occupant view export is missing')
expect(housesService:find('function MZHousesService.CanViewPropertyFurniture', 1, true),
  'occupant view policy is missing')
local viewStart = assert(housesService:find(
  'function MZHousesService.CanViewPropertyFurniture',
  1,
  true
))
local viewEnd = housesService:find(
  'function MZHousesService.CanAccessPropertyFeature',
  viewStart,
  true
) or #housesService
local viewPolicy = housesService:sub(viewStart, viewEnd - 1)
expect(not viewPolicy:find("return false, 'property_owner_required'", 1, true),
  'view policy appears to inherit the owner-only edit denial')
expect(residential:find('ViewSessions', 1, true),
  'authorized viewer sessions are not tracked')
expect(residential:find('GetPlayerRoutingBucket(source) == bucket', 1, true),
  'viewer broadcast list does not recheck routing bucket')
expect(placementServer:find('MZFurnitureResidential.GetViewer(source)', 1, true),
  'snapshot still requires owner-only context')
expect(placementServer:find('local context, contextErr = contextFor(source)', 1, true),
  'editing no longer requires owner-only context')
expect(placementServer:find("'mz_furniture:client:upsertPlacement'", 1, true),
  'incremental placement broadcast is missing')
expect(placementServer:find("'mz_furniture:client:removePlacement'", 1, true),
  'incremental removal broadcast is missing')
expect(placementClient:find("RegisterNetEvent('mz_furniture:client:propertySnapshot'", 1, true),
  'late entrant snapshot handler is missing')
expect(placementClient:find("RegisterNetEvent('mz_furniture:client:upsertPlacement'", 1, true),
  'client upsert handler is missing')
expect(placementClient:find('Runtime.revisions[ownedFurnitureId]', 1, true),
  'client does not deduplicate stale placement revisions')
expect(placementClient:find("RegisterNetEvent('mz_furniture:client:clearProperty'", 1, true),
  'client cleanup event is missing')
expect(config:find('RuntimeSyncEnabled = true', 1, true),
  'Phase 5 runtime synchronization is not enabled')
expect(config:find('RuntimeStreamDistance', 1, true)
  and placementClient:find('RuntimeStreamHysteresis', 1, true),
  'client runtime does not cull distant furniture with hysteresis')

print('[mz_furniture][test] sync contract harness passed')
