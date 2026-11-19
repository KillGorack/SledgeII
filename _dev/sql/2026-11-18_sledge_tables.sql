-- =============================================================================
-- Sledge tables: move the game_* fields out of usr, add weapon accuracy stats.
--
-- PHASE 1 - run together with the new gameAPI.php / register.php deploy.
--           Additive: usr keeps its game_* columns as a backup.
-- PHASE 2 - run once Sledge has been checked against sledge_profile
--           (login, stats posting, OG map list).
--
-- The old column types aren't visible from the code; before running, compare
-- with SHOW CREATE TABLE usr and widen anything below that is smaller.
-- =============================================================================


-- ---------------------------------------------------------------- PHASE 1 ---

-- One row per player who has touched Sledge. Rows are created on demand by
-- gameAPI (INSERT IGNORE), so a player with no row just reads as all defaults.
CREATE TABLE IF NOT EXISTS sledge_profile (
    ID          INT UNSIGNED     NOT NULL AUTO_INCREMENT PRIMARY KEY,
    usr_id      INT UNSIGNED     NOT NULL,               -- usr.ID
    score       BIGINT UNSIGNED  NOT NULL DEFAULT 0,
    vanquishes  INT UNSIGNED     NOT NULL DEFAULT 0,
    falls       INT UNSIGNED     NOT NULL DEFAULT 0,
    level       TINYINT UNSIGNED NOT NULL DEFAULT 1,     -- derived from vanquishes by addUserStats
    og          TINYINT(1)       NOT NULL DEFAULT 0,     -- sees hidden community maps
    stats_at    DATETIME         NULL,                   -- last accepted addUserStats (30s gap)
    UNIQUE KEY uq_usr (usr_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Weapon accuracy, one row per (player, weapon), running totals.
-- missed = fired - hit ; accuracy = hit / fired.
-- fired: one per trigger pull. hit: at most one per pull (any projectile of
-- the volley damaging an enemy craft/base gun).
CREATE TABLE IF NOT EXISTS sledge_weapon_stats (
    ID       INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    usr_id   INT UNSIGNED NOT NULL,
    weapon   VARCHAR(64)  NOT NULL,                      -- WeaponSettings.weapon_name
    fired    INT UNSIGNED NOT NULL DEFAULT 0,
    hit      INT UNSIGNED NOT NULL DEFAULT 0,
    updated  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY uq_usr_weapon (usr_id, weapon),
    KEY idx_weapon (weapon)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Copy everyone with any Sledge data across. Safe to re-run (IGNORE skips
-- rows already copied).
INSERT IGNORE INTO sledge_profile (usr_id, score, vanquishes, falls, level, og, stats_at)
SELECT ID,
       COALESCE(game_score, 0),
       COALESCE(game_vanquishes, 0),
       COALESCE(game_falls, 0),
       GREATEST(COALESCE(game_level, 1), 1),
       COALESCE(game_og, 0),
       game_stats_at
FROM usr
WHERE COALESCE(game_score, 0) <> 0
   OR COALESCE(game_vanquishes, 0) <> 0
   OR COALESCE(game_falls, 0) <> 0
   OR COALESCE(game_og, 0) <> 0
   OR game_stats_at IS NOT NULL;

-- register.php no longer writes game_user_space, so it needs to stop being a
-- required column until phase 2 drops it.
ALTER TABLE usr MODIFY game_user_space LONGTEXT NULL;


-- Sanity check after phase 1 - both counts should match:
-- SELECT (SELECT COUNT(*) FROM sledge_profile) AS profiles,
--        (SELECT COUNT(*) FROM usr WHERE COALESCE(game_score,0)<>0 OR COALESCE(game_vanquishes,0)<>0
--           OR COALESCE(game_falls,0)<>0 OR COALESCE(game_og,0)<>0
--           OR game_stats_at IS NOT NULL) AS usr_with_sledge_data;


-- ---------------------------------------------------------------- PHASE 2 ---
-- Only after the new PHP is live and verified. Not reversible without a backup.

-- ALTER TABLE usr
--     DROP COLUMN game_score,
--     DROP COLUMN game_vanquishes,
--     DROP COLUMN game_falls,
--     DROP COLUMN game_level,
--     DROP COLUMN game_og,
--     DROP COLUMN game_user_space,
--     DROP COLUMN game_stats_at;


-- ---------------------------------------------------------------- QUERIES ---

-- Site-wide accuracy per weapon:
-- SELECT weapon, SUM(fired) fired, SUM(hit) hit, SUM(fired) - SUM(hit) missed,
--        ROUND(SUM(hit) / NULLIF(SUM(fired), 0), 3) accuracy
-- FROM sledge_weapon_stats GROUP BY weapon ORDER BY fired DESC;

-- One player's accuracy:
-- SELECT weapon, fired, hit, fired - hit missed, ROUND(hit / NULLIF(fired, 0), 3) accuracy
-- FROM sledge_weapon_stats WHERE usr_id = ? ORDER BY fired DESC;


-- ------------------------------------------------------------ 2026-11-18 ---
-- The old game's personal Creative space (user_space) is gone: Sledge 1 is retired, Sledge 2 never used it,
-- and gameAPI's updateUserSpace/getUserSpace were removed. For a server that already has the column:
-- ALTER TABLE sledge_profile DROP COLUMN user_space;
-- DELETE fld FROM fld JOIN app ON app.ID = fld.fld_app WHERE app.ap_var = 'sledge_profile' AND fld.fld_column = 'user_space';
