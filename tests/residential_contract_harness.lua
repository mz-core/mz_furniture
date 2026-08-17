local function read(path)
  local file = assert(io.open(path, 'rb'))
  local value = file:read('*a')
  file:close()
  return value
end

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local housesMain = read('mz_houses/server/main.lua')
local housesService = read('mz_houses/server/service.lua')
local furnitureResidential = read('mz_furniture/server/residential.lua')
local furnitureConfig = read('mz_furniture/shared/config.lua')
local interiorsServer = read('mz_interiors/server/main.lua')
local housesClient = read('mz_houses/client/main.lua')

expect(housesMain:find('interiorSessionConfirmed', 1, true), 'confirmed session event is missing')
expect(housesMain:find('interiorSessionEnded', 1, true), 'ended session event is missing')
expect(housesMain:find('GetPlayerRoutingBucket(source)', 1, true), 'routing bucket revalidation is missing')
expect(housesMain:find("exports('CanDecorateProperty'", 1, true), 'house decoration export is missing')
expect(housesService:find('MZHousesDecorationPolicy.Evaluate', 1, true), 'owner-only policy is not used')
expect(furnitureResidential:find("exports['mz_houses']:CanDecorateProperty", 1, true), 'furniture does not revalidate house authority')
expect(furnitureResidential:find("exports['mz_interiors']:ValidateFurniturePlacement", 1, true), 'bounds validation bridge is missing')
expect(interiorsServer:find("exports('GetFurnitureBounds'", 1, true), 'bounds export is missing')
expect(housesClient:find('response.features.furniture == true', 1, true), 'client feature context omits furniture')
expect(furnitureConfig:find('ResidentialAuthorityEnabled = true', 1, true), 'residential authority must be enabled')
expect(furnitureConfig:find('PurchasesEnabled = true', 1, true), 'Phase 3 purchases must be enabled')
expect(furnitureConfig:find('PlacementEnabled = true', 1, true), 'Phase 4 placement must be enabled')

print('[mz_furniture][test] residential contract harness passed')
