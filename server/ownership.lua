MZFurnitureOwnership = MZFurnitureOwnership or {}

local State = {
  running = false,
  lastRunAt = nil,
  lastReason = nil,
  lastSummary = nil,
  totalRuns = 0,
  totalRepaired = 0
}
local Locks = {}

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function log(action, actorSource, target, data)
  if GetResourceState('mz_core') ~= 'started' then return end
  pcall(function()
    local actorType = 'system'
    if tonumber(actorSource) and tonumber(actorSource) > 0 then
      local permissionOk, isStaff = pcall(function()
        return exports['mz_core']:HasGlobalPermission(
          tonumber(actorSource),
          MZFurnitureConfig.Permissions.Recovery
        )
      end)
      actorType = permissionOk and isStaff == true and 'staff' or 'player'
    end
    exports['mz_core']:CreateDetailedLog('furniture', action, {
      actor = {
        type = actorType,
        id = tonumber(actorSource) and tostring(actorSource) or 'owner_reconciliation',
        source = tonumber(actorSource)
      },
      target = { type = 'property', id = tostring(target or 'batch') },
      data = type(data) == 'table' and data or {}
    })
  end)
end

local function notifyOnlineOwner(citizenid, count, houseCode)
  citizenid = trim(citizenid)
  if citizenid == '' or count <= 0 or GetResourceState('mz_core') ~= 'started' then return end
  for _, rawSource in ipairs(GetPlayers()) do
    local source = tonumber(rawSource)
    local ok, identity = pcall(function()
      return exports['mz_core']:ResolvePlayerIdentity(source)
    end)
    if ok and type(identity) == 'table' and identity.ok == true
      and trim(identity.citizenid) == citizenid then
      TriggerClientEvent('mz_furniture:client:ownershipReconciled', source, {
        count = count,
        houseCode = houseCode
      })
      return
    end
  end
end

local function collect(propertyId, houseCode, ownerCitizenid, reason, actorSource)
  propertyId = math.floor(tonumber(propertyId) or 0)
  ownerCitizenid = trim(ownerCitizenid):sub(1, 64)
  if propertyId <= 0 or ownerCitizenid == '' then
    return false, 'invalid_owner_reconciliation'
  end
  local key = ('%d:%s'):format(propertyId, ownerCitizenid)
  if Locks[key] then return false, 'owner_reconciliation_in_progress' end
  Locks[key] = true
  local callOk, result, resultErr = pcall(
    MZFurnitureRepository.CollectPropertyFurniture,
    propertyId,
    ownerCitizenid
  )
  Locks[key] = nil
  if not callOk or not result then
    local err = callOk and resultErr or result
    print(('[mz_furniture][ownership] collect failed property=%s owner=%s error=%s'):format(
      tostring(propertyId), ownerCitizenid, tostring(err)
    ))
    return false, err or 'owner_reconciliation_failed'
  end
  if result.count > 0 then
    MZFurnitureResidential.InvalidateProperty(propertyId)
    notifyOnlineOwner(ownerCitizenid, result.count, houseCode)
    log('furniture.owner_reconciled', actorSource, houseCode or propertyId, {
      propertyId = propertyId,
      houseCode = houseCode,
      previousOwner = ownerCitizenid,
      reason = reason,
      count = result.count,
      ownedFurnitureIds = (function()
        local ids = {}
        for _, item in ipairs(result.items or {}) do ids[#ids + 1] = item.ownedFurnitureId end
        return ids
      end)()
    })
  end
  return true, result
end

function MZFurnitureOwnership.HandleOwnershipChange(payload)
  if MZFurnitureConfig.OwnerReconciliationEnabled ~= true then
    return false, 'owner_reconciliation_disabled'
  end
  payload = type(payload) == 'table' and payload or {}
  local previousOwner = trim(payload.previousOwner):sub(1, 64)
  local property, propertyErr = MZFurnitureRepository.ResolvePropertyIdentity(
    payload.houseCode,
    payload.propertyId
  )
  if not property then return false, propertyErr end
  if previousOwner ~= '' and previousOwner == trim(payload.newOwner) then
    return true, { count = 0, propertyId = property.propertyId }
  end
  local owners = MZFurnitureRepository.ListPropertyFurnitureOwners(property.propertyId)
  if #owners == 0 and previousOwner ~= '' then
    owners[1] = { ownerCitizenid = previousOwner, itemCount = 0 }
  end
  local total, failed = 0, 0
  for _, owner in ipairs(owners) do
    local ok, result = collect(
      property.propertyId,
      property.houseCode,
      owner.ownerCitizenid,
      trim(payload.reason) ~= '' and trim(payload.reason) or 'ownership_changed',
      payload.actorSource
    )
    if ok then total = total + (result.count or 0)
    else failed = failed + 1 end
  end
  if failed > 0 then return false, 'owner_reconciliation_failed' end
  return true, { count = total, propertyId = property.propertyId }
end

function MZFurnitureOwnership.ReconcileAll(reason, actorSource)
  if MZFurnitureConfig.OwnerReconciliationEnabled ~= true then
    return false, 'owner_reconciliation_disabled'
  end
  if State.running then return false, 'owner_reconciliation_in_progress' end
  State.running = true
  local limit = math.max(1, math.min(
    500,
    math.floor(tonumber(MZFurnitureConfig.OwnerReconciliationBatchSize) or 100)
  ))
  local summary = {
    ownershipGroups = 0,
    collectedItems = 0,
    orphanItems = 0,
    danglingPlacements = 0,
    failed = 0
  }
  local callOk, callErr = xpcall(function()
    for _, issue in ipairs(MZFurnitureRepository.ListOwnershipMismatches(limit)) do
      summary.ownershipGroups = summary.ownershipGroups + 1
      local ok, result = collect(
        issue.propertyId,
        issue.houseCode,
        issue.furnitureOwner,
        reason or 'periodic_consistency_scan',
        actorSource
      )
      if ok then summary.collectedItems = summary.collectedItems + (result.count or 0)
      else summary.failed = summary.failed + 1 end
    end
    for _, item in ipairs(MZFurnitureRepository.ListOrphanPlacedItems(limit)) do
      if MZFurnitureRepository.RepairOrphanPlacedItem(item) then
        summary.orphanItems = summary.orphanItems + 1
      else
        summary.failed = summary.failed + 1
      end
    end
    for _, placement in ipairs(MZFurnitureRepository.ListDanglingPlacements(limit)) do
      if MZFurnitureRepository.RemoveDanglingPlacement(placement) then
        summary.danglingPlacements = summary.danglingPlacements + 1
        MZFurnitureResidential.InvalidateProperty(placement.propertyId)
      else
        summary.failed = summary.failed + 1
      end
    end
  end, function(err)
    if type(debug) == 'table' and type(debug.traceback) == 'function' then
      return debug.traceback(tostring(err), 2)
    end
    return tostring(err)
  end)
  State.running = false
  State.lastRunAt = os.time()
  State.lastReason = tostring(reason or 'periodic_consistency_scan')
  State.totalRuns = State.totalRuns + 1
  if not callOk then
    summary.failed = summary.failed + 1
    print(('[mz_furniture][ownership] reconciliation exception: %s'):format(tostring(callErr)))
  end
  State.totalRepaired = State.totalRepaired + summary.collectedItems
    + summary.orphanItems + summary.danglingPlacements
  State.lastSummary = summary
  log('furniture.consistency_reconciliation', actorSource, 'batch', {
    reason = State.lastReason,
    success = callOk,
    summary = summary
  })
  return callOk, callOk and summary or 'owner_reconciliation_failed'
end

function MZFurnitureOwnership.GetOverview()
  local overview = MZFurnitureRepository.GetRecoveryOverview()
  overview.runtime = {
    running = State.running,
    lastRunAt = State.lastRunAt,
    lastReason = State.lastReason,
    lastSummary = State.lastSummary,
    totalRuns = State.totalRuns,
    totalRepaired = State.totalRepaired
  }
  return overview
end

function MZFurnitureOwnership.ReconcilePlayerFinances(targetSource)
  targetSource = tonumber(targetSource)
  if not targetSource or targetSource <= 0 or not GetPlayerName(targetSource) then
    return false, 'player_not_online'
  end
  if GetResourceState('mz_core') ~= 'started' then return false, 'core_unavailable' end
  local identityOk, identity = pcall(function()
    return exports['mz_core']:ResolvePlayerIdentity(targetSource)
  end)
  if not identityOk or type(identity) ~= 'table' or identity.ok ~= true
    or trim(identity.citizenid) == '' then
    return false, 'player_not_loaded'
  end
  local citizenid = trim(identity.citizenid):sub(1, 64)
  local purchaseOk, purchaseSummary = MZFurniturePurchase.Reconcile(targetSource, citizenid)
  local resaleOk, resaleSummary = MZFurnitureResale.Reconcile(targetSource, citizenid)
  if purchaseOk ~= true or resaleOk ~= true then return false, 'financial_reconciliation_failed' end
  return true, {
    citizenid = citizenid,
    purchase = purchaseSummary,
    resale = resaleSummary
  }
end

AddEventHandler('mz_houses:server:propertyOwnershipChanged', function(payload)
  SetTimeout(0, function()
    local ok, result = pcall(MZFurnitureOwnership.HandleOwnershipChange, payload)
    if not ok then
      print(('[mz_furniture][ownership] event exception: %s'):format(tostring(result)))
    end
  end)
end)

CreateThread(function()
  while not MZFurnitureCatalog.IsReady() do Wait(1000) end
  if MZFurnitureConfig.OwnerReconciliationEnabled ~= true then return end
  MZFurnitureOwnership.ReconcileAll('resource_startup')
  local interval = math.max(
    60,
    math.floor(tonumber(MZFurnitureConfig.OwnerReconciliationIntervalSeconds) or 300)
  ) * 1000
  while true do
    Wait(interval)
    MZFurnitureOwnership.ReconcileAll('periodic_consistency_scan')
  end
end)
