MZFurnitureResale = MZFurnitureResale or {}

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
  return ('fresale_%d_%d_%06d'):format(
    os.time(), math.floor(tonumber(source) or 0), Sequence
  )
end

local function log(action, source, citizenid, data)
  if GetResourceState('mz_core') ~= 'started' then return end
  pcall(function()
    exports['mz_core']:CreateDetailedLog('furniture', action, {
      actor = { type = 'player', id = tostring(citizenid or 'unknown'), source = tonumber(source) },
      target = {
        type = 'owned_furniture',
        id = tostring(data and data.ownedFurnitureId or 'pending')
      },
      data = type(data) == 'table' and data or {}
    })
  end)
end

local function replay(transaction)
  if type(transaction) ~= 'table' or transaction.transactionType ~= 'resale' then
    return false, 'invalid_resale_quote'
  end
  if transaction.state == 'committed' then
    return true, {
      replayed = true,
      transactionId = transaction.id,
      ownedFurnitureId = transaction.ownedFurnitureId,
      amount = transaction.amount
    }
  end
  if transaction.state == 'manual_review' then return false, 'resale_manual_review' end
  if transaction.state == 'failed' or transaction.state == 'cancelled' then
    return false, transaction.reason or 'resale_failed'
  end
  return false, 'resale_in_progress'
end

local function finish(source, transaction)
  local committed, commitErr = MZFurnitureRepository.CommitResale(
    transaction.id,
    transaction.citizenid
  )
  if not committed then
    MZFurnitureRepository.MarkResaleManualReview(
      transaction.id,
      commitErr or 'resale_commit_failed'
    )
    return false, 'resale_manual_review'
  end
  log('resale_committed', source, transaction.citizenid, {
    transactionId = transaction.id,
    ownedFurnitureId = transaction.ownedFurnitureId,
    catalogId = transaction.catalogId,
    amount = transaction.amount
  })
  return true, {
    replayed = false,
    transactionId = transaction.id,
    ownedFurnitureId = transaction.ownedFurnitureId,
    amount = transaction.amount
  }
end

function MZFurnitureResale.Reconcile(source, citizenid)
  source = tonumber(source)
  citizenid = citizenid or identity(source)
  if not source or not citizenid then return false, 'player_not_loaded' end
  local summary = { recovered = 0, failed = 0, manualReview = 0 }
  for _, transaction in ipairs(MZFurnitureRepository.ListRecoverableResales(citizenid)) do
    local credited, creditErr = MZFurnitureMoney.RecoverResale(source, transaction.requestId)
    if credited == true then
      local committed = MZFurnitureRepository.CommitResale(transaction.id, citizenid)
      if committed then
        summary.recovered = summary.recovered + 1
        log('resale_reconciled', source, citizenid, {
          transactionId = transaction.id,
          ownedFurnitureId = transaction.ownedFurnitureId,
          amount = transaction.amount
        })
      else
        MZFurnitureRepository.MarkResaleManualReview(transaction.id, 'resale_commit_retry_failed')
        summary.manualReview = summary.manualReview + 1
      end
    elseif credited == false and creditErr == 'operation_not_found' then
      local cancelled = MZFurnitureRepository.CancelResale(
        transaction.id,
        citizenid,
        'resale_credit_not_found'
      )
      if cancelled then summary.failed = summary.failed + 1
      else summary.manualReview = summary.manualReview + 1 end
    else
      MZFurnitureRepository.MarkResaleManualReview(
        transaction.id,
        creditErr or 'resale_credit_lookup_ambiguous'
      )
      summary.manualReview = summary.manualReview + 1
    end
  end
  return true, summary
end

function MZFurnitureResale.CreateQuote(source, ownedFurnitureId)
  source = tonumber(source)
  ownedFurnitureId = math.floor(tonumber(ownedFurnitureId) or 0)
  if not source or source <= 0 or not GetPlayerName(source) then
    return false, 'player_not_loaded'
  end
  if MZFurnitureConfig.Enabled ~= true or MZFurnitureConfig.ResaleEnabled ~= true then
    return false, 'furniture_resale_disabled'
  end
  if ownedFurnitureId <= 0 then return false, 'furniture_not_owned' end
  local citizenid, citizenErr = identity(source)
  if not citizenid then return false, citizenErr end
  MZFurnitureResale.Reconcile(source, citizenid)
  if #MZFurnitureRepository.ListRecoverableResales(citizenid) > 0
    or #MZFurnitureRepository.ListRecoverableTransactions(citizenid) > 0 then
    return false, 'resale_manual_review'
  end
  local item = MZFurnitureRepository.GetOwnedItem(citizenid, ownedFurnitureId)
  if not item then return false, 'furniture_not_owned' end
  if item.status ~= 'warehouse' or item.currentPropertyId ~= nil then
    return false, 'resale_requires_warehouse'
  end
  local amount = MZFurnitureLogic.CalculateResale(item.purchasePrice, item.resalePercent)
  if not amount or amount <= 0 then return false, 'furniture_not_resellable' end
  local quoteToken = token(source)
  local ttl = math.max(10, math.min(
    120,
    math.floor(tonumber(MZFurnitureConfig.QuoteTtlSeconds) or 45)
  ))
  Quotes[source] = {
    token = quoteToken,
    citizenid = citizenid,
    ownedFurnitureId = item.id,
    ownedRevision = item.revision,
    catalogId = item.catalogId,
    purchasePrice = item.purchasePrice,
    resalePercent = item.resalePercent,
    amount = amount,
    expiresAt = os.time() + ttl,
    used = false
  }
  return true, {
    token = quoteToken,
    label = item.label,
    amount = amount,
    purchasePrice = item.purchasePrice,
    resalePercent = item.resalePercent,
    expiresIn = ttl
  }
end

function MZFurnitureResale.Sell(source, quoteToken)
  source = tonumber(source)
  quoteToken = MZFurnitureLogic.NormalizePurchaseToken(quoteToken)
  if not source or source <= 0 or not GetPlayerName(source) then
    return false, 'player_not_loaded'
  end
  if not quoteToken then return false, 'invalid_resale_quote' end
  if MZFurnitureConfig.Enabled ~= true or MZFurnitureConfig.ResaleEnabled ~= true then
    return false, 'furniture_resale_disabled'
  end

  local quote = Quotes[source]
  local lockKey = quote and tonumber(quote.ownedFurnitureId) or ('source:%s'):format(source)
  if Locks[lockKey] then return false, 'resale_in_progress' end
  Locks[lockKey] = true

  local callOk, success, result = xpcall(function()
    local citizenid, citizenErr = identity(source)
    if not citizenid then return false, citizenErr end
    local existing = MZFurnitureRepository.GetTransactionByRequest(quoteToken)
    if existing then
      if existing.citizenid ~= citizenid then return false, 'resale_owner_mismatch' end
      return replay(existing)
    end
    quote = Quotes[source]
    if type(quote) ~= 'table' or quote.token ~= quoteToken then
      return false, 'invalid_resale_quote'
    end
    if quote.citizenid ~= citizenid then return false, 'resale_owner_mismatch' end
    if quote.used == true then return false, 'resale_quote_used' end
    if quote.expiresAt < os.time() then return false, 'resale_quote_expired' end
    local item = MZFurnitureRepository.GetOwnedItem(citizenid, quote.ownedFurnitureId)
    if not item then return false, 'furniture_not_owned' end
    if item.status ~= 'warehouse' or item.currentPropertyId ~= nil then
      return false, 'resale_requires_warehouse'
    end
    local amount = MZFurnitureLogic.CalculateResale(item.purchasePrice, item.resalePercent)
    if item.revision ~= quote.ownedRevision or item.catalogId ~= quote.catalogId
      or amount ~= quote.amount or item.purchasePrice ~= quote.purchasePrice then
      return false, 'resale_quote_changed'
    end
    quote.used = true

    local transactionId, createErr = MZFurnitureRepository.CreateResaleTransaction({
      requestId = quoteToken,
      citizenid = citizenid,
      catalogId = item.catalogId,
      ownedFurnitureId = item.id,
      amount = amount,
      metadata = {
        purchasePrice = item.purchasePrice,
        resalePercent = item.resalePercent,
        ownedRevision = item.revision,
        source = source
      }
    })
    if not transactionId then return false, createErr end
    local transaction = MZFurnitureRepository.GetTransaction(transactionId)
    if createErr == 'already_exists' then return replay(transaction) end
    transaction = MZFurnitureRepository.ReserveResale(
      transactionId,
      citizenid,
      item.revision
    )
    if not transaction then return false, 'resale_reservation_failed' end

    local credited, creditDetail, ambiguous = MZFurnitureMoney.CreditResale(source, amount, {
      requestId = quoteToken,
      catalogId = item.catalogId,
      transactionId = transactionId
    })
    if credited ~= true then
      if ambiguous == true then
        MZFurnitureRepository.MarkResaleManualReview(
          transactionId,
          creditDetail or 'resale_credit_result_ambiguous'
        )
        return false, 'resale_manual_review'
      end
      MZFurnitureRepository.CancelResale(
        transactionId,
        citizenid,
        creditDetail or 'resale_credit_failed'
      )
      return false, creditDetail or 'resale_credit_failed'
    end
    transaction = MZFurnitureRepository.GetTransaction(transactionId) or transaction
    return finish(source, transaction)
  end, safeTraceback)

  Locks[lockKey] = nil
  if not callOk then
    print(('[mz_furniture][resale] exception source=%s error=%s'):format(
      source,
      tostring(success)
    ))
    local transaction = MZFurnitureRepository.GetTransactionByRequest(quoteToken)
    if transaction and (transaction.state == 'payment_pending'
      or transaction.state == 'manual_review') then
      MZFurnitureRepository.MarkResaleManualReview(transaction.id, 'unexpected_resale_error')
      return false, 'resale_manual_review'
    end
    return false, 'resale_failed'
  end
  return success, result
end

AddEventHandler('playerDropped', function()
  Quotes[source] = nil
  Locks[('source:%s'):format(tonumber(source) or 0)] = nil
end)
