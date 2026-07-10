# MacBook GDLauncher storage

GDLauncher is configured to use the NAS replica directly through the existing
SMB mount:

`~/Library/Application Support/gdlauncher_carbon/data/instances` →
`~/Server/replicas/minecraft`

A direct shared path is intentional: it keeps the MacBook and PC on one
authoritative instances tree and avoids two independent rsync writers racing or
creating world conflicts. The old Mac-local copy was intentionally discarded
because the NAS/PC copy is authoritative.
