#!/bin/bash
# Auto-route new Immich photos to Phone Backup or Camera Import albums.
# Camera Import = dedicated cameras only (Fuji, Sony, Canon, etc.)
# Phone Backup = everything else (iPhones, screenshots, WhatsApp, etc.)

PHONE_ALBUM="65a57aa0-91ee-484b-9458-55d8f7af763d"
CAMERA_ALBUM="bca60a90-8352-44d9-ac48-6e64863a52a8"

docker exec immich_postgres psql -U postgres -d immich -t -c "
-- Dedicated cameras -> Camera Import
INSERT INTO album_asset (\"albumId\", \"assetId\")
SELECT '$CAMERA_ALBUM', a.id
FROM asset a
JOIN asset_exif e ON a.id = e.\"assetId\"
WHERE a.id NOT IN (SELECT \"assetId\" FROM album_asset)
AND e.\"make\" IN ('FUJIFILM', 'SONY', 'Canon', 'NIKON', 'Panasonic', 'Olympus', 'Leica')
ON CONFLICT DO NOTHING;

-- Everything else -> Phone Backup
INSERT INTO album_asset (\"albumId\", \"assetId\")
SELECT '$PHONE_ALBUM', a.id
FROM asset a
WHERE a.id NOT IN (SELECT \"assetId\" FROM album_asset)
ON CONFLICT DO NOTHING;
" > /dev/null 2>&1
