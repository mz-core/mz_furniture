local function read(path)
  local file = assert(io.open(path, 'rb'))
  local content = file:read('*a')
  file:close()
  return content
end

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local menu = read('mz_furniture/client/menu.lua')
local placement = read('mz_furniture/client/placement.lua')
local editor = read('mz_world_editor/client/main.lua')
local editorConfig = read('mz_world_editor/shared/config.lua')
local bounds = read('mz_interiors/shared/furniture_bounds.lua')

expect(menu:find("InputDialog('Buscar no catalogo'", 1, true),
  'catalog search/filter dialog is missing')
expect(menu:find("value = 'price_asc'", 1, true)
  and menu:find("value = 'price_desc'", 1, true),
  'catalog price sorting is incomplete')
expect(menu:find('Voce possui:', 1, true), 'catalog does not show owned quantity')
expect(menu:find("title = 'Decorar casa'", 1, true), 'dedicated decoration mode is missing')
expect(menu:find("title = 'Selecionar olhando'", 1, true), 'visual furniture selection is missing')
expect(menu:find("title = 'Movel mais proximo'", 1, true), 'nearest furniture selection is missing')
expect(not menu:find('modelHash', 1, true) and not menu:find('modelName', 1, true),
  'technical model data leaked into the player menu')
expect(not menu:find("tostring(item.id)", 1, true), 'technical owned ID is displayed to the player')
expect(menu:find("title = 'Vender para a loja'", 1, true),
  'warehouse resale action is missing')
expect(menu:find('valor historico', 1, true),
  'resale confirmation must explain the historical purchase value')
expect(menu:find('placementBlockReason', 1, true)
  and menu:find('placementRetryPending', 1, true),
  'placement denial must expose its real reason and retry transient session races')

local housePanel = read('mz_houses/client/player_panel.lua')
expect(housePanel:find("title = 'Moveis residenciais'", 1, true)
  and housePanel:find("TriggerEvent('mz_furniture:client:openMenu')", 1, true),
  '/house is not integrated with the furniture experience')

expect(placement:find(":StartEntitySelection({", 1, true),
  'decoration mode is not connected to visual selection')
expect(placement:find('tonumber(entity) == selectedEntity', 1, true),
  'visual selection is not restricted to synchronized furniture handles')
expect(placement:find('GetNearestPlacement', 1, true),
  'nearest furniture resolver is missing')
expect(placement:find("refreshPlayerMenuSoon('warehouse')", 1, true)
  and placement:find("refreshPlayerMenuSoon('decorate')", 1, true),
  'placement changes must refresh the active visual menu flow')

expect(editorConfig:find('placementPrecisionMultiplier', 1, true),
  'precision movement configuration is missing')
expect(editorConfig:find('placementRotationStep', 1, true),
  'rotation step configuration is missing')
expect(editor:find('PlaceObjectOnGroundProperly(entity)', 1, true),
  'ground alignment control is missing')
expect(editor:find('session.resetRotation', 1, true), 'rotation reset control is missing')
expect(bounds:find('wallClearance = math.min', 1, true),
  'placement feedback does not expose free boundary distance')

print('[mz_furniture][test] player experience contract harness passed')
