MZFurniturePurchase = MZFurniturePurchase or {}

local Quotes = {}
local Locks = {}
local Sequence = 0

local function safeTraceback(err)
  if type(debug) == 'table' and type(debug.traceback) == 'function' then
    return debug.traceback(tostring(err), 2)
  end
  return tostring(err)
end

local function identity(source)
  if GetResourceState('mz_core') ~= 'started' then return nil, 'core_unavailable' end
  local callOk, result = pcall(function()
    return exports['mz_core']:ResolvePlayerIdentity(source)
  end)
  if not callOk or type(result) ~= 'table' or result.ok ~= true
    or MZFurnitureLogic.Trim(result.citizenid) == '' then
    return nil, result and result.error or 'player_not_loaded'
  end
  return tostring(result.citizenid):sub(1, 64)
end

local function token(source)
  Sequence = (Sequence + 1) % 1000000
  return ('furn_%d_%d_%06d_%06d'):format(
    os.time(),
    math.floor(tonumber(source) or 0),
    Sequence,
    math.random(0, 999999)
  )
end

local function log(action, source, citizenid, data)
  if GetResourceState('mz_core') ~= 'started' then return end
  pcall(function()
    exports['mz_core']:CreateDetailedLog('furniture', action, {
      actor = { type = 'player', id = tostring(citizenid or 'unknown'), source = tonumber(source) },
      target = { type = 'furniture_transaction', id = tostring(data and data.transactionId or 'pending') },
      data = type(data) == 'table' and data or {}
    })
  end)
end

local function playerOwnedDto(item)
  return {
    id = item.id,
    catalogId = item.catalogId,
    catalogCode = item.catalogCode,
    category = item.category,
    label = item.label,
    description = item.description,
    purchasePrice = item.purchasePrice,
    status = item.status,
    currentPropertyId = item.currentPropertyId,
    revision = item.revision,
    createdAt = item.createdAt
  }
end

local function hasFinancialReview(citizenid)
  if #MZFurnitureRepository.ListRecoverableTransactions(citizenid) > 0 then return true end
  return type(MZFurnitureRepository.ListRecoverableResales) == 'function'
    and #MZFurnitureRepository.ListRecoverableResales(citizenid) > 0
end

local function transactionReplay(transaction)
  if not transaction then return nil end
  if transaction.state == 'committed' then
    local owned = MZFurnitureRepository.GetOwnedByPurchaseTransaction(transaction.id)
    if owned then
      return true, {
        replayed = true,
        transactionId = transaction.id,
        amount = transaction.amount,
        item = playerOwnedDto(owned)
      }
    end
    return false, 'purchase_manual_review'
  end
  if transaction.state == 'failed' or transaction.state == 'cancelled' then
    return false, transaction.reason or 'purchase_failed'
  end
  if transaction.state == 'refunded' then return false, 'purchase_refunded' end
  if transaction.state == 'manual_review' then return false, 'purchase_manual_review' end
  return false, 'purchase_in_progress'
end

local function manualReview(transaction, reason, detail)
  detail = type(detail) == 'table' and detail or {}
  detail.reason = reason
  MZFurnitureRepository.TransitionTransaction(
    transaction.id,
    'manual_review',
    { 'payment_pending', 'money_removed', 'manual_review' },
    detail
  )
  return false, 'purchase_manual_review'
end

local function refund(source, transaction, reason)
  local refunded, refundDetail, ambiguous = MZFurnitureMoney.Refund(source, transaction.amount, {
    requestId = transaction.requestId,
    catalogId = transaction.catalogId,
    transactionId = transaction.id
  })
  if refunded == true then
    MZFurnitureRepository.TransitionTransaction(
      transaction.id,
      'refunded',
      { 'payment_pending', 'money_removed', 'manual_review' },
      { reason = reason, refund = refundDetail }
    )
    log('purchase_refunded', source, transaction.citizenid, {
      transactionId = transaction.id,
      amount = transaction.amount,
      reason = reason
    })
    return false, reason
  end
  return manualReview(transaction, ambiguous and 'refund_result_ambiguous' or 'refund_failed', {
    originalReason = reason,
    refundError = refundDetail
  })
end

local function grantOrRefund(source, transaction)
  local owned, grantErr = MZFurnitureRepository.CommitPurchasedItem(transaction.id, {
    purchaseRequestId = transaction.requestId,
    acquiredThrough = 'store'
  })
  if owned then
    log('purchase_committed', source, transaction.citizenid, {
      transactionId = transaction.id,
      ownedFurnitureId = owned.id,
      catalogId = transaction.catalogId,
      amount = transaction.amount
    })
    return true, {
      replayed = false,
      transactionId = transaction.id,
      amount = transaction.amount,
      item = playerOwnedDto(owned)
    }
  end

  local reread = MZFurnitureRepository.GetTransaction(transaction.id)
  local existing = MZFurnitureRepository.GetOwnedByPurchaseTransaction(transaction.id)
  if reread and reread.state == 'committed' and existing then
    return true, {
      replayed = true,
      transactionId = reread.id,
      amount = reread.amount,
      item = playerOwnedDto(existing)
    }
  end
  return refund(source, reread or transaction, grantErr or 'ownership_grant_failed')
end

function MZFurniturePurchase.Open(source)
  source = tonumber(source)
  if not source or source <= 0 or not GetPlayerName(source) then return false, 'player_not_loaded' end
  if MZFurnitureConfig.Enabled ~= true or MZFurnitureConfig.CatalogEnabled ~= true then
    return false, 'furniture_catalog_disabled'
  end
  if not MZFurnitureCatalog.IsReady() then return false, 'furniture_not_ready' end
  local citizenid, citizenErr = identity(source)
  if not citizenid then return false, citizenErr end
  MZFurniturePurchase.Reconcile(source, citizenid)
  if MZFurnitureResale then MZFurnitureResale.Reconcile(source, citizenid) end
  MZFurnitureCatalog.RefreshIfStale()
  local catalog, catalogErr = MZFurnitureCatalog.ListForPlayer()
  if not catalog then return false, catalogErr end
  local owned = MZFurnitureRepository.ListOwned(citizenid)
  local financialReview = hasFinancialReview(citizenid)
  local warehouse = {}
  for _, item in ipairs(owned) do warehouse[#warehouse + 1] = playerOwnedDto(item) end
  return true, {
    catalog = catalog,
    warehouse = warehouse,
    purchasesEnabled = MZFurnitureConfig.PurchasesEnabled == true and not financialReview,
    placementEnabled = MZFurnitureConfig.PlacementEnabled == true,
    resaleEnabled = MZFurnitureConfig.ResaleEnabled == true and not financialReview,
    financialReview = financialReview
  }
end

function MZFurniturePurchase.CreateQuote(source, catalogIdentifier)
  source = tonumber(source)
  if not source or source <= 0 or not GetPlayerName(source) then return false, 'player_not_loaded' end
  if MZFurnitureConfig.Enabled ~= true or MZFurnitureConfig.CatalogEnabled ~= true
    or MZFurnitureConfig.PurchasesEnabled ~= true then
    return false, 'furniture_purchases_disabled'
  end
  if not MZFurnitureCatalog.IsReady() then return false, 'furniture_not_ready' end
  local citizenid, citizenErr = identity(source)
  if not citizenid then return false, citizenErr end
  MZFurniturePurchase.Reconcile(source, citizenid)
  if MZFurnitureResale then MZFurnitureResale.Reconcile(source, citizenid) end
  if hasFinancialReview(citizenid) then
    return false, 'purchase_manual_review'
  end
  local item = MZFurnitureRepository.GetCatalogItem(catalogIdentifier)
  if not item or item.enabled ~= true or item.visible ~= true or item.archived == true then
    return false, 'item_unavailable'
  end
  local quoteToken = token(source)
  local ttl = math.max(10, math.min(120, math.floor(tonumber(MZFurnitureConfig.QuoteTtlSeconds) or 45)))
  Quotes[source] = {
    token = quoteToken,
    citizenid = citizenid,
    catalogId = item.id,
    catalogRevision = item.revision,
    price = item.price,
    createdAt = os.time(),
    expiresAt = os.time() + ttl,
    used = false
  }
  return true, {
    token = quoteToken,
    catalogId = item.id,
    label = item.label,
    category = item.category,
    price = item.price,
    expiresIn = ttl
  }
end

function MZFurniturePurchase.Purchase(source, quoteToken)
  source = tonumber(source)
  quoteToken = MZFurnitureLogic.NormalizePurchaseToken(quoteToken)
  if not source or source <= 0 or not GetPlayerName(source) then return false, 'player_not_loaded' end
  if not quoteToken then return false, 'invalid_quote' end
  if MZFurnitureConfig.Enabled ~= true or MZFurnitureConfig.PurchasesEnabled ~= true then
    return false, 'furniture_purchases_disabled'
  end
  if not MZFurnitureCatalog.IsReady() then return false, 'furniture_not_ready' end
  if Locks[source] then return false, 'purchase_in_progress' end
  Locks[source] = true

  local callOk, success, result = xpcall(function()
    local citizenid, citizenErr = identity(source)
    if not citizenid then return false, citizenErr end

    local existing = MZFurnitureRepository.GetTransactionByRequest(quoteToken)
    if existing then
      if existing.citizenid ~= citizenid then return false, 'quote_owner_mismatch' end
      return transactionReplay(existing)
    end

    local quote = Quotes[source]
    if type(quote) ~= 'table' or quote.token ~= quoteToken then return false, 'invalid_quote' end
    local item = MZFurnitureRepository.GetCatalogItem(quote.catalogId)
    local quoteOk, quoteErr = MZFurnitureLogic.QuoteMatches(quote, item, citizenid, os.time())
    if not quoteOk then return false, quoteErr end
    quote.used = true

    local balance, balanceErr = MZFurnitureMoney.GetBalance(source)
    if not balance then return false, balanceErr end
    if balance < item.price then return false, 'not_enough_money' end

    local transactionId, createErr = MZFurnitureRepository.CreatePurchaseTransaction({
      requestId = quoteToken,
      citizenid = citizenid,
      catalogId = item.id,
      amount = item.price,
      metadata = {
        catalogCode = item.code,
        catalogRevision = item.revision,
        quotedAt = quote.createdAt,
        source = source
      }
    })
    if not transactionId then return false, createErr end
    local transaction = MZFurnitureRepository.GetTransaction(transactionId)
    if createErr == 'already_exists' then return transactionReplay(transaction) end

    local pending = MZFurnitureRepository.TransitionTransaction(
      transactionId,
      'payment_pending',
      { 'initiated' },
      { reason = 'debit_started', catalogRevision = item.revision }
    )
    if not pending then return false, 'transaction_state_failed' end
    transaction = MZFurnitureRepository.GetTransaction(transactionId)

    local debited, debitDetail, ambiguous = MZFurnitureMoney.Debit(source, item.price, {
      requestId = quoteToken,
      catalogId = item.id,
      transactionId = transactionId
    })
    if debited ~= true then
      if ambiguous == true then
        return manualReview(transaction, 'debit_result_ambiguous', { debitError = debitDetail })
      end
      MZFurnitureRepository.TransitionTransaction(
        transactionId,
        'failed',
        { 'payment_pending' },
        { reason = debitDetail or 'payment_failed' }
      )
      return false, debitDetail or 'payment_failed'
    end

    local marked = MZFurnitureRepository.TransitionTransaction(
      transactionId,
      'money_removed',
      { 'payment_pending' },
      { reason = 'bank_debit_confirmed', debit = debitDetail }
    )
    transaction = MZFurnitureRepository.GetTransaction(transactionId)
    if not marked and transaction and transaction.state ~= 'money_removed'
      and transaction.state ~= 'committed' then
      return refund(source, transaction, 'transaction_state_failed')
    end
    if transaction and transaction.state == 'committed' then return transactionReplay(transaction) end
    return grantOrRefund(source, transaction)
  end, safeTraceback)

  Locks[source] = nil
  if not callOk then
    print(('[mz_furniture][purchase] exception source=%s error=%s'):format(source, tostring(success)))
    local transaction = MZFurnitureRepository.GetTransactionByRequest(quoteToken)
    if transaction and transaction.state == 'money_removed' then
      return refund(source, transaction, 'unexpected_error')
    end
    if transaction and transaction.state == 'payment_pending' then
      manualReview(transaction, 'unexpected_error_during_debit', { traceback = tostring(success) })
      return false, 'purchase_manual_review'
    end
    return false, 'purchase_failed'
  end
  return success, result
end

function MZFurniturePurchase.Reconcile(source, citizenid)
  source = tonumber(source)
  citizenid = citizenid or identity(source)
  if not source or not citizenid then return false, 'player_not_loaded' end
  local rows = MZFurnitureRepository.ListRecoverableTransactions(citizenid)
  local summary = { recovered = 0, failed = 0, manualReview = 0 }
  for _, transaction in ipairs(rows) do
    local owned = MZFurnitureRepository.GetOwnedByPurchaseTransaction(transaction.id)
    if owned and transaction.state == 'manual_review' then
      local moved = MZFurnitureRepository.TransitionTransaction(
        transaction.id, 'money_removed', { 'manual_review' }, { reason = 'ownership_reconciled' }
      )
      local committed = moved and MZFurnitureRepository.CommitPurchasedItem(
        transaction.id,
        { purchaseRequestId = transaction.requestId, acquiredThrough = 'recovery' }
      )
      if committed then
        summary.recovered = summary.recovered + 1
      else
        summary.manualReview = summary.manualReview + 1
      end
    else
      if transaction.state == 'manual_review' then
        local refunded, refundErr = MZFurnitureMoney.RecoverRefund(source, transaction.requestId)
        if refunded == true then
          MZFurnitureRepository.TransitionTransaction(
            transaction.id,
            'refunded',
            { 'manual_review' },
            { reason = 'refund_reconciled' }
          )
          summary.recovered = summary.recovered + 1
          goto continue
        elseif refunded == nil then
          summary.manualReview = summary.manualReview + 1
          goto continue
        elseif refundErr ~= 'operation_not_found' then
          summary.manualReview = summary.manualReview + 1
          goto continue
        end
      end
      local debited, debitErr = MZFurnitureMoney.RecoverDebit(source, transaction.requestId)
      if debited == true then
        if transaction.state ~= 'money_removed' then
          MZFurnitureRepository.TransitionTransaction(
            transaction.id,
            'money_removed',
            { 'payment_pending', 'manual_review' },
            { reason = 'debit_reconciled' }
          )
        end
        local current = MZFurnitureRepository.GetTransaction(transaction.id)
        local granted = current and grantOrRefund(source, current)
        if granted == true then summary.recovered = summary.recovered + 1
        else summary.manualReview = summary.manualReview + 1 end
      elseif debited == false and debitErr == 'operation_not_found' then
        MZFurnitureRepository.TransitionTransaction(
          transaction.id,
          'failed',
          { 'payment_pending', 'manual_review' },
          { reason = 'debit_not_found_during_recovery' }
        )
        summary.failed = summary.failed + 1
      else
        summary.manualReview = summary.manualReview + 1
      end
    end
    ::continue::
  end
  return true, summary
end

AddEventHandler('playerDropped', function()
  Quotes[source] = nil
  Locks[source] = nil
end)
