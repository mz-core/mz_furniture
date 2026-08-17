MZFurnitureDB = MZFurnitureDB or {}
MZFurnitureDB.OwnerMigration = MZFurnitureDB.OwnerMigration or {
  ready = false,
  organizationReady = false,
  playerRows = 0,
  organizationRows = 0,
  invalidRows = 0
}

local function ensureColumn(tableName, columnName, definition)
  local exists = MySQL.scalar.await([[
    SELECT COUNT(*) FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
  ]], { tableName, columnName })
  if tonumber(exists) == 0 then
    MySQL.query.await(('ALTER TABLE `%s` ADD COLUMN `%s` %s'):format(
      tableName,
      columnName,
      definition
    ))
  end
end

local function ensureIndex(tableName, indexName, definition)
  local exists = MySQL.scalar.await([[
    SELECT COUNT(*) FROM information_schema.STATISTICS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND INDEX_NAME = ?
  ]], { tableName, indexName })
  if tonumber(exists) == 0 then
    MySQL.query.await(('ALTER TABLE `%s` ADD %s'):format(tableName, definition))
  end
end

local function ensureNotNullable(tableName, columnName, definition)
  local nullable = MySQL.scalar.await([[
    SELECT IS_NULLABLE FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
    LIMIT 1
  ]], { tableName, columnName })
  if tostring(nullable or ''):upper() == 'YES' then
    MySQL.query.await(('ALTER TABLE `%s` MODIFY COLUMN `%s` %s'):format(
      tableName,
      columnName,
      definition
    ))
  end
end

local function ensureNullable(tableName, columnName, definition)
  local nullable = MySQL.scalar.await([[
    SELECT IS_NULLABLE FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
    LIMIT 1
  ]], { tableName, columnName })
  if tostring(nullable or ''):upper() == 'NO' then
    MySQL.query.await(('ALTER TABLE `%s` MODIFY COLUMN `%s` %s'):format(
      tableName,
      columnName,
      definition
    ))
  end
end

local function ensureTransactionStateEnum()
  local columnType = MySQL.scalar.await([[
    SELECT COLUMN_TYPE FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'mz_furniture_transactions' AND COLUMN_NAME = 'state'
    LIMIT 1
  ]])
  if type(columnType) == 'string' and columnType:find('manual_review', 1, true) then return end
  MySQL.query.await([[
    ALTER TABLE `mz_furniture_transactions`
    MODIFY COLUMN `state`
      ENUM('pending','initiated','payment_pending','money_removed','committed','cancelled','failed','refunded','manual_review','reversed')
      NOT NULL DEFAULT 'pending'
  ]])
end

local function ensureGenericOwnerSchema()
  ensureColumn(
    'mz_owned_furniture',
    'owner_type',
    "ENUM('player','org') NOT NULL DEFAULT 'player' AFTER `id`"
  )
  ensureColumn(
    'mz_owned_furniture',
    'owner_key',
    'VARCHAR(64) NULL AFTER `owner_type`'
  )
  MySQL.update.await([[
    UPDATE mz_owned_furniture
    SET owner_type = 'player', owner_key = LOWER(owner_citizenid)
    WHERE (owner_key IS NULL OR owner_key = '')
      AND owner_citizenid IS NOT NULL AND owner_citizenid <> ''
  ]])
  ensureNotNullable('mz_owned_furniture', 'owner_key', 'VARCHAR(64) NOT NULL')
  ensureNullable('mz_owned_furniture', 'owner_citizenid', 'VARCHAR(64) NULL')
  ensureIndex(
    'mz_owned_furniture',
    'idx_mz_owned_furniture_owner_scope_status',
    'KEY `idx_mz_owned_furniture_owner_scope_status` (`owner_type`, `owner_key`, `status`)'
  )

  local invalidRows = tonumber(MySQL.scalar.await([[
    SELECT COUNT(*) FROM mz_owned_furniture
    WHERE owner_key IS NULL OR owner_key = ''
      OR owner_type NOT IN ('player', 'org')
      OR (owner_type = 'player' AND (
        owner_citizenid IS NULL OR owner_citizenid = ''
        OR BINARY owner_key <> BINARY LOWER(owner_citizenid)
      )) OR (owner_type = 'org' AND owner_citizenid IS NOT NULL)
  ]])) or 0
  local playerRows = tonumber(MySQL.scalar.await([[
    SELECT COUNT(*) FROM mz_owned_furniture WHERE owner_type = 'player'
  ]])) or 0
  local organizationRows = tonumber(MySQL.scalar.await([[
    SELECT COUNT(*) FROM mz_owned_furniture WHERE owner_type = 'org'
  ]])) or 0
  MZFurnitureDB.OwnerMigration = {
    ready = invalidRows == 0,
    organizationReady = invalidRows == 0,
    playerRows = playerRows,
    organizationRows = organizationRows,
    invalidRows = invalidRows
  }
  if invalidRows > 0 then error('generic_owner_backfill_invalid') end
end

function MZFurnitureDB.Ensure()
  if MZFurnitureConfig.AutoCreateTables ~= true then return true end

  MySQL.query.await([[
    CREATE TABLE IF NOT EXISTS `mz_furniture_catalog` (
      `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
      `code` VARCHAR(64) NOT NULL,
      `category` VARCHAR(64) NOT NULL,
      `label` VARCHAR(100) NOT NULL,
      `description` VARCHAR(500) NOT NULL DEFAULT '',
      `model_hash` BIGINT UNSIGNED NOT NULL,
      `model_name` VARCHAR(100) DEFAULT NULL,
      `price` INT UNSIGNED NOT NULL,
      `resale_percent` TINYINT UNSIGNED NOT NULL DEFAULT 50,
      `footprint_radius` DECIMAL(8,3) NOT NULL DEFAULT 1.000,
      `max_per_property` SMALLINT UNSIGNED DEFAULT NULL,
      `collision_enabled` TINYINT(1) NOT NULL DEFAULT 1,
      `visible` TINYINT(1) NOT NULL DEFAULT 1,
      `enabled` TINYINT(1) NOT NULL DEFAULT 0,
      `sort_order` INT NOT NULL DEFAULT 0,
      `config_json` LONGTEXT DEFAULT NULL,
      `revision` INT UNSIGNED NOT NULL DEFAULT 1,
      `created_by` VARCHAR(100) DEFAULT NULL,
      `updated_by` VARCHAR(100) DEFAULT NULL,
      `archived_by` VARCHAR(100) DEFAULT NULL,
      `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      `archived_at` TIMESTAMP NULL DEFAULT NULL,
      PRIMARY KEY (`id`),
      UNIQUE KEY `uq_mz_furniture_catalog_code` (`code`),
      KEY `idx_mz_furniture_catalog_visible` (`enabled`, `archived_at`, `category`, `sort_order`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
  ]])

  MySQL.query.await([[
    CREATE TABLE IF NOT EXISTS `mz_owned_furniture` (
      `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
      `owner_type` ENUM('player','org') NOT NULL DEFAULT 'player',
      `owner_key` VARCHAR(64) NOT NULL,
      `owner_citizenid` VARCHAR(64) DEFAULT NULL,
      `catalog_id` BIGINT UNSIGNED NOT NULL,
      `purchase_price` INT UNSIGNED NOT NULL,
      `status` ENUM('warehouse','placed','selling','sold','archived') NOT NULL DEFAULT 'warehouse',
      `current_property_id` BIGINT UNSIGNED DEFAULT NULL,
      `purchase_transaction_id` BIGINT UNSIGNED DEFAULT NULL,
      `org_purchase_transaction_id` BIGINT UNSIGNED DEFAULT NULL,
      `revision` INT UNSIGNED NOT NULL DEFAULT 1,
      `metadata_json` LONGTEXT DEFAULT NULL,
      `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      `archived_at` TIMESTAMP NULL DEFAULT NULL,
      PRIMARY KEY (`id`),
      KEY `idx_mz_owned_furniture_owner_status` (`owner_citizenid`, `status`),
      KEY `idx_mz_owned_furniture_owner_scope_status` (`owner_type`, `owner_key`, `status`),
      KEY `idx_mz_owned_furniture_property` (`current_property_id`, `status`),
      KEY `idx_mz_owned_furniture_catalog` (`catalog_id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
  ]])

  MySQL.query.await([[
    CREATE TABLE IF NOT EXISTS `mz_property_furniture` (
      `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
      `property_id` BIGINT UNSIGNED NOT NULL,
      `owned_furniture_id` BIGINT UNSIGNED NOT NULL,
      `offset_x` DOUBLE NOT NULL,
      `offset_y` DOUBLE NOT NULL,
      `offset_z` DOUBLE NOT NULL,
      `rotation_x` DOUBLE NOT NULL DEFAULT 0,
      `rotation_y` DOUBLE NOT NULL DEFAULT 0,
      `rotation_z` DOUBLE NOT NULL DEFAULT 0,
      `collision_enabled` TINYINT(1) NOT NULL DEFAULT 1,
      `visible` TINYINT(1) NOT NULL DEFAULT 1,
      `revision` INT UNSIGNED NOT NULL DEFAULT 1,
      `placed_by` VARCHAR(64) NOT NULL,
      `updated_by` VARCHAR(64) NOT NULL,
      `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      `removed_at` TIMESTAMP NULL DEFAULT NULL,
      PRIMARY KEY (`id`),
      UNIQUE KEY `uq_mz_property_furniture_owned` (`owned_furniture_id`),
      KEY `idx_mz_property_furniture_property` (`property_id`, `removed_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
  ]])

  MySQL.query.await([[
    CREATE TABLE IF NOT EXISTS `mz_furniture_transactions` (
      `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
      `request_id` VARCHAR(100) NOT NULL,
      `citizenid` VARCHAR(64) NOT NULL,
      `transaction_type` ENUM('purchase','resale','refund','recovery') NOT NULL,
      `state` ENUM('pending','initiated','payment_pending','money_removed','committed','cancelled','failed','refunded','manual_review','reversed') NOT NULL DEFAULT 'pending',
      `amount` INT UNSIGNED NOT NULL,
      `catalog_id` BIGINT UNSIGNED DEFAULT NULL,
      `owned_furniture_id` BIGINT UNSIGNED DEFAULT NULL,
      `property_id` BIGINT UNSIGNED DEFAULT NULL,
      `bank_reference` VARCHAR(128) DEFAULT NULL,
      `reason` VARCHAR(255) DEFAULT NULL,
      `metadata_json` LONGTEXT DEFAULT NULL,
      `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      `committed_at` TIMESTAMP NULL DEFAULT NULL,
      PRIMARY KEY (`id`),
      UNIQUE KEY `uq_mz_furniture_transactions_request` (`request_id`),
      KEY `idx_mz_furniture_transactions_citizen` (`citizenid`, `created_at`),
      KEY `idx_mz_furniture_transactions_state` (`state`, `created_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
  ]])

  MySQL.query.await([[
    CREATE TABLE IF NOT EXISTS `mz_org_furniture_transactions` (
      `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
      `request_id` VARCHAR(100) NOT NULL,
      `org_code` VARCHAR(64) NOT NULL,
      `actor_citizenid` VARCHAR(64) NOT NULL,
      `state` ENUM('initiated','payment_pending','money_removed','committed','failed','refunded','manual_review') NOT NULL DEFAULT 'initiated',
      `amount` INT UNSIGNED NOT NULL,
      `catalog_id` BIGINT UNSIGNED NOT NULL,
      `owned_furniture_id` BIGINT UNSIGNED DEFAULT NULL,
      `spend_receipt_id` VARCHAR(128) DEFAULT NULL,
      `refund_receipt_id` VARCHAR(128) DEFAULT NULL,
      `reason` VARCHAR(255) DEFAULT NULL,
      `metadata_json` LONGTEXT DEFAULT NULL,
      `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
      `committed_at` TIMESTAMP NULL DEFAULT NULL,
      PRIMARY KEY (`id`),
      UNIQUE KEY `uq_mz_org_furniture_tx_request` (`request_id`),
      UNIQUE KEY `uq_mz_org_furniture_tx_spend_receipt` (`spend_receipt_id`),
      KEY `idx_mz_org_furniture_tx_recovery` (`actor_citizenid`, `state`, `created_at`),
      KEY `idx_mz_org_furniture_tx_org` (`org_code`, `created_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
  ]])

  ensureColumn(
    'mz_owned_furniture',
    'purchase_transaction_id',
    'BIGINT UNSIGNED DEFAULT NULL AFTER `current_property_id`'
  )
  ensureColumn(
    'mz_owned_furniture',
    'org_purchase_transaction_id',
    'BIGINT UNSIGNED DEFAULT NULL AFTER `purchase_transaction_id`'
  )
  ensureIndex(
    'mz_owned_furniture',
    'uq_mz_owned_furniture_purchase_tx',
    'UNIQUE KEY `uq_mz_owned_furniture_purchase_tx` (`purchase_transaction_id`)'
  )
  ensureIndex(
    'mz_owned_furniture',
    'uq_mz_owned_furniture_org_purchase_tx',
    'UNIQUE KEY `uq_mz_owned_furniture_org_purchase_tx` (`org_purchase_transaction_id`)'
  )
  ensureGenericOwnerSchema()
  ensureTransactionStateEnum()

  return true
end

function MZFurnitureDB.GetOwnerMigrationStatus()
  return {
    ready = MZFurnitureDB.OwnerMigration.ready == true,
    organizationReady = MZFurnitureDB.OwnerMigration.organizationReady == true,
    playerRows = tonumber(MZFurnitureDB.OwnerMigration.playerRows) or 0,
    organizationRows = tonumber(MZFurnitureDB.OwnerMigration.organizationRows) or 0,
    invalidRows = tonumber(MZFurnitureDB.OwnerMigration.invalidRows) or 0
  }
end
