MZFurnitureLogic = MZFurnitureLogic or {}

local ITEM_TRANSITIONS = {
  warehouse = { placed = true, selling = true, archived = true },
  placed = { warehouse = true, selling = true, archived = true },
  selling = { warehouse = true, sold = true },
  sold = {},
  archived = { warehouse = true }
}

local TRANSACTION_TRANSITIONS = {
  pending = { initiated = true, cancelled = true, failed = true },
  initiated = { payment_pending = true, cancelled = true, failed = true },
  payment_pending = { money_removed = true, failed = true, refunded = true, manual_review = true },
  money_removed = { committed = true, refunded = true, manual_review = true },
  committed = { reversed = true },
  cancelled = {},
  failed = {},
  refunded = {},
  manual_review = { money_removed = true, failed = true, refunded = true, committed = true },
  reversed = {}
}

local function finiteNumber(value)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
  return value
end

local function trim(value)
  if type(value) ~= 'string' then return '' end
  return value:gsub('%c', ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function bool(value, default)
  if value == nil then return default == true end
  return value == true or value == 1 or value == '1' or value == 'true'
end

function MZFurnitureLogic.Trim(value)
  return trim(value)
end

function MZFurnitureLogic.NormalizeCode(value)
  local code = trim(value):lower()
  code = code:gsub('[^a-z0-9_%-]+', '_'):gsub('_+', '_'):gsub('^[_%-]+', ''):gsub('[_%-]+$', '')
  if #code < 3 or #code > 64 then return nil end
  return code
end

function MZFurnitureLogic.NormalizeOwner(input)
  input = type(input) == 'table' and input or {}
  local citizenid = trim(input.citizenid or input.ownerCitizenid or input.owner_citizenid):sub(1, 64)
  local ownerType = trim(input.type or input.ownerType or input.owner_type):lower()
  local ownerKey = trim(input.key or input.ownerKey or input.owner_key):lower():sub(1, 64)

  if ownerType == '' and citizenid ~= '' then ownerType = 'player' end
  if ownerType ~= 'player' and ownerType ~= 'org' then return nil, 'invalid_owner_type' end
  if ownerType == 'player' then
    if ownerKey == '' then ownerKey = citizenid:lower() end
    if citizenid == '' or ownerKey ~= citizenid:lower() then return nil, 'invalid_player_owner' end
    return { type = 'player', key = ownerKey, citizenid = citizenid }
  end

  ownerKey = MZFurnitureLogic.NormalizeCode(ownerKey)
  if not ownerKey then return nil, 'invalid_org_owner' end
  if citizenid ~= '' then return nil, 'org_owner_citizenid_forbidden' end
  return { type = 'org', key = ownerKey, citizenid = nil }
end

function MZFurnitureLogic.Joaat(value)
  local hash = 0
  value = tostring(value or ''):lower()
  for index = 1, #value do
    hash = (hash + value:byte(index)) & 0xffffffff
    hash = (hash + ((hash << 10) & 0xffffffff)) & 0xffffffff
    hash = (hash ~ (hash >> 6)) & 0xffffffff
  end
  hash = (hash + ((hash << 3) & 0xffffffff)) & 0xffffffff
  hash = (hash ~ (hash >> 11)) & 0xffffffff
  hash = (hash + ((hash << 15) & 0xffffffff)) & 0xffffffff
  return hash
end

function MZFurnitureLogic.NormalizeCatalog(input)
  if type(input) ~= 'table' then return nil, 'invalid_catalog_item' end
  local code = MZFurnitureLogic.NormalizeCode(input.code)
  local category = MZFurnitureLogic.NormalizeCode(input.category)
  local label = trim(input.label)
  local description = trim(input.description)
  local modelName = trim(input.modelName or input.model_name):lower()
  local modelHash = finiteNumber(input.modelHash or input.model_hash)
  local price = finiteNumber(input.price)
  local resalePercent = finiteNumber(input.resalePercent or input.resale_percent)
  local footprintRadius = finiteNumber(input.footprintRadius or input.footprint_radius)
  local maxPerProperty = input.maxPerProperty or input.max_per_property
  local sortOrder = finiteNumber(input.sortOrder or input.sort_order) or 0
  local collisionValue = input.collisionEnabled
  if collisionValue == nil then collisionValue = input.collision_enabled end

  if not code then return nil, 'invalid_code' end
  if not category then return nil, 'invalid_category' end
  if #label < 3 or #label > 100 then return nil, 'invalid_label' end
  if #description > 500 then return nil, 'invalid_description' end
  if modelName == '' and not modelHash then return nil, 'missing_model' end
  if #modelName > 100 then return nil, 'invalid_model_name' end
  modelHash = math.floor(modelHash or MZFurnitureLogic.Joaat(modelName))
  if modelHash < 0 then modelHash = modelHash & 0xffffffff end
  if not price or price < 1 or price > 100000000 then return nil, 'invalid_price' end
  resalePercent = math.floor(resalePercent or tonumber(MZFurnitureConfig.DefaultResalePercent) or 50)
  if resalePercent < 0 or resalePercent > 100 then return nil, 'invalid_resale_percent' end
  if not footprintRadius or footprintRadius < 0.1 or footprintRadius > 20.0 then
    return nil, 'invalid_footprint_radius'
  end
  if maxPerProperty ~= nil then
    maxPerProperty = finiteNumber(maxPerProperty)
    if not maxPerProperty or maxPerProperty < 1 or maxPerProperty > 1000 then
      return nil, 'invalid_max_per_property'
    end
    maxPerProperty = math.floor(maxPerProperty)
  end

  return {
    code = code,
    category = category,
    label = label,
    description = description,
    modelHash = modelHash,
    modelName = modelName ~= '' and modelName or nil,
    price = math.floor(price),
    resalePercent = resalePercent,
    footprintRadius = footprintRadius + 0.0,
    maxPerProperty = maxPerProperty,
    collisionEnabled = bool(collisionValue, true),
    visible = bool(input.visible, true),
    enabled = bool(input.enabled, false),
    sortOrder = math.floor(sortOrder),
    config = type(input.config) == 'table' and input.config or {}
  }
end

function MZFurnitureLogic.NormalizeTransform(offset, rotation)
  offset = type(offset) == 'table' and offset or {}
  rotation = type(rotation) == 'table' and rotation or {}
  local result = {
    offset = {
      x = finiteNumber(offset.x),
      y = finiteNumber(offset.y),
      z = finiteNumber(offset.z)
    },
    rotation = {
      x = finiteNumber(rotation.x),
      y = finiteNumber(rotation.y),
      z = finiteNumber(rotation.z)
    }
  }
  for _, axis in ipairs({ 'x', 'y', 'z' }) do
    if result.offset[axis] == nil or result.rotation[axis] == nil then
      return nil, 'invalid_transform_number'
    end
    if math.abs(result.offset[axis]) > (tonumber(MZFurnitureConfig.MaxPlacementOffset) or 60.0) then
      return nil, 'offset_out_of_bounds'
    end
    if math.abs(result.rotation[axis]) > (tonumber(MZFurnitureConfig.MaxAbsoluteRotation) or 36000.0) then
      return nil, 'rotation_out_of_bounds'
    end
  end
  return result
end

function MZFurnitureLogic.IsItemTransitionAllowed(fromState, toState)
  return ITEM_TRANSITIONS[tostring(fromState or '')]
    and ITEM_TRANSITIONS[tostring(fromState or '')][tostring(toState or '')] == true
end

function MZFurnitureLogic.IsTransactionTransitionAllowed(fromState, toState)
  return TRANSACTION_TRANSITIONS[tostring(fromState or '')]
    and TRANSACTION_TRANSITIONS[tostring(fromState or '')][tostring(toState or '')] == true
end

function MZFurnitureLogic.CalculateResale(purchasePrice, percent)
  purchasePrice = finiteNumber(purchasePrice)
  percent = finiteNumber(percent)
  if not purchasePrice or purchasePrice < 0 or not percent or percent < 0 or percent > 100 then
    return nil
  end
  return math.floor((purchasePrice * percent / 100) + 0.5)
end

function MZFurnitureLogic.CanApplyRevision(currentRevision, expectedRevision)
  currentRevision = finiteNumber(currentRevision)
  expectedRevision = finiteNumber(expectedRevision)
  return currentRevision ~= nil and expectedRevision ~= nil
    and math.floor(currentRevision) == math.floor(expectedRevision)
end

function MZFurnitureLogic.NormalizePurchaseToken(value)
  if type(value) ~= 'string' then return nil end
  value = trim(value)
  if #value < 16 or #value > 64 or not value:match('^[%w_%-]+$') then return nil end
  return value
end

function MZFurnitureLogic.QuoteMatches(quote, item, citizenid, now)
  if type(quote) ~= 'table' or type(item) ~= 'table' then return false, 'invalid_quote' end
  if trim(quote.citizenid) == '' or trim(quote.citizenid) ~= trim(citizenid) then
    return false, 'quote_owner_mismatch'
  end
  if quote.used == true then return false, 'quote_used' end
  if (tonumber(quote.expiresAt) or 0) < (tonumber(now) or os.time()) then
    return false, 'quote_expired'
  end
  if tonumber(quote.catalogId) ~= tonumber(item.id)
    or tonumber(quote.catalogRevision) ~= tonumber(item.revision)
    or tonumber(quote.price) ~= tonumber(item.price) then
    return false, 'quote_changed'
  end
  if item.enabled ~= true or item.visible ~= true or item.archived == true then
    return false, 'item_unavailable'
  end
  return true
end
