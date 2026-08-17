MZFurnitureConfig = nil
MZFurnitureLogic = nil

dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local item = {
  id = 91,
  catalogId = 7,
  catalogCode = 'chair_test',
  label = 'Cadeira',
  modelHash = 123456,
  modelName = 'prop_chair_01a',
  footprintRadius = 0.5,
  maxPerProperty = 4,
  collisionEnabled = true,
  status = 'warehouse',
  currentPropertyId = nil,
  revision = 1
}
local placement
local contextAllowed = true
local boundsAllowed = true
local syncEvents = {}

MZFurnitureRepository = {
  GetOwnedItem = function(citizenid, id)
    if citizenid ~= 'citizen:test' or tonumber(id) ~= item.id then return nil end
    local copy = {}
    for key, value in pairs(item) do copy[key] = value end
    return copy
  end,
  CountPropertyPlacements = function(_, catalogId)
    return placement and (not catalogId or catalogId == item.catalogId) and 1 or 0
  end,
  GetPlacementByOwned = function(id)
    return tonumber(id) == item.id and placement or nil
  end,
  ListPropertyPlacements = function()
    return placement and { placement } or {}
  end,
  PlaceOwnedItem = function(data)
    item.status = 'placed'
    item.currentPropertyId = data.propertyId
    item.revision = item.revision + 1
    placement = {
      id = 301,
      propertyId = data.propertyId,
      ownedFurnitureId = item.id,
      catalogId = item.catalogId,
      catalogCode = item.catalogCode,
      label = item.label,
      modelHash = item.modelHash,
      modelName = item.modelName,
      footprintRadius = item.footprintRadius,
      offset = data.transform.offset,
      rotation = data.transform.rotation,
      collisionEnabled = true,
      visible = true,
      revision = 1,
      ownedRevision = item.revision
    }
    return placement, item
  end,
  MovePlacedItem = function(data)
    if data.placementRevision ~= placement.revision then return nil, 'stale_placement_revision' end
    placement.offset = data.transform.offset
    placement.rotation = data.transform.rotation
    placement.revision = placement.revision + 1
    return placement
  end,
  StorePlacedItem = function(data)
    if data.ownedRevision ~= item.revision
      or data.placementRevision ~= placement.revision then
      return nil, 'stale_placement_revision'
    end
    item.status = 'warehouse'
    item.currentPropertyId = nil
    item.revision = item.revision + 1
    placement = nil
    return item
  end
}

MZFurnitureResidential = {
  Get = function(source)
    if tonumber(source) == 2 then return false, 'property_owner_required' end
    if not contextAllowed then return false, 'property_owner_required' end
    return true, {
      citizenid = 'citizen:test',
      propertyId = 44,
      houseCode = 'house_test',
      shell = 'shell_test',
      bucket = 1044
    }
  end,
  GetViewer = function(source)
    return true, {
      citizenid = tonumber(source) == 2 and 'citizen:visitor' or 'citizen:test',
      propertyId = 44,
      houseCode = 'house_test',
      shell = 'shell_test',
      bucket = 1044,
      canEdit = tonumber(source) == 1
    }
  end,
  ListViewers = function()
    return { 1, 2 }
  end,
  ValidateOffset = function(_, offset)
    if not boundsAllowed then return false, 'outside_furniture_bounds' end
    return true, { propertyId = 44, offset = offset }
  end
}

exports = setmetatable({}, {
  __index = function(_, resource)
    if resource == 'mz_core' then
      return {
        ResolvePlayerIdentity = function()
          return { ok = true, citizenid = 'citizen:test' }
        end,
        CreateDetailedLog = function() return true end
      }
    end
    return {}
  end
})
GetResourceState = function() return 'started' end
GetPlayerName = function() return 'Tester' end
AddEventHandler = function() end
CreateThread = function() end
Wait = function() end
SetTimeout = function(_, callback) callback() end
TriggerClientEvent = function(eventName, target, payload)
  syncEvents[#syncEvents + 1] = {
    eventName = eventName,
    target = target,
    payload = payload
  }
end

MZFurniturePlacement = nil
dofile('mz_furniture/server/placement.lua')

local opened, snapshot = MZFurniturePlacement.Snapshot(1)
expect(opened == true and snapshot.propertyId == 44 and #snapshot.placements == 0,
  'authorized empty property snapshot failed')
local visitorOpened, visitorSnapshot = MZFurniturePlacement.Snapshot(2)
expect(visitorOpened == true and visitorSnapshot.canEdit == false,
  'authorized visitor did not receive a read-only snapshot')
local visitorEdit, visitorEditError = MZFurniturePlacement.Begin(2, 'place', item.id)
expect(visitorEdit == false and visitorEditError == 'property_owner_required',
  'visitor was allowed to start furniture editing')

local began, draft = MZFurniturePlacement.Begin(1, 'place', item.id)
expect(began == true and draft.modelHash == item.modelHash,
  'warehouse item did not create an authorized placement draft')
local submitted, placed = MZFurniturePlacement.Submit(
  1,
  draft.token,
  { x = 1.0, y = 1.0, z = 0.2 },
  { x = 0.0, y = 0.0, z = 90.0 }
)
expect(submitted == true and placed.placement.ownedFurnitureId == item.id,
  'valid placement was not persisted')
expect(item.status == 'placed' and item.currentPropertyId == 44,
  'placed item did not leave the warehouse')
expect(#syncEvents == 2
  and syncEvents[1].eventName == 'mz_furniture:client:upsertPlacement'
  and syncEvents[2].target == 2,
  'placement was not broadcast to every authorized viewer')
local replayed, replayError = MZFurniturePlacement.Submit(
  1,
  draft.token,
  { x = 1.0, y = 1.0, z = 0.2 },
  { x = 0.0, y = 0.0, z = 90.0 }
)
expect(replayed == false and replayError == 'invalid_placement_token',
  'consumed placement token was replayed')

local moveBegan, moveDraft = MZFurniturePlacement.Begin(1, 'move', item.id)
expect(moveBegan == true and moveDraft.placement.revision == 1,
  'placed item did not start from its persisted transform')
local moved = MZFurniturePlacement.Submit(
  1,
  moveDraft.token,
  { x = 2.0, y = 1.0, z = 0.2 },
  { x = 0.0, y = 0.0, z = 180.0 }
)
expect(moved == true and placement.offset.x == 2.0 and placement.revision == 2,
  'move did not apply compare-and-set revision')

local stored = MZFurniturePlacement.Store(1, item.id, item.revision, placement.revision)
expect(stored == true and item.status == 'warehouse' and placement == nil,
  'store did not return the item to the warehouse')
expect(syncEvents[#syncEvents].eventName == 'mz_furniture:client:removePlacement',
  'stored furniture removal was not broadcast')

boundsAllowed = false
local invalidBegan, invalidDraft = MZFurniturePlacement.Begin(1, 'place', item.id)
expect(invalidBegan == true, 'second placement draft was not created')
local invalid, invalidError = MZFurniturePlacement.Submit(
  1,
  invalidDraft.token,
  { x = 50.0, y = 50.0, z = 0.2 },
  { x = 0.0, y = 0.0, z = 0.0 }
)
expect(invalid == false and invalidError == 'outside_furniture_bounds',
  'server bounds rejection was bypassed')

contextAllowed = false
local denied, deniedError = MZFurniturePlacement.Begin(1, 'place', item.id)
expect(denied == false and deniedError == 'property_owner_required',
  'non-owner placement was not denied')

print('[mz_furniture][test] placement flow harness passed')
