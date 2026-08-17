MZFurnitureConfig = nil
MZFurnitureLogic = nil
dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')

local function expect(condition, message) if not condition then error(message, 2) end end

local capabilityAllowed = true
local facilityActive = true
local deniedLogs = 0

function GetPlayerName(source) return source == 1 and 'Mafia Member' or nil end
function GetResourceState(resource)
  return ({ mz_core = true, mz_org_activities = true })[resource] and 'started' or 'missing'
end

exports = {
  mz_core = {
    GetPlayerOrgContext = function(_, source)
      if source ~= 1 then return {} end
      return {
        { code = 'mafia', name = 'Mafia', active = true, status = 'active' }
      }
    end,
    CanOrg = function(_, source, orgCode, capability)
      return capabilityAllowed and source == 1 and orgCode == 'mafia'
        and capability == 'facility.furniture.view'
    end,
    CreateDetailedLog = function(_, _, action)
      if action == 'organization_warehouse_read_denied' then deniedLogs = deniedLogs + 1 end
      return true
    end
  },
  mz_org_activities = {
    ListActiveFurnitureFacilitiesForSource = function(_, source, orgCode)
      if source ~= 1 or orgCode ~= 'mafia' then return nil, 'forbidden' end
      if not facilityActive then return nil, 'active_facility_required' end
      return { { id = 9, orgCode = 'mafia', status = 'active' } }
    end
  }
}

MZFurnitureDB = {
  GetOwnerMigrationStatus = function() return { ready = true, invalidRows = 0 } end
}
MZFurnitureRepository = {
  ListOwnedByOwner = function(owner)
    expect(owner.type == 'org' and owner.key == 'mafia', 'repository received an unsafe owner')
    return {
      {
        id = 50, catalogId = 10, catalogCode = 'chair_01', category = 'sala',
        label = 'Cadeira coletiva', description = '', purchasePrice = 500,
        status = 'warehouse', revision = 1
      }
    }
  end
}

MZFurnitureOrganization = nil
dofile('mz_furniture/server/organization.lua')

local contexts = MZFurnitureOrganization.ListContexts(1)
expect(#contexts == 1 and contexts[1].available == true and contexts[1].itemCount == 1,
  'authorized active organization context was not listed')

local opened, warehouse = MZFurnitureOrganization.Open(1, 'MAFIA')
expect(opened == true and warehouse.readOnly == true and #warehouse.items == 1,
  'authorized read-only organization warehouse did not open')
expect(warehouse.purchasesEnabled == false and warehouse.placementEnabled == false,
  'organization warehouse exposed a mutation flag')

facilityActive = false
local suspendedContexts = MZFurnitureOrganization.ListContexts(1)
expect(#suspendedContexts == 1 and suspendedContexts[1].available == false
  and suspendedContexts[1].error == 'organization_facility_required',
  'inactive facility was not represented as unavailable')
local inactiveOpen, inactiveErr = MZFurnitureOrganization.Open(1, 'mafia')
expect(inactiveOpen == false and inactiveErr == 'organization_facility_required',
  'inactive facility did not block the warehouse')

facilityActive = true
capabilityAllowed = false
expect(#MZFurnitureOrganization.ListContexts(1) == 0,
  'organization without capability leaked into the menu')
local deniedOpen, deniedErr = MZFurnitureOrganization.Open(1, 'mafia')
expect(deniedOpen == false and deniedErr == 'organization_warehouse_forbidden',
  'missing capability did not block the warehouse')
expect(deniedLogs == 2, 'denied warehouse attempts were not audited')

print('[mz_furniture][test] organization warehouse read harness passed')
