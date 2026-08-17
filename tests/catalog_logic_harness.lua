MZFurnitureConfig = nil
MZFurnitureLogic = nil

dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')

local function expect(condition, message)
  if not condition then error(message, 2) end
end

local valid, err = MZFurnitureLogic.NormalizeCatalog({
  code = ' Sala Sofa 01 ',
  category = 'Sala',
  label = 'Sofa de teste',
  modelName = 'prop_couch_01',
  price = 3500.9,
  resalePercent = 50,
  footprintRadius = 1.5,
  collisionEnabled = false,
  enabled = false
})
expect(valid ~= nil and err == nil, 'valid catalog item was rejected')
expect(valid.code == 'sala_sofa_01', 'catalog code was not normalized')
expect(valid.category == 'sala', 'category was not normalized')
expect(valid.price == 3500, 'price must be stored as an integer')
expect(valid.collisionEnabled == false, 'explicit collision=false was lost')
expect(valid.enabled == false, 'seed item must remain disabled')
expect(valid.modelHash == MZFurnitureLogic.Joaat('prop_couch_01'), 'model hash is not deterministic')

local invalidPrice, invalidPriceError = MZFurnitureLogic.NormalizeCatalog({
  code = 'bad_price',
  category = 'sala',
  label = 'Preco invalido',
  modelName = 'prop_couch_01',
  price = 0,
  footprintRadius = 1
})
expect(invalidPrice == nil and invalidPriceError == 'invalid_price', 'zero price must be rejected')

local invalidRadius, invalidRadiusError = MZFurnitureLogic.NormalizeCatalog({
  code = 'bad_radius',
  category = 'sala',
  label = 'Raio invalido',
  modelName = 'prop_couch_01',
  price = 1,
  footprintRadius = 100
})
expect(invalidRadius == nil and invalidRadiusError == 'invalid_footprint_radius', 'unsafe footprint must be rejected')

expect(MZFurnitureLogic.CalculateResale(3501, 50) == 1751, 'resale rounding is incorrect')
expect(MZFurnitureLogic.CalculateResale(100, 101) == nil, 'resale above 100% must be rejected')

local quote = {
  token = 'furn_test_0000000001',
  citizenid = 'citizen:test',
  catalogId = 7,
  catalogRevision = 3,
  price = 2500,
  expiresAt = 1045,
  used = false
}
local quotedItem = {
  id = 7,
  revision = 3,
  price = 2500,
  enabled = true,
  visible = true,
  archived = false
}
expect(MZFurnitureLogic.QuoteMatches(quote, quotedItem, 'citizen:test', 1000),
  'valid server quote must be accepted')
local ownerOk, ownerErr = MZFurnitureLogic.QuoteMatches(quote, quotedItem, 'citizen:other', 1000)
expect(ownerOk == false and ownerErr == 'quote_owner_mismatch',
  'quote must remain bound to its server-side owner')
local expiryOk, expiryErr = MZFurnitureLogic.QuoteMatches(quote, quotedItem, 'citizen:test', 1046)
expect(expiryOk == false and expiryErr == 'quote_expired', 'expired quote must be rejected')
quotedItem.price = 2501
local changedOk, changedErr = MZFurnitureLogic.QuoteMatches(quote, quotedItem, 'citizen:test', 1000)
expect(changedOk == false and changedErr == 'quote_changed',
  'server price change must invalidate the quote')

print('[mz_furniture][test] catalog logic harness passed')
