# BlackVault — Phase 8.6.1: Conflict Resolution Audit & Design Specification

---

## Executive Overview

This document specifies the **Conflict Resolution Architecture** for **BlackVault**, building directly upon the Phase 8.3.1 (Local Sync Queue), Phase 8.4.1 (Push Synchronization), and Phase 8.5.1 (Pull Synchronization) foundations.

BlackVault is an **offline-first application**:
> Local SQLite remains the application's primary operational database on the device, while synchronization operates asynchronously in the background.

When local offline mutations overlap with concurrent server mutations, the system must resolve conflicts deterministically without data loss, silent overwrites, or broken business invariants.

---

## 1. Grounded Architecture Baseline (Phases 8.1 – 8.5.1)

### 1.1 Local SQLite Schema & Queue (`blackvault.db`)
- **Business Tables**: `users`, `loans`, `loan_activities`, `notifications`.
- **Sync Queue Table (`sync_queue`)**: Tracks local pending mutations (`id`, `entityType`, `entityId`, `operation`, `payload`, `clientOperationId`, `createdAt`, `retryCount`, `lastAttemptAt`, `status`, `error`).
- **Sync Metadata Table (`sync_metadata`)**: Stores local sync cursor `lastAppliedServerVersion` (key-value pair).

### 1.2 Central Backend Schema (`backend_blackvault.db`)
- **Authoritative Tables**: `users`, `loans` (with `version INTEGER`), `loan_activities`, `notifications`.
- **Sync Changes Table (`sync_changes`)**: Monotonically increasing sequence `serverVersion AUTOINCREMENT` log (`serverVersion`, `entityType`, `entityId`, `operation`, `payload`, `userId`, `originDeviceId`, `createdAt`).
- **Idempotency Records (`idempotency_records`)**: Maps `clientOperationId` (UUID v4) to cached responses to prevent duplicate operations during retries.

### 1.3 Synchronization Flows
- **Push Flow (`POST /api/sync/push`)**: Pushes local `PENDING_SYNC` operations to backend. Evaluates idempotency and field ownership rules.
- **Pull Flow (`GET /api/sync/pull?since=<version>&deviceId=<deviceId>`)**: Retrieves server changes sequentially after cursor. Applies changes atomically in local SQLite transaction, advances `lastAppliedServerVersion`, and prevents echo loops (`applyServerLoan` bypasses `sync_queue`).

---

## 2. Entity Ownership Matrix

| Entity | Primary Stored Location | Primary Entity Owner | Sync Direction | Authority Rule |
| :--- | :--- | :--- | :--- | :--- |
| **Customer Profile** | Local `users` / Server `users` | Customer | Bidirectional | Customer (profile attributes) / Server (role & credentials) |
| **Loan Application** | Local `loans` / Server `loans` | Customer (Draft/Pending) | Bidirectional | Split Ownership: Customer owns request fields while `pending`; Admin owns `status` |
| **Loan Activity Log** | Local `loan_activities` / Server | System / Admin / Customer | Append-Only | Merged by `id` & `createdAt` (Immutable event log) |
| **Notification** | Local `notifications` / Server | Server (creation) / Customer (`isRead`) | Bidirectional | Server creates notifications; Customer owns `isRead` boolean |

---

## 3. Concrete Field Ownership Matrix

For synchronizable entities, fields are classified into immutable, customer-owned, or admin-owned:

### 3.1 `LoanModel` (`loans` table)

| Field | Data Type | Owner / Authority | Mutable? | Conflict Behavior |
| :--- | :--- | :--- | :--- | :--- |
| `id` | `TEXT PRIMARY KEY` | System / Client | **Immutable** | UUID v4 generated on creation. Primary key, no conflict. |
| `userId` | `TEXT` | Customer | **Immutable** | Entity owner identifier. Immutable. |
| `userName` | `TEXT` | Customer | Mutable | Display attribute. Customer authority. |
| `amount` | `REAL` | **Customer** | Mutable | Customer authority when `status == pending`. Server rejects customer edit if `status != pending`. |
| `tenureMonths` | `INTEGER` | **Customer** | Mutable | Customer authority when `status == pending`. Server rejects customer edit if `status != pending`. |
| `purpose` | `TEXT` | **Customer** | Mutable | Customer authority when `status == pending`. Server rejects customer edit if `status != pending`. |
| `priority` | `TEXT` | **Customer** | Mutable | Customer authority when `status == pending`. Server rejects customer edit if `status != pending`. |
| `status` | `TEXT` | **Admin / Server** | Mutable | **Admin / Server ALWAYS Overrides**. Customer cannot modify status. |
| `createdAt` | `TEXT (ISO-8601)` | Client / Server | **Immutable** | Creation timestamp. Immutable. |

### 3.2 `LoanActivityModel` (`loan_activities` table)
- **All Fields** (`id`, `loanId`, `userId`, `userName`, `type`, `message`, `createdAt`): **Immutable Append-Only Log**.
- Conflict Behavior: No attribute modification conflicts. Merged deterministically by `id`.

### 3.3 `NotificationModel` (`notifications` table)
- `id`, `userId`, `title`, `message`, `type`, `loanId`, `createdAt`: **Server-Owned**. Server creates notifications.
- `isRead`: **Customer-Owned**. Customer updates read state (`0` / `1`).

---

## 4. Status Transition & Authority Matrix

| Local Status | Server Status | Customer Edit Allowed? | Expected Conflict Outcome | Authority |
| :--- | :--- | :--- | :--- | :--- |
| `pending` | `pending` | **Yes** | Local customer edit accepted on server via push | Customer |
| `pending` | `approved` | **No** (New edits rejected) | Server `status = approved` overrides local status; Customer edits queued after approval rejected with `HTTP 409 CONFLICT` | Admin / Server |
| `pending` | `rejected` | **No** (New edits rejected) | Server `status = rejected` overrides local status; Customer edits queued after rejection rejected with `HTTP 409 CONFLICT` | Admin / Server |
| `pending` | `cancelled` | **No** | Customer cancellation pushes to server; if already finalized on server, server `approved/rejected` overrides | Admin / Server |
| `approved` | `approved` | **No** | No conflict | Admin / Server |
| `approved` | `rejected` | **No** | Illegal transition. Server state is final authoritative state | Admin / Server |
| `rejected` | `approved` | **No** | Illegal transition. Server state is final authoritative state | Admin / Server |

---

## 5. Conflict Taxonomy (9 Categories)

1. **`NO_CONFLICT`**: Operations affect disjoint entities or identical field values.
2. **`ALREADY_APPLIED`**: Idempotent replay of an operation that was previously processed (`clientOperationId` cache match).
3. **`OWN_DEVICE_ECHO`**: Server change originated from the same device (`originDeviceId == clientDeviceId`); cursor advances without local write.
4. **`SPLIT_OWNERSHIP_MERGE`**: Concurrent edits touch disjoint fields (e.g. Customer edited `amount` while Admin approved `status`). Merged cleanly via split-field update.
5. **`CUSTOMER_FIELD_CONFLICT`**: Customer edited customer-owned field (`amount`, `purpose`) offline, but server contains a different value. Customer wins if `status == pending`.
6. **`ADMIN_STATUS_OVERRIDE`**: Admin updated `status` (`approved`/`rejected`) on server while Customer had offline edits. Admin status wins; if customer attempted post-decision edits, server returns `409 CONFLICT`.
7. **`STALE_PUSH_REJECTION`**: Device attempts to push an edit based on an outdated server version after Admin has finalized decision (`status != pending`). Server returns `HTTP 409 CONFLICT`.
8. **`UPDATE_DELETE_CONFLICT`**: One party updated an entity while the other deleted it.
9. **`INVALID_MUTATION`**: Operation violates business constraints (e.g., negative amount, customer setting `status`).

---

## 6. Concurrency Control & Versioning Strategy

### 6.1 Cursor vs Entity Version
- **Global Sync Cursor (`serverVersion`)**: Monotonically increasing sequence on `sync_changes`. Used exclusively by devices to track progress in the pull log (`since=<version>`).
- **Entity Version (`version`)**: Integer column in central `loans` table. Incremented on every loan update (`version = existing.version + 1`).

### 6.2 Stale Push Scenario Walkthrough

```text
Server State:
loan.amount = 15,000
version = 1
status = pending
serverVersion = 100

1. Device A downloads loan version 1 at serverVersion 100.
2. Device A goes offline and edits loan.amount = 20,000 (queued in sync_queue).
3. Meanwhile, Admin on server approves loan (status = approved, version = 2, serverVersion = 101).
4. Device A reconnects and pushes amount = 20,000.
```

#### Push Result & Resolution Flow
1. **Server Validation**: `SyncBackendController` checks `existingLoan.status`: since `status == 'approved'` (no longer `pending`), the customer edit is **rejected** with `status = 'CONFLICT'`, `message = 'Conflict: Cannot edit loan after admin decision'`.
2. **Client Processing**:
   - `SyncEngine.pushPending()` receives `CONFLICT` status. `sync_queue` item is marked `status = 'CONFLICT'`.
   - `SyncEngine.pullChanges()` receives `serverVersion 101` (`status = approved`). Local SQLite loan `status` is updated to `approved`.
   - The customer's rejected edit is preserved in `sync_queue` with status `'CONFLICT'` for user inspection/review.

---

## 7. Conflict Evidence & Persistence Proposal (`sync_conflicts`)

To ensure evidence is preserved without destroying local edits or silently dropping customer changes, Phase 8.6 will introduce a dedicated SQLite `sync_conflicts` table:

```sql
CREATE TABLE IF NOT EXISTS sync_conflicts (
  id TEXT PRIMARY KEY,
  clientOperationId TEXT NOT NULL,
  entityType TEXT NOT NULL,
  entityId TEXT NOT NULL,
  conflictType TEXT NOT NULL,       -- 'STALE_PUSH', 'ADMIN_OVERRIDE', 'UPDATE_DELETE'
  localValue TEXT NOT NULL,          -- JSON payload of local attempt
  serverValue TEXT NOT NULL,         -- JSON payload of server state
  serverVersion INTEGER NOT NULL,
  createdAt TEXT NOT NULL,
  resolvedAt TEXT,
  resolution TEXT                    -- 'CUSTOMER_WINS', 'SERVER_WINS', 'MERGED', 'DISCARDED'
);

CREATE INDEX IF NOT EXISTS idx_sync_conflicts_entity ON sync_conflicts(entityType, entityId);
```

---

## 8. Conflict State Lifecycle

```
[Local Edit Offline]
        │
        ▼
   PENDING_SYNC
        │
        ▼ (Push Attempt)
     SYNCING
        │
        ├─────────────────────────────┐
        ▼                             ▼ (Server HTTP 409 Conflict)
     SYNCED                        CONFLICT
                                      │
                                      ▼
                             RESOLUTION_PENDING
                                      │
                       ┌──────────────┴──────────────┐
                       ▼                             ▼
                  (User Accepts)               (User Retries)
                       │                             │
                       ▼                             ▼
                   DISCARDED                    PENDING_SYNC
```

---

## 9. Security & Data Isolation Boundaries

1. **Row-Level Authorization**: Conflict records in `sync_conflicts` contain payloads for the authenticated user only (`userId == authUser.userId`).
2. **Field Ownership Enforcement**: Customer cannot override admin status, even via crafted API payloads. Server validates role on every push.
3. **No Cross-Customer Leakage**: Pull queries filter `sync_changes` by `userId = authUser.userId` for CUSTOMER role.

---

## 10. Test Matrix for Phase 8.6

| Category | Scenario | Expected Behavior |
| :--- | :--- | :--- |
| **Customer Fields** | Offline edit of amount (`20k`) while server pending (`15k`) | Push succeeds; server updates amount to `20k` |
| **Admin Status** | Admin approves loan (`status = approved`) on server | Pull updates local `status = approved`; local pending edits preserved/rejected cleanly |
| **Split Edits** | Customer edits `amount`, Admin approves `status` | Merged cleanly: `status = approved`, `amount = 20k` |
| **Stale Push** | Customer pushes edit after loan is `approved` | Server rejects with `HTTP 409 CONFLICT`; local queue item marked `CONFLICT` |
| **Idempotency Retry** | Push retry with same `clientOperationId` | Server returns cached response; no duplicate `sync_changes` |
| **Own-Device Echo** | Device pulls change with matching `originDeviceId` | Skipped local re-application; cursor advances |

---

## 11. Implementation Roadmap & Current Status

- **Phase 8.6.1 — Conflict Resolution Audit & Design (Completed)**: Architectural audit, field ownership matrix, status transition rules, and design document.
- **Phase 8.6.2 — Conflict Persistence & Concurrency Foundation (Completed)**:
  - Preserved entity-level optimistic concurrency version (`loans.version`).
  - Added `baseVersion` tracking to `SyncQueueItem` and `POST /api/sync/push` payload.
  - Implemented server-side stale push detection (`baseVersion < server.version` -> `status: CONFLICT` with `serverState`).
  - Implemented local `sync_conflicts` table schema (DB version 3 migration) for persistent conflict evidence storage.
  - Implemented atomic transaction persistence for queue status update and conflict record storage in `SyncEngine`.
- **Phase 8.6.3 — Merge Engine & Split-Field Resolver (Next)**: Field-level merge algorithm in `SyncEngine` for split ownership.
- **Phase 8.6.4 — Conflict Recovery & Lifecycle Management**: Queue retry/resolution handlers for `CONFLICT` state items.
- **Phase 8.6.5 — End-to-End Conflict Resolution Verification**: Multi-device conflict resolution tests.
