local function read(path)
  local file = assert(io.open(path, 'rb'))
  local value = file:read('*a')
  file:close()
  return value
end
local function expect(condition, message) if not condition then error(message, 2) end end

local config = read('mz_furniture/shared/config.lua')
local repository = read('mz_furniture/server/repository.lua')
local database = read('mz_furniture/server/database.lua')
local main = read('mz_furniture/server/main.lua')
local manifest = read('mz_furniture/fxmanifest.lua')
local organization = read('mz_furniture/server/organization.lua')
local organizationPurchase = read('mz_furniture/server/organization_purchase.lua')
local player = read('mz_furniture/server/player.lua')
local menu = read('mz_furniture/client/menu.lua')
local orgCapabilities = read('mz_org/shared/capabilities.lua')
local orgSeed = read('mz_org/server/domain/default_orgs.lua')
local activitiesConfig = read('mz_org_activities/shared/config.lua')
local activitiesService = read('mz_org_activities/server/facility_service.lua')
local activitiesMain = read('mz_org_activities/server/main.lua')

for _, flag in ipairs({
  'OrganizationOwnershipEnabled = true',
  'OrganizationPurchasesEnabled = true',
  'OrganizationPlacementEnabled = false'
}) do expect(config:find(flag, 1, true), ('organization rollout flag mismatch: %s'):format(flag)) end

expect(repository:find('ListOwnedByOwner', 1, true), 'generic owner list is missing')
expect(repository:find('GetOwnedItemByOwner', 1, true), 'generic owner item read is missing')
expect(repository:find("SELECT 'player', LOWER(t.citizenid), t.citizenid", 1, true),
  'residential purchase is not dual-writing player ownership')
expect(database:find('idx_mz_owned_furniture_owner_scope_status', 1, true),
  'generic owner index is missing')
expect(main:find("exports('GetOwnerMigrationStatus'", 1, true),
  'owner migration status export is missing')
expect(main:find("RegisterCommand('mfurniture_owner_schema'", 1, true),
  'owner migration console diagnostic is missing')
expect(main:find("RegisterCommand('mfurniture_org_warehouse'", 1, true),
  'organization warehouse console diagnostic is missing')
expect(main:find("RegisterCommand('mfurniture_org_purchase_status'", 1, true),
  'organization purchase console diagnostic is missing')
expect(repository:find("SELECT 'org', t.org_code, NULL", 1, true),
  'controlled organization item grant is missing')
expect(repository:find('org_purchase_transaction_id', 1, true),
  'organization ownership is not bound to its purchase transaction')
expect(organizationPurchase:find("purpose = 'furniture_purchase'", 1, true),
  'organization purchase does not use the dedicated financial purpose')
expect(organizationPurchase:find("'facility.furniture.buy'", 1, true) == nil,
  'purchase capability must be enforced by the organization authority service')
expect(organization:find("'facility.furniture.buy'", 1, true),
  'organization purchase capability is not enforced')
expect(config:find('OrganizationWarehouseReadEnabled = true', 1, true),
  'read-only organization warehouse flag is missing')
expect(manifest:find("'server/organization.lua'", 1, true),
  'organization warehouse service is not loaded')
expect(organization:find("'facility.furniture.view'", 1, true),
  'organization warehouse capability is not enforced')
expect(organization:find('ListActiveFurnitureFacilitiesForSource', 1, true),
  'active facility authority is not enforced')
expect(not organization:find('INSERT ', 1, true) and not organization:find('UPDATE ', 1, true)
  and not organization:find('DELETE ', 1, true),
  'read-only organization service contains a mutation query')
expect(player:find("'mz_furniture:server:openOrganizationWarehouse'", 1, true),
  'rate-limited organization warehouse callback is missing')
expect(menu:find("action == 'organizationWarehouse'", 1, true)
  and menu:find("title = 'Somente leitura'", 1, true),
  'read-only organization warehouse menu is missing')
expect(orgCapabilities:find("'facility.furniture.view'", 1, true),
  'organization furniture read capability is not registered')
expect(orgSeed:find("'facility.furniture.view'", 1, true),
  'mafia seed does not grant the read capability')
expect(activitiesConfig:find('OrgFurnitureReadEnabled = true', 1, true)
  and activitiesConfig:find('OrgFurnitureEnabled = false', 1, true),
  'activities read/write gates are not separated')
expect(activitiesService:find('ListActiveForFurnitureSource', 1, true)
  and activitiesMain:find("exports('ListActiveFurnitureFacilitiesForSource'", 1, true),
  'active facility furniture authority is missing')

local _, residentialMutationGuards = repository:gsub("owner_type = 'player'", '')
expect(residentialMutationGuards >= 15,
  'residential mutations and reconciliation are not isolated from organization rows')
expect(repository:find("o.id IS NULL OR (o.owner_type = 'player'", 1, true),
  'residential dangling placement repair can reach organization rows')

print('[mz_furniture][test] organization owner foundation contract harness passed')
