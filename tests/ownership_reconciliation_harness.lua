MZFurnitureConfig = nil
MZFurnitureLogic = nil
dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local collected, repairedOrphans, removedPlacements, invalidated = {}, 0, 0, 0

function GetResourceState() return 'started' end
function GetPlayerName(source) return source == 9 and 'Online Player' or nil end
function GetPlayers() return {} end
function TriggerClientEvent() end
function AddEventHandler() end
function SetTimeout(_, callback) callback() end
function CreateThread() end
function Wait() end
exports = {
  mz_core = {
    CreateDetailedLog = function() return true end,
    ResolvePlayerIdentity = function(_, source)
      return { ok = true, citizenid = source == 9 and 'CID-ONLINE' or 'CID-UNKNOWN' }
    end
  }
}

MZFurnitureRepository = {
  ResolvePropertyIdentity = function(code, id)
    return { propertyId = tonumber(id) or 10, houseCode = code or 'house_10', ownerCitizenid = 'CID-NEW' }
  end,
  ListPropertyFurnitureOwners = function()
    return { { ownerCitizenid = 'CID-OLD', itemCount = 2 } }
  end,
  CollectPropertyFurniture = function(propertyId, owner)
    local key = ('%s:%s'):format(propertyId, owner)
    collected[key] = (collected[key] or 0) + 1
    return {
      count = 2,
      items = {
        { ownedFurnitureId = 101, revision = 2 },
        { ownedFurnitureId = 102, revision = 4 }
      }
    }
  end,
  ListOwnershipMismatches = function()
    return {
      { propertyId = 20, houseCode = 'house_20', furnitureOwner = 'CID-OLD-20', itemCount = 2 }
    }
  end,
  ListOrphanPlacedItems = function()
    return { { ownedFurnitureId = 201, ownerCitizenid = 'CID-X', propertyId = 30, revision = 1 } }
  end,
  RepairOrphanPlacedItem = function() repairedOrphans = repairedOrphans + 1 return true end,
  ListDanglingPlacements = function()
    return { { placementId = 301, propertyId = 31, ownedFurnitureId = 202, revision = 1 } }
  end,
  RemoveDanglingPlacement = function() removedPlacements = removedPlacements + 1 return true end,
  GetRecoveryOverview = function()
    return {
      ownershipMismatches = 0,
      orphanPlacedItems = 0,
      danglingPlacements = 0,
      manualReviewTransactions = {},
      manualReviewCount = 0
    }
  end
}

MZFurnitureResidential = {
  InvalidateProperty = function() invalidated = invalidated + 1 return 1 end
}
MZFurniturePurchase = {
  Reconcile = function(_, citizenid)
    return citizenid == 'CID-ONLINE', { recovered = 1, failed = 0, manualReview = 0 }
  end
}
MZFurnitureResale = {
  Reconcile = function(_, citizenid)
    return citizenid == 'CID-ONLINE', { recovered = 0, failed = 1, manualReview = 0 }
  end
}
MZFurnitureCatalog = { IsReady = function() return true end }

MZFurnitureOwnership = nil
dofile('mz_furniture/server/ownership.lua')

local changed, changedResult = MZFurnitureOwnership.HandleOwnershipChange({
  houseCode = 'house_10',
  propertyId = 10,
  previousOwner = 'CID-OLD',
  newOwner = 'CID-NEW',
  reason = 'owner_set'
})
expect(changed == true and changedResult.count == 2, 'owner change did not collect furniture')
expect(collected['10:CID-OLD'] == 1 and invalidated == 1,
  'owner collection must target the previous owner and invalidate runtime')

local purchased, purchasedResult = MZFurnitureOwnership.HandleOwnershipChange({
  houseCode = 'house_11', propertyId = 11,
  previousOwner = nil, newOwner = 'CID-BUYER', reason = 'property_purchase_completed'
})
expect(purchased == true and purchasedResult.count == 2
  and collected['11:CID-OLD'] == 1,
  'purchase of an ownerless property must still clear any stale layout')

local unchanged, unchangedResult = MZFurnitureOwnership.HandleOwnershipChange({
  houseCode = 'house_10', propertyId = 10,
  previousOwner = 'CID-SAME', newOwner = 'CID-SAME'
})
expect(unchanged == true and unchangedResult.count == 0,
  'same-owner update must be idempotent')

local scanOk, scan = MZFurnitureOwnership.ReconcileAll('test_scan')
expect(scanOk == true and scan.collectedItems == 2, 'mismatch scan did not collect furniture')
expect(scan.orphanItems == 1 and repairedOrphans == 1, 'orphan item was not repaired')
expect(scan.danglingPlacements == 1 and removedPlacements == 1,
  'dangling placement was not repaired')

local financeOk, finance = MZFurnitureOwnership.ReconcilePlayerFinances(9)
expect(financeOk == true and finance.citizenid == 'CID-ONLINE',
  'online financial reconciliation failed')
expect(finance.purchase.recovered == 1 and finance.resale.failed == 1,
  'financial reconciliation summaries were lost')

print('[mz_furniture][test] ownership reconciliation harness passed')
