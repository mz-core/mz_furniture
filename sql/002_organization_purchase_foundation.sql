ALTER TABLE mz_owned_furniture
  MODIFY COLUMN owner_citizenid VARCHAR(64) NULL;

ALTER TABLE mz_owned_furniture
  ADD COLUMN IF NOT EXISTS org_purchase_transaction_id BIGINT UNSIGNED NULL
    AFTER purchase_transaction_id;

ALTER TABLE mz_owned_furniture
  ADD UNIQUE INDEX IF NOT EXISTS uq_mz_owned_furniture_org_purchase_tx
    (org_purchase_transaction_id);

CREATE TABLE IF NOT EXISTS mz_org_furniture_transactions (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  request_id VARCHAR(100) NOT NULL,
  org_code VARCHAR(64) NOT NULL,
  actor_citizenid VARCHAR(64) NOT NULL,
  state ENUM('initiated','payment_pending','money_removed','committed','failed','refunded','manual_review')
    NOT NULL DEFAULT 'initiated',
  amount INT UNSIGNED NOT NULL,
  catalog_id BIGINT UNSIGNED NOT NULL,
  owned_furniture_id BIGINT UNSIGNED NULL,
  spend_receipt_id VARCHAR(128) NULL,
  refund_receipt_id VARCHAR(128) NULL,
  reason VARCHAR(255) NULL,
  metadata_json LONGTEXT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  committed_at TIMESTAMP NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_mz_org_furniture_tx_request (request_id),
  UNIQUE KEY uq_mz_org_furniture_tx_spend_receipt (spend_receipt_id),
  KEY idx_mz_org_furniture_tx_recovery (actor_citizenid, state, created_at),
  KEY idx_mz_org_furniture_tx_org (org_code, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Deve retornar zero antes de liberar compras organizacionais.
SELECT COUNT(*) AS invalid_owner_rows
FROM mz_owned_furniture
WHERE owner_key IS NULL OR owner_key = ''
  OR owner_type NOT IN ('player', 'org')
  OR (owner_type = 'player' AND (
    owner_citizenid IS NULL OR owner_citizenid = ''
    OR BINARY owner_key <> BINARY LOWER(owner_citizenid)
  ))
  OR (owner_type = 'org' AND owner_citizenid IS NOT NULL);
