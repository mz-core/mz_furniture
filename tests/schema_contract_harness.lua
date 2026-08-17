local function read(path)
  local file = assert(io.open(path, 'rb'))
  local value = file:read('*a')
  file:close()
  return value
end

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local runtimeSchema = read('mz_furniture/server/database.lua')
local installSchema = read('mz_furniture/install.sql')
local tables = {
  'mz_furniture_catalog',
  'mz_owned_furniture',
  'mz_property_furniture',
  'mz_furniture_transactions',
  'mz_org_furniture_transactions'
}

for _, tableName in ipairs(tables) do
  expect(runtimeSchema:find(tableName, 1, true), ('runtime schema is missing %s'):format(tableName))
  expect(installSchema:find(tableName, 1, true), ('install schema is missing %s'):format(tableName))
end

expect(runtimeSchema:find('CREATE TABLE IF NOT EXISTS', 1, true), 'runtime bootstrap must be idempotent')
expect(runtimeSchema:find('request_id', 1, true), 'transaction idempotency key is missing')
expect(runtimeSchema:find('purchase_transaction_id', 1, true), 'ownership idempotency link is missing')
expect(runtimeSchema:find('manual_review', 1, true), 'manual review state is missing')
expect(runtimeSchema:find('revision', 1, true), 'optimistic revision fields are missing')
expect(runtimeSchema:find('offset_x', 1, true), 'relative transform fields are missing')
for _, field in ipairs({ 'owner_type', 'owner_key', 'owner_citizenid' }) do
  expect(runtimeSchema:find(field, 1, true), ('runtime owner schema missing %s'):format(field))
  expect(installSchema:find(field, 1, true), ('install owner schema missing %s'):format(field))
end
expect(runtimeSchema:find('org_purchase_transaction_id', 1, true)
  and installSchema:find('org_purchase_transaction_id', 1, true),
  'organization ownership idempotency link is missing')
expect(runtimeSchema:find('ensureNullable', 1, true),
  'legacy citizen ownership must become nullable for real organization rows')
expect(runtimeSchema:find('spend_receipt_id', 1, true)
  and runtimeSchema:find('refund_receipt_id', 1, true),
  'organization financial recovery receipts are missing')
expect(runtimeSchema:find("owner_type = 'org' AND owner_citizenid IS NOT NULL", 1, true),
  'organization rows with a citizen owner are not rejected')
expect(runtimeSchema:find("SET owner_type = 'player', owner_key = LOWER(owner_citizenid)", 1, true),
  'existing player ownership backfill is missing')
expect(runtimeSchema:find('generic_owner_backfill_invalid', 1, true),
  'owner backfill verification is missing')
expect(runtimeSchema:find('ensureNotNullable', 1, true),
  'owner key nullability migration must avoid an ALTER on every startup')

print('[mz_furniture][test] schema contract harness passed')
