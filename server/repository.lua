MZFurnitureRepository = MZFurnitureRepository or {}

local function decodeJson(value)
  if type(value) ~= 'string' or value == '' then return {} end
  local ok, decoded = pcall(json.decode, value)
  return ok and type(decoded) == 'table' and decoded or {}
end

local function encodeJson(value)
  local ok, encoded = pcall(json.encode, type(value) == 'table' and value or {})
  return ok and encoded or '{}'
end

local function enabled(value)
  return value == true or value == 1 or value == '1'
end

local function normalizeRow(row)
  return {
    id = tonumber(row.id),
    code = tostring(row.code or ''),
    category = tostring(row.category or ''),
    label = tostring(row.label or ''),
    description = tostring(row.description or ''),
    modelHash = tonumber(row.model_hash),
    modelName = row.model_name and tostring(row.model_name) or nil,
    price = tonumber(row.price) or 0,
    resalePercent = tonumber(row.resale_percent) or 0,
    footprintRadius = tonumber(row.footprint_radius) or 1.0,
    maxPerProperty = row.max_per_property and tonumber(row.max_per_property) or nil,
    collisionEnabled = enabled(row.collision_enabled),
    visible = enabled(row.visible),
    enabled = enabled(row.enabled),
    sortOrder = tonumber(row.sort_order) or 0,
    config = decodeJson(row.config_json),
    revision = tonumber(row.revision) or 1,
    archived = row.archived_at ~= nil,
    createdAt = row.created_at,
    updatedAt = row.updated_at,
    archivedAt = row.archived_at
  }
end

function MZFurnitureRepository.Seed(seed, actor)
  local inserted = 0
  for _, raw in ipairs(seed or {}) do
    local item, err = MZFurnitureLogic.NormalizeCatalog(raw)
    if not item then
      print(('[mz_furniture][seed] skipped code=%s reason=%s'):format(tostring(raw and raw.code), tostring(err)))
    else
      local result = MySQL.insert.await([[
        INSERT IGNORE INTO `mz_furniture_catalog`
          (`code`, `category`, `label`, `description`, `model_hash`, `model_name`, `price`,
           `resale_percent`, `footprint_radius`, `max_per_property`, `collision_enabled`,
           `visible`, `enabled`, `sort_order`, `config_json`, `created_by`, `updated_by`)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ]], {
        item.code, item.category, item.label, item.description, item.modelHash, item.modelName,
        item.price, item.resalePercent, item.footprintRadius, item.maxPerProperty,
        item.collisionEnabled and 1 or 0, item.visible and 1 or 0, item.enabled and 1 or 0,
        item.sortOrder, json.encode(item.config), actor, actor
      })
      if tonumber(result) and tonumber(result) > 0 then inserted = inserted + 1 end
    end
  end
  return inserted
end

function MZFurnitureRepository.EnableReviewedSeed(seed)
  local enabledCodes = {}
  for _, raw in ipairs(seed or {}) do
    local item = MZFurnitureLogic.NormalizeCatalog(raw)
    if item and item.enabled == true then enabledCodes[#enabledCodes + 1] = item.code end
  end
  local changed = 0
  for _, code in ipairs(enabledCodes) do
    local affected = MySQL.update.await([[
      UPDATE mz_furniture_catalog
      SET enabled = 1
      WHERE code = ? AND enabled = 0 AND archived_at IS NULL
        AND created_by = 'system:seed' AND updated_by = 'system:seed' AND revision = 1
    ]], { code })
    changed = changed + (tonumber(affected) or 0)
  end
  return changed
end

function MZFurnitureRepository.ListCatalog(includeArchived)
  local sql = [[
    SELECT c.*,
      (SELECT COUNT(*) FROM mz_owned_furniture o WHERE o.catalog_id = c.id) AS owned_count,
      (SELECT COUNT(*) FROM mz_owned_furniture o WHERE o.catalog_id = c.id AND o.status = 'placed') AS placed_count
    FROM mz_furniture_catalog c
  ]]
  if includeArchived ~= true then sql = sql .. ' WHERE c.archived_at IS NULL' end
  sql = sql .. ' ORDER BY c.category ASC, c.sort_order ASC, c.label ASC, c.id ASC'
  local rows = MySQL.query.await(sql) or {}
  local result = {}
  for _, row in ipairs(rows) do
    local item = normalizeRow(row)
    item.ownedCount = tonumber(row.owned_count) or 0
    item.placedCount = tonumber(row.placed_count) or 0
    result[#result + 1] = item
  end
  return result
end

function MZFurnitureRepository.GetCatalogItem(identifier)
  local id = tonumber(identifier)
  local row
  if id then
    row = MySQL.single.await('SELECT * FROM mz_furniture_catalog WHERE id = ? LIMIT 1', { math.floor(id) })
  else
    local code = MZFurnitureLogic.NormalizeCode(identifier)
    if not code then return nil end
    row = MySQL.single.await('SELECT * FROM mz_furniture_catalog WHERE code = ? LIMIT 1', { code })
  end
  return row and normalizeRow(row) or nil
end

local function normalizeOwnedRow(row)
  if type(row) ~= 'table' then return nil end
  local owner = MZFurnitureLogic.NormalizeOwner({
    ownerType = row.owner_type,
    ownerKey = row.owner_key,
    ownerCitizenid = row.owner_citizenid
  })
  if not owner then return nil end
  return {
    id = tonumber(row.id),
    owner = owner,
    ownerType = owner.type,
    ownerKey = owner.key,
    ownerCitizenid = owner.citizenid,
    catalogId = tonumber(row.catalog_id),
    catalogCode = tostring(row.catalog_code or row.code or ''),
    category = tostring(row.category or ''),
    label = tostring(row.catalog_label or row.label or ''),
    description = tostring(row.description or ''),
    purchasePrice = tonumber(row.purchase_price) or 0,
    status = tostring(row.status or 'warehouse'),
    currentPropertyId = row.current_property_id and tonumber(row.current_property_id) or nil,
    revision = tonumber(row.revision) or 1,
    metadata = decodeJson(row.metadata_json),
    createdAt = row.created_at,
    updatedAt = row.updated_at
  }
end

local function normalizeTransactionRow(row)
  if type(row) ~= 'table' then return nil end
  return {
    id = tonumber(row.id),
    requestId = tostring(row.request_id or ''),
    citizenid = tostring(row.citizenid or ''),
    transactionType = tostring(row.transaction_type or ''),
    state = tostring(row.state or ''),
    amount = tonumber(row.amount) or 0,
    catalogId = row.catalog_id and tonumber(row.catalog_id) or nil,
    ownedFurnitureId = row.owned_furniture_id and tonumber(row.owned_furniture_id) or nil,
    propertyId = row.property_id and tonumber(row.property_id) or nil,
    bankReference = row.bank_reference and tostring(row.bank_reference) or nil,
    reason = row.reason and tostring(row.reason) or nil,
    metadata = decodeJson(row.metadata_json),
    createdAt = row.created_at,
    updatedAt = row.updated_at,
    committedAt = row.committed_at
  }
end

local function normalizeOrgTransactionRow(row)
  if type(row) ~= 'table' then return nil end
  return {
    id = tonumber(row.id),
    requestId = tostring(row.request_id or ''),
    orgCode = tostring(row.org_code or ''),
    actorCitizenid = tostring(row.actor_citizenid or ''),
    state = tostring(row.state or ''),
    amount = tonumber(row.amount) or 0,
    catalogId = tonumber(row.catalog_id),
    ownedFurnitureId = row.owned_furniture_id and tonumber(row.owned_furniture_id) or nil,
    spendReceiptId = row.spend_receipt_id and tostring(row.spend_receipt_id) or nil,
    refundReceiptId = row.refund_receipt_id and tostring(row.refund_receipt_id) or nil,
    reason = row.reason and tostring(row.reason) or nil,
    metadata = decodeJson(row.metadata_json),
    createdAt = row.created_at,
    updatedAt = row.updated_at,
    committedAt = row.committed_at
  }
end

function MZFurnitureRepository.ListOwnedByOwner(rawOwner)
  local owner = MZFurnitureLogic.NormalizeOwner(rawOwner)
  if not owner then return {} end
  local sql = [[
    SELECT o.*, c.code AS catalog_code, c.category, c.label AS catalog_label, c.description
    FROM mz_owned_furniture o
    INNER JOIN mz_furniture_catalog c ON c.id = o.catalog_id
    WHERE o.owner_type = ? AND o.owner_key = ?
  ]]
  local parameters = { owner.type, owner.key }
  if owner.type == 'player' then
    sql = sql .. ' AND o.owner_citizenid = ?'
    parameters[#parameters + 1] = owner.citizenid
  end
  sql = sql .. [[ AND o.status NOT IN ('sold', 'archived')
    ORDER BY o.created_at DESC, o.id DESC
  ]]
  local rows = MySQL.query.await(sql, parameters) or {}
  local result = {}
  for _, row in ipairs(rows) do
    local item = normalizeOwnedRow(row)
    if item then result[#result + 1] = item end
  end
  return result
end

function MZFurnitureRepository.ListOwned(citizenid)
  return MZFurnitureRepository.ListOwnedByOwner({
    type = 'player', key = citizenid, citizenid = citizenid
  })
end

function MZFurnitureRepository.GetOwnedByPurchaseTransaction(transactionId)
  transactionId = math.floor(tonumber(transactionId) or 0)
  if transactionId <= 0 then return nil end
  local row = MySQL.single.await([[
    SELECT o.*, c.code AS catalog_code, c.category, c.label AS catalog_label, c.description
    FROM mz_owned_furniture o
    INNER JOIN mz_furniture_catalog c ON c.id = o.catalog_id
    WHERE o.purchase_transaction_id = ? LIMIT 1
  ]], { transactionId })
  return row and normalizeOwnedRow(row) or nil
end

function MZFurnitureRepository.GetOwnedByOrgPurchaseTransaction(transactionId)
  transactionId = math.floor(tonumber(transactionId) or 0)
  if transactionId <= 0 then return nil end
  local row = MySQL.single.await([[
    SELECT o.*, c.code AS catalog_code, c.category, c.label AS catalog_label, c.description
    FROM mz_owned_furniture o
    INNER JOIN mz_furniture_catalog c ON c.id = o.catalog_id
    WHERE o.org_purchase_transaction_id = ? AND o.owner_type = 'org' LIMIT 1
  ]], { transactionId })
  return row and normalizeOwnedRow(row) or nil
end

function MZFurnitureRepository.GetOwnedItemByOwner(rawOwner, ownedFurnitureId)
  local owner = MZFurnitureLogic.NormalizeOwner(rawOwner)
  ownedFurnitureId = math.floor(tonumber(ownedFurnitureId) or 0)
  if not owner or ownedFurnitureId <= 0 then return nil end
  local sql = [[
    SELECT o.*, c.code AS catalog_code, c.category, c.label AS catalog_label,
      c.description, c.model_hash, c.model_name, c.footprint_radius,
      c.max_per_property, c.collision_enabled, c.resale_percent
    FROM mz_owned_furniture o
    INNER JOIN mz_furniture_catalog c ON c.id = o.catalog_id
    WHERE o.id = ? AND o.owner_type = ? AND o.owner_key = ?
  ]]
  local parameters = { ownedFurnitureId, owner.type, owner.key }
  if owner.type == 'player' then
    sql = sql .. ' AND o.owner_citizenid = ?'
    parameters[#parameters + 1] = owner.citizenid
  end
  sql = sql .. ' LIMIT 1'
  local row = MySQL.single.await(sql, parameters)
  if not row then return nil end
  local item = normalizeOwnedRow(row)
  item.modelHash = tonumber(row.model_hash)
  item.modelName = row.model_name and tostring(row.model_name) or nil
  item.footprintRadius = tonumber(row.footprint_radius) or 1.0
  item.maxPerProperty = row.max_per_property and tonumber(row.max_per_property) or nil
  item.resalePercent = tonumber(row.resale_percent) or 0
  item.collisionEnabled = enabled(row.collision_enabled)
  return item
end

function MZFurnitureRepository.GetOwnedItem(citizenid, ownedFurnitureId)
  return MZFurnitureRepository.GetOwnedItemByOwner({
    type = 'player', key = citizenid, citizenid = citizenid
  }, ownedFurnitureId)
end

local function normalizePlacementRow(row)
  if type(row) ~= 'table' then return nil end
  local owner = MZFurnitureLogic.NormalizeOwner({
    ownerType = row.owner_type,
    ownerKey = row.owner_key,
    ownerCitizenid = row.owner_citizenid
  })
  if not owner then return nil end
  return {
    id = tonumber(row.id),
    propertyId = tonumber(row.property_id),
    ownedFurnitureId = tonumber(row.owned_furniture_id),
    offset = {
      x = tonumber(row.offset_x) or 0.0,
      y = tonumber(row.offset_y) or 0.0,
      z = tonumber(row.offset_z) or 0.0
    },
    rotation = {
      x = tonumber(row.rotation_x) or 0.0,
      y = tonumber(row.rotation_y) or 0.0,
      z = tonumber(row.rotation_z) or 0.0
    },
    collisionEnabled = enabled(row.collision_enabled),
    visible = enabled(row.visible),
    revision = tonumber(row.revision) or 1,
    ownedRevision = tonumber(row.owned_revision) or nil,
    owner = owner,
    ownerType = owner.type,
    ownerKey = owner.key,
    ownerCitizenid = owner.citizenid,
    catalogId = row.catalog_id and tonumber(row.catalog_id) or nil,
    catalogCode = row.catalog_code and tostring(row.catalog_code) or nil,
    label = row.catalog_label and tostring(row.catalog_label) or nil,
    modelHash = row.model_hash and tonumber(row.model_hash) or nil,
    modelName = row.model_name and tostring(row.model_name) or nil,
    footprintRadius = tonumber(row.footprint_radius) or 1.0,
    createdAt = row.created_at,
    updatedAt = row.updated_at
  }
end

local PLACEMENT_SELECT = [[
  SELECT p.*, o.owner_type, o.owner_key, o.owner_citizenid,
    o.catalog_id, o.revision AS owned_revision,
    c.code AS catalog_code, c.label AS catalog_label, c.model_hash, c.model_name,
    c.footprint_radius
  FROM mz_property_furniture p
  INNER JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
  INNER JOIN mz_furniture_catalog c ON c.id = o.catalog_id
]]

function MZFurnitureRepository.ListPropertyPlacements(propertyId)
  propertyId = math.floor(tonumber(propertyId) or 0)
  if propertyId <= 0 then return {} end
  local rows = MySQL.query.await(PLACEMENT_SELECT .. [[
    WHERE p.property_id = ? AND p.removed_at IS NULL
      AND o.status = 'placed' AND o.current_property_id = ?
    ORDER BY p.id ASC
  ]], { propertyId, propertyId }) or {}
  local result = {}
  for _, row in ipairs(rows) do
    local placement = normalizePlacementRow(row)
    if placement then result[#result + 1] = placement end
  end
  return result
end

function MZFurnitureRepository.GetPlacementByOwned(ownedFurnitureId)
  ownedFurnitureId = math.floor(tonumber(ownedFurnitureId) or 0)
  if ownedFurnitureId <= 0 then return nil end
  local row = MySQL.single.await(PLACEMENT_SELECT .. [[
    WHERE p.owned_furniture_id = ? AND p.removed_at IS NULL LIMIT 1
  ]], { ownedFurnitureId })
  return normalizePlacementRow(row)
end

function MZFurnitureRepository.CountPropertyPlacements(propertyId, catalogId)
  propertyId = math.floor(tonumber(propertyId) or 0)
  catalogId = catalogId and math.floor(tonumber(catalogId) or 0) or nil
  if propertyId <= 0 then return 0 end
  local sql = [[
    SELECT COUNT(*)
    FROM mz_property_furniture p
    INNER JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
    WHERE p.property_id = ? AND p.removed_at IS NULL
      AND o.status = 'placed' AND o.current_property_id = ?
  ]]
  local parameters = { propertyId, propertyId }
  if catalogId and catalogId > 0 then
    sql = sql .. ' AND o.catalog_id = ?'
    parameters[#parameters + 1] = catalogId
  end
  return tonumber(MySQL.scalar.await(sql, parameters)) or 0
end

function MZFurnitureRepository.PlaceOwnedItem(data)
  data = type(data) == 'table' and data or {}
  local ownedId = math.floor(tonumber(data.ownedFurnitureId) or 0)
  local propertyId = math.floor(tonumber(data.propertyId) or 0)
  local expectedRevision = math.floor(tonumber(data.expectedRevision) or 0)
  local citizenid = MZFurnitureLogic.Trim(data.citizenid):sub(1, 64)
  local transform = data.transform
  if ownedId <= 0 or propertyId <= 0 or expectedRevision <= 0 or citizenid == ''
    or type(transform) ~= 'table' then
    return nil, 'invalid_placement_mutation'
  end
  local committed = MySQL.transaction.await({
    {
      query = [[
        INSERT INTO mz_property_furniture
          (property_id, owned_furniture_id, offset_x, offset_y, offset_z,
           rotation_x, rotation_y, rotation_z, collision_enabled, visible,
           revision, placed_by, updated_by, removed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 1, ?, ?, NULL)
        ON DUPLICATE KEY UPDATE
          property_id = VALUES(property_id),
          offset_x = VALUES(offset_x), offset_y = VALUES(offset_y), offset_z = VALUES(offset_z),
          rotation_x = VALUES(rotation_x), rotation_y = VALUES(rotation_y),
          rotation_z = VALUES(rotation_z), collision_enabled = VALUES(collision_enabled),
          visible = 1, revision = revision + 1, updated_by = VALUES(updated_by),
          removed_at = NULL
      ]],
      parameters = {
        propertyId, ownedId,
        transform.offset.x, transform.offset.y, transform.offset.z,
        transform.rotation.x, transform.rotation.y, transform.rotation.z,
        data.collisionEnabled == false and 0 or 1,
        citizenid, citizenid
      }
    },
    {
      query = [[
        UPDATE mz_owned_furniture
        SET status = 'placed', current_property_id = ?, revision = revision + 1
        WHERE id = ? AND owner_type = 'player' AND owner_citizenid = ?
          AND status = 'warehouse' AND revision = ?
      ]],
      parameters = { propertyId, ownedId, citizenid, expectedRevision }
    }
  })
  if committed ~= true then return nil, 'placement_commit_failed' end
  local item = MZFurnitureRepository.GetOwnedItem(citizenid, ownedId)
  local placement = MZFurnitureRepository.GetPlacementByOwned(ownedId)
  if not item or item.status ~= 'placed' or item.currentPropertyId ~= propertyId
    or not placement or placement.propertyId ~= propertyId then
    return nil, 'placement_commit_unverified'
  end
  return placement, item
end

function MZFurnitureRepository.MovePlacedItem(data)
  data = type(data) == 'table' and data or {}
  local ownedId = math.floor(tonumber(data.ownedFurnitureId) or 0)
  local propertyId = math.floor(tonumber(data.propertyId) or 0)
  local placementRevision = math.floor(tonumber(data.placementRevision) or 0)
  local citizenid = MZFurnitureLogic.Trim(data.citizenid):sub(1, 64)
  local transform = data.transform
  if ownedId <= 0 or propertyId <= 0 or placementRevision <= 0 or citizenid == ''
    or type(transform) ~= 'table' then
    return nil, 'invalid_move_mutation'
  end
  local affected = MySQL.update.await([[
    UPDATE mz_property_furniture p
    INNER JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
    SET p.offset_x = ?, p.offset_y = ?, p.offset_z = ?,
      p.rotation_x = ?, p.rotation_y = ?, p.rotation_z = ?,
      p.revision = p.revision + 1, p.updated_by = ?
    WHERE p.owned_furniture_id = ? AND p.property_id = ?
      AND p.revision = ? AND p.removed_at IS NULL
      AND o.owner_type = 'player' AND o.owner_citizenid = ? AND o.status = 'placed'
      AND o.current_property_id = ?
  ]], {
    transform.offset.x, transform.offset.y, transform.offset.z,
    transform.rotation.x, transform.rotation.y, transform.rotation.z,
    citizenid, ownedId, propertyId, placementRevision, citizenid, propertyId
  })
  if tonumber(affected) ~= 1 then return nil, 'stale_placement_revision' end
  return MZFurnitureRepository.GetPlacementByOwned(ownedId)
end

function MZFurnitureRepository.StorePlacedItem(data)
  data = type(data) == 'table' and data or {}
  local ownedId = math.floor(tonumber(data.ownedFurnitureId) or 0)
  local propertyId = math.floor(tonumber(data.propertyId) or 0)
  local ownedRevision = math.floor(tonumber(data.ownedRevision) or 0)
  local placementRevision = math.floor(tonumber(data.placementRevision) or 0)
  local citizenid = MZFurnitureLogic.Trim(data.citizenid):sub(1, 64)
  if ownedId <= 0 or propertyId <= 0 or ownedRevision <= 0
    or placementRevision <= 0 or citizenid == '' then
    return nil, 'invalid_store_mutation'
  end
  local committed = MySQL.transaction.await({
    {
      query = [[
        UPDATE mz_property_furniture p
        INNER JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
        SET p.removed_at = UTC_TIMESTAMP(), p.revision = p.revision + 1,
          p.updated_by = ?
        WHERE p.owned_furniture_id = ? AND p.property_id = ?
          AND p.revision = ? AND p.removed_at IS NULL
          AND o.owner_type = 'player' AND o.owner_citizenid = ? AND o.status = 'placed'
          AND o.current_property_id = ?
      ]],
      parameters = {
        citizenid, ownedId, propertyId, placementRevision, citizenid, propertyId
      }
    },
    {
      query = [[
        UPDATE mz_owned_furniture
        SET status = 'warehouse', current_property_id = NULL, revision = revision + 1
        WHERE id = ? AND owner_type = 'player' AND owner_citizenid = ? AND status = 'placed'
          AND current_property_id = ? AND revision = ?
      ]],
      parameters = { ownedId, citizenid, propertyId, ownedRevision }
    }
  })
  if committed ~= true then return nil, 'store_commit_failed' end
  local item = MZFurnitureRepository.GetOwnedItem(citizenid, ownedId)
  local placement = MZFurnitureRepository.GetPlacementByOwned(ownedId)
  if not item or item.status ~= 'warehouse' or item.currentPropertyId ~= nil or placement then
    return nil, 'store_commit_unverified'
  end
  return item
end

function MZFurnitureRepository.CreateResaleTransaction(data)
  data = type(data) == 'table' and data or {}
  local requestId = MZFurnitureLogic.NormalizePurchaseToken(data.requestId)
  local citizenid = MZFurnitureLogic.Trim(data.citizenid):sub(1, 64)
  local catalogId = math.floor(tonumber(data.catalogId) or 0)
  local ownedId = math.floor(tonumber(data.ownedFurnitureId) or 0)
  local amount = math.floor(tonumber(data.amount) or 0)
  if not requestId or citizenid == '' or catalogId <= 0 or ownedId <= 0 or amount <= 0 then
    return nil, 'invalid_resale_transaction'
  end
  local insertOk, inserted = pcall(function()
    return MySQL.insert.await([[
      INSERT INTO mz_furniture_transactions
        (request_id, citizenid, transaction_type, state, amount, catalog_id,
         owned_furniture_id, bank_reference, metadata_json)
      VALUES (?, ?, 'resale', 'initiated', ?, ?, ?, ?, ?)
    ]], {
      requestId, citizenid, amount, catalogId, ownedId, requestId, encodeJson(data.metadata)
    })
  end)
  if insertOk and (tonumber(inserted) or 0) > 0 then return tonumber(inserted) end
  local existing = MZFurnitureRepository.GetTransactionByRequest(requestId)
  if existing and existing.citizenid == citizenid then return existing.id, 'already_exists' end
  return nil, 'transaction_insert_failed'
end

function MZFurnitureRepository.ReserveResale(transactionId, citizenid, expectedRevision)
  transactionId = math.floor(tonumber(transactionId) or 0)
  citizenid = MZFurnitureLogic.Trim(citizenid):sub(1, 64)
  expectedRevision = math.floor(tonumber(expectedRevision) or 0)
  if transactionId <= 0 or citizenid == '' or expectedRevision <= 0 then
    return nil, 'invalid_resale_reservation'
  end
  local committed = MySQL.transaction.await({
    {
      query = [[
        UPDATE mz_owned_furniture o
        INNER JOIN mz_furniture_transactions t ON t.owned_furniture_id = o.id
        SET o.status = 'selling', o.revision = o.revision + 1
        WHERE t.id = ? AND t.citizenid = ? AND t.transaction_type = 'resale'
          AND t.state = 'initiated' AND o.owner_type = 'player' AND o.owner_citizenid = ?
          AND o.status = 'warehouse' AND o.current_property_id IS NULL
          AND o.revision = ?
      ]],
      parameters = { transactionId, citizenid, citizenid, expectedRevision }
    },
    {
      query = [[
        UPDATE mz_furniture_transactions t
        INNER JOIN mz_owned_furniture o ON o.id = t.owned_furniture_id
        SET t.state = 'payment_pending', t.reason = 'resale_credit_started'
        WHERE t.id = ? AND t.citizenid = ? AND t.transaction_type = 'resale'
          AND t.state = 'initiated' AND o.status = 'selling'
      ]],
      parameters = { transactionId, citizenid }
    }
  })
  if committed ~= true then return nil, 'resale_reservation_failed' end
  local transaction = MZFurnitureRepository.GetTransaction(transactionId)
  if not transaction or transaction.state ~= 'payment_pending' then
    return nil, 'resale_reservation_unverified'
  end
  return transaction
end

function MZFurnitureRepository.CommitResale(transactionId, citizenid)
  transactionId = math.floor(tonumber(transactionId) or 0)
  citizenid = MZFurnitureLogic.Trim(citizenid):sub(1, 64)
  if transactionId <= 0 or citizenid == '' then return nil, 'invalid_resale_commit' end
  local committed = MySQL.transaction.await({
    {
      query = [[
        UPDATE mz_owned_furniture o
        INNER JOIN mz_furniture_transactions t ON t.owned_furniture_id = o.id
        SET o.status = 'sold', o.current_property_id = NULL, o.revision = o.revision + 1
        WHERE t.id = ? AND t.citizenid = ? AND t.transaction_type = 'resale'
          AND t.state IN ('payment_pending', 'manual_review', 'committed')
          AND o.owner_type = 'player' AND o.owner_citizenid = ?
          AND o.status IN ('selling', 'sold')
      ]],
      parameters = { transactionId, citizenid, citizenid }
    },
    {
      query = [[
        UPDATE mz_furniture_transactions t
        INNER JOIN mz_owned_furniture o ON o.id = t.owned_furniture_id
        SET t.state = 'committed', t.reason = NULL,
          t.committed_at = COALESCE(t.committed_at, UTC_TIMESTAMP())
        WHERE t.id = ? AND t.citizenid = ? AND t.transaction_type = 'resale'
          AND t.state IN ('payment_pending', 'manual_review', 'committed')
          AND o.status = 'sold'
      ]],
      parameters = { transactionId, citizenid }
    }
  })
  if committed ~= true then return nil, 'resale_commit_failed' end
  local transaction = MZFurnitureRepository.GetTransaction(transactionId)
  if not transaction or transaction.state ~= 'committed' then
    return nil, 'resale_commit_unverified'
  end
  return transaction
end

function MZFurnitureRepository.CancelResale(transactionId, citizenid, reason)
  transactionId = math.floor(tonumber(transactionId) or 0)
  citizenid = MZFurnitureLogic.Trim(citizenid):sub(1, 64)
  if transactionId <= 0 or citizenid == '' then return false, 'invalid_resale_cancel' end
  local committed = MySQL.transaction.await({
    {
      query = [[
        UPDATE mz_owned_furniture o
        INNER JOIN mz_furniture_transactions t ON t.owned_furniture_id = o.id
        SET o.status = 'warehouse', o.revision = o.revision + 1
        WHERE t.id = ? AND t.citizenid = ? AND t.transaction_type = 'resale'
          AND o.owner_type = 'player' AND o.owner_citizenid = ? AND o.status = 'selling'
      ]],
      parameters = { transactionId, citizenid, citizenid }
    },
    {
      query = [[
        UPDATE mz_furniture_transactions
        SET state = 'failed', reason = ?, metadata_json = ?
        WHERE id = ? AND citizenid = ? AND transaction_type = 'resale'
          AND state IN ('initiated', 'payment_pending', 'manual_review')
      ]],
      parameters = { tostring(reason or 'resale_cancelled'), encodeJson({ reason = reason }), transactionId, citizenid }
    }
  })
  return committed == true
end

function MZFurnitureRepository.MarkResaleManualReview(transactionId, reason)
  return MZFurnitureRepository.TransitionTransaction(
    transactionId,
    'manual_review',
    { 'payment_pending', 'manual_review' },
    { reason = reason }
  )
end

function MZFurnitureRepository.ListRecoverableResales(citizenid)
  citizenid = MZFurnitureLogic.Trim(citizenid):sub(1, 64)
  if citizenid == '' then return {} end
  local rows = MySQL.query.await([[
    SELECT * FROM mz_furniture_transactions
    WHERE citizenid = ? AND transaction_type = 'resale'
      AND state IN ('payment_pending', 'manual_review')
    ORDER BY id ASC LIMIT 25
  ]], { citizenid }) or {}
  local result = {}
  for _, row in ipairs(rows) do result[#result + 1] = normalizeTransactionRow(row) end
  return result
end

function MZFurnitureRepository.CreatePurchaseTransaction(data)
  data = type(data) == 'table' and data or {}
  local requestId = MZFurnitureLogic.NormalizePurchaseToken(data.requestId)
  local citizenid = MZFurnitureLogic.Trim(data.citizenid):sub(1, 64)
  local catalogId = math.floor(tonumber(data.catalogId) or 0)
  local amount = math.floor(tonumber(data.amount) or 0)
  if not requestId or citizenid == '' or catalogId <= 0 or amount <= 0 then
    return nil, 'invalid_purchase_transaction'
  end
  local insertOk, inserted = pcall(function()
    return MySQL.insert.await([[
      INSERT INTO mz_furniture_transactions
        (request_id, citizenid, transaction_type, state, amount, catalog_id,
         bank_reference, metadata_json)
      VALUES (?, ?, 'purchase', 'initiated', ?, ?, ?, ?)
    ]], {
      requestId,
      citizenid,
      amount,
      catalogId,
      requestId,
      encodeJson(data.metadata)
    })
  end)
  if insertOk and (tonumber(inserted) or 0) > 0 then return tonumber(inserted) end
  local existing = MZFurnitureRepository.GetTransactionByRequest(requestId)
  if existing and existing.citizenid == citizenid then return existing.id, 'already_exists' end
  return nil, 'transaction_insert_failed'
end

function MZFurnitureRepository.GetTransactionByRequest(requestId)
  requestId = MZFurnitureLogic.NormalizePurchaseToken(requestId)
  if not requestId then return nil end
  local row = MySQL.single.await(
    'SELECT * FROM mz_furniture_transactions WHERE request_id = ? LIMIT 1',
    { requestId }
  )
  return normalizeTransactionRow(row)
end

function MZFurnitureRepository.GetTransaction(id)
  id = math.floor(tonumber(id) or 0)
  if id <= 0 then return nil end
  return normalizeTransactionRow(MySQL.single.await(
    'SELECT * FROM mz_furniture_transactions WHERE id = ? LIMIT 1',
    { id }
  ))
end

function MZFurnitureRepository.TransitionTransaction(id, toState, fromStates, detail)
  id = math.floor(tonumber(id) or 0)
  toState = MZFurnitureLogic.Trim(toState):lower()
  if id <= 0 or toState == '' or type(fromStates) ~= 'table' or #fromStates == 0 then
    return false, 'invalid_transaction_transition'
  end
  local placeholders, parameters = {}, {
    toState,
    type(detail) == 'table' and detail.reason or nil,
    encodeJson(detail),
    toState == 'committed' and 1 or 0,
    id
  }
  for _, state in ipairs(fromStates) do
    placeholders[#placeholders + 1] = '?'
    parameters[#parameters + 1] = tostring(state)
  end
  local affected = MySQL.update.await(([[
    UPDATE mz_furniture_transactions
    SET state = ?, reason = ?, metadata_json = ?,
      committed_at = CASE WHEN ? = 1 THEN UTC_TIMESTAMP() ELSE committed_at END
    WHERE id = ? AND state IN (%s)
  ]]):format(table.concat(placeholders, ', ')), parameters)
  return (tonumber(affected) or 0) == 1
end

function MZFurnitureRepository.CommitPurchasedItem(transactionId, metadata)
  transactionId = math.floor(tonumber(transactionId) or 0)
  if transactionId <= 0 then return nil, 'invalid_transaction' end
  local committed = MySQL.transaction.await({
    {
      query = [[
        INSERT IGNORE INTO mz_owned_furniture
          (owner_type, owner_key, owner_citizenid, catalog_id, purchase_price, status,
           current_property_id, purchase_transaction_id, metadata_json)
        SELECT 'player', LOWER(t.citizenid), t.citizenid,
          t.catalog_id, t.amount, 'warehouse', NULL, t.id, ?
        FROM mz_furniture_transactions t
        INNER JOIN mz_furniture_catalog c ON c.id = t.catalog_id
        WHERE t.id = ? AND t.transaction_type = 'purchase'
          AND t.state IN ('money_removed', 'committed')
      ]],
      parameters = { encodeJson(metadata), transactionId }
    },
    {
      query = [[
        UPDATE mz_furniture_transactions t
        INNER JOIN mz_owned_furniture o ON o.purchase_transaction_id = t.id
        SET t.state = 'committed', t.owned_furniture_id = o.id,
          t.reason = NULL, t.committed_at = COALESCE(t.committed_at, UTC_TIMESTAMP())
        WHERE t.id = ? AND t.state IN ('money_removed', 'committed')
      ]],
      parameters = { transactionId }
    }
  })
  if committed ~= true then return nil, 'ownership_commit_failed' end
  local transaction = MZFurnitureRepository.GetTransaction(transactionId)
  local owned = MZFurnitureRepository.GetOwnedByPurchaseTransaction(transactionId)
  if not transaction or transaction.state ~= 'committed' or not owned then
    return nil, 'ownership_commit_unverified'
  end
  return owned
end

function MZFurnitureRepository.CreateOrgFurnitureTransaction(data)
  data = type(data) == 'table' and data or {}
  local requestId = MZFurnitureLogic.NormalizePurchaseToken(data.requestId)
  local owner = MZFurnitureLogic.NormalizeOwner({ type = 'org', key = data.orgCode })
  local actorCitizenid = MZFurnitureLogic.Trim(data.actorCitizenid):sub(1, 64)
  local catalogId = math.floor(tonumber(data.catalogId) or 0)
  local amount = math.floor(tonumber(data.amount) or 0)
  if not requestId or not owner or actorCitizenid == '' or catalogId <= 0 or amount <= 0 then
    return nil, 'invalid_org_furniture_transaction'
  end
  local insertOk, inserted = pcall(function()
    return MySQL.insert.await([[
      INSERT INTO mz_org_furniture_transactions
        (request_id, org_code, actor_citizenid, state, amount, catalog_id, metadata_json)
      VALUES (?, ?, ?, 'initiated', ?, ?, ?)
    ]], {
      requestId, owner.key, actorCitizenid, amount, catalogId, encodeJson(data.metadata)
    })
  end)
  if insertOk and (tonumber(inserted) or 0) > 0 then return tonumber(inserted) end
  local existing = MZFurnitureRepository.GetOrgFurnitureTransactionByRequest(requestId)
  if existing and existing.orgCode == owner.key and existing.actorCitizenid == actorCitizenid then
    return existing.id, 'already_exists'
  end
  return nil, 'org_furniture_transaction_insert_failed'
end

function MZFurnitureRepository.GetOrgFurnitureTransactionByRequest(requestId)
  requestId = MZFurnitureLogic.NormalizePurchaseToken(requestId)
  if not requestId then return nil end
  return normalizeOrgTransactionRow(MySQL.single.await(
    'SELECT * FROM mz_org_furniture_transactions WHERE request_id = ? LIMIT 1',
    { requestId }
  ))
end

function MZFurnitureRepository.GetOrgFurnitureTransaction(transactionId)
  transactionId = math.floor(tonumber(transactionId) or 0)
  if transactionId <= 0 then return nil end
  return normalizeOrgTransactionRow(MySQL.single.await(
    'SELECT * FROM mz_org_furniture_transactions WHERE id = ? LIMIT 1',
    { transactionId }
  ))
end

function MZFurnitureRepository.TransitionOrgFurnitureTransaction(
  transactionId,
  toState,
  fromStates,
  detail
)
  transactionId = math.floor(tonumber(transactionId) or 0)
  toState = MZFurnitureLogic.Trim(toState):lower()
  detail = type(detail) == 'table' and detail or {}
  if transactionId <= 0 or toState == '' or type(fromStates) ~= 'table' or #fromStates == 0 then
    return false, 'invalid_org_furniture_transition'
  end
  local placeholders = {}
  local parameters = {
    toState,
    detail.reason,
    encodeJson(detail),
    detail.spendReceiptId,
    detail.refundReceiptId,
    toState == 'committed' and 1 or 0,
    transactionId
  }
  for _, state in ipairs(fromStates) do
    placeholders[#placeholders + 1] = '?'
    parameters[#parameters + 1] = tostring(state)
  end
  local affected = MySQL.update.await(([[
    UPDATE mz_org_furniture_transactions
    SET state = ?, reason = ?, metadata_json = ?,
      spend_receipt_id = COALESCE(?, spend_receipt_id),
      refund_receipt_id = COALESCE(?, refund_receipt_id),
      committed_at = CASE WHEN ? = 1 THEN COALESCE(committed_at, UTC_TIMESTAMP()) ELSE committed_at END
    WHERE id = ? AND state IN (%s)
  ]]):format(table.concat(placeholders, ', ')), parameters)
  return (tonumber(affected) or 0) == 1
end

function MZFurnitureRepository.CommitOrgPurchasedItem(transactionId, metadata)
  transactionId = math.floor(tonumber(transactionId) or 0)
  if transactionId <= 0 then return nil, 'invalid_org_furniture_transaction' end
  local committed = MySQL.transaction.await({
    {
      query = [[
        INSERT IGNORE INTO mz_owned_furniture
          (owner_type, owner_key, owner_citizenid, catalog_id, purchase_price, status,
           current_property_id, purchase_transaction_id, org_purchase_transaction_id,
           metadata_json)
        SELECT 'org', t.org_code, NULL, t.catalog_id, t.amount, 'warehouse',
          NULL, NULL, t.id, ?
        FROM mz_org_furniture_transactions t
        INNER JOIN mz_furniture_catalog c ON c.id = t.catalog_id
        WHERE t.id = ? AND t.state IN ('money_removed', 'committed')
      ]],
      parameters = { encodeJson(metadata), transactionId }
    },
    {
      query = [[
        UPDATE mz_org_furniture_transactions t
        INNER JOIN mz_owned_furniture o
          ON o.org_purchase_transaction_id = t.id AND o.owner_type = 'org'
        SET t.state = 'committed', t.owned_furniture_id = o.id,
          t.reason = NULL, t.committed_at = COALESCE(t.committed_at, UTC_TIMESTAMP())
        WHERE t.id = ? AND t.state IN ('money_removed', 'committed')
      ]],
      parameters = { transactionId }
    }
  })
  if committed ~= true then return nil, 'org_ownership_commit_failed' end
  local transaction = MZFurnitureRepository.GetOrgFurnitureTransaction(transactionId)
  local owned = MZFurnitureRepository.GetOwnedByOrgPurchaseTransaction(transactionId)
  if not transaction or transaction.state ~= 'committed' or not owned
    or owned.ownerType ~= 'org' or owned.ownerKey ~= transaction.orgCode then
    return nil, 'org_ownership_commit_unverified'
  end
  return owned
end

function MZFurnitureRepository.ListRecoverableOrgFurnitureTransactions(actorCitizenid)
  actorCitizenid = MZFurnitureLogic.Trim(actorCitizenid):sub(1, 64)
  if actorCitizenid == '' then return {} end
  local rows = MySQL.query.await([[
    SELECT * FROM mz_org_furniture_transactions
    WHERE actor_citizenid = ? AND state IN ('payment_pending', 'money_removed', 'manual_review')
    ORDER BY id ASC LIMIT 25
  ]], { actorCitizenid }) or {}
  local result = {}
  for _, row in ipairs(rows) do result[#result + 1] = normalizeOrgTransactionRow(row) end
  return result
end

function MZFurnitureRepository.ListRecoverableTransactions(citizenid)
  citizenid = MZFurnitureLogic.Trim(citizenid):sub(1, 64)
  if citizenid == '' then return {} end
  local rows = MySQL.query.await([[
    SELECT * FROM mz_furniture_transactions
    WHERE citizenid = ? AND transaction_type = 'purchase'
      AND state IN ('payment_pending', 'money_removed', 'manual_review')
    ORDER BY id ASC LIMIT 25
  ]], { citizenid }) or {}
  local result = {}
  for _, row in ipairs(rows) do result[#result + 1] = normalizeTransactionRow(row) end
  return result
end

function MZFurnitureRepository.ResolvePropertyIdentity(houseCode, propertyId)
  houseCode = MZFurnitureLogic.Trim(houseCode):sub(1, 64)
  propertyId = math.floor(tonumber(propertyId) or 0)
  local row
  if propertyId > 0 then
    row = MySQL.single.await([[
      SELECT id, code, owner_citizenid FROM mz_houses WHERE id = ? LIMIT 1
    ]], { propertyId })
  elseif houseCode ~= '' then
    row = MySQL.single.await([[
      SELECT id, code, owner_citizenid FROM mz_houses WHERE code = ? LIMIT 1
    ]], { houseCode })
  end
  if not row then return nil, 'property_not_found' end
  return {
    propertyId = tonumber(row.id),
    houseCode = tostring(row.code or ''),
    ownerCitizenid = row.owner_citizenid and tostring(row.owner_citizenid) or nil
  }
end

function MZFurnitureRepository.ListOwnershipMismatches(limit)
  limit = math.max(1, math.min(500, math.floor(tonumber(limit) or 100)))
  local rows = MySQL.query.await(([[
    SELECT p.property_id, h.code AS house_code,
      h.owner_citizenid AS property_owner,
      o.owner_citizenid AS furniture_owner,
      COUNT(*) AS item_count
    FROM mz_property_furniture p
    INNER JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
    LEFT JOIN mz_houses h ON h.id = p.property_id
    WHERE p.removed_at IS NULL AND o.owner_type = 'player' AND o.status = 'placed'
      AND o.current_property_id = p.property_id
      AND (h.id IS NULL OR h.owner_citizenid IS NULL
        OR BINARY h.owner_citizenid <> BINARY o.owner_citizenid)
    GROUP BY p.property_id, h.code, h.owner_citizenid, o.owner_citizenid
    ORDER BY p.property_id ASC
    LIMIT %d
  ]]):format(limit)) or {}
  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = {
      propertyId = tonumber(row.property_id),
      houseCode = row.house_code and tostring(row.house_code) or nil,
      propertyOwner = row.property_owner and tostring(row.property_owner) or nil,
      furnitureOwner = tostring(row.furniture_owner or ''),
      itemCount = tonumber(row.item_count) or 0
    }
  end
  return result
end

function MZFurnitureRepository.ListPropertyFurnitureOwners(propertyId)
  propertyId = math.floor(tonumber(propertyId) or 0)
  if propertyId <= 0 then return {} end
  local rows = MySQL.query.await([[
    SELECT o.owner_citizenid, COUNT(*) AS item_count
    FROM mz_property_furniture p
    INNER JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
    WHERE p.property_id = ? AND p.removed_at IS NULL
      AND o.owner_type = 'player' AND o.status = 'placed' AND o.current_property_id = ?
    GROUP BY o.owner_citizenid
    ORDER BY o.owner_citizenid ASC
  ]], { propertyId, propertyId }) or {}
  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = {
      ownerCitizenid = tostring(row.owner_citizenid or ''),
      itemCount = tonumber(row.item_count) or 0
    }
  end
  return result
end

function MZFurnitureRepository.CollectPropertyFurniture(propertyId, ownerCitizenid)
  propertyId = math.floor(tonumber(propertyId) or 0)
  ownerCitizenid = MZFurnitureLogic.Trim(ownerCitizenid):sub(1, 64)
  if propertyId <= 0 or ownerCitizenid == '' then
    return nil, 'invalid_owner_reconciliation'
  end
  local items = MySQL.query.await([[
    SELECT p.id AS placement_id, p.owned_furniture_id, p.revision,
      o.owner_citizenid
    FROM mz_property_furniture p
    INNER JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
    WHERE p.property_id = ? AND p.removed_at IS NULL
      AND o.owner_type = 'player' AND o.current_property_id = ? AND o.status = 'placed'
      AND o.owner_citizenid = ?
    ORDER BY p.id ASC
  ]], { propertyId, propertyId, ownerCitizenid }) or {}
  if #items == 0 then return { count = 0, items = {} } end
  local committed = MySQL.transaction.await({
    {
      query = [[
        UPDATE mz_property_furniture p
        INNER JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
        SET p.removed_at = UTC_TIMESTAMP(), p.visible = 0,
          p.revision = p.revision + 1, p.updated_by = 'system:owner_reconciliation'
        WHERE p.property_id = ? AND p.removed_at IS NULL
          AND o.owner_type = 'player' AND o.current_property_id = ? AND o.status = 'placed'
          AND o.owner_citizenid = ?
      ]],
      parameters = { propertyId, propertyId, ownerCitizenid }
    },
    {
      query = [[
        UPDATE mz_owned_furniture
        SET status = 'warehouse', current_property_id = NULL, revision = revision + 1
        WHERE owner_type = 'player' AND current_property_id = ?
          AND status = 'placed' AND owner_citizenid = ?
      ]],
      parameters = { propertyId, ownerCitizenid }
    }
  })
  if committed ~= true then return nil, 'owner_reconciliation_commit_failed' end
  local remaining = tonumber(MySQL.scalar.await([[
    SELECT COUNT(*)
    FROM mz_property_furniture p
    INNER JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
    WHERE p.property_id = ? AND p.removed_at IS NULL
      AND o.owner_type = 'player' AND o.current_property_id = ? AND o.status = 'placed'
      AND o.owner_citizenid = ?
  ]], { propertyId, propertyId, ownerCitizenid })) or 0
  if remaining > 0 then return nil, 'owner_reconciliation_unverified' end
  local normalized = {}
  for _, row in ipairs(items) do
    normalized[#normalized + 1] = {
      placementId = tonumber(row.placement_id),
      ownedFurnitureId = tonumber(row.owned_furniture_id),
      revision = (tonumber(row.revision) or 0) + 1
    }
  end
  return { count = #normalized, items = normalized }
end

function MZFurnitureRepository.ListOrphanPlacedItems(limit)
  limit = math.max(1, math.min(500, math.floor(tonumber(limit) or 100)))
  local rows = MySQL.query.await(([[
    SELECT o.id, o.owner_citizenid, o.current_property_id, o.revision
    FROM mz_owned_furniture o
    WHERE o.owner_type = 'player' AND o.status = 'placed'
      AND o.current_property_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM mz_property_furniture p
        WHERE p.owned_furniture_id = o.id AND p.property_id = o.current_property_id
          AND p.removed_at IS NULL
      )
    ORDER BY o.id ASC LIMIT %d
  ]]):format(limit)) or {}
  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = {
      ownedFurnitureId = tonumber(row.id),
      ownerCitizenid = tostring(row.owner_citizenid or ''),
      propertyId = tonumber(row.current_property_id),
      revision = tonumber(row.revision) or 1
    }
  end
  return result
end

function MZFurnitureRepository.RepairOrphanPlacedItem(item)
  item = type(item) == 'table' and item or {}
  local affected = MySQL.update.await([[
    UPDATE mz_owned_furniture
    SET status = 'warehouse', current_property_id = NULL, revision = revision + 1
    WHERE id = ? AND owner_type = 'player' AND owner_citizenid = ? AND status = 'placed'
      AND current_property_id = ? AND revision = ?
      AND NOT EXISTS (
        SELECT 1 FROM mz_property_furniture p
        WHERE p.owned_furniture_id = mz_owned_furniture.id
          AND p.property_id = mz_owned_furniture.current_property_id
          AND p.removed_at IS NULL
      )
  ]], {
    tonumber(item.ownedFurnitureId), tostring(item.ownerCitizenid or ''),
    tonumber(item.propertyId), tonumber(item.revision)
  })
  return (tonumber(affected) or 0) == 1
end

function MZFurnitureRepository.ListDanglingPlacements(limit)
  limit = math.max(1, math.min(500, math.floor(tonumber(limit) or 100)))
  local rows = MySQL.query.await(([[
    SELECT p.id, p.property_id, p.owned_furniture_id, p.revision
    FROM mz_property_furniture p
    LEFT JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
    WHERE p.removed_at IS NULL
      AND (o.id IS NULL OR (o.owner_type = 'player' AND (
        o.status <> 'placed' OR o.current_property_id IS NULL
        OR o.current_property_id <> p.property_id)))
    ORDER BY p.id ASC LIMIT %d
  ]]):format(limit)) or {}
  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = {
      placementId = tonumber(row.id),
      propertyId = tonumber(row.property_id),
      ownedFurnitureId = tonumber(row.owned_furniture_id),
      revision = tonumber(row.revision) or 1
    }
  end
  return result
end

function MZFurnitureRepository.RemoveDanglingPlacement(item)
  item = type(item) == 'table' and item or {}
  local affected = MySQL.update.await([[
    UPDATE mz_property_furniture p
    LEFT JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
    SET p.removed_at = UTC_TIMESTAMP(), p.visible = 0,
      p.revision = p.revision + 1, p.updated_by = 'system:consistency_repair'
    WHERE p.id = ? AND p.property_id = ? AND p.revision = ? AND p.removed_at IS NULL
      AND (o.id IS NULL OR (o.owner_type = 'player' AND (
        o.status <> 'placed' OR o.current_property_id IS NULL
        OR o.current_property_id <> p.property_id)))
  ]], { tonumber(item.placementId), tonumber(item.propertyId), tonumber(item.revision) })
  return (tonumber(affected) or 0) == 1
end

function MZFurnitureRepository.GetRecoveryOverview()
  local mismatchCount = tonumber(MySQL.scalar.await([[
    SELECT COUNT(*) FROM mz_property_furniture p
    INNER JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
    LEFT JOIN mz_houses h ON h.id = p.property_id
    WHERE p.removed_at IS NULL AND o.owner_type = 'player' AND o.status = 'placed'
      AND o.current_property_id = p.property_id
      AND (h.id IS NULL OR h.owner_citizenid IS NULL
        OR BINARY h.owner_citizenid <> BINARY o.owner_citizenid)
  ]])) or 0
  local orphanCount = tonumber(MySQL.scalar.await([[
    SELECT COUNT(*) FROM mz_owned_furniture o
    WHERE o.owner_type = 'player' AND o.status = 'placed'
      AND o.current_property_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM mz_property_furniture p
        WHERE p.owned_furniture_id = o.id AND p.property_id = o.current_property_id
          AND p.removed_at IS NULL
      )
  ]])) or 0
  local danglingCount = tonumber(MySQL.scalar.await([[
    SELECT COUNT(*) FROM mz_property_furniture p
    LEFT JOIN mz_owned_furniture o ON o.id = p.owned_furniture_id
    WHERE p.removed_at IS NULL
      AND (o.id IS NULL OR (o.owner_type = 'player' AND (
        o.status <> 'placed' OR o.current_property_id IS NULL
        OR o.current_property_id <> p.property_id)))
  ]])) or 0
  local manualRows = MySQL.query.await([[
    SELECT id, request_id, citizenid, transaction_type, state, amount, reason, created_at
    FROM mz_furniture_transactions
    WHERE state = 'manual_review'
    ORDER BY id DESC LIMIT 25
  ]]) or {}
  local manualCount = tonumber(MySQL.scalar.await([[
    SELECT COUNT(*) FROM mz_furniture_transactions WHERE state = 'manual_review'
  ]])) or 0
  local manual = {}
  for _, row in ipairs(manualRows) do
    manual[#manual + 1] = {
      id = tonumber(row.id),
      requestId = tostring(row.request_id or ''),
      citizenid = tostring(row.citizenid or ''),
      transactionType = tostring(row.transaction_type or ''),
      state = tostring(row.state or ''),
      amount = tonumber(row.amount) or 0,
      reason = row.reason and tostring(row.reason) or nil,
      createdAt = row.created_at
    }
  end
  return {
    ownershipMismatches = mismatchCount,
    orphanPlacedItems = orphanCount,
    danglingPlacements = danglingCount,
    manualReviewTransactions = manual,
    manualReviewCount = manualCount
  }
end

function MZFurnitureRepository.RecoverStartupStates()
  local failed = MySQL.update.await([[
    UPDATE mz_furniture_transactions
    SET state = 'failed', reason = 'restart_before_payment',
      metadata_json = JSON_OBJECT('reason', 'restart_before_payment')
    WHERE transaction_type = 'purchase' AND state IN ('pending', 'initiated')
  ]], {})
  local review = MySQL.update.await([[
    UPDATE mz_furniture_transactions
    SET state = 'manual_review', reason = 'restart_reconciliation_required',
      metadata_json = JSON_OBJECT('reason', 'restart_reconciliation_required')
    WHERE transaction_type = 'purchase' AND state IN ('payment_pending', 'money_removed')
  ]], {})
  local resaleFailed = MySQL.update.await([[
    UPDATE mz_furniture_transactions
    SET state = 'failed', reason = 'restart_before_resale_reservation',
      metadata_json = JSON_OBJECT('reason', 'restart_before_resale_reservation')
    WHERE transaction_type = 'resale' AND state = 'initiated'
  ]], {})
  local resaleReview = MySQL.update.await([[
    UPDATE mz_furniture_transactions
    SET state = 'manual_review', reason = 'restart_resale_reconciliation_required',
      metadata_json = JSON_OBJECT('reason', 'restart_resale_reconciliation_required')
    WHERE transaction_type = 'resale' AND state = 'payment_pending'
  ]], {})
  local orgFailed = MySQL.update.await([[
    UPDATE mz_org_furniture_transactions
    SET state = 'failed', reason = 'restart_before_org_payment',
      metadata_json = JSON_OBJECT('reason', 'restart_before_org_payment')
    WHERE state = 'initiated'
  ]], {})
  local orgReview = MySQL.update.await([[
    UPDATE mz_org_furniture_transactions
    SET state = 'manual_review', reason = 'restart_org_reconciliation_required',
      metadata_json = JSON_OBJECT('reason', 'restart_org_reconciliation_required')
    WHERE state IN ('payment_pending', 'money_removed')
  ]], {})
  return {
    failed = (tonumber(failed) or 0) + (tonumber(resaleFailed) or 0)
      + (tonumber(orgFailed) or 0),
    manualReview = (tonumber(review) or 0) + (tonumber(resaleReview) or 0)
      + (tonumber(orgReview) or 0)
  }
end
