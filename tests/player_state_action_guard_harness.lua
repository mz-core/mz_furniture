local function expect(condition, message)
  if not condition then error('[player_state_action_guard_harness] ' .. message, 2) end
end

local callbacks = {}
local droppedHandler
lib = { callback = { register = function(name, handler) callbacks[name] = handler end } }
AddEventHandler = function(name, handler)
  if name == 'playerDropped' then droppedHandler = handler end
end

local currentState = 'alive'
local unavailable = false
exports = {
  mz_core = {
    CanPlayerPerformAction = function(_, _, action)
      if unavailable then error('state unavailable') end
      return currentState == 'alive', { allowed = currentState == 'alive', action = action }
    end
  }
}

MZFurniturePurchase = {
  Open = function() return false, 'alive_reached_service' end,
  CreateQuote = function() return false, 'alive_reached_service' end,
  Purchase = function() return false, 'alive_reached_service' end
}
MZFurnitureOrganization = { ListContexts = function() return {} end, Open = function() return false, 'alive_reached_service' end }
MZFurnitureOrganizationPurchase = {
  CreateQuote = function() return false, 'alive_reached_service' end,
  Purchase = function() return false, 'alive_reached_service' end
}
MZFurnitureResale = { CreateQuote = function() return false, 'alive_reached_service' end, Sell = function() return false, 'alive_reached_service' end }
MZFurniturePlacement = {
  Snapshot = function() return false, 'alive_reached_service' end,
  Begin = function() return false, 'alive_reached_service' end,
  Submit = function() return false, 'alive_reached_service' end,
  Store = function() return false, 'alive_reached_service' end
}
MZFurnitureConfig = { PurchaseRateLimitSeconds = 2, PlacementRateLimitSeconds = 1 }

dofile('server/player.lua')

local open = assert(callbacks['mz_furniture:server:open'])
local placement = assert(callbacks['mz_furniture:server:beginPlacement'])
local sourceId = 100
for _, state in ipairs({ 'alive', 'downed', 'dead', 'respawning', 'alive' }) do
  currentState = state
  sourceId = sourceId + 1
  local shopResult = open(sourceId)
  local placementResult = placement(sourceId, 'place', 1)
  local expected = state == 'alive' and 'alive_reached_service' or 'player_state_blocked'
  expect(shopResult.error == expected, state .. ' shop retornou ' .. tostring(shopResult.error))
  expect(placementResult.error == expected, state .. ' placement retornou ' .. tostring(placementResult.error))
end

unavailable = true
expect(open(201).error == 'player_state_blocked', 'shop nao falhou fechado')
expect(placement(202, 'place', 1).error == 'player_state_blocked', 'placement nao falhou fechado')
expect(type(droppedHandler) == 'function', 'cleanup playerDropped removido')

print('[player_state_action_guard_harness] PASS cases=12 cleanup_preserved=1')
