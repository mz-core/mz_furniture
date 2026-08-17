MZFurnitureConfig = nil
MZFurnitureLogic = nil

dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local transform, err = MZFurnitureLogic.NormalizeTransform(
  { x = 1.25, y = -3.5, z = 0.125 },
  { x = 0, y = 0, z = 181.5 }
)
expect(transform ~= nil and err == nil, 'valid relative transform was rejected')
expect(transform.offset.y == -3.5 and transform.rotation.z == 181.5, 'transform values changed unexpectedly')

local outside, outsideError = MZFurnitureLogic.NormalizeTransform(
  { x = MZFurnitureConfig.MaxPlacementOffset + 0.01, y = 0, z = 0 },
  { x = 0, y = 0, z = 0 }
)
expect(outside == nil and outsideError == 'offset_out_of_bounds', 'outside placement must be rejected')

local invalid, invalidError = MZFurnitureLogic.NormalizeTransform(
  { x = 0 / 0, y = 0, z = 0 },
  { x = 0, y = 0, z = 0 }
)
expect(invalid == nil and invalidError == 'invalid_transform_number', 'NaN must be rejected')

print('[mz_furniture][test] placement logic harness passed')

