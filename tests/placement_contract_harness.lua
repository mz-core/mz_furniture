local function read(path)
  local file = assert(io.open(path, 'rb'))
  local content = file:read('*a')
  file:close()
  return content
end

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local server = read('mz_furniture/server/placement.lua')
local repository = read('mz_furniture/server/repository.lua')
local client = read('mz_furniture/client/placement.lua')
local editor = read('mz_world_editor/client/main.lua')
local interiors = read('mz_interiors/client/shells.lua')
local starter = read('mz_starter/cfg/resources.cfg')

expect(server:find('MZFurnitureResidential.ValidateOffset', 1, true),
  'server-side residential bounds validation is missing')
expect(server:find('MZFurnitureLogic.CanApplyRevision', 1, true),
  'owned furniture revision is not checked')
expect(server:find('clearSourceToken(source)', 1, true),
  'placement token is not consumed')
expect(server:find('maxPerProperty', 1, true) and server:find('MaxItemsPerProperty', 1, true),
  'property and catalog limits are not enforced')
expect(server:find('PropertyLocks[draft.propertyId]', 1, true),
  'concurrent placement limit checks are not serialized per property')
expect(repository:find('MySQL.transaction.await', 1, true),
  'place/store persistence must be transactional')
expect(repository:find('removed_at = NULL', 1, true),
  'stored placement cannot be safely reactivated')
expect(repository:find('p.revision = ?', 1, true),
  'placement compare-and-set revision is missing')

expect(client:find(":StartPropPlacement({", 1, true),
  'warehouse is not connected to the visual object editor')
expect(client:find('CaptureCurrentInteriorPoint', 1, true),
  'world position is not converted to a relative transform')
expect(client:find('ResolveCurrentInteriorPoint', 1, true),
  'relative placement cannot be restored in the shell')
expect(editor:find("exports('SetPlacementValidity'", 1, true),
  'generic editor cannot receive live validity')
expect(editor:find('session.valid ~= true', 1, true),
  'generic editor permits confirmation of an invalid preview')
expect(interiors:find("exports('ValidateCurrentFurniturePlacement'", 1, true),
  'client-side bounds preview export is missing')
expect(interiors:find('MZInteriorsFurnitureBounds.ValidatePlacement(\n    CurrentInterior.shellName,', 1, true),
  'client-side validation must use the current shell name')
expect(interiors:find("exports('FindCurrentFurniturePlacementSeed'", 1, true)
  and client:find("exports['mz_interiors']:FindCurrentFurniturePlacementSeed", 1, true),
  'new furniture does not start at a valid interior position')
expect(client:find("exports['mz_menu']:CloseMenu()", 1, true),
  'the furniture menu must close before the visual editor starts')
expect(starter:find('ensure mz_world_editor', 1, true),
  'world editor is not started before furniture')

print('[mz_furniture][test] placement contract harness passed')
