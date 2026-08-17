ALTER TABLE mz_owned_furniture
  ADD COLUMN IF NOT EXISTS owner_type ENUM('player','org')
    NOT NULL DEFAULT 'player' AFTER id;

ALTER TABLE mz_owned_furniture
  ADD COLUMN IF NOT EXISTS owner_key VARCHAR(64) NULL AFTER owner_type;

UPDATE mz_owned_furniture
SET owner_type = 'player', owner_key = LOWER(owner_citizenid)
WHERE (owner_key IS NULL OR owner_key = '')
  AND owner_citizenid IS NOT NULL AND owner_citizenid <> '';

ALTER TABLE mz_owned_furniture
  MODIFY COLUMN owner_key VARCHAR(64) NOT NULL;

ALTER TABLE mz_owned_furniture
  ADD INDEX IF NOT EXISTS idx_mz_owned_furniture_owner_scope_status
    (owner_type, owner_key, status);

-- Ambos os resultados devem ser zero antes do rollout.
SELECT COUNT(*) AS invalid_owner_rows
FROM mz_owned_furniture
WHERE owner_key IS NULL OR owner_key = ''
  OR owner_type NOT IN ('player', 'org')
  OR (owner_type = 'player' AND (
    owner_citizenid IS NULL OR owner_citizenid = ''
    OR BINARY owner_key <> BINARY LOWER(owner_citizenid)
  ));

SELECT COUNT(*) AS non_player_rows_before_org_rollout
FROM mz_owned_furniture
WHERE owner_type <> 'player';
