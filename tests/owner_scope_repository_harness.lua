MZFurnitureConfig = nil
MZFurnitureLogic = nil
dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')

local function expect(condition, message) if not condition then error(message, 2) end end
local calls = {}
json = { decode = function() return {} end, encode = function() return '{}' end }

local function ownedRow(ownerType, ownerKey, citizenid, id)
  return {
    id = id or 1, owner_type = ownerType, owner_key = ownerKey,
    owner_citizenid = citizenid, catalog_id = 10, catalog_code = 'chair_01',
    category = 'chairs', catalog_label = 'Chair', description = '',
    purchase_price = 100, status = 'warehouse', revision = 1,
    metadata_json = '{}'
  }
end

MySQL = {
  query = { await = function(sql, parameters)
    calls[#calls + 1] = { kind = 'query', sql = sql, parameters = parameters }
    if parameters[1] == 'org' then return { ownedRow('org', 'mafia', nil, 2) } end
    return { ownedRow('player', 'mz000123', 'MZ000123', 1) }
  end },
  single = { await = function(sql, parameters)
    calls[#calls + 1] = { kind = 'single', sql = sql, parameters = parameters }
    if parameters[2] == 'org' then return ownedRow('org', 'mafia', nil, parameters[1]) end
    return ownedRow('player', 'mz000123', 'MZ000123', parameters[1])
  end }
}

dofile('mz_furniture/server/repository.lua')

local playerItems = MZFurnitureRepository.ListOwned('MZ000123')
expect(#playerItems == 1 and playerItems[1].ownerType == 'player'
  and playerItems[1].ownerCitizenid == 'MZ000123', 'legacy player list changed')
expect(calls[1].parameters[1] == 'player' and calls[1].parameters[2] == 'mz000123'
  and calls[1].parameters[3] == 'MZ000123', 'player dual-read parameters are incomplete')

local orgItems = MZFurnitureRepository.ListOwnedByOwner({ type = 'org', key = 'mafia' })
expect(#orgItems == 1 and orgItems[1].ownerType == 'org'
  and orgItems[1].ownerKey == 'mafia', 'organization dual-read failed')
expect(#calls[2].parameters == 2 and calls[2].parameters[1] == 'org',
  'organization read leaked a citizenid parameter')

local orgItem = MZFurnitureRepository.GetOwnedItemByOwner({ type = 'org', key = 'mafia' }, 2)
expect(orgItem and orgItem.owner.type == 'org', 'organization item read failed')

print('[mz_furniture][test] owner scope repository harness passed')
