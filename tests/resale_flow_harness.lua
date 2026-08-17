MZFurnitureConfig = nil
MZFurnitureLogic = nil
dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local owned = {
  [1] = { id = 1, ownerCitizenid = 'CID-1', catalogId = 10, label = 'Sofa', purchasePrice = 3501, resalePercent = 50, status = 'warehouse', revision = 1 },
  [2] = { id = 2, ownerCitizenid = 'CID-2', catalogId = 10, label = 'Mesa', purchasePrice = 1000, resalePercent = 40, status = 'placed', currentPropertyId = 7, revision = 1 },
  [3] = { id = 3, ownerCitizenid = 'CID-3', catalogId = 10, label = 'Cama', purchasePrice = 2000, resalePercent = 50, status = 'warehouse', revision = 1 },
  [4] = { id = 4, ownerCitizenid = 'CID-4', catalogId = 10, label = 'Planta', purchasePrice = 800, resalePercent = 35, status = 'warehouse', revision = 1 }
}
local transactions, byRequest = {}, {}
local transactionSequence = 0
local creditCount, balances, creditMode, creditOperations = {}, {}, {}, {}

function GetResourceState() return 'started' end
function GetPlayerName(source) return source and ('Player %s'):format(source) or nil end
function AddEventHandler() end
exports = {
  mz_core = {
    ResolvePlayerIdentity = function(_, source)
      return { ok = true, citizenid = ('CID-%s'):format(source) }
    end,
    CreateDetailedLog = function() return true end
  }
}

MZFurnitureRepository = {}

function MZFurnitureRepository.GetOwnedItem(citizenid, id)
  local item = owned[tonumber(id)]
  if not item or item.ownerCitizenid ~= citizenid then return nil end
  local copy = {}
  for key, value in pairs(item) do copy[key] = value end
  return copy
end

function MZFurnitureRepository.ListRecoverableTransactions() return {} end

function MZFurnitureRepository.ListRecoverableResales(citizenid)
  local result = {}
  for _, transaction in pairs(transactions) do
    if transaction.citizenid == citizenid
      and (transaction.state == 'payment_pending' or transaction.state == 'manual_review') then
      result[#result + 1] = transaction
    end
  end
  return result
end

function MZFurnitureRepository.CreateResaleTransaction(data)
  if byRequest[data.requestId] then return byRequest[data.requestId].id, 'already_exists' end
  transactionSequence = transactionSequence + 1
  local transaction = {
    id = transactionSequence,
    requestId = data.requestId,
    citizenid = data.citizenid,
    transactionType = 'resale',
    state = 'initiated',
    amount = data.amount,
    catalogId = data.catalogId,
    ownedFurnitureId = data.ownedFurnitureId
  }
  transactions[transaction.id] = transaction
  byRequest[transaction.requestId] = transaction
  return transaction.id
end

function MZFurnitureRepository.GetTransactionByRequest(requestId) return byRequest[requestId] end
function MZFurnitureRepository.GetTransaction(id) return transactions[id] end

function MZFurnitureRepository.ReserveResale(id, citizenid, expectedRevision)
  local transaction, item = transactions[id], transactions[id] and owned[transactions[id].ownedFurnitureId]
  if not transaction or transaction.citizenid ~= citizenid or transaction.state ~= 'initiated'
    or not item or item.status ~= 'warehouse' or item.revision ~= expectedRevision then
    return nil, 'resale_reservation_failed'
  end
  item.status = 'selling'
  item.revision = item.revision + 1
  transaction.state = 'payment_pending'
  return transaction
end

function MZFurnitureRepository.CommitResale(id, citizenid)
  local transaction, item = transactions[id], transactions[id] and owned[transactions[id].ownedFurnitureId]
  if not transaction or transaction.citizenid ~= citizenid or not item then return nil end
  if transaction.state ~= 'payment_pending' and transaction.state ~= 'manual_review'
    and transaction.state ~= 'committed' then return nil end
  item.status = 'sold'
  item.revision = item.revision + 1
  transaction.state = 'committed'
  return transaction
end

function MZFurnitureRepository.CancelResale(id, citizenid, reason)
  local transaction, item = transactions[id], transactions[id] and owned[transactions[id].ownedFurnitureId]
  if not transaction or transaction.citizenid ~= citizenid then return false end
  if item and item.status == 'selling' then
    item.status = 'warehouse'
    item.revision = item.revision + 1
  end
  transaction.state = 'failed'
  transaction.reason = reason
  return true
end

function MZFurnitureRepository.MarkResaleManualReview(id, reason)
  local transaction = transactions[id]
  if not transaction then return false end
  transaction.state = 'manual_review'
  transaction.reason = reason
  return true
end

MZFurnitureMoney = {}

function MZFurnitureMoney.CreditResale(source, amount, context)
  creditCount[source] = (creditCount[source] or 0) + 1
  if creditMode[source] == 'fail' then return false, 'bank_rejected', false end
  if creditMode[source] == 'ambiguous' then return false, 'lookup_failed', true end
  balances[source] = (balances[source] or 0) + amount
  creditOperations[context.requestId] = true
  return true, { recovered = false }
end

function MZFurnitureMoney.RecoverResale(_, requestId)
  if creditOperations[requestId] == true then return true, { recovered = true } end
  if creditOperations[requestId] == false then return false, 'operation_not_found' end
  return nil, 'operation_lookup_failed'
end

MZFurnitureResale = nil
dofile('mz_furniture/server/resale.lua')

local quoteOk, quote = MZFurnitureResale.CreateQuote(1, 1)
expect(quoteOk == true and quote.amount == 1751, 'historical resale quote is incorrect')
local soldOk, sold = MZFurnitureResale.Sell(1, quote.token)
expect(soldOk == true and sold.amount == 1751, 'warehouse resale did not complete')
expect(owned[1].status == 'sold' and balances[1] == 1751, 'resale ownership or bank credit is incorrect')
local replayOk, replayed = MZFurnitureResale.Sell(1, quote.token)
expect(replayOk == true and replayed.replayed == true, 'duplicate resale did not replay')
expect(creditCount[1] == 1 and balances[1] == 1751, 'duplicate resale credited twice')

local placedOk, placedErr = MZFurnitureResale.CreateQuote(2, 2)
expect(placedOk == false and placedErr == 'resale_requires_warehouse',
  'placed furniture must not be resold')

creditMode[3] = 'fail'
local failedQuoteOk, failedQuote = MZFurnitureResale.CreateQuote(3, 3)
expect(failedQuoteOk == true, 'failed-credit quote was not created')
local failedOk = MZFurnitureResale.Sell(3, failedQuote.token)
expect(failedOk == false and owned[3].status == 'warehouse',
  'confirmed credit failure must release the furniture')

creditMode[4] = 'ambiguous'
local reviewQuoteOk, reviewQuote = MZFurnitureResale.CreateQuote(4, 4)
expect(reviewQuoteOk == true, 'ambiguous-credit quote was not created')
local reviewOk, reviewErr = MZFurnitureResale.Sell(4, reviewQuote.token)
expect(reviewOk == false and reviewErr == 'resale_manual_review',
  'ambiguous resale credit must enter manual review')
expect(owned[4].status == 'selling', 'manual review must reserve the furniture')
creditOperations[reviewQuote.token] = true
local reconciled, summary = MZFurnitureResale.Reconcile(4, 'CID-4')
expect(reconciled == true and summary.recovered == 1, 'confirmed resale credit was not reconciled')
expect(owned[4].status == 'sold', 'reconciled resale did not finalize ownership')

print('[mz_furniture][test] resale flow harness passed')
