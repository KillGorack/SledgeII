-- Mines and recon captures (run on the server with the matching gameAPI.php deploy).

-- Mines share sledge_weapon_stats: kind 'mine', fired = laid, hit = caught (its blast reached an enemy, once per
-- mine). Existing rows are all weapons.
ALTER TABLE sledge_weapon_stats
    ADD COLUMN kind VARCHAR(8) NOT NULL DEFAULT 'weapon' AFTER usr_id,
    DROP INDEX uq_usr_weapon,
    ADD UNIQUE KEY uq_usr_kind_weapon (usr_id, kind, weapon);

-- Recon stations captured (gameAPI SLEDGE_COUNTERS 'captures').
ALTER TABLE sledge_profile
    ADD COLUMN captures INT UNSIGNED NOT NULL DEFAULT 0 AFTER falls;

-- New columns for the site's generic pages (fld rows, same defaults the fld admin's "update fields" writes).
INSERT INTO fld (fld_type, fld_app, fld_column, fld_length, fld_human, fld_pdotype, fld_precision, fld_pass, fld_order, fld_enable, fld_index, fld_detail, fld_form)
SELECT 'VAR_STRING', app.ID, 'kind', 32, 'kind', 2, 0, 0, 99, 1, 1, 1, 1 FROM app
WHERE app.ap_var = 'sledge_weapon_stats'
  AND NOT EXISTS (SELECT 1 FROM fld WHERE fld.fld_app = app.ID AND fld.fld_column = 'kind');
INSERT INTO fld (fld_type, fld_app, fld_column, fld_length, fld_human, fld_pdotype, fld_precision, fld_pass, fld_order, fld_enable, fld_index, fld_detail, fld_form)
SELECT 'LONG', app.ID, 'captures', 10, 'captures', 1, 0, 0, 99, 1, 0, 1, 1 FROM app
WHERE app.ap_var = 'sledge_profile'
  AND NOT EXISTS (SELECT 1 FROM fld WHERE fld.fld_app = app.ID AND fld.fld_column = 'captures');
