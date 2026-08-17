MZFurnitureConfig = nil
MZFurnitureLogic = nil
MZFurnitureCatalogSeed = nil

dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')
dofile('mz_furniture/shared/catalog_seed.lua')

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local codes = {}
local categories = {}
for index, raw in ipairs(MZFurnitureCatalogSeed) do
  local item, err = MZFurnitureLogic.NormalizeCatalog(raw)
  expect(item ~= nil and err == nil, ('seed item %d is invalid: %s'):format(index, tostring(err)))
  expect(codes[item.code] == nil, 'catalog seed contains a duplicate code: ' .. item.code)
  expect(item.enabled == true and item.visible == true, 'reviewed seed item must be purchasable')
  codes[item.code] = true
  categories[item.category] = true
end

expect(#MZFurnitureCatalogSeed >= 14, 'Phase 6 catalog expansion is incomplete')
for _, category in ipairs({ 'sala', 'cozinha', 'quarto', 'banheiro', 'escritorio', 'decoracao' }) do
  expect(categories[category] == true, 'catalog is missing category: ' .. category)
end

print('[mz_furniture][test] catalog seed harness passed')
