MZFurnitureMoney = MZFurnitureMoney or {}

local function metadata(action, requestId, catalogId, transactionId)
  local refund = action == 'furniture_purchase_refund'
  local resale = action == 'furniture_resale'
  return {
    reason = action,
    category = refund and 'refund' or resale and 'furniture_resale' or 'housing_furniture',
    source_resource = 'mz_furniture',
    source_type = 'furniture_store',
    -- Revenda recupera parte de um gasto anterior; nao e renda produtiva.
    counts_as_income = false,
    counts_as_expense = not refund and not resale,
    external_ref = requestId,
    idempotency_key = refund and (requestId .. '_refund')
      or resale and (requestId .. '_resale')
      or requestId,
    data = {
      action = action,
      payment_method = 'bank',
      catalog_id = tonumber(catalogId),
      furniture_transaction_id = tonumber(transactionId),
      request_id = requestId
    }
  }
end

local function operationResult(source, key, operation)
  if GetResourceState('mz_core') ~= 'started' then return nil, 'core_unavailable' end
  local callOk, result = pcall(function()
    return exports['mz_core']:GetOperationResult(source, key, operation)
  end)
  if not callOk or type(result) ~= 'table' then return nil, 'operation_lookup_failed' end
  if result.ok == true and result.found == true and type(result.result) == 'table'
    and result.result.ok == true then
    return true, {
      recovered = true,
      correlationId = result.correlationId
    }
  end
  if result.error == 'operation_not_found' then return false, 'operation_not_found' end
  return nil, result.error or 'operation_lookup_failed'
end

function MZFurnitureMoney.GetBalance(source)
  if GetResourceState('mz_core') ~= 'started' then return nil, 'core_unavailable' end
  local callOk, money = pcall(function() return exports['mz_core']:GetMoney(source) end)
  if not callOk or type(money) ~= 'table' then return nil, 'money_lookup_failed' end
  return math.max(0, math.floor(tonumber(money.bank) or 0))
end

function MZFurnitureMoney.RecoverDebit(source, requestId)
  return operationResult(source, requestId, 'remove_money')
end

function MZFurnitureMoney.RecoverRefund(source, requestId)
  return operationResult(source, requestId .. '_refund', 'add_money')
end

function MZFurnitureMoney.RecoverResale(source, requestId)
  return operationResult(source, requestId .. '_resale', 'add_money')
end

function MZFurnitureMoney.Debit(source, amount, context)
  amount = math.floor(tonumber(amount) or 0)
  context = type(context) == 'table' and context or {}
  local requestId = MZFurnitureLogic.NormalizePurchaseToken(context.requestId)
  if amount <= 0 or not requestId then return false, 'invalid_payment', false end
  if GetResourceState('mz_core') ~= 'started' then return false, 'core_unavailable', false end
  local callOk, success, err = pcall(function()
    return exports['mz_core']:RemoveMoney(source, 'bank', amount, metadata(
      'furniture_purchase',
      requestId,
      context.catalogId,
      context.transactionId
    ))
  end)
  if callOk then
    if success == true then return true, { recovered = false } end
    return false, err or 'payment_failed', false
  end
  local recovered, recovery = MZFurnitureMoney.RecoverDebit(source, requestId)
  if recovered == true then return true, recovery end
  if recovered == false then return false, 'payment_export_failed', false end
  return false, recovery or 'debit_result_ambiguous', true
end

function MZFurnitureMoney.Refund(source, amount, context)
  amount = math.floor(tonumber(amount) or 0)
  context = type(context) == 'table' and context or {}
  local requestId = MZFurnitureLogic.NormalizePurchaseToken(context.requestId)
  if amount <= 0 or not requestId then return false, 'invalid_refund', false end
  if GetResourceState('mz_core') ~= 'started' then return false, 'core_unavailable', true end
  local callOk, success, err = pcall(function()
    return exports['mz_core']:AddMoney(source, 'bank', amount, metadata(
      'furniture_purchase_refund',
      requestId,
      context.catalogId,
      context.transactionId
    ))
  end)
  if callOk then
    if success == true then return true, { recovered = false } end
    return false, err or 'refund_failed', false
  end
  local recovered, recovery = MZFurnitureMoney.RecoverRefund(source, requestId)
  if recovered == true then return true, recovery end
  if recovered == false then return false, 'refund_export_failed', false end
  return false, recovery or 'refund_result_ambiguous', true
end

function MZFurnitureMoney.CreditResale(source, amount, context)
  amount = math.floor(tonumber(amount) or 0)
  context = type(context) == 'table' and context or {}
  local requestId = MZFurnitureLogic.NormalizePurchaseToken(context.requestId)
  if amount <= 0 or not requestId then return false, 'invalid_resale_credit', false end
  if GetResourceState('mz_core') ~= 'started' then return false, 'core_unavailable', true end
  local callOk, success, err = pcall(function()
    return exports['mz_core']:AddMoney(source, 'bank', amount, metadata(
      'furniture_resale',
      requestId,
      context.catalogId,
      context.transactionId
    ))
  end)
  if callOk then
    if success == true then return true, { recovered = false } end
    return false, err or 'resale_credit_failed', false
  end
  local recovered, recovery = MZFurnitureMoney.RecoverResale(source, requestId)
  if recovered == true then return true, recovery end
  if recovered == false then return false, 'resale_credit_export_failed', false end
  return false, recovery or 'resale_credit_result_ambiguous', true
end
