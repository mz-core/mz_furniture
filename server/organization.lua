MZFurnitureOrganization = MZFurnitureOrganization or {}

local function validSource(source)
  source = tonumber(source)
  if not source or source <= 0 or not GetPlayerName(source) then return nil end
  return math.floor(source)
end

local function resourceExport(resourceName, exportName, ...)
  if GetResourceState(resourceName) ~= 'started' then return nil, 'dependency_unavailable' end
  local args = { ... }
  local ok, result, extra = pcall(function()
    local resource = exports[resourceName]
    return resource[exportName](resource, table.unpack(args))
  end)
  if not ok then return nil, 'dependency_unavailable' end
  return result, extra
end

local function normalizeOrgCode(value)
  if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
  value = MZFurnitureLogic.Trim(tostring(value))
  if value == '' or #value > 64 then return nil end
  return MZFurnitureLogic.NormalizeCode(value)
end

local function activeMembership(source, orgCode)
  local memberships, membershipsErr = resourceExport('mz_org', 'GetPlayerOrgContext', source)
  if type(memberships) ~= 'table' then return nil, membershipsErr or 'organization_service_unavailable' end
  for _, membership in ipairs(memberships) do
    local code = normalizeOrgCode(membership.code)
    local active = membership.active == true
      and tostring(membership.status or 'active'):lower() == 'active'
    if code == orgCode and active then return membership end
  end
  return nil, 'organization_membership_required'
end

local function hasCapability(source, orgCode, capability)
  local allowed, allowedErr = resourceExport(
    'mz_org',
    'CanOrg',
    source,
    orgCode,
    capability
  )
  if allowed ~= true then return false, allowedErr or 'organization_warehouse_forbidden' end
  return true
end

local function hasViewCapability(source, orgCode)
  return hasCapability(source, orgCode, 'facility.furniture.view')
end

local function activeFacilities(source, orgCode)
  local facilities, facilitiesErr = resourceExport(
    'mz_org_activities',
    'ListActiveFurnitureFacilitiesForSource',
    source,
    orgCode
  )
  if type(facilities) ~= 'table' or #facilities == 0 then
    if facilitiesErr == 'active_facility_required' then
      return nil, 'organization_facility_required'
    end
    if facilitiesErr == 'forbidden' then return nil, 'organization_warehouse_forbidden' end
    if facilitiesErr == 'activities_disabled' or facilitiesErr == 'facilities_disabled'
      or facilitiesErr == 'org_furniture_read_disabled' or facilitiesErr == 'schema_not_ready'
      or facilitiesErr == 'dependency_unavailable' then
      return nil, 'organization_facility_unavailable'
    end
    return nil, facilitiesErr or 'organization_facility_required'
  end
  return facilities
end

local function organizationItemDto(item)
  return {
    category = item.category,
    label = item.label,
    description = item.description,
    purchasePrice = item.purchasePrice,
    status = item.status
  }
end

local function logDenied(source, orgCode, reason)
  pcall(function()
    exports['mz_core']:CreateDetailedLog('furniture', 'organization_warehouse_read_denied', {
      actor = { type = 'player', source = tonumber(source) },
      target = { type = 'organization', id = tostring(orgCode or 'invalid') },
      data = { reason = tostring(reason or 'unknown') }
    })
  end)
end

local function resolve(source, rawOrgCode, capability)
  source = validSource(source)
  if not source then return nil, 'player_not_loaded' end
  if MZFurnitureConfig.Enabled ~= true
    or MZFurnitureConfig.OrganizationWarehouseReadEnabled ~= true then
    return nil, 'organization_warehouse_disabled'
  end
  local migration = MZFurnitureDB.GetOwnerMigrationStatus()
  if migration.ready ~= true then return nil, 'organization_owner_schema_not_ready' end
  local orgCode = normalizeOrgCode(rawOrgCode)
  if not orgCode then return nil, 'organization_not_found' end
  local membership, membershipErr = activeMembership(source, orgCode)
  if not membership then return nil, membershipErr end
  local allowed, allowedErr = hasCapability(
    source,
    orgCode,
    capability or 'facility.furniture.view'
  )
  if not allowed then return nil, allowedErr end
  local facilities, facilitiesErr = activeFacilities(source, orgCode)
  if not facilities then return nil, facilitiesErr end
  return {
    source = source,
    orgCode = orgCode,
    orgName = tostring(membership.name or orgCode),
    facilities = facilities
  }
end

function MZFurnitureOrganization.ListContexts(source)
  source = validSource(source)
  if not source or MZFurnitureConfig.Enabled ~= true
    or MZFurnitureConfig.OrganizationWarehouseReadEnabled ~= true then return {} end
  local migration = MZFurnitureDB.GetOwnerMigrationStatus()
  if migration.ready ~= true then return {} end
  local memberships = resourceExport('mz_org', 'GetPlayerOrgContext', source)
  if type(memberships) ~= 'table' then return {} end
  local result, seen = {}, {}
  for _, membership in ipairs(memberships) do
    local orgCode = normalizeOrgCode(membership.code)
    local active = membership.active == true
      and tostring(membership.status or 'active'):lower() == 'active'
    if orgCode and active and not seen[orgCode] then
      seen[orgCode] = true
      local allowed = hasViewCapability(source, orgCode)
      if allowed then
        local facilities, facilitiesErr = activeFacilities(source, orgCode)
        local available = type(facilities) == 'table' and #facilities > 0
        local itemCount = 0
        if available then
          itemCount = #MZFurnitureRepository.ListOwnedByOwner({ type = 'org', key = orgCode })
        end
        local canPurchase = false
        if available and MZFurnitureConfig.OrganizationOwnershipEnabled == true
          and MZFurnitureConfig.OrganizationPurchasesEnabled == true then
          canPurchase = hasCapability(source, orgCode, 'facility.furniture.buy') == true
            and type(MZFurnitureOrganizationPurchase) == 'table'
            and MZFurnitureOrganizationPurchase.IsReady() == true
        end
        result[#result + 1] = {
          orgCode = orgCode,
          orgName = tostring(membership.name or orgCode),
          available = available,
          error = available and nil or facilitiesErr,
          facilityCount = available and #facilities or 0,
          itemCount = itemCount,
          purchasesEnabled = canPurchase,
          readOnly = canPurchase ~= true
        }
      end
    end
  end
  table.sort(result, function(left, right) return left.orgName:lower() < right.orgName:lower() end)
  return result
end

function MZFurnitureOrganization.Open(source, rawOrgCode)
  if MZFurnitureOrganizationPurchase then
    pcall(MZFurnitureOrganizationPurchase.Reconcile, source)
  end
  local context, contextErr = resolve(source, rawOrgCode, 'facility.furniture.view')
  if not context then
    logDenied(source, rawOrgCode, contextErr)
    return false, contextErr
  end
  local owned = MZFurnitureRepository.ListOwnedByOwner({
    type = 'org',
    key = context.orgCode
  })
  local items, warehouseCount, placedCount = {}, 0, 0
  for _, item in ipairs(owned) do
    items[#items + 1] = organizationItemDto(item)
    if item.status == 'warehouse' then warehouseCount = warehouseCount + 1 end
    if item.status == 'placed' then placedCount = placedCount + 1 end
  end
  local purchasesEnabled = MZFurnitureConfig.OrganizationOwnershipEnabled == true
    and MZFurnitureConfig.OrganizationPurchasesEnabled == true
    and hasCapability(context.source, context.orgCode, 'facility.furniture.buy') == true
    and type(MZFurnitureOrganizationPurchase) == 'table'
    and MZFurnitureOrganizationPurchase.IsReady() == true
  return true, {
    organization = { code = context.orgCode, name = context.orgName },
    facilityCount = #context.facilities,
    warehouseCount = warehouseCount,
    placedCount = placedCount,
    items = items,
    readOnly = purchasesEnabled ~= true,
    purchasesEnabled = purchasesEnabled,
    placementEnabled = false
  }
end

function MZFurnitureOrganization.ResolvePurchaseContext(source, rawOrgCode)
  local context, contextErr = resolve(source, rawOrgCode, 'facility.furniture.buy')
  if not context and contextErr == 'organization_warehouse_forbidden' then
    return nil, 'organization_purchase_forbidden'
  end
  return context, contextErr
end
