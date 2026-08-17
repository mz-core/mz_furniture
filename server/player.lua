local Requests = {}

local function safePlacementCall(operation, callback, ...)
  local callOk, ok, result = pcall(callback, ...)
  if not callOk then
    print(('[mz_furniture][placement] callback=%s error=%s'):format(
      tostring(operation),
      tostring(ok)
    ))
    return { ok = false, error = 'placement_service_failed' }
  end
  return ok and { ok = true, data = result } or { ok = false, error = result }
end

local function safeResaleCall(operation, callback, ...)
  local callOk, ok, result = pcall(callback, ...)
  if not callOk then
    print(('[mz_furniture][resale] callback=%s error=%s'):format(
      tostring(operation),
      tostring(ok)
    ))
    return { ok = false, error = 'resale_service_failed' }
  end
  return ok and { ok = true, data = result } or { ok = false, error = result }
end

local function safeOrganizationCall(operation, callback, ...)
  local callOk, ok, result = pcall(callback, ...)
  if not callOk then
    print(('[mz_furniture][organization] callback=%s error=%s'):format(
      tostring(operation),
      tostring(ok)
    ))
    return { ok = false, error = 'organization_warehouse_service_failed' }
  end
  return ok and { ok = true, data = result } or { ok = false, error = result }
end

local function rateAllowed(source, action, seconds)
  local key = ('%s:%s'):format(tonumber(source) or 0, action)
  local now = os.time()
  local previous = Requests[key] or 0
  if now - previous < seconds then return false end
  Requests[key] = now
  return true
end

lib.callback.register('mz_furniture:server:open', function(source)
  if not rateAllowed(source, 'open', 1) then return { ok = false, error = 'rate_limited' } end
  local ok, result = MZFurniturePurchase.Open(source)
  if ok and type(result) == 'table' then
    local contextsOk, contexts = pcall(MZFurnitureOrganization.ListContexts, source)
    result.organizationWarehouses = contextsOk and type(contexts) == 'table' and contexts or {}
    if not contextsOk then
      print(('[mz_furniture][organization] passive_context_error=%s'):format(tostring(contexts)))
    end
  end
  return ok and { ok = true, data = result } or { ok = false, error = result }
end)

lib.callback.register('mz_furniture:server:openOrganizationWarehouse', function(source, orgCode)
  if not rateAllowed(source, 'organization_warehouse', 2) then
    return { ok = false, error = 'rate_limited' }
  end
  return safeOrganizationCall('open', MZFurnitureOrganization.Open, source, orgCode)
end)

lib.callback.register('mz_furniture:server:createOrganizationQuote', function(
  source,
  orgCode,
  catalogId
)
  if not rateAllowed(source, 'organization_quote', 1) then
    return { ok = false, error = 'rate_limited' }
  end
  return safeOrganizationCall(
    'quote',
    MZFurnitureOrganizationPurchase.CreateQuote,
    source,
    orgCode,
    catalogId
  )
end)

lib.callback.register('mz_furniture:server:purchaseForOrganization', function(source, quoteToken)
  local cooldown = math.max(
    1,
    math.floor(tonumber(MZFurnitureConfig.PurchaseRateLimitSeconds) or 2)
  )
  if not rateAllowed(source, 'organization_purchase', cooldown) then
    return { ok = false, error = 'rate_limited' }
  end
  return safeOrganizationCall(
    'purchase',
    MZFurnitureOrganizationPurchase.Purchase,
    source,
    quoteToken
  )
end)

lib.callback.register('mz_furniture:server:createQuote', function(source, catalogId)
  if not rateAllowed(source, 'quote', 1) then return { ok = false, error = 'rate_limited' } end
  local ok, result = MZFurniturePurchase.CreateQuote(source, catalogId)
  return ok and { ok = true, data = result } or { ok = false, error = result }
end)

lib.callback.register('mz_furniture:server:purchase', function(source, quoteToken)
  local cooldown = math.max(1, math.floor(tonumber(MZFurnitureConfig.PurchaseRateLimitSeconds) or 2))
  if not rateAllowed(source, 'purchase', cooldown) then return { ok = false, error = 'rate_limited' } end
  local ok, result = MZFurniturePurchase.Purchase(source, quoteToken)
  return ok and { ok = true, data = result } or { ok = false, error = result }
end)

lib.callback.register('mz_furniture:server:createResaleQuote', function(source, ownedFurnitureId)
  if not rateAllowed(source, 'resale_quote', 1) then
    return { ok = false, error = 'rate_limited' }
  end
  return safeResaleCall(
    'quote',
    MZFurnitureResale.CreateQuote,
    source,
    ownedFurnitureId
  )
end)

lib.callback.register('mz_furniture:server:resale', function(source, quoteToken)
  local cooldown = math.max(1, math.floor(tonumber(MZFurnitureConfig.PurchaseRateLimitSeconds) or 2))
  if not rateAllowed(source, 'resale', cooldown) then
    return { ok = false, error = 'rate_limited' }
  end
  return safeResaleCall('sell', MZFurnitureResale.Sell, source, quoteToken)
end)

lib.callback.register('mz_furniture:server:placementSnapshot', function(source)
  if not rateAllowed(source, 'placement_snapshot', 1) then
    return { ok = false, error = 'rate_limited' }
  end
  return safePlacementCall('snapshot', MZFurniturePlacement.Snapshot, source)
end)

lib.callback.register('mz_furniture:server:beginPlacement', function(source, action, ownedFurnitureId)
  local cooldown = math.max(
    1,
    math.floor(tonumber(MZFurnitureConfig.PlacementRateLimitSeconds) or 1)
  )
  if not rateAllowed(source, 'begin_placement', cooldown) then
    return { ok = false, error = 'rate_limited' }
  end
  return safePlacementCall(
    'begin',
    MZFurniturePlacement.Begin,
    source,
    action,
    ownedFurnitureId
  )
end)

lib.callback.register('mz_furniture:server:submitPlacement', function(
  source,
  placementToken,
  offset,
  rotation
)
  return safePlacementCall(
    'submit',
    MZFurniturePlacement.Submit,
    source,
    placementToken,
    offset,
    rotation
  )
end)

lib.callback.register('mz_furniture:server:storeFurniture', function(
  source,
  ownedFurnitureId,
  ownedRevision,
  placementRevision
)
  if not rateAllowed(source, 'store_furniture', 1) then
    return { ok = false, error = 'rate_limited' }
  end
  return safePlacementCall(
    'store',
    MZFurniturePlacement.Store,
    source,
    ownedFurnitureId,
    ownedRevision,
    placementRevision
  )
end)

AddEventHandler('playerDropped', function()
  local prefix = ('%s:'):format(tonumber(source) or 0)
  for key in pairs(Requests) do
    if key:sub(1, #prefix) == prefix then Requests[key] = nil end
  end
end)
