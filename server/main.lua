local State = {
  initializing = false,
  error = nil
}

local function hasPermission(source, permission)
  source = tonumber(source)
  if not source or source <= 0 or GetResourceState('mz_core') ~= 'started' then return false end
  local ok, allowed = pcall(function()
    return exports['mz_core']:HasGlobalPermission(source, permission)
  end)
  return ok and allowed == true
end

local function featureFlags()
  return {
    enabled = MZFurnitureConfig.Enabled == true,
    catalogEnabled = MZFurnitureConfig.CatalogEnabled == true,
    purchasesEnabled = MZFurnitureConfig.PurchasesEnabled == true,
    placementEnabled = MZFurnitureConfig.PlacementEnabled == true,
    runtimeSyncEnabled = MZFurnitureConfig.RuntimeSyncEnabled == true,
    resaleEnabled = MZFurnitureConfig.ResaleEnabled == true,
    ownerReconciliationEnabled = MZFurnitureConfig.OwnerReconciliationEnabled == true,
    residentialAuthorityEnabled = MZFurnitureConfig.ResidentialAuthorityEnabled == true,
    organizationWarehouseReadEnabled = MZFurnitureConfig.OrganizationWarehouseReadEnabled == true,
    organizationOwnershipEnabled = MZFurnitureConfig.OrganizationOwnershipEnabled == true,
    organizationPurchasesEnabled = MZFurnitureConfig.OrganizationPurchasesEnabled == true,
    organizationPlacementEnabled = MZFurnitureConfig.OrganizationPlacementEnabled == true
  }
end

local function initialize()
  if State.initializing or MZFurnitureCatalog.IsReady() then return end
  State.initializing = true
  local ok, err = pcall(function()
    MZFurnitureDB.Ensure()
    if MZFurnitureConfig.AutoSeedCatalog == true then
      MZFurnitureRepository.Seed(MZFurnitureCatalogSeed, 'system:seed')
      if MZFurnitureConfig.EnableReviewedSeedItems == true then
        MZFurnitureRepository.EnableReviewedSeed(MZFurnitureCatalogSeed)
      end
    end
    local recovery = MZFurnitureRepository.RecoverStartupStates()
    local count = MZFurnitureCatalog.Load()
    print(('[mz_furniture] catalog ready items=%d gameplay=%s recovery_failed=%d recovery_review=%d'):format(
      count,
      MZFurnitureConfig.Enabled == true and 'enabled' or 'disabled',
      recovery.failed,
      recovery.manualReview
    ))
  end)
  State.initializing = false
  State.error = ok and nil or tostring(err)
  if not ok then print(('[mz_furniture] initialization failed: %s'):format(State.error)) end
end

CreateThread(function()
  Wait(500)
  initialize()
end)

exports('IsReady', function()
  return MZFurnitureCatalog.IsReady(), State.error
end)

exports('GetFeatureFlags', featureFlags)

exports('GetOwnerMigrationStatus', function()
  return MZFurnitureDB.GetOwnerMigrationStatus()
end)

exports('GetOrganizationWarehouseForSource', function(source, orgCode)
  local callOk, ok, result = pcall(MZFurnitureOrganization.Open, source, orgCode)
  if not callOk then return false, 'organization_warehouse_service_failed' end
  return ok, result
end)

RegisterCommand('mfurniture_owner_schema', function(source)
  if tonumber(source) ~= 0 then return end
  local status = MZFurnitureDB.GetOwnerMigrationStatus()
  print(('[mz_furniture][owner_schema] ready=%s org_ready=%s player_rows=%d org_rows=%d invalid_rows=%d org_gameplay=%s error=%s'):format(
    status.ready == true and 'yes' or 'no',
    status.organizationReady == true and 'yes' or 'no',
    status.playerRows,
    status.organizationRows,
    status.invalidRows,
    MZFurnitureConfig.OrganizationOwnershipEnabled == true and 'enabled' or 'disabled',
    State.error or 'none'
  ))
end, false)

RegisterCommand('mfurniture_org_warehouse', function(source, args)
  if tonumber(source) ~= 0 then return end
  local targetSource = math.floor(tonumber(args and args[1]) or 0)
  local orgCode = tostring(args and args[2] or '')
  if targetSource <= 0 or orgCode == '' then
    print('[mz_furniture][org_warehouse] usage=mfurniture_org_warehouse <player_id> <org_code>')
    return
  end
  local ok, result = MZFurnitureOrganization.Open(targetSource, orgCode)
  if ok ~= true then
    print(('[mz_furniture][org_warehouse] player=%d org=%s available=no reason=%s'):format(
      targetSource,
      orgCode,
      tostring(result or 'unknown')
    ))
    return
  end
  print(('[mz_furniture][org_warehouse] player=%d org=%s available=yes read_only=%s purchases=%s facilities=%d warehouse=%d placed=%d'):format(
    targetSource,
    tostring(result.organization and result.organization.code or orgCode),
    result.readOnly == true and 'yes' or 'no',
    result.purchasesEnabled == true and 'yes' or 'no',
    tonumber(result.facilityCount) or 0,
    tonumber(result.warehouseCount) or 0,
    tonumber(result.placedCount) or 0
  ))
end, false)

RegisterCommand('mfurniture_org_purchase_status', function(source, args)
  if tonumber(source) ~= 0 then return end
  local targetSource = math.floor(tonumber(args and args[1]) or 0)
  local orgCode = tostring(args and args[2] or '')
  if targetSource <= 0 or orgCode == '' then
    print('[mz_furniture][org_purchase] usage=mfurniture_org_purchase_status <player_id> <org_code>')
    return
  end
  local ready, readyErr = MZFurnitureOrganizationPurchase.IsReady()
  if ready ~= true then
    print(('[mz_furniture][org_purchase] player=%d org=%s ready=no reason=%s'):format(
      targetSource,
      orgCode,
      tostring(readyErr or 'unknown')
    ))
    return
  end
  local context, contextErr = MZFurnitureOrganization.ResolvePurchaseContext(targetSource, orgCode)
  if not context then
    print(('[mz_furniture][org_purchase] player=%d org=%s ready=yes authorized=no reason=%s'):format(
      targetSource,
      orgCode,
      tostring(contextErr or 'unknown')
    ))
    return
  end
  print(('[mz_furniture][org_purchase] player=%d org=%s ready=yes authorized=yes facilities=%d'):format(
    targetSource,
    tostring(context.orgCode),
    #(context.facilities or {})
  ))
end, false)

exports('ListCatalogForAdmin', function(source)
  if not hasPermission(source, MZFurnitureConfig.Permissions.View) then
    return false, 'permission_denied'
  end
  MZFurnitureCatalog.RefreshIfStale()
  local items, err = MZFurnitureCatalog.ListForAdmin()
  if not items then return false, err end
  return true, {
    items = items,
    flags = featureFlags()
  }
end)

exports('GetCatalogItem', function(identifier)
  if MZFurnitureConfig.CatalogEnabled ~= true then return nil, 'catalog_disabled' end
  MZFurnitureCatalog.RefreshIfStale()
  local item = MZFurnitureCatalog.Get(identifier)
  if not item or item.archived == true or item.enabled ~= true then return nil, 'item_unavailable' end
  return item
end)

exports('ReloadCatalogForAdmin', function(source)
  if not hasPermission(source, MZFurnitureConfig.Permissions.Manage) then
    return false, 'permission_denied'
  end
  local ok, result = pcall(MZFurnitureCatalog.Load)
  if not ok then return false, tostring(result) end
  return true, result
end)

exports('GetRecoveryOverviewForAdmin', function(source)
  if not hasPermission(source, MZFurnitureConfig.Permissions.Recovery) then
    return false, 'permission_denied'
  end
  local ok, result = pcall(MZFurnitureOwnership.GetOverview)
  if not ok then return false, 'recovery_overview_failed' end
  return true, result
end)

exports('RunOwnerReconciliationForAdmin', function(source, reason)
  if not hasPermission(source, MZFurnitureConfig.Permissions.Recovery) then
    return false, 'permission_denied'
  end
  return MZFurnitureOwnership.ReconcileAll(
    MZFurnitureLogic.Trim(reason) ~= '' and MZFurnitureLogic.Trim(reason)
      or 'staff_manual_reconciliation',
    source
  )
end)

exports('ReconcilePlayerFinancesForAdmin', function(source, targetSource)
  if not hasPermission(source, MZFurnitureConfig.Permissions.Recovery) then
    return false, 'permission_denied'
  end
  return MZFurnitureOwnership.ReconcilePlayerFinances(targetSource)
end)
