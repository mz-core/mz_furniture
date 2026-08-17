local function flags()
  local source = type(MZFurnitureConfig) == 'table' and MZFurnitureConfig or {}
  return {
    enabled = source.Enabled == true,
    catalogEnabled = source.CatalogEnabled == true,
    purchasesEnabled = source.PurchasesEnabled == true,
    placementEnabled = source.PlacementEnabled == true,
    runtimeSyncEnabled = source.RuntimeSyncEnabled == true,
    resaleEnabled = source.ResaleEnabled == true,
    residentialAuthorityEnabled = source.ResidentialAuthorityEnabled == true
  }
end

exports('GetFeatureFlags', flags)
