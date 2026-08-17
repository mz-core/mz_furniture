MZFurnitureConfig = {
  -- Fase 7: ciclo residencial, revenda, transferencia e recuperacao automatica.
  Enabled = true,
  CatalogEnabled = true,
  PurchasesEnabled = true,
  PlacementEnabled = true,
  RuntimeSyncEnabled = true,
  RuntimeStreamDistance = 80.0,
  RuntimeStreamHysteresis = 10.0,
  ResaleEnabled = true,
  OwnerReconciliationEnabled = true,
  OwnerReconciliationIntervalSeconds = 300,
  OwnerReconciliationBatchSize = 100,
  ResidentialAuthorityEnabled = true,

  -- Ownership e compra coletiva exigem facility ativa e capability server-side.
  -- Placement permanece bloqueado ate os bounds do IPL serem calibrados.
  OrganizationWarehouseReadEnabled = true,
  OrganizationOwnershipEnabled = true,
  OrganizationPurchasesEnabled = true,
  OrganizationPlacementEnabled = false,

  AutoCreateTables = true,
  AutoSeedCatalog = true,
  EnableReviewedSeedItems = true,
  CatalogCacheSeconds = 60,
  QuoteTtlSeconds = 45,
  PlacementTokenTtlSeconds = 120,
  PlacementRateLimitSeconds = 1,
  PurchaseRateLimitSeconds = 2,
  PlayerMenuCommand = 'moveis',
  PlayerMenuAliases = { 'furniture' },

  MaxItemsPerProperty = 100,
  DefaultResalePercent = 50,
  MaxPlacementOffset = 60.0,
  MaxAbsoluteRotation = 36000.0,

  Permissions = {
    View = 'staff.furniture.view',
    Create = 'staff.furniture.create',
    Manage = 'staff.furniture.manage',
    Archive = 'staff.furniture.archive',
    Recovery = 'staff.furniture.recovery'
  }
}
