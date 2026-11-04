MZFurnitureOrganizationPurchase = MZFurnitureOrganizationPurchase or {}

local Quotes = {}
local Locks = {}
local Sequence = 0

local function identity(source)
  if GetResourceState('mz_core') ~= 'started' then return nil, 'core_unavailable' end
  local ok, result = pcall(function()
    return exports['mz_core']:ResolvePlayerIdentity(source)
  end)
  if not ok or type(result) ~= 'table' or result.ok ~= true
    or MZFurnitureLogic.Trim(result.citizenid) == '' then
    return nil, result and result.error or 'player_not_loaded'
  end
  return tostring(result.citizenid):sub(1, 64)
end

local function token(source)
  Sequence = (Sequence + 1) % 1000000
  return ('orgfurn_%d_%d_%06d_%06d'):format(
    os.time(),
    math.floor(tonumber(source) or 0),
    Sequence,
    math.random(0, 999999)
  )
end

local function purposeAvailable(capabilities)
  if type(capabilities) ~= 'table' or capabilities.ready ~= true
    or capabilities.spend ~= true or capabilities.refund ~= true
    or capabilities.idempotent ~= true or capabilities.receipt ~= true then return false end
  for _, purpose in ipairs(type(capabilities.purposes) == 'table' and capabilities.purposes or {}) do
    if purpose == 'furniture_purchase' then return true end
  end
  return false
end

function MZFurnitureOrganizationPurchase.IsReady()
  if MZFurnitureConfig.Enabled ~= true
    or MZFurnitureConfig.OrganizationOwnershipEnabled ~= true
    or MZFurnitureConfig.OrganizationPurchasesEnabled ~= true then
    return false, 'organization_purchases_disabled'
  end
  local migration = MZFurnitureDB.GetOwnerMigrationStatus()
  if migration.organizationReady ~= true then
    return false, 'organization_owner_schema_not_ready'
  end
  if GetResourceState('mz_core') ~= 'started' then return false, 'core_unavailable' end
  local ok, capabilities = pcall(function()
    return exports['mz_org']:GetOrgAccountCommerceCapabilities()
  end)
  if not ok or not purposeAvailable(capabilities) then
    return false, 'org_furniture_spend_contract_unavailable'
  end
  return true
end

local function log(action, source, orgCode, actorCitizenid, data)
  pcall(function()
    exports['mz_core']:CreateDetailedLog('furniture', action, {
      actor = {
        type = 'player', id = tostring(actorCitizenid or 'unknown'), source = tonumber(source)
      },
      target = { type = 'organization', id = tostring(orgCode or 'unknown') },
      data = type(data) == 'table' and data or {}
    })
  end)
end

local function itemDto(item)
  return {
    category = item.category,
    label = item.label,
    description = item.description,
    purchasePrice = item.purchasePrice,
    status = item.status
  }
end

local function transactionReplay(transaction)
  if not transaction then return false, 'organization_purchase_failed' end
  if transaction.state == 'committed' then
    local owned = MZFurnitureRepository.GetOwnedByOrgPurchaseTransaction(transaction.id)
    if owned then
      return true, {
        replayed = true,
        amount = transaction.amount,
        organization = { code = transaction.orgCode },
        item = itemDto(owned)
      }
    end
    return false, 'organization_purchase_manual_review'
  end
  if transaction.state == 'failed' then
    return false, transaction.reason or 'organization_purchase_failed'
  end
  if transaction.state == 'refunded' then return false, 'organization_purchase_refunded' end
  if transaction.state == 'manual_review' then
    return false, 'organization_purchase_manual_review'
  end
  return false, 'organization_purchase_in_progress'
end

local function manualReview(transaction, reason, detail)
  if type(transaction) ~= 'table' or not transaction.id then
    return false, 'organization_purchase_manual_review'
  end
  detail = type(detail) == 'table' and detail or {}
  detail.reason = reason
  MZFurnitureRepository.TransitionOrgFurnitureTransaction(
    transaction.id,
    'manual_review',
    { 'payment_pending', 'money_removed', 'manual_review' },
    detail
  )
  return false, 'organization_purchase_manual_review'
end

local function spend(source, transaction)
  local operationKey = 'furniture_purchase:' .. transaction.requestId
  local callOk, success, result = pcall(function()
    return exports['mz_org']:SpendOrgAccount(
      source,
      transaction.orgCode,
      transaction.amount,
      {
        operationKey = operationKey,
        purpose = 'furniture_purchase',
        relatedRef = operationKey,
        reason = 'organization_furniture_purchase'
      }
    )
  end)
  if not callOk then return nil, 'org_spend_result_ambiguous', true end
  if success ~= true or type(result) ~= 'table' or not result.receiptId then
    return false, result or 'org_furniture_spend_failed', false
  end
  return true, result, false
end

local function refund(source, transaction, reason)
  if not transaction.spendReceiptId then
    return manualReview(transaction, 'org_refund_receipt_missing', { originalReason = reason })
  end
  local callOk, success, result = pcall(function()
    return exports['mz_org']:RefundOrgAccount(
      source,
      transaction.orgCode,
      transaction.spendReceiptId,
      {
        operationKey = 'furniture_refund:' .. transaction.requestId,
        reason = reason or 'organization_furniture_grant_failed'
      }
    )
  end)
  if callOk and success == true and type(result) == 'table' and result.receiptId then
    MZFurnitureRepository.TransitionOrgFurnitureTransaction(
      transaction.id,
      'refunded',
      { 'payment_pending', 'money_removed', 'manual_review' },
      {
        reason = reason or 'organization_furniture_grant_failed',
        spendReceiptId = transaction.spendReceiptId,
        refundReceiptId = result.receiptId
      }
    )
    log('organization_purchase_refunded', source, transaction.orgCode,
      transaction.actorCitizenid, {
        requestId = transaction.requestId,
        amount = transaction.amount,
        spendReceiptId = transaction.spendReceiptId,
        refundReceiptId = result.receiptId
      })
    return false, 'organization_purchase_refunded'
  end
  return manualReview(transaction, 'org_refund_result_ambiguous', {
    originalReason = reason,
    spendReceiptId = transaction.spendReceiptId,
    refundError = callOk and result or 'refund_export_failed'
  })
end

local function grantOrRefund(source, transaction)
  local owned, grantErr = MZFurnitureRepository.CommitOrgPurchasedItem(transaction.id, {
    purchaseRequestId = transaction.requestId,
    spendReceiptId = transaction.spendReceiptId,
    acquiredThrough = 'organization_store',
    actorCitizenid = transaction.actorCitizenid
  })
  if owned then
    log('organization_purchase_committed', source, transaction.orgCode,
      transaction.actorCitizenid, {
        requestId = transaction.requestId,
        amount = transaction.amount,
        catalogId = transaction.catalogId,
        spendReceiptId = transaction.spendReceiptId
      })
    return true, {
      replayed = false,
      amount = transaction.amount,
      organization = { code = transaction.orgCode },
      item = itemDto(owned)
    }
  end
  local current = MZFurnitureRepository.GetOrgFurnitureTransaction(transaction.id) or transaction
  local existing = MZFurnitureRepository.GetOwnedByOrgPurchaseTransaction(transaction.id)
  if current.state == 'committed' and existing then return transactionReplay(current) end
  return refund(source, current, grantErr or 'organization_ownership_grant_failed')
end

function MZFurnitureOrganizationPurchase.Reconcile(source, actorCitizenid)
  source = tonumber(source)
  actorCitizenid = actorCitizenid or identity(source)
  if not source or source <= 0 or not actorCitizenid then return false, 'player_not_loaded' end
  local rows = MZFurnitureRepository.ListRecoverableOrgFurnitureTransactions(actorCitizenid)
  local summary = { recovered = 0, refunded = 0, manualReview = 0 }
  for _, transaction in ipairs(rows) do
    local owned = MZFurnitureRepository.GetOwnedByOrgPurchaseTransaction(transaction.id)
    if owned then
      if transaction.state == 'manual_review' then
        MZFurnitureRepository.TransitionOrgFurnitureTransaction(
          transaction.id, 'money_removed', { 'manual_review' }, {
            reason = 'organization_ownership_reconciled',
            spendReceiptId = transaction.spendReceiptId
          }
        )
      end
      local committed = MZFurnitureRepository.CommitOrgPurchasedItem(transaction.id, {
        purchaseRequestId = transaction.requestId,
        spendReceiptId = transaction.spendReceiptId,
        acquiredThrough = 'organization_recovery',
        actorCitizenid = transaction.actorCitizenid
      })
      if committed then summary.recovered = summary.recovered + 1
      else summary.manualReview = summary.manualReview + 1 end
    elseif transaction.spendReceiptId then
      local _, refundResult = refund(source, transaction, 'organization_recovery_refund')
      if refundResult == 'organization_purchase_refunded' then
        summary.refunded = summary.refunded + 1
      else
        summary.manualReview = summary.manualReview + 1
      end
    else
      local context = MZFurnitureOrganization.ResolvePurchaseContext(source, transaction.orgCode)
      if not context then
        summary.manualReview = summary.manualReview + 1
      else
        local spent, spendResult, ambiguous = spend(source, transaction)
        if spent == true then
          MZFurnitureRepository.TransitionOrgFurnitureTransaction(
            transaction.id, 'money_removed', { 'payment_pending', 'manual_review' }, {
              reason = 'organization_spend_reconciled',
              spendReceiptId = spendResult.receiptId
            }
          )
          local current = MZFurnitureRepository.GetOrgFurnitureTransaction(transaction.id)
          local granted, grantResult = current and grantOrRefund(source, current)
          if granted == true then
            summary.recovered = summary.recovered + 1
          elseif grantResult == 'organization_purchase_refunded' then
            summary.refunded = summary.refunded + 1
          else
            summary.manualReview = summary.manualReview + 1
          end
        elseif ambiguous == true then
          manualReview(transaction, 'org_spend_result_ambiguous', { spendError = spendResult })
          summary.manualReview = summary.manualReview + 1
        else
          MZFurnitureRepository.TransitionOrgFurnitureTransaction(
            transaction.id, 'failed', { 'payment_pending', 'manual_review' }, {
              reason = spendResult or 'org_furniture_spend_failed'
            }
          )
        end
      end
    end
  end
  return true, summary
end

function MZFurnitureOrganizationPurchase.CreateQuote(source, rawOrgCode, catalogIdentifier)
  source = tonumber(source)
  if not source or source <= 0 or not GetPlayerName(source) then return false, 'player_not_loaded' end
  local ready, readyErr = MZFurnitureOrganizationPurchase.IsReady()
  if not ready then return false, readyErr end
  if not MZFurnitureCatalog.IsReady() then return false, 'furniture_not_ready' end
  local actorCitizenid, identityErr = identity(source)
  if not actorCitizenid then return false, identityErr end
  MZFurnitureOrganizationPurchase.Reconcile(source, actorCitizenid)
  local context, contextErr = MZFurnitureOrganization.ResolvePurchaseContext(source, rawOrgCode)
  if not context then return false, contextErr end
  local item = MZFurnitureRepository.GetCatalogItem(catalogIdentifier)
  if not item or item.enabled ~= true or item.visible ~= true or item.archived == true then
    return false, 'item_unavailable'
  end
  local quoteToken = token(source)
  local ttl = math.max(10, math.min(120,
    math.floor(tonumber(MZFurnitureConfig.QuoteTtlSeconds) or 45)))
  Quotes[source] = {
    token = quoteToken,
    source = source,
    actorCitizenid = actorCitizenid,
    orgCode = context.orgCode,
    catalogId = item.id,
    catalogRevision = item.revision,
    price = item.price,
    createdAt = os.time(),
    expiresAt = os.time() + ttl,
    used = false
  }
  return true, {
    token = quoteToken,
    organization = { code = context.orgCode, name = context.orgName },
    label = item.label,
    category = item.category,
    price = item.price,
    expiresIn = ttl
  }
end

function MZFurnitureOrganizationPurchase.Purchase(source, quoteToken)
  source = tonumber(source)
  quoteToken = MZFurnitureLogic.NormalizePurchaseToken(quoteToken)
  if not source or source <= 0 or not GetPlayerName(source) then return false, 'player_not_loaded' end
  if not quoteToken then return false, 'invalid_quote' end
  local ready, readyErr = MZFurnitureOrganizationPurchase.IsReady()
  if not ready then return false, readyErr end
  local lockKey = tostring(source)
  if Locks[lockKey] then return false, 'organization_purchase_in_progress' end
  Locks[lockKey] = true

  local callOk, success, result = xpcall(function()
    local actorCitizenid, identityErr = identity(source)
    if not actorCitizenid then return false, identityErr end
    local existing = MZFurnitureRepository.GetOrgFurnitureTransactionByRequest(quoteToken)
    if existing then
      if existing.actorCitizenid ~= actorCitizenid then return false, 'quote_owner_mismatch' end
      return transactionReplay(existing)
    end
    local quote = Quotes[source]
    if type(quote) ~= 'table' or quote.token ~= quoteToken or quote.source ~= source then
      return false, 'invalid_quote'
    end
    if quote.used == true then return false, 'quote_used' end
    if quote.actorCitizenid ~= actorCitizenid then return false, 'quote_owner_mismatch' end
    if quote.expiresAt < os.time() then return false, 'quote_expired' end
    local context, contextErr = MZFurnitureOrganization.ResolvePurchaseContext(source, quote.orgCode)
    if not context then return false, contextErr end
    local item = MZFurnitureRepository.GetCatalogItem(quote.catalogId)
    if not item or item.enabled ~= true or item.visible ~= true or item.archived == true then
      return false, 'item_unavailable'
    end
    if tonumber(item.revision) ~= tonumber(quote.catalogRevision)
      or tonumber(item.price) ~= tonumber(quote.price) then return false, 'quote_changed' end
    quote.used = true

    local transactionId, createErr = MZFurnitureRepository.CreateOrgFurnitureTransaction({
      requestId = quoteToken,
      orgCode = context.orgCode,
      actorCitizenid = actorCitizenid,
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
    local transaction = MZFurnitureRepository.GetOrgFurnitureTransaction(transactionId)
    if createErr == 'already_exists' then return transactionReplay(transaction) end
    local pending = MZFurnitureRepository.TransitionOrgFurnitureTransaction(
      transactionId, 'payment_pending', { 'initiated' }, { reason = 'org_spend_started' }
    )
    if not pending then return false, 'organization_transaction_state_failed' end
    transaction = MZFurnitureRepository.GetOrgFurnitureTransaction(transactionId)

    local spent, spendResult, ambiguous = spend(source, transaction)
    if spent ~= true then
      if ambiguous == true then
        return manualReview(transaction, 'org_spend_result_ambiguous', {
          spendError = spendResult
        })
      end
      MZFurnitureRepository.TransitionOrgFurnitureTransaction(
        transactionId, 'failed', { 'payment_pending' }, {
          reason = spendResult or 'org_furniture_spend_failed'
        }
      )
      return false, spendResult or 'org_furniture_spend_failed'
    end

    local marked = MZFurnitureRepository.TransitionOrgFurnitureTransaction(
      transactionId, 'money_removed', { 'payment_pending' }, {
        reason = 'org_spend_confirmed', spendReceiptId = spendResult.receiptId
      }
    )
    transaction = MZFurnitureRepository.GetOrgFurnitureTransaction(transactionId)
    if transaction and not transaction.spendReceiptId then
      transaction.spendReceiptId = spendResult.receiptId
    end
    if not marked and transaction and transaction.state ~= 'money_removed'
      and transaction.state ~= 'committed' then
      return refund(source, transaction, 'organization_transaction_state_failed')
    end
    if transaction and transaction.state == 'committed' then return transactionReplay(transaction) end
    return grantOrRefund(source, transaction)
  end, function(err)
    return type(debug) == 'table' and debug.traceback and debug.traceback(tostring(err), 2)
      or tostring(err)
  end)

  Locks[lockKey] = nil
  if not callOk then
    print(('[mz_furniture][organization_purchase] exception source=%s error=%s'):format(
      tostring(source), tostring(success)
    ))
    local transaction = MZFurnitureRepository.GetOrgFurnitureTransactionByRequest(quoteToken)
    if transaction and transaction.state == 'money_removed' then
      return refund(source, transaction, 'organization_purchase_unexpected_error')
    end
    if transaction and transaction.state == 'payment_pending' then
      return manualReview(transaction, 'unexpected_error_during_org_spend', {
        traceback = tostring(success)
      })
    end
    return false, 'organization_purchase_failed'
  end
  return success, result
end

AddEventHandler('playerDropped', function()
  Quotes[source] = nil
  Locks[tostring(source)] = nil
end)
