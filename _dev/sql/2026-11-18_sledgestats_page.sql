-- Sledge stats page (alacarte\sledge\sledgestats) - server setup.
-- Needs alacarte/sledge/sledgestats.php deployed, and the sledge_profile app already registered.
-- Looks the app up by ap_var, so the app ID can differ from the local one.

-- The ala line. 22 = ala_access "Read" (opt_field 'ala_access'): anyone who can read the app can open it.
INSERT INTO ala (ala_name, ala_variable, ala_description, ala_app, ala_location, ala_access, ala_navi, ala_navii, ala_record_dependant, ala_fullScreen)
SELECT 'Sledge stats', 'sledgestats', 'Weapon accuracy and player stats from Sledge 2.', app.ID, 'alacarte\\sledge\\', 22, 0, 0, 0, 0
FROM app
WHERE app.ap_var = 'sledge_profile'
  AND NOT EXISTS (SELECT 1 FROM ala WHERE ala_variable = 'sledgestats');

-- Row link: each row of the sledge_profile list opens that player's stats (the list appends the row ID).
UPDATE app SET ap_row_link = 'index.php?ap=sledge_profile&ala=sledgestats&id=' WHERE ap_var = 'sledge_profile';

-- No record toolbar (naviii): with an id in the address it adds a grey bar over the stats page, whose
-- return icon now lives in the page header. Trade-off: the generic record view (cn=det) loses its
-- edit/delete/attach icons for this app.
UPDATE app SET ap_naviii = 0 WHERE ap_var = 'sledge_profile';

-- Check:
-- SELECT ID, ala_name, ala_variable, ala_app, ala_location, ala_access FROM ala WHERE ala_variable = 'sledgestats';
-- SELECT ID, ap_var, ap_row_link, ap_read FROM app WHERE ap_var = 'sledge_profile';
