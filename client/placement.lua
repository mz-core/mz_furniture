MZFurniturePlacementClient = MZFurniturePlacementClient or {}

local Runtime = {
  houseCode = nil,
  propertyId = nil,
  canEdit = false,
  placements = {},
  revisions = {},
  entities = {},
  active = nil,
  selectionRequest = nil,
  lastError = nil,
  lastSnapshotAttempt = 0,
  generation = 0
}

local ERRORS = {
  furniture_placement_disabled = 'O posicionamento de moveis esta temporariamente bloqueado.',
  not_inside_property = 'Entre na sua residencia para posicionar este movel.',
  property_owner_required = 'Somente o proprietario pode decorar esta residencia.',
  property_without_owner = 'Esta residencia ainda nao possui proprietario.',
  guest_decoration_denied = 'Visitantes nao podem alterar os moveis da residencia.',
  furniture_disabled = 'Esta residencia nao possui decoracao habilitada.',
  invalid_decoration_session = 'A sessao da residencia mudou. Entre novamente.',
  routing_bucket_mismatch = 'A instancia da residencia mudou. Entre novamente.',
  furniture_bounds_required = 'Este interior ainda nao foi calibrado para receber moveis.',
  outside_furniture_bounds = 'O movel ficou fora dos limites do interior.',
  blocked_furniture_zone = 'Esta area precisa permanecer livre.',
  property_furniture_limit = 'Esta residencia atingiu o limite total de moveis.',
  catalog_furniture_limit = 'Esta residencia atingiu o limite desse tipo de movel.',
  furniture_not_in_warehouse = 'Este movel nao esta mais no deposito.',
  furniture_not_in_current_property = 'Este movel nao pertence ao interior atual.',
  stale_owned_furniture_revision = 'O movel foi alterado. Abra o deposito novamente.',
  stale_placement_revision = 'A posicao foi alterada. Tente novamente.',
  placement_token_expired = 'O tempo para posicionar expirou. Inicie novamente.',
  invalid_placement_token = 'A sessao de posicionamento nao e mais valida.',
  placement_in_progress = 'Este movel ja esta sendo alterado.',
  editor_busy = 'O editor visual ja esta sendo usado.',
  leave_vehicle_first = 'Saia do veiculo antes de posicionar o movel.',
  invalid_model = 'O modelo deste movel nao esta disponivel.',
  model_timeout = 'O modelo demorou demais para carregar.',
  placement_service_failed = 'O servico de moveis encontrou um erro. Tente novamente.',
  rate_limited = 'Aguarde um instante antes de tentar novamente.'
}

local function notify(message, kind)
  kind = kind or 'inform'
  if GetResourceState('mz_notify') == 'started' then
    local notifyType = kind == 'inform' and 'info' or (kind == 'warn' and 'warning' or kind)
    local ok, result = pcall(function()
      return exports['mz_notify']:Notify({
        type = notifyType,
        title = 'Moveis residenciais',
        message = tostring(message or ''),
        duration = 4500
      })
    end)
    if ok and result ~= false then return true end
  end
  if GetResourceState('mz_menu') == 'started' then
    return exports['mz_menu']:Notify(message, kind, 4500, { title = 'Moveis residenciais' })
  end
  return false
end

local function call(name, ...)
  local result = lib.callback.await('mz_furniture:server:' .. name, false, ...)
  if type(result) ~= 'table' or result.ok ~= true then
    return nil, tostring(result and result.error or 'sem_resposta')
  end
  return result.data or {}
end

local function currentInterior()
  if GetResourceState('mz_interiors') ~= 'started' then return nil end
  local ok, interior = pcall(function()
    return exports['mz_interiors']:GetCurrentInterior()
  end)
  return ok and type(interior) == 'table' and interior.active == true and interior or nil
end

local function currentHouseCode()
  local interior = currentInterior()
  local metadata = interior and type(interior.metadata) == 'table' and interior.metadata or nil
  local code = metadata and tostring(metadata.houseCode or '') or ''
  return code ~= '' and code or nil
end

local function deleteEntityFor(ownedFurnitureId)
  local entity = Runtime.entities[tonumber(ownedFurnitureId)]
  if entity and DoesEntityExist(entity) then DeleteEntity(entity) end
  Runtime.entities[tonumber(ownedFurnitureId)] = nil
end

local function clearRuntime()
  Runtime.generation = Runtime.generation + 1
  for ownedFurnitureId in pairs(Runtime.entities) do deleteEntityFor(ownedFurnitureId) end
  Runtime.houseCode = nil
  Runtime.propertyId = nil
  Runtime.canEdit = false
  Runtime.placements = {}
  Runtime.revisions = {}
  Runtime.lastError = nil
end

local function requestModel(modelHash)
  modelHash = tonumber(modelHash)
  if not modelHash or not IsModelInCdimage(modelHash) or not IsModelValid(modelHash) then
    return false
  end
  RequestModel(modelHash)
  local timeout = GetGameTimer() + 5000
  while not HasModelLoaded(modelHash) do
    Wait(10)
    if GetGameTimer() > timeout then return false end
  end
  return true
end

local function resolveWorld(offset)
  local ok, coords = pcall(function()
    return exports['mz_interiors']:ResolveCurrentInteriorPoint(offset)
  end)
  return ok and type(coords) == 'table' and coords or nil
end

local function spawnPlacement(placement)
  if type(placement) ~= 'table' or placement.visible == false then return end
  local ownedFurnitureId = tonumber(placement.ownedFurnitureId)
  if not ownedFurnitureId or not requestModel(placement.modelHash) then return end
  local coords = resolveWorld(placement.offset)
  if not coords then return end
  local pedCoords = GetEntityCoords(PlayerPedId())
  local distance = #(pedCoords - vector3(
    tonumber(coords.x) or 0.0,
    tonumber(coords.y) or 0.0,
    tonumber(coords.z) or 0.0
  ))
  if distance > (tonumber(MZFurnitureConfig.RuntimeStreamDistance) or 80.0) then return end
  deleteEntityFor(ownedFurnitureId)
  local object = CreateObjectNoOffset(
    tonumber(placement.modelHash),
    tonumber(coords.x) or 0.0,
    tonumber(coords.y) or 0.0,
    tonumber(coords.z) or 0.0,
    false,
    false,
    false
  )
  if not object or object == 0 or not DoesEntityExist(object) then return end
  local interior = currentInterior()
  local shellHeading = tonumber(interior and interior.shellHeading) or 0.0
  SetEntityAsMissionEntity(object, true, true)
  SetEntityRotation(
    object,
    tonumber(placement.rotation and placement.rotation.x) or 0.0,
    tonumber(placement.rotation and placement.rotation.y) or 0.0,
    (tonumber(placement.rotation and placement.rotation.z) or 0.0) + shellHeading,
    2,
    true
  )
  FreezeEntityPosition(object, true)
  SetEntityCollision(object, placement.collisionEnabled ~= false, true)
  SetEntityLodDist(object, 500)
  Runtime.entities[ownedFurnitureId] = object
  SetModelAsNoLongerNeeded(tonumber(placement.modelHash))
end

local function applySnapshot(snapshot)
  if type(snapshot) ~= 'table' then return false end
  for ownedFurnitureId in pairs(Runtime.entities) do deleteEntityFor(ownedFurnitureId) end
  Runtime.houseCode = tostring(snapshot.houseCode or '')
  Runtime.propertyId = tonumber(snapshot.propertyId)
  Runtime.canEdit = snapshot.canEdit == true
  Runtime.placements = type(snapshot.placements) == 'table' and snapshot.placements or {}
  Runtime.revisions = {}
  Runtime.lastError = nil
  for _, placement in ipairs(Runtime.placements) do
    Runtime.revisions[tonumber(placement.ownedFurnitureId)] = tonumber(placement.revision) or 0
  end
  Runtime.generation = Runtime.generation + 1
  local generation = Runtime.generation
  CreateThread(function()
    for index, placement in ipairs(Runtime.placements) do
      if Runtime.generation ~= generation then return end
      spawnPlacement(placement)
      if index % 5 == 0 then Wait(0) end
    end
  end)
  return true
end

function MZFurniturePlacementClient.RefreshSnapshot(silent)
  if Runtime.active then return false, 'placement_active' end
  local code = currentHouseCode()
  if not code then
    clearRuntime()
    Runtime.lastError = 'not_inside_property'
    return false, 'not_inside_property'
  end
  Runtime.lastSnapshotAttempt = GetGameTimer()
  local snapshot, err = call('placementSnapshot')
  if not snapshot then
    Runtime.lastError = err
    if silent ~= true and err ~= 'rate_limited' then
      notify(ERRORS[err] or ('Nao foi possivel carregar os moveis: ' .. tostring(err)), 'error')
    end
    return false, err
  end
  applySnapshot(snapshot)
  Runtime.lastError = nil
  return true, snapshot
end

function MZFurniturePlacementClient.GetSnapshot()
  return {
    houseCode = Runtime.houseCode,
    propertyId = Runtime.propertyId,
    canEdit = Runtime.canEdit,
    placements = Runtime.placements,
    error = Runtime.lastError
  }
end

function MZFurniturePlacementClient.GetNearestPlacement(maxDistance)
  maxDistance = tonumber(maxDistance) or 4.0
  local pedCoords = GetEntityCoords(PlayerPedId())
  local nearest, nearestDistance
  for _, placement in ipairs(Runtime.placements) do
    local coords
    local entity = Runtime.entities[tonumber(placement.ownedFurnitureId)]
    if entity and DoesEntityExist(entity) then
      coords = GetEntityCoords(entity)
    else
      local resolved = resolveWorld(placement.offset)
      if resolved then coords = vector3(resolved.x, resolved.y, resolved.z) end
    end
    if coords then
      local distance = #(pedCoords - coords)
      if distance <= maxDistance and (not nearestDistance or distance < nearestDistance) then
        nearest, nearestDistance = placement, distance
      end
    end
  end
  return nearest, nearestDistance
end

function MZFurniturePlacementClient.StartVisualSelection()
  if Runtime.canEdit ~= true or not Runtime.propertyId then
    return notify('Somente o proprietario pode selecionar moveis para editar.', 'error')
  end
  if Runtime.active or Runtime.selectionRequest then
    return notify(ERRORS.editor_busy, 'error')
  end
  local requestId = ('fselect_%d_%d'):format(GetGameTimer(), math.random(100000, 999999))
  Runtime.selectionRequest = requestId
  if GetResourceState('mz_menu') == 'started' then
    pcall(function() exports['mz_menu']:CloseMenu() end)
  end
  local started, err = exports['mz_world_editor']:StartEntitySelection({
    requestId = requestId,
    objectsOnly = true,
    title = 'Mire no movel que deseja editar',
    requiredCount = 1
  })
  if started ~= true then
    Runtime.selectionRequest = nil
    return notify(ERRORS[err] or ('Seletor indisponivel: ' .. tostring(err)), 'error')
  end
  notify('Mire em um movel da casa e pressione E. Backspace cancela.', 'inform')
  return true
end

local function refreshSoon()
  local refreshed, err = MZFurniturePlacementClient.RefreshSnapshot(true)
  if refreshed ~= true and err == 'rate_limited' then
    SetTimeout(1100, function()
      if not Runtime.active then MZFurniturePlacementClient.RefreshSnapshot(true) end
    end)
  end
end

local function refreshPlayerMenuSoon(context)
  SetTimeout(1150, function()
    if MZFurniturePlayerMenu and type(MZFurniturePlayerMenu.Refresh) == 'function'
      and not Runtime.active then
      MZFurniturePlayerMenu.Refresh(context)
    end
  end)
end

local function initialTransform(draft)
  local placement = type(draft.placement) == 'table' and draft.placement or nil
  if not placement then
    local seedOk, seed = pcall(function()
      return exports['mz_interiors']:FindCurrentFurniturePlacementSeed(
        tonumber(draft.footprintRadius) or 1.0
      )
    end)
    return seedOk and type(seed) == 'table' and seed or nil, nil
  end
  local coords = resolveWorld(placement.offset)
  local interior = currentInterior()
  local shellHeading = tonumber(interior and interior.shellHeading) or 0.0
  local rotation = {
    x = tonumber(placement.rotation and placement.rotation.x) or 0.0,
    y = tonumber(placement.rotation and placement.rotation.y) or 0.0,
    z = (tonumber(placement.rotation and placement.rotation.z) or 0.0) + shellHeading
  }
  return coords, rotation
end

function MZFurniturePlacementClient.Start(action, ownedFurnitureId)
  action = tostring(action or ''):lower()
  ownedFurnitureId = tonumber(ownedFurnitureId)
  if Runtime.active then return notify(ERRORS.placement_in_progress, 'error') end
  if GetResourceState('mz_world_editor') ~= 'started' then
    return notify('O editor visual de objetos esta indisponivel.', 'error')
  end
  local draft, err = call('beginPlacement', action, ownedFurnitureId)
  if not draft then return notify(ERRORS[err] or ('Posicionamento recusado: ' .. err), 'error') end
  local initialCoords, initialRotation = initialTransform(draft)
  local interior = currentInterior()
  local shellHeading = tonumber(interior and interior.shellHeading) or 0.0
  if action == 'move' then deleteEntityFor(ownedFurnitureId) end
  Runtime.active = {
    requestId = draft.token,
    token = draft.token,
    action = action,
    ownedFurnitureId = ownedFurnitureId,
    houseCode = currentHouseCode(),
    footprintRadius = tonumber(draft.footprintRadius) or 1.0,
    lastValidation = 0
  }
  if GetResourceState('mz_menu') == 'started' then
    pcall(function() exports['mz_menu']:CloseMenu() end)
  end
  local started, startErr = exports['mz_world_editor']:StartPropPlacement({
    requestId = draft.token,
    title = action == 'move'
      and ('Mover: %s'):format(tostring(draft.label))
      or ('Posicionar: %s'):format(tostring(draft.label)),
    modelHash = draft.modelHash,
    modelName = draft.modelName,
    initialCoords = initialCoords,
    initialRotation = initialRotation,
    resetRotation = { x = 0.0, y = 0.0, z = shellHeading },
    validationRequired = true
  })
  if started ~= true then
    Runtime.active = nil
    refreshSoon()
    return notify(ERRORS[startErr] or ('Editor recusou o objeto: ' .. tostring(startErr)), 'error')
  end
  return true
end

function MZFurniturePlacementClient.Store(item)
  item = type(item) == 'table' and item or {}
  local ownedFurnitureId = tonumber(item.id or item.ownedFurnitureId)
  local placement
  for _, row in ipairs(Runtime.placements) do
    if tonumber(row.ownedFurnitureId) == ownedFurnitureId then placement = row break end
  end
  if not placement then return notify(ERRORS.furniture_not_in_current_property, 'error') end
  local confirmed = exports['mz_menu']:Confirm(
    'Guardar movel',
    ('Guardar **%s** novamente no deposito?'):format(tostring(item.label or placement.label)),
    { labels = { confirm = 'Guardar', cancel = 'Cancelar' } }
  )
  if not confirmed then return false end
  local result, err = call(
    'storeFurniture',
    ownedFurnitureId,
    item.revision or placement.ownedRevision,
    placement.revision
  )
  if not result then return notify(ERRORS[err] or ('Nao foi possivel guardar: ' .. err), 'error') end
  notify(('%s voltou para o deposito.'):format(tostring(item.label or placement.label)), 'success')
  deleteEntityFor(ownedFurnitureId)
  refreshSoon()
  refreshPlayerMenuSoon('warehouse')
  return true
end

AddEventHandler('mz_world_editor:client:placementUpdated', function(requestId, result)
  local active = Runtime.active
  if not active or active.requestId ~= tostring(requestId or '') or type(result) ~= 'table' then return end
  local now = GetGameTimer()
  if now - active.lastValidation < 100 then return end
  active.lastValidation = now
  local ok, valid, detail = pcall(function()
    return exports['mz_interiors']:ValidateCurrentFurniturePlacement(
      result.coords,
      active.footprintRadius
    )
  end)
  local accepted = ok and valid == true
  local reason = accepted and nil or (ok and detail or 'interiors_validation_failed')
  exports['mz_world_editor']:SetPlacementValidity(
    requestId,
    accepted,
    accepted and nil or (ERRORS[reason] or reason),
    accepted and detail or nil
  )
end)

AddEventHandler('mz_world_editor:client:selectionResult', function(requestId, result)
  if Runtime.selectionRequest ~= tostring(requestId or '') then return end
  Runtime.selectionRequest = nil
  local selectedEntity = tonumber(result and result.entity)
  local selectedOwnedId
  for ownedFurnitureId, entity in pairs(Runtime.entities) do
    if tonumber(entity) == selectedEntity then
      selectedOwnedId = tonumber(ownedFurnitureId)
      break
    end
  end
  if not selectedOwnedId then
    return notify('O objeto selecionado nao e um movel desta residencia.', 'error')
  end
  if MZFurniturePlayerMenu and MZFurniturePlayerMenu.ShowPlacementActions then
    MZFurniturePlayerMenu.ShowPlacementActions(selectedOwnedId)
  end
end)

AddEventHandler('mz_world_editor:client:selectionCancelled', function(requestId)
  if Runtime.selectionRequest ~= tostring(requestId or '') then return end
  Runtime.selectionRequest = nil
  notify('Selecao visual cancelada.', 'inform')
end)

RegisterNetEvent('mz_furniture:client:propertySnapshot', function(snapshot)
  if Runtime.active or type(snapshot) ~= 'table' then return end
  if currentHouseCode() ~= tostring(snapshot.houseCode or '') then return end
  applySnapshot(snapshot)
end)

RegisterNetEvent('mz_furniture:client:upsertPlacement', function(payload)
  payload = type(payload) == 'table' and payload or {}
  local placement = type(payload.placement) == 'table' and payload.placement or nil
  if not placement or currentHouseCode() ~= tostring(payload.houseCode or '') then return end
  if tonumber(Runtime.propertyId) ~= tonumber(payload.propertyId) then
    refreshSoon()
    return
  end
  local ownedFurnitureId = tonumber(placement.ownedFurnitureId)
  if not ownedFurnitureId then return end
  local incomingRevision = tonumber(placement.revision) or 0
  if (Runtime.revisions[ownedFurnitureId] or 0) >= incomingRevision then return end
  local found = false
  for index, current in ipairs(Runtime.placements) do
    if tonumber(current.ownedFurnitureId) == ownedFurnitureId then
      Runtime.placements[index] = placement
      found = true
      break
    end
  end
  if not found then Runtime.placements[#Runtime.placements + 1] = placement end
  Runtime.revisions[ownedFurnitureId] = incomingRevision
  if not Runtime.active or Runtime.active.ownedFurnitureId ~= ownedFurnitureId then
    spawnPlacement(placement)
  end
end)

RegisterNetEvent('mz_furniture:client:removePlacement', function(payload)
  payload = type(payload) == 'table' and payload or {}
  if currentHouseCode() ~= tostring(payload.houseCode or '')
    or tonumber(Runtime.propertyId) ~= tonumber(payload.propertyId) then
    return
  end
  local ownedFurnitureId = tonumber(payload.ownedFurnitureId)
  if not ownedFurnitureId then return end
  local incomingRevision = tonumber(payload.revision) or 0
  if (Runtime.revisions[ownedFurnitureId] or 0) >= incomingRevision then return end
  for index = #Runtime.placements, 1, -1 do
    if tonumber(Runtime.placements[index].ownedFurnitureId) == ownedFurnitureId then
      table.remove(Runtime.placements, index)
    end
  end
  Runtime.revisions[ownedFurnitureId] = incomingRevision
  deleteEntityFor(ownedFurnitureId)
end)

RegisterNetEvent('mz_furniture:client:clearProperty', function()
  if (Runtime.active or Runtime.selectionRequest) and GetResourceState('mz_world_editor') == 'started' then
    pcall(function() exports['mz_world_editor']:CancelActiveSession('property_session_ended') end)
  end
  clearRuntime()
end)

RegisterNetEvent('mz_furniture:client:ownershipReconciled', function(payload)
  payload = type(payload) == 'table' and payload or {}
  local count = math.max(0, math.floor(tonumber(payload.count) or 0))
  notify(('%d movel(is) foram recolhidos para seu deposito apos a alteracao do imovel.'):format(
    count
  ), 'inform')
end)

AddEventHandler('mz_world_editor:client:placementResult', function(requestId, result)
  local active = Runtime.active
  if not active or active.requestId ~= tostring(requestId or '') then return end
  Runtime.active = nil
  local offsetOk, offset = pcall(function()
    return exports['mz_interiors']:CaptureCurrentInteriorPoint(result.coords)
  end)
  if not offsetOk or type(offset) ~= 'table' then
    notify('Nao foi possivel converter a posicao dentro do interior.', 'error')
    refreshSoon()
    return
  end
  local interior = currentInterior()
  local shellHeading = tonumber(interior and interior.shellHeading) or 0.0
  local rotation = {
    x = tonumber(result.rotation and result.rotation.x) or 0.0,
    y = tonumber(result.rotation and result.rotation.y) or 0.0,
    z = (tonumber(result.rotation and result.rotation.z) or 0.0) - shellHeading
  }
  local persisted, err = call('submitPlacement', active.token, offset, rotation)
  if not persisted then
    notify(ERRORS[err] or ('Posicao recusada: ' .. tostring(err)), 'error')
    refreshSoon()
    return
  end
  notify(
    active.action == 'move' and 'Posicao do movel atualizada.'
      or 'Movel posicionado na residencia.',
    'success'
  )
  refreshSoon()
  refreshPlayerMenuSoon('decorate')
end)

AddEventHandler('mz_world_editor:client:placementCancelled', function(requestId)
  local active = Runtime.active
  if not active or active.requestId ~= tostring(requestId or '') then return end
  Runtime.active = nil
  notify('Posicionamento cancelado. Nenhuma alteracao foi salva.', 'inform')
  refreshSoon()
end)

CreateThread(function()
  while true do
    Wait(1000)
    local code = currentHouseCode()
    if Runtime.active then
      if not code or code ~= Runtime.active.houseCode then
        pcall(function()
          exports['mz_world_editor']:CancelActiveSession('property_context_changed')
        end)
      end
    else
      if not code then
        if Runtime.houseCode then clearRuntime() end
      elseif Runtime.houseCode ~= code
        and GetGameTimer() - Runtime.lastSnapshotAttempt >= 1800 then
        MZFurniturePlacementClient.RefreshSnapshot(true)
      end
    end
  end
end)

CreateThread(function()
  while true do
    Wait(750)
    if Runtime.propertyId and not Runtime.active then
      local pedCoords = GetEntityCoords(PlayerPedId())
      local streamDistance = tonumber(MZFurnitureConfig.RuntimeStreamDistance) or 80.0
      local removeDistance = streamDistance
        + (tonumber(MZFurnitureConfig.RuntimeStreamHysteresis) or 10.0)
      for _, placement in ipairs(Runtime.placements) do
        local ownedFurnitureId = tonumber(placement.ownedFurnitureId)
        local coords = resolveWorld(placement.offset)
        if ownedFurnitureId and coords then
          local distance = #(pedCoords - vector3(coords.x, coords.y, coords.z))
          local entity = Runtime.entities[ownedFurnitureId]
          if distance <= streamDistance then
            if not entity or not DoesEntityExist(entity) then spawnPlacement(placement) end
          elseif distance > removeDistance then
            deleteEntityFor(ownedFurnitureId)
          end
        end
      end
    end
  end
end)

AddEventHandler('onResourceStop', function(resource)
  if resource == GetCurrentResourceName() then
    if GetResourceState('mz_world_editor') == 'started' then
      pcall(function() exports['mz_world_editor']:CancelActiveSession('furniture_stopped') end)
    end
    clearRuntime()
  elseif resource == 'mz_interiors' or resource == 'mz_houses' then
    if GetResourceState('mz_world_editor') == 'started' then
      pcall(function() exports['mz_world_editor']:CancelActiveSession('residential_resource_stopped') end)
    end
    Runtime.active = nil
    Runtime.selectionRequest = nil
    clearRuntime()
  end
end)
