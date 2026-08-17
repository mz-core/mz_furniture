MZFurniturePlacement = MZFurniturePlacement or {}

local Tokens = {}
local SourceTokens = {}
local Locks = {}
local PropertyLocks = {}
local Sequence = 0

local function identity(source)
  if GetResourceState('mz_core') ~= 'started' then return nil, 'core_unavailable' end
  local callOk, result = pcall(function()
    return exports['mz_core']:ResolvePlayerIdentity(source)
  end)
  if not callOk or type(result) ~= 'table' or result.ok ~= true
    or MZFurnitureLogic.Trim(result.citizenid) == '' then
    return nil, result and result.error or 'player_not_loaded'
  end
  return tostring(result.citizenid):sub(1, 64)
end

local function token(source)
  Sequence = (Sequence + 1) % 1000000
  return ('fplace_%d_%d_%06d_%06d'):format(
    os.time(),
    math.floor(tonumber(source) or 0),
    Sequence,
    math.random(0, 999999)
  )
end

local function log(action, source, citizenid, data)
  if GetResourceState('mz_core') ~= 'started' then return end
  pcall(function()
    exports['mz_core']:CreateDetailedLog('furniture', action, {
      actor = { type = 'player', id = tostring(citizenid), source = tonumber(source) },
      target = {
        type = 'owned_furniture',
        id = tostring(data and data.ownedFurnitureId or 'unknown')
      },
      data = type(data) == 'table' and data or {}
    })
  end)
end

local function publicPlacement(row)
  return {
    id = row.id,
    propertyId = row.propertyId,
    ownedFurnitureId = row.ownedFurnitureId,
    catalogId = row.catalogId,
    catalogCode = row.catalogCode,
    label = row.label,
    modelHash = row.modelHash,
    modelName = row.modelName,
    footprintRadius = row.footprintRadius,
    offset = row.offset,
    rotation = row.rotation,
    collisionEnabled = row.collisionEnabled,
    visible = row.visible,
    revision = row.revision,
    ownedRevision = row.ownedRevision
  }
end

local function broadcastToViewers(eventName, propertyId, bucket, payload)
  if MZFurnitureConfig.RuntimeSyncEnabled ~= true then return end
  local listOk, viewers = pcall(
    MZFurnitureResidential.ListViewers,
    propertyId,
    bucket
  )
  if not listOk or type(viewers) ~= 'table' then
    print(('[mz_furniture][sync] viewer list failed property=%s'):format(tostring(propertyId)))
    return
  end
  for _, viewer in ipairs(viewers) do
    pcall(TriggerClientEvent, eventName, viewer, payload)
  end
end

local function pushSnapshot(source)
  local ok, snapshot = MZFurniturePlacement.Snapshot(source)
  if ok == true then
    TriggerClientEvent('mz_furniture:client:propertySnapshot', source, snapshot)
  end
  return ok, snapshot
end

local function contextFor(source, expectedPropertyId)
  local citizenid, citizenErr = identity(source)
  if not citizenid then return nil, citizenErr end
  local allowed, context = MZFurnitureResidential.Get(source)
  if allowed ~= true or type(context) ~= 'table' then return nil, context end
  if tostring(context.citizenid or '') ~= citizenid then
    return nil, 'residential_identity_mismatch'
  end
  if expectedPropertyId and tonumber(context.propertyId) ~= tonumber(expectedPropertyId) then
    return nil, 'property_context_changed'
  end
  context.citizenid = citizenid
  return context
end

local function findPlacement(rows, ownedFurnitureId)
  ownedFurnitureId = tonumber(ownedFurnitureId)
  for _, row in ipairs(rows or {}) do
    if tonumber(row.ownedFurnitureId) == ownedFurnitureId then return row end
  end
  return nil
end

local function clearSourceToken(source)
  local previous = SourceTokens[tonumber(source)]
  if previous then Tokens[previous] = nil end
  SourceTokens[tonumber(source)] = nil
end

function MZFurniturePlacement.Snapshot(source)
  source = tonumber(source)
  if not source or source <= 0 or not GetPlayerName(source) then
    return false, 'player_not_loaded'
  end
  if MZFurnitureConfig.Enabled ~= true or MZFurnitureConfig.PlacementEnabled ~= true then
    return false, 'furniture_placement_disabled'
  end
  local allowed, context = MZFurnitureResidential.GetViewer(source)
  if allowed ~= true or type(context) ~= 'table' then return false, context end
  local placements = MZFurnitureRepository.ListPropertyPlacements(context.propertyId)
  local result = {}
  for _, row in ipairs(placements) do result[#result + 1] = publicPlacement(row) end
  return true, {
    propertyId = context.propertyId,
    houseCode = context.houseCode,
    shell = context.shell,
    bucket = context.bucket,
    canEdit = context.canEdit == true,
    placements = result
  }
end

function MZFurniturePlacement.Begin(source, action, ownedFurnitureId)
  source = tonumber(source)
  action = MZFurnitureLogic.Trim(action):lower()
  ownedFurnitureId = math.floor(tonumber(ownedFurnitureId) or 0)
  if not source or source <= 0 or not GetPlayerName(source) then
    return false, 'player_not_loaded'
  end
  if MZFurnitureConfig.Enabled ~= true or MZFurnitureConfig.PlacementEnabled ~= true then
    return false, 'furniture_placement_disabled'
  end
  if action ~= 'place' and action ~= 'move' then return false, 'invalid_placement_action' end
  if ownedFurnitureId <= 0 then return false, 'invalid_owned_furniture' end
  local context, contextErr = contextFor(source)
  if not context then return false, contextErr end
  local item = MZFurnitureRepository.GetOwnedItem(context.citizenid, ownedFurnitureId)
  if not item then return false, 'owned_furniture_not_found' end
  local placement
  if action == 'place' then
    if item.status ~= 'warehouse' or item.currentPropertyId ~= nil then
      return false, 'furniture_not_in_warehouse'
    end
    local total = MZFurnitureRepository.CountPropertyPlacements(context.propertyId)
    if total >= math.floor(tonumber(MZFurnitureConfig.MaxItemsPerProperty) or 100) then
      return false, 'property_furniture_limit'
    end
    if item.maxPerProperty then
      local sameCatalog = MZFurnitureRepository.CountPropertyPlacements(
        context.propertyId,
        item.catalogId
      )
      if sameCatalog >= item.maxPerProperty then return false, 'catalog_furniture_limit' end
    end
  else
    if item.status ~= 'placed' or item.currentPropertyId ~= tonumber(context.propertyId) then
      return false, 'furniture_not_in_current_property'
    end
    placement = MZFurnitureRepository.GetPlacementByOwned(ownedFurnitureId)
    if not placement or placement.propertyId ~= tonumber(context.propertyId) then
      return false, 'placement_not_found'
    end
  end

  clearSourceToken(source)
  local placementToken = token(source)
  local ttl = math.max(
    30,
    math.min(300, math.floor(tonumber(MZFurnitureConfig.PlacementTokenTtlSeconds) or 120))
  )
  Tokens[placementToken] = {
    token = placementToken,
    source = source,
    citizenid = context.citizenid,
    propertyId = tonumber(context.propertyId),
    houseCode = context.houseCode,
    bucket = tonumber(context.bucket),
    action = action,
    ownedFurnitureId = ownedFurnitureId,
    ownedRevision = item.revision,
    placementRevision = placement and placement.revision or nil,
    catalogId = item.catalogId,
    footprintRadius = item.footprintRadius,
    collisionEnabled = item.collisionEnabled,
    expiresAt = os.time() + ttl
  }
  SourceTokens[source] = placementToken
  return true, {
    token = placementToken,
    action = action,
    ownedFurnitureId = ownedFurnitureId,
    label = item.label,
    modelHash = item.modelHash,
    modelName = item.modelName,
    footprintRadius = item.footprintRadius,
    placement = placement and publicPlacement(placement) or nil,
    expiresIn = ttl
  }
end

function MZFurniturePlacement.Submit(source, placementToken, offset, rotation)
  source = tonumber(source)
  placementToken = MZFurnitureLogic.NormalizePurchaseToken(placementToken)
  if not source or source <= 0 or not GetPlayerName(source) then
    return false, 'player_not_loaded'
  end
  if not placementToken then return false, 'invalid_placement_token' end
  local draft = Tokens[placementToken]
  if not draft or draft.source ~= source or SourceTokens[source] ~= placementToken then
    return false, 'invalid_placement_token'
  end
  if draft.expiresAt < os.time() then
    clearSourceToken(source)
    return false, 'placement_token_expired'
  end
  if Locks[draft.ownedFurnitureId] or PropertyLocks[draft.propertyId] then
    return false, 'placement_in_progress'
  end

  local context, contextErr = contextFor(source, draft.propertyId)
  if not context then return false, contextErr end
  if tonumber(context.bucket) ~= draft.bucket or context.houseCode ~= draft.houseCode
    or context.citizenid ~= draft.citizenid then
    return false, 'property_context_changed'
  end
  local transform, transformErr = MZFurnitureLogic.NormalizeTransform(offset, rotation)
  if not transform then return false, transformErr end
  local valid, bounds = MZFurnitureResidential.ValidateOffset(
    source,
    transform.offset,
    draft.footprintRadius
  )
  if valid ~= true then return false, bounds end
  if tonumber(bounds.propertyId) ~= draft.propertyId then return false, 'property_context_changed' end

  local item = MZFurnitureRepository.GetOwnedItem(draft.citizenid, draft.ownedFurnitureId)
  if not item then return false, 'owned_furniture_not_found' end
  if not MZFurnitureLogic.CanApplyRevision(item.revision, draft.ownedRevision) then
    return false, 'stale_owned_furniture_revision'
  end

  Locks[draft.ownedFurnitureId] = true
  PropertyLocks[draft.propertyId] = true
  clearSourceToken(source)
  local mutationOk, placement, mutationDetail = pcall(function()
    if draft.action == 'place' then
      if item.status ~= 'warehouse' or item.currentPropertyId ~= nil then
        return nil, 'furniture_not_in_warehouse'
      end
      local total = MZFurnitureRepository.CountPropertyPlacements(draft.propertyId)
      if total >= math.floor(tonumber(MZFurnitureConfig.MaxItemsPerProperty) or 100) then
        return nil, 'property_furniture_limit'
      end
      if item.maxPerProperty
        and MZFurnitureRepository.CountPropertyPlacements(
          draft.propertyId,
          item.catalogId
        ) >= item.maxPerProperty then
        return nil, 'catalog_furniture_limit'
      end
      return MZFurnitureRepository.PlaceOwnedItem({
        citizenid = draft.citizenid,
        propertyId = draft.propertyId,
        ownedFurnitureId = draft.ownedFurnitureId,
        expectedRevision = draft.ownedRevision,
        collisionEnabled = draft.collisionEnabled,
        transform = transform
      })
    end
    if item.status ~= 'placed' or item.currentPropertyId ~= draft.propertyId then
      return nil, 'furniture_not_in_current_property'
    end
    return MZFurnitureRepository.MovePlacedItem({
      citizenid = draft.citizenid,
      propertyId = draft.propertyId,
      ownedFurnitureId = draft.ownedFurnitureId,
      placementRevision = draft.placementRevision,
      transform = transform
    })
  end)
  Locks[draft.ownedFurnitureId] = nil
  PropertyLocks[draft.propertyId] = nil
  if not mutationOk then
    print(('[mz_furniture][placement] mutation exception item=%s error=%s'):format(
      draft.ownedFurnitureId,
      tostring(placement)
    ))
    return false, 'placement_persistence_failed'
  end
  if not placement then return false, mutationDetail or 'placement_persistence_failed' end

  log(draft.action == 'place' and 'furniture.placed' or 'furniture.moved', source, draft.citizenid, {
    ownedFurnitureId = draft.ownedFurnitureId,
    propertyId = draft.propertyId,
    placementId = placement.id,
    placementRevision = placement.revision
  })
  broadcastToViewers(
    'mz_furniture:client:upsertPlacement',
    draft.propertyId,
    draft.bucket,
    {
      propertyId = draft.propertyId,
      houseCode = draft.houseCode,
      placement = publicPlacement(placement)
    }
  )
  return true, {
    action = draft.action,
    placement = publicPlacement(placement)
  }
end

function MZFurniturePlacement.Store(source, ownedFurnitureId, ownedRevision, placementRevision)
  source = tonumber(source)
  ownedFurnitureId = math.floor(tonumber(ownedFurnitureId) or 0)
  if not source or source <= 0 or not GetPlayerName(source) then
    return false, 'player_not_loaded'
  end
  if MZFurnitureConfig.Enabled ~= true or MZFurnitureConfig.PlacementEnabled ~= true then
    return false, 'furniture_placement_disabled'
  end
  if ownedFurnitureId <= 0 or Locks[ownedFurnitureId] then
    return false, ownedFurnitureId <= 0 and 'invalid_owned_furniture' or 'placement_in_progress'
  end
  local context, contextErr = contextFor(source)
  if not context then return false, contextErr end
  local item = MZFurnitureRepository.GetOwnedItem(context.citizenid, ownedFurnitureId)
  local placement = MZFurnitureRepository.GetPlacementByOwned(ownedFurnitureId)
  if not item or item.status ~= 'placed' or item.currentPropertyId ~= tonumber(context.propertyId) then
    return false, 'furniture_not_in_current_property'
  end
  if not placement or placement.propertyId ~= tonumber(context.propertyId) then
    return false, 'placement_not_found'
  end
  if PropertyLocks[tonumber(context.propertyId)] then return false, 'placement_in_progress' end
  if not MZFurnitureLogic.CanApplyRevision(item.revision, ownedRevision)
    or not MZFurnitureLogic.CanApplyRevision(placement.revision, placementRevision) then
    return false, 'stale_placement_revision'
  end

  Locks[ownedFurnitureId] = true
  PropertyLocks[tonumber(context.propertyId)] = true
  local storeCallOk, stored, storeErr = pcall(function()
    return MZFurnitureRepository.StorePlacedItem({
      citizenid = context.citizenid,
      propertyId = context.propertyId,
      ownedFurnitureId = ownedFurnitureId,
      ownedRevision = item.revision,
      placementRevision = placement.revision
    })
  end)
  Locks[ownedFurnitureId] = nil
  PropertyLocks[tonumber(context.propertyId)] = nil
  if not storeCallOk then
    print(('[mz_furniture][placement] store exception item=%s error=%s'):format(
      ownedFurnitureId,
      tostring(stored)
    ))
    return false, 'store_persistence_failed'
  end
  if not stored then return false, storeErr end
  log('furniture.stored', source, context.citizenid, {
    ownedFurnitureId = ownedFurnitureId,
    propertyId = context.propertyId,
    placementId = placement.id
  })
  broadcastToViewers(
    'mz_furniture:client:removePlacement',
    context.propertyId,
    context.bucket,
    {
      propertyId = context.propertyId,
      houseCode = context.houseCode,
      ownedFurnitureId = ownedFurnitureId,
      revision = (tonumber(placement.revision) or 0) + 1
    }
  )
  return true, { ownedFurnitureId = ownedFurnitureId, status = 'warehouse' }
end

AddEventHandler('mz_furniture:server:viewerReady', function(source)
  source = tonumber(source)
  if not source then return end
  SetTimeout(0, function()
    if GetPlayerName(source) then
      local ok, err = pcall(pushSnapshot, source)
      if not ok then
        print(('[mz_furniture][sync] initial snapshot failed source=%s error=%s'):format(
          source,
          tostring(err)
        ))
      end
    end
  end)
end)

AddEventHandler('playerDropped', function()
  clearSourceToken(source)
end)

CreateThread(function()
  while true do
    Wait(30000)
    local now = os.time()
    for placementToken, draft in pairs(Tokens) do
      if draft.expiresAt < now then
        Tokens[placementToken] = nil
        if SourceTokens[draft.source] == placementToken then SourceTokens[draft.source] = nil end
      end
    end
  end
end)
