local function read(path)
  local file = assert(io.open(path, 'rb'))
  local content = file:read('*a')
  file:close()
  return content
end

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local houseService = read('mz_houses/server/service.lua')
local houseCommerce = read('mz_houses/server/commerce.lua')
local ownership = read('mz_furniture/server/ownership.lua')
local repository = read('mz_furniture/server/repository.lua')
local furnitureMain = read('mz_furniture/server/main.lua')
local adminServer = read('mz_admin/server/world.lua')
local adminClient = read('mz_admin/client/world_furniture_catalog.lua')

expect(houseService:find("'mz_houses:server:propertyOwnershipChanged'", 1, true)
  and houseService:find('previousOwner = previousOwner', 1, true)
  and houseService:find('newOwner = citizenid', 1, true),
  'manual owner changes must emit the explicit ownership contract')
expect(houseCommerce:find("'mz_houses:server:propertyOwnershipChanged'", 1, true)
  and houseCommerce:find("reason = 'property_purchase_completed'", 1, true),
  'property purchases must emit the ownership contract')

expect(ownership:find("AddEventHandler('mz_houses:server:propertyOwnershipChanged'", 1, true),
  'furniture does not consume the ownership contract')
expect(ownership:find("MZFurnitureOwnership.ReconcileAll('resource_startup')", 1, true)
  and ownership:find("MZFurnitureOwnership.ReconcileAll('periodic_consistency_scan')", 1, true),
  'startup and periodic consistency repair are required')
expect(repository:find('function MZFurnitureRepository.CollectPropertyFurniture', 1, true)
  and repository:find('MySQL.transaction.await', 1, true)
  and repository:find("status = 'warehouse', current_property_id = NULL", 1, true),
  'offline owner collection must be atomic and return items to warehouse')
expect(repository:find('ListOwnershipMismatches', 1, true)
  and repository:find('ListPropertyFurnitureOwners', 1, true)
  and repository:find('ListOrphanPlacedItems', 1, true)
  and repository:find('ListDanglingPlacements', 1, true),
  'consistency scanners are incomplete')
local ownershipComparison = 'BINARY h.owner_citizenid <> BINARY o.owner_citizenid'
local firstComparison = repository:find(ownershipComparison, 1, true)
local secondComparison = firstComparison
  and repository:find(ownershipComparison, firstComparison + #ownershipComparison, true)
expect(firstComparison and secondComparison,
  'ownership reconciliation queries must tolerate different database collations')

expect(furnitureMain:find("exports('GetRecoveryOverviewForAdmin'", 1, true)
  and furnitureMain:find("exports('RunOwnerReconciliationForAdmin'", 1, true)
  and furnitureMain:find("exports('ReconcilePlayerFinancesForAdmin'", 1, true),
  'staff recovery exports are incomplete')
expect(adminServer:find("'furnitureRecovery'", 1, true)
  and adminClient:find("title = 'Recuperacao e consistencia'", 1, true),
  'admin recovery is not permission-gated or visible')

print('[mz_furniture][test] phase 7 contract harness passed')
