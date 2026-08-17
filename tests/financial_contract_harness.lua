local function read(path)
  local file = assert(io.open(path, 'rb'))
  local content = file:read('*a')
  file:close()
  return content
end

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local money = read('mz_furniture/server/money.lua')
local purchase = read('mz_furniture/server/purchase.lua')
local repository = read('mz_furniture/server/repository.lua')
local player = read('mz_furniture/server/player.lua')
local catalog = read('mz_furniture/server/catalog.lua')

expect(money:find(":RemoveMoney(source, 'bank'", 1, true),
  'purchase debit must use the bank account')
expect(money:find(":AddMoney(source, 'bank'", 1, true),
  'refund must return money to the bank account')
expect(money:find(':GetOperationResult(source, key, operation)', 1, true),
  'ambiguous financial results must be recoverable')
expect(money:find("source_resource = 'mz_furniture'", 1, true),
  'ledger metadata must identify mz_furniture')
expect(money:find('idempotency_key =', 1, true),
  'financial operations require an idempotency key')
expect(money:find('counts_as_expense = not refund', 1, true),
  'purchase ledger entry must count as an expense')
expect(money:find("action == 'furniture_resale'", 1, true)
  and money:find('Revenda recupera parte de um gasto anterior', 1, true),
  'resale credit must not be classified as productive player income')
expect(money:find("requestId .. '_resale'", 1, true)
  and money:find("'add_money'", 1, true),
  'resale credit must have an independently recoverable idempotency key')

expect(player:find("function(source, quoteToken)", 1, true),
  'purchase callback must accept only the quote token')
expect(not player:find('clientPrice', 1, true),
  'purchase callback must not accept a client price')
expect(purchase:find('MZFurnitureLogic.QuoteMatches(quote, item, citizenid, os.time())', 1, true),
  'purchase must revalidate price, revision, owner and expiry server-side')
expect(purchase:find("return refund(source, reread or transaction", 1, true),
  'failed ownership grant must trigger refund handling')
expect(purchase:find("'purchase_manual_review'", 1, true),
  'ambiguous flow must expose manual review')

expect(repository:find('MySQL.transaction.await', 1, true),
  'ownership grant and transaction commit must be atomic')
expect(repository:find('purchase_transaction_id', 1, true),
  'owned furniture must be linked to its purchase transaction')
expect(repository:find('function MZFurnitureRepository.ReserveResale', 1, true)
  and repository:find("o.status = 'selling'", 1, true),
  'resale must reserve a warehouse item before crediting money')
expect(catalog:find('modelName', 1, true) == nil and catalog:find('modelHash', 1, true) == nil,
  'public catalog DTO must not expose object model data before placement')

print('[mz_furniture][test] financial contract harness passed')
