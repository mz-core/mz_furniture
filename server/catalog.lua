MZFurnitureCatalog = MZFurnitureCatalog or {}

local Cache = {
  ready = false,
  items = {},
  byId = {},
  byCode = {},
  loadedAt = 0
}

local function copyItem(item)
  local result = {}
  for key, value in pairs(item or {}) do
    if type(value) == 'table' then
      local nested = {}
      for nestedKey, nestedValue in pairs(value) do nested[nestedKey] = nestedValue end
      result[key] = nested
    else
      result[key] = value
    end
  end
  return result
end

function MZFurnitureCatalog.Load()
  local items = MZFurnitureRepository.ListCatalog(true)
  local byId, byCode = {}, {}
  for _, item in ipairs(items) do
    byId[item.id] = item
    byCode[item.code] = item
  end
  Cache.items = items
  Cache.byId = byId
  Cache.byCode = byCode
  Cache.loadedAt = os.time()
  Cache.ready = true
  return #items
end

function MZFurnitureCatalog.IsReady()
  return Cache.ready == true
end

function MZFurnitureCatalog.ListForAdmin()
  if not Cache.ready then return nil, 'catalog_not_ready' end
  local result = {}
  for _, item in ipairs(Cache.items) do result[#result + 1] = copyItem(item) end
  return result
end

function MZFurnitureCatalog.ListForPlayer()
  if not Cache.ready then return nil, 'catalog_not_ready' end
  local result = {}
  for _, item in ipairs(Cache.items) do
    if item.enabled == true and item.visible == true and item.archived ~= true then
      result[#result + 1] = {
        id = item.id,
        code = item.code,
        category = item.category,
        label = item.label,
        description = item.description,
        price = item.price,
        resalePercent = item.resalePercent,
        footprintRadius = item.footprintRadius,
        maxPerProperty = item.maxPerProperty,
        revision = item.revision
      }
    end
  end
  return result
end

function MZFurnitureCatalog.Get(identifier)
  if not Cache.ready then return nil end
  local item = tonumber(identifier) and Cache.byId[math.floor(tonumber(identifier))] or Cache.byCode[tostring(identifier)]
  return item and copyItem(item) or nil
end

function MZFurnitureCatalog.RefreshIfStale()
  if not Cache.ready
    or os.time() - Cache.loadedAt >= (tonumber(MZFurnitureConfig.CatalogCacheSeconds) or 60) then
    return MZFurnitureCatalog.Load()
  end
  return #Cache.items
end
