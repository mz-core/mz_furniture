MZFurnitureConfig = nil
MZFurnitureLogic = nil
dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')

local function expect(condition, message) if not condition then error(message, 2) end end

local legacy = assert(MZFurnitureLogic.NormalizeOwner({ ownerCitizenid = 'MZ000123' }))
expect(legacy.type == 'player' and legacy.key == 'mz000123'
  and legacy.citizenid == 'MZ000123', 'legacy player owner did not normalize')

local player = assert(MZFurnitureLogic.NormalizeOwner({
  type = 'player', key = 'mz000123', citizenid = 'MZ000123'
}))
expect(player.type == 'player' and player.key == 'mz000123', 'explicit player owner failed')

local mismatch, mismatchErr = MZFurnitureLogic.NormalizeOwner({
  type = 'player', key = 'mz999999', citizenid = 'MZ000123'
})
expect(mismatch == nil and mismatchErr == 'invalid_player_owner',
  'player owner mismatch was accepted')

local org = assert(MZFurnitureLogic.NormalizeOwner({ type = 'org', key = 'Mafia' }))
expect(org.type == 'org' and org.key == 'mafia' and org.citizenid == nil,
  'organization owner did not normalize')

local mixed, mixedErr = MZFurnitureLogic.NormalizeOwner({
  type = 'org', key = 'mafia', citizenid = 'MZ000123'
})
expect(mixed == nil and mixedErr == 'org_owner_citizenid_forbidden',
  'organization owner accepted citizenid overload')

print('[mz_furniture][test] owner scope logic harness passed')
