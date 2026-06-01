# TaskManager Folders — Off-Chain Schema & Pinning

TaskManager v4 introduces project folders. The contract stores only a single
`bytes32 foldersRoot` per org; the folder-tree JSON lives off-chain on IPFS
pinned at that root, following the same convention as `metadataHash` on
`Project` and `Task`.

This document is the authoritative reference for clients (frontend, subgraph,
backend, integrators) that read or write folder state. Implementations should
treat it as a spec; deviations break interop.

## On-chain shape

- `Organization.foldersRoot: bytes32` — raw 32-byte sha256 digest extracted
  from the CIDv0 of the folder JSON file. Matches the existing `metadataHash`
  encoding used by `Project` and `Task`. The bytes32 is NOT the CID string;
  it's the multihash digest portion only.
- Updated atomically via
  `setFolders(bytes32 expectedCurrentRoot, bytes32 newRoot)`. CAS-guarded:
  reverts `FoldersRootStale(expected, actual)` if `expectedCurrentRoot`
  doesn't match storage.
- `event FoldersUpdated(bytes32 indexed newRoot, bytes32 indexed oldRoot, address indexed sender)`
  emitted on every successful update.
- Permission: executor OR any wearer of an `organizerHatIds` hat.

`foldersRoot == bytes32(0)` is reserved. It means "uninitialized" or
"explicitly cleared" — semantically equivalent. Clients MUST treat zero as
the empty tree (see schema below) and MUST NOT attempt IPFS resolution on a
zero hash.

## Off-chain JSON schema

A flat list of folder records. Trees are reconstructed client-side via
`parentId` pointers. Flat shape is chosen over a nested tree because it makes
diffing trivial (drag-drop = update one row's `parentId`), which matters for
the CAS-retry flow.

```json
{
  "schemaVersion": 1,
  "folders": [
    {
      "id": "f-7c4f9e2a-1b3d-4c8a-9e2b-1234567890ab",
      "name": "Engineering",
      "parentId": null,
      "sortOrder": 0,
      "projectIds": [
        "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
      ]
    },
    {
      "id": "f-3a8d2b1c-9e5f-4a7b-8c2d-fedcba0987654321",
      "name": "Frontend",
      "parentId": "f-7c4f9e2a-1b3d-4c8a-9e2b-1234567890ab",
      "sortOrder": 0,
      "projectIds": []
    }
  ]
}
```

### Field reference

| Field | Type | Required | Notes |
|---|---|---|---|
| `schemaVersion` | number | yes | Current: `1`. Bump on breaking changes. |
| `folders` | array | yes | Empty array = no folders defined. |
| `folders[].id` | string | yes | Stable folder ID, unique within the file. UUID recommended (`"f-<uuidv4>"` prefix is conventional, not required). Used by `parentId` references; renaming `name` does NOT change `id`. |
| `folders[].name` | string | yes | Human-readable. May be empty. Clients may truncate for display. |
| `folders[].parentId` | string \| null | yes | `id` of parent folder, or `null` for top-level. Non-null values MUST reference another folder in the same `folders` array. Cycles MUST be rejected. |
| `folders[].sortOrder` | number | yes | Siblings sorted ascending; ties broken by lexicographic `id`. Clients SHOULD use sparse numbering (e.g. 0, 100, 200) so inserts don't require renumbering. |
| `folders[].projectIds` | string[] | yes | 0x-prefixed hex `bytes32` project IDs. A project SHOULD appear in at most one folder; clients SHOULD detect and reject duplicate assignments. |

### Unassigned projects

Projects not listed in any folder's `projectIds` are unassigned. There is no
explicit "unsorted" folder. Frontends typically render unassigned projects in
a virtual top-level bucket.

### Schema evolution

- **Non-breaking** (no version bump): adding new optional fields to folder
  records; adding new optional top-level fields.
- **Breaking** (bump `schemaVersion`): removing fields, renaming fields,
  changing field types, restructuring the document.

Clients MUST refuse to render a document whose `schemaVersion` is greater
than the version they know about — a forward-incompatible newer version is a
data-integrity hazard, not a graceful degradation.

## CID encoding (matches `metadataHash`)

The `foldersRoot` bytes32 is the raw sha256 digest from a CIDv0:

```js
import { CID } from "multiformats/cid";
const cid = CID.parse(pinResponse.cid);        // e.g. "QmXyz..." (CIDv0)
const digest = cid.multihash.digest;            // 32-byte Uint8Array
const foldersRoot = "0x" + Buffer.from(digest).toString("hex");
```

To reconstruct the CID from `foldersRoot` for IPFS fetching, prepend the
sha256-256 multihash prefix `0x1220`:

```js
const cidHex = "1220" + foldersRoot.slice(2);
const cid = CID.decode(Buffer.from(cidHex, "hex"));
```

(Exact API depends on the IPFS client library. Same encoding used everywhere
in the protocol for IPFS-anchored bytes32 hashes.)

## Pinning

The folder JSON MUST be pinned to IPFS BEFORE `setFolders` is called —
otherwise the on-chain root references content that may not be retrievable
by other clients.

The Poa platform operates a managed pinning service. Frontend clients SHOULD
use the platform's pin API rather than requiring users to provide their own
IPFS credentials. The endpoint, auth, and retention SLA are defined in the
Poa-frontend / Poa-site backend; they are out of scope for this document.

Self-hosted pinning is permitted (advanced users, sovereignty cases), but
the platform makes no guarantee about retrievability for un-pinned content.

This pinning convention is the same one already implicit in
`Project.metadataHash` and `Task.metadataHash` — the contract makes no
provision for hosting; clients coordinate off-chain.

## CAS retry semantics

`setFolders` uses optimistic concurrency. Two organizers editing the tree
simultaneously will collide: the second-to-mine reverts. Clients MUST handle
this without silently dropping user edits.

Recommended flow:

1. Read `foldersRoot` (from subgraph or lens key `10`), call it `R0`.
2. Fetch & parse JSON at `R0` → tree `T0`.
3. User edits → produce tree `T1`. Pin `T1` to IPFS → get `R1`.
4. Call `setFolders(R0, R1)`.
5. If revert `FoldersRootStale(R0, R_actual)`:
   - Read current root `R_actual` (came back in the revert data).
   - Fetch & parse JSON at `R_actual` → tree `T_actual`.
   - Present the user with a diff of `T1` vs `T_actual`. Recommended MVP: a
     simple "your changes vs the new state, pick one or merge manually"
     dialog. Don't auto-merge in v1 — too easy to lose intent.
   - User confirms a merged tree `T2`. Pin `T2` → `R2`. Retry
     `setFolders(R_actual, R2)`.

Clients MUST NOT retry by simply replaying with the new root — that
overwrites the other organizer's edits.

## Example: empty tree

```json
{ "schemaVersion": 1, "folders": [] }
```

When `foldersRoot == bytes32(0)`, clients MUST treat the state as if this
document were pinned, without performing IPFS resolution.
