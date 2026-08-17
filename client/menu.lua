MZFurniturePlayerMenu = MZFurniturePlayerMenu or {}

local ROOT_ID = 'mz_furniture:player'
local CATALOG_ID = 'mz_furniture:player:catalog'
local WAREHOUSE_ID = 'mz_furniture:player:warehouse'
local WAREHOUSE_DETAIL_ID = 'mz_furniture:player:warehouse_detail'
local DECORATE_ID = 'mz_furniture:player:decorate'
local DETAIL_ID = 'mz_furniture:player:detail'
local PLACEMENT_DETAIL_ID = 'mz_furniture:player:placement'
local ORG_WAREHOUSE_ID = 'mz_furniture:organization:warehouse'
local ORG_CATALOG_ID = 'mz_furniture:organization:catalog'
local ACTION_EVENT = 'mz_furniture:client:menuAction'

local State = {
  catalog = {},
  warehouse = {},
  organizationWarehouses = {},
  purchasesEnabled = false,
  resaleEnabled = false,
  placementEnabled = false,
  placementRetryPending = false,
  placement = { placements = {} },
  filters = { search = '', category = 'all', sort = 'name' }
}

local CATEGORY_LABELS = {
  sala = 'Sala',
  cozinha = 'Cozinha',
  quarto = 'Quarto',
  banheiro = 'Banheiro',
  escritorio = 'Escritorio',
  decoracao = 'Decoracao'
}

local ERROR_MESSAGES = {
  furniture_catalog_disabled = 'A loja de moveis esta temporariamente indisponivel.',
  furniture_not_ready = 'A loja de moveis ainda esta iniciando.',
  furniture_purchases_disabled = 'As compras de moveis estao temporariamente bloqueadas.',
  item_unavailable = 'Este movel nao esta mais disponivel.',
  invalid_quote = 'A cotacao expirou ou e invalida. Tente novamente.',
  quote_expired = 'A cotacao expirou. Confirme a compra novamente.',
  quote_changed = 'O preco ou cadastro mudou. Revise a nova cotacao.',
  quote_used = 'Esta cotacao ja foi utilizada.',
  not_enough_money = 'Saldo bancario insuficiente.',
  purchase_in_progress = 'Ja existe uma compra em andamento.',
  purchase_refunded = 'A compra falhou e o valor foi devolvido.',
  purchase_manual_review = 'A operacao ficou em revisao financeira. Nao tente comprar novamente.',
  furniture_resale_disabled = 'A revenda de moveis esta temporariamente bloqueada.',
  furniture_not_owned = 'Este movel nao pertence mais ao seu personagem.',
  furniture_not_resellable = 'Este movel nao pode ser revendido.',
  resale_requires_warehouse = 'Guarde o movel no deposito antes de vender.',
  invalid_resale_quote = 'A cotacao de revenda e invalida. Tente novamente.',
  resale_quote_expired = 'A cotacao de revenda expirou. Confirme novamente.',
  resale_quote_changed = 'O movel mudou depois da cotacao. Revise novamente.',
  resale_quote_used = 'Esta cotacao de revenda ja foi utilizada.',
  resale_in_progress = 'A revenda deste movel ja esta em andamento.',
  resale_manual_review = 'A revenda ficou em revisao financeira. Nao repita a operacao.',
  resale_credit_failed = 'O banco nao conseguiu creditar a revenda.',
  resale_service_failed = 'A revenda esta indisponivel neste momento.',
  rate_limited = 'Aguarde um instante antes de tentar novamente.',
  core_unavailable = 'O banco esta indisponivel.',
  player_not_loaded = 'Seu personagem ainda nao terminou de carregar.',
  not_inside_property = 'A sessao desta residencia ainda nao foi confirmada.',
  property_owner_required = 'Somente o proprietario atual pode posicionar moveis.',
  property_without_owner = 'Esta residencia ainda nao possui proprietario.',
  furniture_disabled = 'A feature de moveis nao esta habilitada nesta residencia.',
  invalid_decoration_session = 'A sessao interior ficou desatualizada. Saia e entre novamente.',
  invalid_furniture_view_session = 'A entrada na residencia ainda esta sendo confirmada.',
  routing_bucket_mismatch = 'A instancia da casa ficou desatualizada. Saia e entre novamente.',
  furniture_bounds_required = 'O shell desta casa ainda nao possui limites de moveis calibrados.',
  property_shell_required = 'Esta residencia nao possui um shell configurado.',
  organization_warehouse_disabled = 'O deposito organizacional esta desabilitado.',
  organization_owner_schema_not_ready = 'A migracao dos depositos ainda nao foi aprovada.',
  organization_not_found = 'A organizacao nao foi encontrada.',
  organization_membership_required = 'Seu vinculo com esta organizacao nao esta ativo.',
  organization_warehouse_forbidden = 'Seu cargo nao pode consultar este deposito.',
  organization_facility_required = 'A organizacao ainda nao possui uma instalacao ativa.',
  organization_facility_unavailable = 'A instalacao organizacional ainda nao esta liberada.',
  organization_warehouse_service_failed = 'O deposito organizacional esta indisponivel.',
  organization_purchases_disabled = 'As compras coletivas ainda nao estao liberadas.',
  organization_purchase_forbidden = 'Seu cargo nao pode comprar para esta organizacao.',
  org_furniture_spend_contract_unavailable = 'O pagamento coletivo ainda nao esta disponivel.',
  organization_purchase_in_progress = 'Ja existe uma compra coletiva em andamento.',
  organization_purchase_manual_review = 'A compra coletiva exige revisao financeira.',
  organization_purchase_refunded = 'A compra falhou e a conta coletiva foi reembolsada.',
  organization_purchase_failed = 'A compra coletiva nao foi concluida.',
  insufficient_org_funds = 'A conta da organizacao nao possui saldo suficiente.'
}

local function trim(value)
  return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function notify(message, kind)
  kind = kind or 'inform'
  if GetResourceState('mz_notify') == 'started' then
    local notifyType = kind == 'inform' and 'info' or (kind == 'warn' and 'warning' or kind)
    local ok, result = pcall(function()
      return exports['mz_notify']:Notify({
        type = notifyType,
        title = 'Moveis',
        message = tostring(message or ''),
        duration = 4500
      })
    end)
    if ok and result ~= false then return true end
  end
  if GetResourceState('mz_menu') == 'started' then
    return exports['mz_menu']:Notify(message, kind, 4500, { title = 'Moveis' })
  end
  return false
end

local function money(value)
  local text = tostring(math.max(0, math.floor(tonumber(value) or 0)))
  while true do
    local updated, count = text:gsub('^(-?%d+)(%d%d%d)', '%1.%2')
    text = updated
    if count == 0 then break end
  end
  return ('R$ %s'):format(text)
end

local function call(name, ...)
  local result = lib.callback.await('mz_furniture:server:' .. name, false, ...)
  if type(result) ~= 'table' or result.ok ~= true then
    return nil, tostring(result and result.error or 'sem_resposta')
  end
  return result.data or {}
end

local function bind(option, action, args)
  args = type(args) == 'table' and args or {}
  args.action = action
  option.event = ACTION_EVENT
  option.args = args
  return option
end

local function categoryLabel(category)
  category = trim(category):lower()
  return CATEGORY_LABELS[category] or (category ~= '' and category or 'Outros')
end

local function ownedCountForCatalog(catalogId)
  local count = 0
  for _, item in ipairs(State.warehouse) do
    if tonumber(item.catalogId) == tonumber(catalogId) then count = count + 1 end
  end
  return count
end

local function warehouseCount()
  local count = 0
  for _, item in ipairs(State.warehouse) do
    if item.status == 'warehouse' then count = count + 1 end
  end
  return count
end

local function placementBlockReason()
  local errorCode = tostring(State.placement.error or '')
  if errorCode ~= '' then return ERROR_MESSAGES[errorCode] or errorCode end
  if State.placement.propertyId and State.placement.canEdit ~= true then
    return ERROR_MESSAGES.property_owner_required
  end
  if not State.placement.propertyId then
    return ERROR_MESSAGES.not_inside_property
  end
  return 'O posicionamento esta indisponivel neste momento.'
end

local function currentPlacementCount()
  return #(State.placement.placements or {})
end

local function otherPropertyCount()
  local current = {}
  for _, placement in ipairs(State.placement.placements or {}) do
    current[tonumber(placement.ownedFurnitureId)] = true
  end
  local count = 0
  for _, item in ipairs(State.warehouse) do
    if item.status == 'placed' and not current[tonumber(item.id)] then count = count + 1 end
  end
  return count
end

local function findOwnedItem(id)
  id = tonumber(id)
  for _, item in ipairs(State.warehouse) do
    if tonumber(item.id) == id then return item end
  end
  return nil
end

local function findCatalogItem(id)
  id = tonumber(id)
  for _, item in ipairs(State.catalog) do
    if tonumber(item.id) == id then return item end
  end
  return nil
end

local function filteredCatalog()
  local search = trim(State.filters.search):lower()
  local category = trim(State.filters.category):lower()
  local result = {}
  for _, item in ipairs(State.catalog) do
    local matchesCategory = category == '' or category == 'all'
      or trim(item.category):lower() == category
    local haystack = (tostring(item.label or '') .. ' ' .. tostring(item.description or '')):lower()
    if matchesCategory and (search == '' or haystack:find(search, 1, true)) then
      result[#result + 1] = item
    end
  end
  table.sort(result, function(left, right)
    if State.filters.sort == 'price_asc' and left.price ~= right.price then
      return (tonumber(left.price) or 0) < (tonumber(right.price) or 0)
    elseif State.filters.sort == 'price_desc' and left.price ~= right.price then
      return (tonumber(left.price) or 0) > (tonumber(right.price) or 0)
    end
    return tostring(left.label or ''):lower() < tostring(right.label or ''):lower()
  end)
  return result
end

local function registerCatalog()
  local filtered = filteredCatalog()
  local options = {
    bind({
      title = 'Buscar e filtrar',
      description = ('Busca: %s | Categoria: %s | Ordem: %s'):format(
        State.filters.search ~= '' and State.filters.search or 'todas',
        State.filters.category == 'all' and 'Todas' or categoryLabel(State.filters.category),
        State.filters.sort == 'price_asc' and 'Menor preco'
          or State.filters.sort == 'price_desc' and 'Maior preco'
          or 'Nome'
      ),
      icon = 'filter'
    }, 'catalogFilters')
  }
  for _, item in ipairs(filtered) do
    local owned = ownedCountForCatalog(item.id)
    options[#options + 1] = bind({
      title = tostring(item.label),
      description = ('%s | %s | Voce possui: %d%s'):format(
        categoryLabel(item.category),
        money(item.price),
        owned,
        item.maxPerProperty and (' | max. %s/casa'):format(item.maxPerProperty) or ''
      ),
      icon = 'couch',
      readOnly = State.purchasesEnabled ~= true
    }, 'catalogDetail', { catalogId = item.id })
  end
  if #filtered == 0 then
    options[#options + 1] = {
      title = 'Nenhum movel encontrado',
      description = 'Altere a busca ou os filtros do catalogo.',
      icon = 'box-open',
      readOnly = true
    }
  end
  exports['mz_menu']:RegisterContext({
    id = CATALOG_ID,
    menu = ROOT_ID,
    title = 'Catalogo de moveis',
    subtitle = ('%d de %d item(ns) | precos do servidor'):format(#filtered, #State.catalog),
    options = options
  })
end

local function registerWarehouse()
  local options = {}
  for _, item in ipairs(State.warehouse) do
    if item.status == 'warehouse' then
      local canPlace = State.placementEnabled and State.placement.propertyId
        and State.placement.canEdit == true
      local option = bind({
        title = tostring(item.label),
        description = ('%s | adquirido por %s'):format(
          categoryLabel(item.category),
          money(item.purchasePrice)
        ),
        icon = 'box',
        arrow = true
      }, 'warehouseDetail', { ownedFurnitureId = item.id })
      if not canPlace then
        option.description = option.description .. ' | ' .. placementBlockReason()
      end
      options[#options + 1] = option
    end
  end
  if #options == 0 then
    options[1] = {
      title = 'Deposito vazio',
      description = 'Compre moveis no catalogo ou guarde um movel da residencia.',
      icon = 'warehouse',
      readOnly = true
    }
  end
  exports['mz_menu']:RegisterContext({
    id = WAREHOUSE_ID,
    menu = ROOT_ID,
    title = 'Meu deposito',
    subtitle = ('%d movel(is) disponivel(is)'):format(warehouseCount()),
    options = options
  })
end

local function showWarehouseDetail(ownedFurnitureId)
  local item = findOwnedItem(ownedFurnitureId)
  if not item or item.status ~= 'warehouse' then
    return notify('O deposito ficou desatualizado. Abra novamente.', 'error')
  end
  local canPlace = State.placementEnabled and State.placement.propertyId
    and State.placement.canEdit == true
  local options = {
    {
      title = 'Item no deposito',
      description = ('%s | valor pago: %s'):format(
        categoryLabel(item.category),
        money(item.purchasePrice)
      ),
      icon = 'box',
      readOnly = true
    }
  }
  if canPlace then
    options[#options + 1] = bind({
      title = 'Posicionar nesta casa',
      description = 'Abrir o editor visual para colocar o movel.',
      icon = 'arrows-up-down-left-right'
    }, 'placeFurniture', { ownedFurnitureId = item.id })
  else
    options[#options + 1] = {
      title = 'Posicionar',
      description = placementBlockReason(),
      icon = 'house',
      readOnly = true
    }
  end
  if State.resaleEnabled then
    options[#options + 1] = bind({
      title = 'Vender para a loja',
      description = 'Receber uma cotacao baseada no valor que voce pagou.',
      icon = 'money-bill-transfer'
    }, 'resaleQuote', { ownedFurnitureId = item.id })
  elseif State.financialReview then
    options[#options + 1] = {
      title = 'Revenda em revisao',
      description = 'Aguarde a conciliacao financeira antes de tentar novamente.',
      icon = 'triangle-exclamation',
      readOnly = true
    }
  end
  exports['mz_menu']:RegisterContext({
    id = WAREHOUSE_DETAIL_ID,
    menu = WAREHOUSE_ID,
    title = tostring(item.label),
    subtitle = 'Gerenciar movel',
    options = options
  })
  exports['mz_menu']:ShowContext(WAREHOUSE_DETAIL_ID)
end

local function registerDecorate()
  local options = {
    bind({
      title = 'Selecionar olhando',
      description = 'Mire em um movel da casa para mover ou guardar.',
      icon = 'crosshairs'
    }, 'visualSelect'),
    bind({
      title = 'Movel mais proximo',
      description = 'Seleciona o movel a ate 4 metros de voce.',
      icon = 'location-crosshairs'
    }, 'nearestFurniture')
  }
  for _, placement in ipairs(State.placement.placements or {}) do
    options[#options + 1] = bind({
      title = tostring(placement.label or 'Movel'),
      description = ('%s | pronto para editar'):format(categoryLabel(
        findOwnedItem(placement.ownedFurnitureId) and findOwnedItem(placement.ownedFurnitureId).category
          or ''
      )),
      icon = 'couch'
    }, 'manageFurniture', { ownedFurnitureId = placement.ownedFurnitureId })
  end
  if currentPlacementCount() == 0 then
    options[#options + 1] = {
      title = 'Casa ainda sem moveis',
      description = 'Escolha um item no deposito para comecar.',
      icon = 'house-circle-xmark',
      readOnly = true
    }
  end
  exports['mz_menu']:RegisterContext({
    id = DECORATE_ID,
    menu = ROOT_ID,
    title = 'Decorar casa',
    subtitle = ('%d movel(is) nesta residencia'):format(currentPlacementCount()),
    options = options
  })
end

local function registerRoot()
  local placementDescription = State.placementEnabled
    and State.placement.propertyId and State.placement.canEdit
      and 'Selecionar, mover e guardar os moveis desta casa.'
    or State.placementEnabled and State.placement.propertyId
      and 'Visualizacao ativa; somente o proprietario pode editar.'
    or State.placementEnabled and placementBlockReason()
    or 'Temporariamente indisponivel.'
  local decorateOption = {
    title = ('Decorar casa (%d)'):format(currentPlacementCount()),
    description = placementDescription,
    icon = 'paint-roller',
    readOnly = not (State.placementEnabled and State.placement.propertyId
      and State.placement.canEdit == true)
  }
  if decorateOption.readOnly ~= true then
    decorateOption.menu = DECORATE_ID
    decorateOption.arrow = true
  end
  local options = {
    {
      title = ('Catalogo (%d)'):format(#State.catalog),
      description = State.financialReview and 'Compras bloqueadas por revisao financeira.'
        or State.purchasesEnabled and 'Comprar por categoria usando saldo bancario.'
        or 'Consulta liberada; compras temporariamente bloqueadas.',
      icon = 'store',
      menu = CATALOG_ID,
      arrow = true
    },
    {
      title = ('Meu deposito (%d)'):format(warehouseCount()),
      description = 'Moveis disponiveis para posicionar ou revender.',
      icon = 'warehouse',
      menu = WAREHOUSE_ID,
      arrow = true
    }
  }
  for _, organization in ipairs(State.organizationWarehouses) do
    local option = {
      title = ('Deposito da %s (%d)'):format(
        tostring(organization.orgName or organization.orgCode or 'organizacao'),
        tonumber(organization.itemCount) or 0
      ),
      description = organization.available == true
        and ('Consulta coletiva somente leitura | %d instalacao(oes) ativa(s)'):format(
          tonumber(organization.facilityCount) or 0
        )
        or (ERROR_MESSAGES[tostring(organization.error or '')]
          or 'O deposito coletivo ainda nao esta disponivel.'),
      icon = 'people-roof',
      readOnly = organization.available ~= true
    }
    if option.readOnly ~= true then
      bind(option, 'organizationWarehouse', { orgCode = organization.orgCode })
      option.arrow = true
    end
    options[#options + 1] = option
  end
  options[#options + 1] = decorateOption
  if otherPropertyCount() > 0 then
    options[#options + 1] = {
      title = ('Em outras residencias (%d)'):format(otherPropertyCount()),
      description = 'Entre na residencia correspondente para editar esses moveis.',
      icon = 'house',
      readOnly = true
    }
  end
  exports['mz_menu']:RegisterContext({
    id = ROOT_ID,
    title = 'Moveis',
    subtitle = 'Loja, depositos e decoracao',
    options = options
  })
end

local function showOrganizationWarehouse(orgCode)
  local data, err = call('openOrganizationWarehouse', orgCode)
  if not data then
    return notify(ERROR_MESSAGES[err] or ('Consulta recusada: ' .. tostring(err)), 'error')
  end
  local organization = type(data.organization) == 'table' and data.organization or {}
  local options = {
    {
      title = 'Somente leitura',
      description = ('%d no deposito | %d colocado(s) | compras e edicao bloqueadas'):format(
        tonumber(data.warehouseCount) or 0,
        tonumber(data.placedCount) or 0
      ),
      icon = 'eye',
      readOnly = true
    }
  }
  if data.purchasesEnabled == true then
    options[#options + 1] = bind({
      title = 'Comprar para a organizacao',
      description = 'Usar a conta coletiva; o item sera enviado para este deposito.',
      icon = 'cart-flatbed',
      arrow = true
    }, 'organizationCatalog', {
      orgCode = organization.code,
      orgName = organization.name
    })
  end
  for _, item in ipairs(type(data.items) == 'table' and data.items or {}) do
    local status = item.status == 'placed' and 'Colocado na instalacao'
      or item.status == 'warehouse' and 'No deposito'
      or 'Indisponivel'
    options[#options + 1] = {
      title = tostring(item.label or 'Movel'),
      description = ('%s | %s | valor historico: %s'):format(
        categoryLabel(item.category),
        status,
        money(item.purchasePrice)
      ),
      icon = item.status == 'placed' and 'couch' or 'box',
      readOnly = true
    }
  end
  if #options == 1 then
    options[#options + 1] = {
      title = 'Deposito coletivo vazio',
      description = 'A compra organizacional ainda nao esta liberada.',
      icon = 'warehouse',
      readOnly = true
    }
  end
  exports['mz_menu']:RegisterContext({
    id = ORG_WAREHOUSE_ID,
    menu = ROOT_ID,
    title = ('Deposito da %s'):format(tostring(organization.name or organization.code or 'organizacao')),
    subtitle = ('Somente leitura | %d instalacao(oes) ativa(s)'):format(
      tonumber(data.facilityCount) or 0
    ),
    options = options
  })
  exports['mz_menu']:ShowContext(ORG_WAREHOUSE_ID)
end

local function showOrganizationCatalog(orgCode, orgName)
  local options = {}
  for _, item in ipairs(State.catalog) do
    options[#options + 1] = bind({
      title = tostring(item.label or 'Movel'),
      description = ('%s | %s'):format(categoryLabel(item.category), money(item.price)),
      icon = 'couch'
    }, 'organizationQuote', { orgCode = orgCode, catalogId = item.id })
  end
  if #options == 0 then
    options[1] = {
      title = 'Catalogo indisponivel',
      description = 'Nenhum movel revisado esta liberado para compra.',
      icon = 'store-slash',
      readOnly = true
    }
  end
  exports['mz_menu']:RegisterContext({
    id = ORG_CATALOG_ID,
    menu = ORG_WAREHOUSE_ID,
    title = ('Comprar para %s'):format(tostring(orgName or orgCode or 'organizacao')),
    subtitle = 'Pagamento pela conta coletiva',
    options = options
  })
  exports['mz_menu']:ShowContext(ORG_CATALOG_ID)
end

local function purchaseForOrganization(orgCode, catalogId)
  local quote, quoteErr = call('createOrganizationQuote', orgCode, catalogId)
  if not quote then
    return notify(ERROR_MESSAGES[quoteErr]
      or ('Cotacao coletiva recusada: ' .. tostring(quoteErr)), 'error')
  end
  local organization = type(quote.organization) == 'table' and quote.organization or {}
  local confirmed = exports['mz_menu']:Confirm(
    'Confirmar compra coletiva',
    ('Comprar **%s** por **%s** usando a conta da **%s**?\n\nO item sera coletivo e a cotacao expira em %d segundos.'):format(
      tostring(quote.label or 'movel'),
      money(quote.price),
      tostring(organization.name or organization.code or 'organizacao'),
      tonumber(quote.expiresIn) or 0
    ),
    { labels = { confirm = 'Comprar', cancel = 'Cancelar' } }
  )
  if not confirmed then return end
  local result, purchaseErr = call('purchaseForOrganization', quote.token)
  if not result then
    return notify(ERROR_MESSAGES[purchaseErr]
      or ('Compra coletiva recusada: ' .. tostring(purchaseErr)), 'error')
  end
  notify(('%s foi enviado ao deposito da organizacao por %s.'):format(
    tostring(result.item and result.item.label or quote.label),
    money(result.amount or quote.price)
  ), 'success')
  SetTimeout(1100, function() showOrganizationWarehouse(organization.code or orgCode) end)
end

local function showPlacementActions(ownedFurnitureId)
  local item = findOwnedItem(ownedFurnitureId)
  if not item then return notify('O deposito ficou desatualizado. Abra novamente.', 'error') end
  exports['mz_menu']:RegisterContext({
    id = PLACEMENT_DETAIL_ID,
    menu = DECORATE_ID,
    title = tostring(item.label),
    subtitle = categoryLabel(item.category),
    options = {
      bind({
        title = 'Mover',
        description = 'Abrir o editor visual na posicao atual.',
        icon = 'arrows-up-down-left-right'
      }, 'moveFurniture', { ownedFurnitureId = item.id }),
      bind({
        title = 'Guardar no deposito',
        description = 'Remove da residencia sem vender ou apagar.',
        icon = 'box'
      }, 'storeFurniture', { ownedFurnitureId = item.id })
    }
  })
  exports['mz_menu']:ShowContext(PLACEMENT_DETAIL_ID)
end

function MZFurniturePlayerMenu.ShowPlacementActions(ownedFurnitureId)
  return showPlacementActions(ownedFurnitureId)
end

local function showCatalogDetail(catalogId)
  local item = findCatalogItem(catalogId)
  if not item then return notify('O catalogo ficou desatualizado. Abra novamente.', 'error') end
  exports['mz_menu']:RegisterContext({
    id = DETAIL_ID,
    menu = CATALOG_ID,
    title = tostring(item.label),
    subtitle = categoryLabel(item.category),
    options = {
      {
        title = money(item.price),
        description = ('%s | Voce possui %d'):format(
          tostring(item.description or ''),
          ownedCountForCatalog(item.id)
        ),
        icon = 'credit-card',
        readOnly = true
      },
      bind({
        title = 'Comprar pelo banco',
        description = 'O servidor confirma o preco antes da cobranca.',
        icon = 'cart-shopping'
      }, 'quote', { catalogId = item.id })
    }
  })
  exports['mz_menu']:ShowContext(DETAIL_ID)
end

local function configureCatalogFilters()
  local categories = { { value = 'all', label = 'Todas' } }
  local known = {}
  for _, item in ipairs(State.catalog) do known[tostring(item.category)] = true end
  for category in pairs(known) do
    categories[#categories + 1] = { value = category, label = categoryLabel(category) }
  end
  table.sort(categories, function(left, right)
    if left.value == 'all' then return true end
    if right.value == 'all' then return false end
    return left.label < right.label
  end)
  local values = exports['mz_menu']:InputDialog('Buscar no catalogo', {
    { type = 'input', label = 'Nome do movel', default = State.filters.search },
    { type = 'select', label = 'Comodo / categoria', default = State.filters.category, options = categories },
    {
      type = 'select', label = 'Ordenar', default = State.filters.sort,
      options = {
        { value = 'name', label = 'Nome' },
        { value = 'price_asc', label = 'Menor preco' },
        { value = 'price_desc', label = 'Maior preco' }
      }
    }
  }, { allowCancel = true, labels = { confirm = 'Aplicar', cancel = 'Cancelar' } })
  if type(values) ~= 'table' then return end
  State.filters.search = trim(values[1])
  State.filters.category = trim(values[2]) ~= '' and trim(values[2]) or 'all'
  State.filters.sort = trim(values[3]) ~= '' and trim(values[3]) or 'name'
  registerCatalog()
  exports['mz_menu']:ShowContext(CATALOG_ID)
end

local function purchase(catalogId)
  local quote, quoteErr = call('createQuote', catalogId)
  if not quote then return notify(ERROR_MESSAGES[quoteErr] or ('Compra recusada: ' .. quoteErr), 'error') end
  local confirmed = exports['mz_menu']:Confirm(
    'Confirmar compra',
    ('Comprar **%s** por **%s** usando o banco?\n\nA cotacao expira em %d segundos.'):format(
      tostring(quote.label), money(quote.price), tonumber(quote.expiresIn) or 0
    ),
    { labels = { confirm = 'Comprar', cancel = 'Cancelar' } }
  )
  if not confirmed then return end
  local result, purchaseErr = call('purchase', quote.token)
  if not result then
    return notify(ERROR_MESSAGES[purchaseErr] or ('Compra recusada: ' .. tostring(purchaseErr)), 'error')
  end
  notify(('%s foi enviado para seu deposito por %s.'):format(
    tostring(result.item and result.item.label or quote.label),
    money(result.amount or quote.price)
  ), 'success')
  SetTimeout(1100, function() MZFurniturePlayerMenu.Refresh(WAREHOUSE_ID) end)
end

local function resale(ownedFurnitureId)
  local quote, quoteErr = call('createResaleQuote', ownedFurnitureId)
  if not quote then
    return notify(ERROR_MESSAGES[quoteErr] or ('Revenda recusada: ' .. quoteErr), 'error')
  end
  local confirmed = exports['mz_menu']:Confirm(
    'Confirmar revenda',
    ('Vender **%s** por **%s**?\n\nA loja paga **%d%%** do valor historico de **%s**. O valor sera creditado no banco.'):format(
      tostring(quote.label),
      money(quote.amount),
      tonumber(quote.resalePercent) or 0,
      money(quote.purchasePrice)
    ),
    { labels = { confirm = 'Vender', cancel = 'Cancelar' } }
  )
  if not confirmed then return end
  local result, resaleErr = call('resale', quote.token)
  if not result then
    return notify(ERROR_MESSAGES[resaleErr] or ('Revenda recusada: ' .. tostring(resaleErr)), 'error')
  end
  notify(('Movel vendido por %s. O valor entrou no banco.'):format(
    money(result.amount or quote.amount)
  ), 'success')
  SetTimeout(1100, function() MZFurniturePlayerMenu.Refresh(WAREHOUSE_ID) end)
end

function MZFurniturePlayerMenu.Refresh(targetContext)
  if GetResourceState('mz_menu') ~= 'started' then return false end
  local contextAliases = {
    root = ROOT_ID,
    catalog = CATALOG_ID,
    warehouse = WAREHOUSE_ID,
    decorate = DECORATE_ID
  }
  targetContext = contextAliases[tostring(targetContext or '')] or targetContext or ROOT_ID
  local data, err = call('open')
  if not data then
    notify(ERROR_MESSAGES[err] or ('Nao foi possivel abrir: ' .. tostring(err)), 'error')
    return false
  end
  State.catalog = type(data.catalog) == 'table' and data.catalog or {}
  State.warehouse = type(data.warehouse) == 'table' and data.warehouse or {}
  State.organizationWarehouses = type(data.organizationWarehouses) == 'table'
    and data.organizationWarehouses or {}
  State.purchasesEnabled = data.purchasesEnabled == true
  State.resaleEnabled = data.resaleEnabled == true
  State.placementEnabled = data.placementEnabled == true
  State.financialReview = data.financialReview == true
  if State.placementEnabled and MZFurniturePlacementClient then
    local refreshed, placementErr = MZFurniturePlacementClient.RefreshSnapshot(true)
    State.placement = MZFurniturePlacementClient.GetSnapshot()
    if refreshed ~= true and placementErr and not State.placement.error then
      State.placement.error = placementErr
    end
    if refreshed == true then
      State.placementRetryPending = false
    elseif State.placementRetryPending ~= true
      and (placementErr == 'rate_limited' or placementErr == 'not_inside_property'
        or placementErr == 'invalid_furniture_view_session') then
      State.placementRetryPending = true
      SetTimeout(1200, function()
        State.placementRetryPending = false
        MZFurniturePlayerMenu.Refresh(targetContext)
      end)
    end
  else
    State.placement = { placements = {} }
  end
  registerCatalog()
  registerWarehouse()
  registerDecorate()
  registerRoot()
  exports['mz_menu']:ShowContext(targetContext)
  return true
end

function MZFurniturePlayerMenu.Open()
  return MZFurniturePlayerMenu.Refresh(ROOT_ID)
end

AddEventHandler(ACTION_EVENT, function(payload)
  local action = type(payload) == 'table' and tostring(payload.action or '') or ''
  if action == 'catalogDetail' then showCatalogDetail(payload.catalogId)
  elseif action == 'catalogFilters' then configureCatalogFilters()
  elseif action == 'quote' then purchase(payload.catalogId)
  elseif action == 'warehouseDetail' then showWarehouseDetail(payload.ownedFurnitureId)
  elseif action == 'resaleQuote' then resale(payload.ownedFurnitureId)
  elseif action == 'organizationWarehouse' then showOrganizationWarehouse(payload.orgCode)
  elseif action == 'organizationCatalog' then
    showOrganizationCatalog(payload.orgCode, payload.orgName)
  elseif action == 'organizationQuote' then
    purchaseForOrganization(payload.orgCode, payload.catalogId)
  elseif action == 'placeFurniture' then
    MZFurniturePlacementClient.Start('place', payload.ownedFurnitureId)
  elseif action == 'manageFurniture' then
    showPlacementActions(payload.ownedFurnitureId)
  elseif action == 'moveFurniture' then
    MZFurniturePlacementClient.Start('move', payload.ownedFurnitureId)
  elseif action == 'storeFurniture' then
    local item = findOwnedItem(payload.ownedFurnitureId)
    if item then MZFurniturePlacementClient.Store(item) end
  elseif action == 'visualSelect' then
    MZFurniturePlacementClient.StartVisualSelection()
  elseif action == 'nearestFurniture' then
    local placement = MZFurniturePlacementClient.GetNearestPlacement(4.0)
    if placement then showPlacementActions(placement.ownedFurnitureId)
    else notify('Nenhum movel da casa esta a menos de 4 metros.', 'error') end
  end
end)

RegisterNetEvent('mz_furniture:client:openMenu', function()
  MZFurniturePlayerMenu.Open()
end)

CreateThread(function()
  local command = tostring(MZFurnitureConfig.PlayerMenuCommand or 'moveis')
  RegisterCommand(command, function() MZFurniturePlayerMenu.Open() end, false)
  for _, alias in ipairs(type(MZFurnitureConfig.PlayerMenuAliases) == 'table'
    and MZFurnitureConfig.PlayerMenuAliases or {}) do
    alias = tostring(alias or '')
    if alias ~= '' and alias ~= command then
      RegisterCommand(alias, function() MZFurniturePlayerMenu.Open() end, false)
    end
  end
end)

exports('OpenFurnitureMenu', function()
  return MZFurniturePlayerMenu.Open()
end)
