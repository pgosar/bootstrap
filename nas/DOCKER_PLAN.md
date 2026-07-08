# NAS Docker Plan

This is the target service direction for the Docker restore/configuration pass.

## Core decisions

- Do not restore or maintain Codex Docker containers. Install and run Codex directly on the NAS host instead.
- Use Immich for the photo library.
- Use Tdarr for media re-encoding.
- Use the NAS as the orchestrator/control node for scheduled compute work.
- Use the PC as the high-power worker when jobs need substantially more CPU/GPU.

## Photos and Immich

- Immich owns photo indexing and library services on the NAS.
- Immich can run small, low-latency ML work on the NAS for a small number of new images.
- Bulk Immich ML jobs must defer to the PC worker.
- Bulk ML offload to the PC must only run at night and only when the PC is not in active use.

## Media re-encoding

- Tdarr server/orchestrator runs on the NAS.
- Tdarr worker/transcode node runs on the PC and uses the PC GPU/CPU.
- Re-encoding jobs that use the PC must only run at night and only when the PC is not in active use.
- The NAS wake script can be used by the scheduler to wake the PC before nightly work.

## ISO mirroring

- Add a small service for Linux ISO mirroring.
- Maintain a repo-controlled distro list.
- The service downloads or updates the latest ISO for each distro in that list.
- Store downloaded ISOs under `/data` in a path that is excluded from SnapRAID if the files are easy to re-download, or included if long-term retention matters.

## Scheduling constraints

- Nightly compute windows should be enforced centrally from the NAS.
- The PC worker should not be used when a local interactive session appears active.
- Jobs should be resumable and safe to skip if the PC is unavailable.
