MZFurnitureConfig = nil
MZFurnitureLogic = nil
dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')
MZFurnitureConfig.OrganizationOwnershipEnabled = true
MZFurnitureConfig.OrganizationPurchasesEnabled = true

local function expect(condition, message) if not condition then error(message, 2) end end

local catalog = {
  id = 10, code = 'collective_chair', category = 'sala', label = 'Cadeira coletiva',
  description = '', price = 500, revision = 1, enabled = true, visible = true,
  archived = false
}
local balances = { [1] = 2000, [2] = 2000, [3] = 100, [4] = 2000, [5] = 2000 }
local spends, refunds = {}, {}
local transactions, byRequest, ownedByTransaction = {}, {}, {}
local transactionSequence, ownedSequence = 0, 0
local spendCalls, refundCalls = {}, {}
local grantFails = false
local ambiguousAfterDebit = { [5] = true }

function GetPlayerName(source) return balances[source] and ('Player %s'):format(source) or nil end
function GetResourceState(resource) return (resource == 'mz_core' or resource == 'mz_org') and 'started' or 'missing' end
function AddEventHandler() end

exports = {
  mz_core = {
    ResolvePlayerIdentity = function(_, source)
      return { ok = true, citizenid = ('CID-%s'):format(source) }
    end,
    CreateDetailedLog = function() return true end
  },
  mz_org = {
    GetOrgAccountCommerceCapabilities = function()
      return {
        ready = true, spend = true, refund = true, idempotent = true, receipt = true,
        purposes = { 'facility_purchase', 'furniture_purchase' }
      }
    end,
    SpendOrgAccount = function(_, source, orgCode, amount, options)
      spendCalls[source] = (spendCalls[source] or 0) + 1
      local existing = spends[options.operationKey]
      if existing then existing.replayed = true return true, existing end
      if orgCode ~= 'mafia' then return false, 'invalid_org' end
      if balances[source] < amount then return false, 'insufficient_org_funds' end
      balances[source] = balances[source] - amount
      local receipt = {
        receiptId = ('spend-%s'):format(source), amount = amount,
        purpose = 'furniture_purchase', replayed = false
      }
      spends[options.operationKey] = receipt
      if ambiguousAfterDebit[source] then
        ambiguousAfterDebit[source] = false
        error('injected timeout after debit')
      end
      return true, receipt
    end,
    RefundOrgAccount = function(_, source, orgCode, spendReceiptId, options)
      refundCalls[source] = (refundCalls[source] or 0) + 1
      if refunds[options.operationKey] then return true, refunds[options.operationKey] end
      if orgCode ~= 'mafia' then return false, 'invalid_org' end
      local original
      for _, receipt in pairs(spends) do
        if receipt.receiptId == spendReceiptId then original = receipt break end
      end
      if not original then return false, 'spend_receipt_not_found' end
      balances[source] = balances[source] + original.amount
      local receipt = { receiptId = ('refund-%s'):format(source), amount = original.amount }
      refunds[options.operationKey] = receipt
      return true, receipt
    end
  }
}

MZFurnitureDB = {
  GetOwnerMigrationStatus = function()
    return { ready = true, organizationReady = true, invalidRows = 0 }
  end
}
MZFurnitureCatalog = { IsReady = function() return true end }
MZFurnitureOrganization = {
  ResolvePurchaseContext = function(source, orgCode)
    if balances[source] and tostring(orgCode):lower() == 'mafia' then
      return { source = source, orgCode = 'mafia', orgName = 'Mafia', facilities = { { id = 1 } } }
    end
    return nil, 'organization_purchase_forbidden'
  end
}

MZFurnitureRepository = {}
function MZFurnitureRepository.GetCatalogItem() return catalog end
function MZFurnitureRepository.CreateOrgFurnitureTransaction(data)
  local existing = byRequest[data.requestId]
  if existing then return existing.id, 'already_exists' end
  transactionSequence = transactionSequence + 1
  local row = {
    id = transactionSequence, requestId = data.requestId, orgCode = data.orgCode,
    actorCitizenid = data.actorCitizenid, state = 'initiated', amount = data.amount,
    catalogId = data.catalogId, metadata = data.metadata
  }
  transactions[row.id], byRequest[row.requestId] = row, row
  return row.id
end
function MZFurnitureRepository.GetOrgFurnitureTransactionByRequest(requestId)
  return byRequest[requestId]
end
function MZFurnitureRepository.GetOrgFurnitureTransaction(id) return transactions[id] end
function MZFurnitureRepository.TransitionOrgFurnitureTransaction(id, toState, fromStates, detail)
  local row = transactions[id]
  if not row then return false end
  local allowed = false
  for _, state in ipairs(fromStates) do if row.state == state then allowed = true break end end
  if not allowed then return false end
  row.state, row.reason = toState, detail and detail.reason or nil
  if detail and detail.spendReceiptId then row.spendReceiptId = detail.spendReceiptId end
  if detail and detail.refundReceiptId then row.refundReceiptId = detail.refundReceiptId end
  return true
end
function MZFurnitureRepository.CommitOrgPurchasedItem(id)
  if grantFails then return nil, 'injected_org_grant_failure' end
  local existing = ownedByTransaction[id]
  if existing then transactions[id].state = 'committed' return existing end
  local row = transactions[id]
  if not row or row.state ~= 'money_removed' then return nil, 'invalid_state' end
  ownedSequence = ownedSequence + 1
  local item = {
    id = ownedSequence, ownerType = 'org', ownerKey = row.orgCode,
    catalogId = row.catalogId, category = catalog.category, label = catalog.label,
    description = '', purchasePrice = row.amount, status = 'warehouse', revision = 1
  }
  ownedByTransaction[id] = item
  row.state, row.ownedFurnitureId = 'committed', item.id
  return item
end
function MZFurnitureRepository.GetOwnedByOrgPurchaseTransaction(id)
  return ownedByTransaction[id]
end
function MZFurnitureRepository.ListRecoverableOrgFurnitureTransactions(citizenid)
  local result = {}
  for _, row in pairs(transactions) do
    if row.actorCitizenid == citizenid
      and (row.state == 'payment_pending' or row.state == 'money_removed'
        or row.state == 'manual_review') then result[#result + 1] = row end
  end
  return result
end

MZFurnitureOrganizationPurchase = nil
dofile('mz_furniture/server/organization_purchase.lua')

local quoteOk, quote = MZFurnitureOrganizationPurchase.CreateQuote(1, 'mafia', catalog.id)
expect(quoteOk and quote.price == 500, 'organization quote was not created')
local purchaseOk, purchase = MZFurnitureOrganizationPurchase.Purchase(1, quote.token)
expect(purchaseOk and purchase.item.status == 'warehouse', 'organization purchase did not grant')
expect(balances[1] == 1500 and ownedSequence == 1, 'organization debit or grant is incorrect')
local replayOk, replay = MZFurnitureOrganizationPurchase.Purchase(1, quote.token)
expect(replayOk and replay.replayed == true and balances[1] == 1500 and ownedSequence == 1,
  'organization purchase replay duplicated debit or ownership')

local changedOk, changedQuote = MZFurnitureOrganizationPurchase.CreateQuote(2, 'mafia', catalog.id)
expect(changedOk, 'price change quote failed')
catalog.price, catalog.revision = 600, 2
local changedPurchase, changedErr = MZFurnitureOrganizationPurchase.Purchase(2, changedQuote.token)
expect(not changedPurchase and changedErr == 'quote_changed' and balances[2] == 2000,
  'changed organization quote was charged')

local insufficientOk, insufficientQuote = MZFurnitureOrganizationPurchase.CreateQuote(3, 'mafia', catalog.id)
expect(insufficientOk, 'insufficient balance quote failed')
local insufficientPurchase, insufficientErr =
  MZFurnitureOrganizationPurchase.Purchase(3, insufficientQuote.token)
expect(not insufficientPurchase and insufficientErr == 'insufficient_org_funds'
  and balances[3] == 100, 'insufficient organization balance did not fail safely')

grantFails = true
local refundQuoteOk, refundQuote = MZFurnitureOrganizationPurchase.CreateQuote(4, 'mafia', catalog.id)
expect(refundQuoteOk, 'refund quote failed')
local refundPurchase, refundErr = MZFurnitureOrganizationPurchase.Purchase(4, refundQuote.token)
expect(not refundPurchase and refundErr == 'organization_purchase_refunded'
  and balances[4] == 2000 and refundCalls[4] == 1,
  'organization grant failure was not compensated exactly once')
grantFails = false

local ambiguousQuoteOk, ambiguousQuote =
  MZFurnitureOrganizationPurchase.CreateQuote(5, 'mafia', catalog.id)
expect(ambiguousQuoteOk, 'ambiguous spend quote failed')
local ambiguousPurchase, ambiguousErr =
  MZFurnitureOrganizationPurchase.Purchase(5, ambiguousQuote.token)
expect(not ambiguousPurchase and ambiguousErr == 'organization_purchase_manual_review'
  and balances[5] == 1400, 'ambiguous spend did not enter manual review after one debit')
local reconcileOk, summary = MZFurnitureOrganizationPurchase.Reconcile(5, 'CID-5')
expect(reconcileOk and summary.recovered == 1 and balances[5] == 1400,
  'idempotent spend recovery did not grant the item')
expect(spendCalls[5] == 2 and ownedSequence == 2,
  'recovery duplicated the debit or produced the wrong ownership count')

print('[mz_furniture][test] organization purchase flow harness passed')
