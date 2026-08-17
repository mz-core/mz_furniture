MZFurnitureConfig = nil
MZFurnitureLogic = nil
dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local catalogItem = {
  id = 10,
  code = 'living_couch_01',
  category = 'sala',
  label = 'Sofa',
  description = 'Teste',
  price = 3500,
  revision = 1,
  enabled = true,
  visible = true,
  archived = false
}
local transactions, transactionsByRequest, ownedByTransaction = {}, {}, {}
local transactionSequence, ownedSequence = 0, 0
local balances = { [1] = 10000, [2] = 10000, [3] = 0, [4] = 10000, [5] = 10000 }
local debitCount, refundCount = {}, {}
local grantFails = false
local ambiguousDebit = {}

function GetResourceState() return 'started' end
function GetPlayerName(source) return source and ('Player %s'):format(source) or nil end
function AddEventHandler() end
exports = {
  mz_core = {
    ResolvePlayerIdentity = function(source)
      return { ok = true, citizenid = ('CID-%s'):format(source) }
    end,
    CreateDetailedLog = function() return true end
  }
}

MZFurnitureCatalog = {
  IsReady = function() return true end,
  RefreshIfStale = function() return 1 end,
  ListForPlayer = function() return { catalogItem } end
}

MZFurnitureRepository = {}

function MZFurnitureRepository.GetCatalogItem()
  local copy = {}
  for key, value in pairs(catalogItem) do copy[key] = value end
  return copy
end

function MZFurnitureRepository.ListOwned(citizenid)
  local out = {}
  for _, item in pairs(ownedByTransaction) do
    if item.ownerCitizenid == citizenid then out[#out + 1] = item end
  end
  return out
end

function MZFurnitureRepository.ListRecoverableTransactions(citizenid)
  local out = {}
  for _, transaction in pairs(transactions) do
    if transaction.citizenid == citizenid
      and (transaction.state == 'payment_pending' or transaction.state == 'money_removed'
        or transaction.state == 'manual_review') then
      out[#out + 1] = transaction
    end
  end
  return out
end

function MZFurnitureRepository.CreatePurchaseTransaction(data)
  local existing = transactionsByRequest[data.requestId]
  if existing then return existing.id, 'already_exists' end
  transactionSequence = transactionSequence + 1
  local transaction = {
    id = transactionSequence,
    requestId = data.requestId,
    citizenid = data.citizenid,
    transactionType = 'purchase',
    state = 'initiated',
    amount = data.amount,
    catalogId = data.catalogId
  }
  transactions[transaction.id] = transaction
  transactionsByRequest[transaction.requestId] = transaction
  return transaction.id
end

function MZFurnitureRepository.GetTransactionByRequest(requestId)
  return transactionsByRequest[requestId]
end

function MZFurnitureRepository.GetTransaction(id)
  return transactions[id]
end

function MZFurnitureRepository.TransitionTransaction(id, toState, fromStates, detail)
  local transaction = transactions[id]
  if not transaction then return false end
  local allowed = false
  for _, state in ipairs(fromStates) do
    if transaction.state == state then allowed = true break end
  end
  if not allowed then return false end
  transaction.state = toState
  transaction.reason = detail and detail.reason or nil
  return true
end

function MZFurnitureRepository.CommitPurchasedItem(transactionId)
  if grantFails then return nil, 'injected_grant_failure' end
  local existing = ownedByTransaction[transactionId]
  if existing then return existing end
  local transaction = transactions[transactionId]
  if not transaction or transaction.state ~= 'money_removed' then return nil, 'invalid_state' end
  ownedSequence = ownedSequence + 1
  local item = {
    id = ownedSequence,
    catalogId = transaction.catalogId,
    catalogCode = catalogItem.code,
    category = catalogItem.category,
    label = catalogItem.label,
    description = catalogItem.description,
    purchasePrice = transaction.amount,
    status = 'warehouse',
    revision = 1,
    ownerCitizenid = transaction.citizenid
  }
  ownedByTransaction[transactionId] = item
  transaction.state = 'committed'
  transaction.ownedFurnitureId = item.id
  return item
end

function MZFurnitureRepository.GetOwnedByPurchaseTransaction(transactionId)
  return ownedByTransaction[transactionId]
end

MZFurnitureMoney = {}

function MZFurnitureMoney.GetBalance(source)
  return balances[source]
end

function MZFurnitureMoney.Debit(source, amount)
  debitCount[source] = (debitCount[source] or 0) + 1
  if ambiguousDebit[source] then return false, 'debit_result_ambiguous', true end
  if (balances[source] or 0) < amount then return false, 'not_enough_money', false end
  balances[source] = balances[source] - amount
  return true, { recovered = false }
end

function MZFurnitureMoney.Refund(source, amount)
  refundCount[source] = (refundCount[source] or 0) + 1
  balances[source] = (balances[source] or 0) + amount
  return true, { recovered = false }
end

function MZFurnitureMoney.RecoverDebit()
  return false, 'operation_not_found'
end

function MZFurnitureMoney.RecoverRefund()
  return false, 'operation_not_found'
end

MZFurniturePurchase = nil
dofile('mz_furniture/server/purchase.lua')

local quoteOk, quote = MZFurniturePurchase.CreateQuote(1, catalogItem.id)
expect(quoteOk == true and quote.price == 3500, 'server quote was not created')
local purchaseOk, purchase = MZFurniturePurchase.Purchase(1, quote.token)
expect(purchaseOk == true and purchase.item.status == 'warehouse', 'purchase did not grant warehouse item')
expect(debitCount[1] == 1 and balances[1] == 6500, 'bank debit is incorrect')
local replayOk, replay = MZFurniturePurchase.Purchase(1, quote.token)
expect(replayOk == true and replay.replayed == true, 'duplicate request did not replay')
expect(debitCount[1] == 1 and ownedSequence == 1, 'duplicate request charged or granted twice')

local changedOk, changedQuote = MZFurniturePurchase.CreateQuote(2, catalogItem.id)
expect(changedOk == true, 'price-change quote failed')
catalogItem.price = 3600
catalogItem.revision = 2
local changedPurchase, changedReason = MZFurniturePurchase.Purchase(2, changedQuote.token)
expect(changedPurchase == false and changedReason == 'quote_changed', 'changed server price must invalidate quote')
expect(debitCount[2] == nil, 'changed quote must not debit')

local insufficientOk, insufficientQuote = MZFurniturePurchase.CreateQuote(3, catalogItem.id)
expect(insufficientOk == true, 'insufficient-funds quote failed')
local insufficientPurchase, insufficientReason = MZFurniturePurchase.Purchase(3, insufficientQuote.token)
expect(insufficientPurchase == false and insufficientReason == 'not_enough_money', 'insufficient funds must fail')
expect(debitCount[3] == nil, 'balance precheck should avoid debit attempt')

grantFails = true
local refundOk, refundQuote = MZFurniturePurchase.CreateQuote(4, catalogItem.id)
expect(refundOk == true, 'refund scenario quote failed')
local refundPurchase = MZFurniturePurchase.Purchase(4, refundQuote.token)
expect(refundPurchase == false, 'grant failure must not report success')
local refundedTransaction = transactionsByRequest[refundQuote.token]
expect(refundedTransaction.state == 'refunded', 'grant failure did not finish as refunded')
expect(debitCount[4] == 1 and refundCount[4] == 1 and balances[4] == 10000, 'refund compensation is incorrect')
grantFails = false

ambiguousDebit[5] = true
local reviewOk, reviewQuote = MZFurniturePurchase.CreateQuote(5, catalogItem.id)
expect(reviewOk == true, 'manual-review quote failed')
local reviewPurchase, reviewReason = MZFurniturePurchase.Purchase(5, reviewQuote.token)
expect(reviewPurchase == false and reviewReason == 'purchase_manual_review', 'ambiguous debit must enter manual review')
expect(transactionsByRequest[reviewQuote.token].state == 'manual_review', 'manual review state was not persisted')
expect(refundCount[5] == nil, 'ambiguous debit must not refund blindly')

print('[mz_furniture][test] purchase flow harness passed')
