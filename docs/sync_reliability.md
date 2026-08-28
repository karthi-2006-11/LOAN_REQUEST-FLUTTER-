# BlackVault — Phase 8.7.1: Sync Reliability & Automatic Sync Architecture Specification

---

## 1. Executive Overview & Baseline State

- **Current Checkpoint**: `acb7361` — *"Verify end-to-end conflict resolution"*
- **Baseline Verification**:
  - **Flutter Client**: 108 / 108 unit and integration tests passed (`dart analyze lib/ test/` zero warnings).
  - **Central Backend**: 8 / 8 server tests passed (`dart analyze backend/` zero warnings).
  - **Working Tree**: Clean and synchronized with `origin/main`.
- **Purpose**: This specification establishes the architecture, concurrency model, lifecycle triggers, network reachability detection, failure-state matrix, and implementation roadmap for **Phase 8.7 Automatic & Reliable Synchronization**.
- **Scope Lock**: This document is produced during **Phase 8.7.1 (Audit & Design)**. No production code changes, database migrations, package installations, or Git commits are performed in this phase.

---

## 2. Current Architecture & Identified Gaps

### 2.1 Existing Synchronization Components
1. **`SyncEngine`** ([`lib/services/sync_engine.dart`](file:///d:/LOAN_REQUEST_AG/lib/services/sync_engine.dart)): Handles `pushPending()` (`POST /api/sync/push`) and `pullChanges()` (`GET /api/sync/pull`).
2. **`ConflictRecoveryService`** ([`lib/services/conflict_recovery_service.dart`](file:///d:/LOAN_REQUEST_AG/lib/services/conflict_recovery_service.dart)): Atomically resolves conflicts via pure `ConflictClassifier` and `ConflictResolver`.
3. **`LocalSyncQueueRepository`** ([`lib/repositories/sync_queue_repository.dart`](file:///d:/LOAN_REQUEST_AG/lib/repositories/sync_queue_repository.dart)): SQLite persistence for `sync_queue`, `sync_conflicts`, and `sync_metadata`.

### 2.2 Identified Gaps in Current Architecture
1. **No Automatic Triggering**: Synchronization currently runs only when manually invoked or executed within test scripts.
2. **No Connectivity State Abstraction**: `SyncEngine` relies solely on catching HTTP network exceptions during request attempts. There is no passive network interface listener or proactive reachability check.
3. **No Concurrency Guard**: Calling `pushPending()` or `pullChanges()` from multiple callers simultaneously (e.g. app resume + post-mutation trigger) would cause concurrent SQLite transactions, lock contention, and duplicate HTTP requests.
4. **No App Lifecycle Hooks**: The app does not automatically trigger sync on application startup, foreground resume, or after local business mutations.
5. **Interrupted Sync Stale State**: If the application process is killed mid-push while queue items are marked `SYNCING`, those items remain in `SYNCING` state until reset.

---

## 3. Connectivity & Reachability Strategy

### 3.1 Three-Tier Connectivity Model

To ensure reliability without wasting device battery or data, BlackVault distinguishes between three distinct network states:

```text
┌─────────────────────────┐
│ 1. Network Interface    │  Device has Wi-Fi / Cellular interface enabled (via connectivity_plus).
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ 2. Internet Access      │  Device can resolve DNS and reach public gateway (Active probe).
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ 3. Backend Reachable    │  BlackVault backend responds HTTP 200 to GET /api/health.
└─────────────────────────┘
```

### 3.2 Trigger vs. Authority Rule
- **Connectivity Listener** (`connectivity_plus` or HTTP health probe) acts **STRICTLY AS A TRIGGER**.
- **Network Interface Available != Backend Reachable**.
- The actual HTTP response (`200 OK`, `401 Unauthorized`, `409 Conflict`, `500 Server Error`, `SocketException`) received during `SyncEngine` execution remains the **SOLE AUTHORITATIVE ARBITER** of operation success or failure.

---

## 4. Synchronization Coordinator (`SyncCoordinator`) Strategy

To prevent race conditions, lock contention, and duplicate execution, BlackVault introduces a single, unified **`SyncCoordinator`** service.

### 4.1 Conceptual Architecture

```text
                                  SYNC TRIGGERS
     ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
     │   App Startup    │   App Resume     │ Network Restored │  Post-Mutation   │
     └────────┬─────────┴────────┬─────────┴────────┬─────────┴────────┬─────────┘
              │                  │                  │                  │
              └──────────────────┴────────┬─────────┴──────────────────┘
                                          │
                                          ▼
                               ┌─────────────────────┐
                               │   SyncCoordinator   │
                               └──────────┬──────────┘
                                          │  Request Coalescing Guard
                                          ▼
                              ┌───────────────────────┐
                              │ 1. PUSH Pending Items │
                              └──────────┬────────────┘
                                         │
                                         ▼
                              ┌───────────────────────┐
                              │ 2. PULL Server Changes│
                              └──────────┬────────────┘
                                         │
                                         ▼
                              ┌───────────────────────┐
                              │ 3. Conflict Recovery  │
                              └───────────────────────┘
```

### 4.2 Request Coalescing & Lock Pseudocode

```dart
class SyncCoordinator {
  bool _isSyncRunning = false;
  bool _hasPendingSyncRequest = false;

  /// Entry point for all sync triggers
  Future<SyncCoordinatorResult> requestSync({String trigger = 'MANUAL'}) async {
    if (_isSyncRunning) {
      // Coalesce concurrent triggers into a single follow-up run
      _hasPendingSyncRequest = true;
      return SyncCoordinatorResult.coalesced();
    }

    _isSyncRunning = true;
    try {
      do {
        _hasPendingSyncRequest = false;
        await _executeSyncCycle();
      } while (_hasPendingSyncRequest);
    } finally {
      _isSyncRunning = false;
    }
    return SyncCoordinatorResult.success();
  }
}
```

---

## 5. PUSH / PULL Ordering Decision

### 5.1 Evaluated Strategies
- **Strategy A (`PULL → PUSH`)**: Pulls remote changes first, then pushes local edits.
  - *Risk*: Risk of applying remote changes over local pending entities before push attempts occur, creating unnecessary conflict overhead.
- **Strategy B (`PUSH → PULL`) — RECOMMENDED & SELECTED**:
  - *Rationale*:
    1. **Flush Local Intent First**: Local pending `sync_queue` mutations are pushed with their original `baseVersion`.
    2. **Conflict Resolution at Push Time**: Server stale push rejections (`HTTP 409 CONFLICT`) are immediately handled by `ConflictRecoveryService`, updating local entity state and re-queuing with fresh UUID v4 and aligned `baseVersion = serverVersion`.
    3. **Clean Pull Following Push**: PULL retrieves remote updates after local mutations are reconciled.
    4. **Own-Device Echo Prevention**: Remote changes returned by PULL that originated from `clientDeviceId` are skipped during pull application while global cursor `lastAppliedServerVersion` advances monotonically.
- **Strategy C (`PULL → PUSH → PULL`)**: Unnecessary network overhead (3 round-trips).

---

## 6. Phase 8.6 Integration Boundary

`SyncCoordinator` is an **orchestration layer only**. It DOES NOT bypass, alter, or replace Phase 8.6 conflict resolution logic.

$$\text{SyncCoordinator} \longrightarrow \text{SyncEngine.pushPending()} \longrightarrow \text{HTTP 409} \longrightarrow \text{ConflictClassifier} \longrightarrow \text{ConflictResolver} \longrightarrow \text{ConflictRecoveryService} \longrightarrow \text{SQLite Transaction}$$

All transaction boundaries, UUID v4 re-queueing, baseVersion alignments, and idempotency checks implemented in Phase 8.6 remain 100% enforced.

---

## 7. App Lifecycle Strategy

### 7.1 Lifecycle Events & Synchronization Behavior
1. **Application Startup (`main()`)**:
   - Resets any stale `SYNCING` items in `sync_queue` back to `PENDING_SYNC`.
   - Checks authentication state. If authenticated, triggers `SyncCoordinator.requestSync(trigger: 'STARTUP')`.
2. **Foreground Resume (`AppLifecycleState.resumed`)**:
   - Observed via `WidgetsBindingObserver`. Triggers `SyncCoordinator.requestSync(trigger: 'RESUME')`.
3. **Background Inactive (`AppLifecycleState.paused`)**:
   - In-flight SQLite transactions commit cleanly. No new sync cycles are initiated.
4. **App Termination / Process Killed**:
   - Local SQLite database persists all business records and `sync_queue` entries cleanly. Next app launch resumes automatically.

---

## 8. Background Execution Assessment

### 8.1 Investigation Findings
- **WorkManager (Android)** / **BGTaskScheduler (iOS)**:
  - Requires native platform dependencies, background fetch permissions, battery optimization exemptions, and faces heavy OS throttling (15-min minimum intervals, manufacturer OS kills).
  - Unnecessary for BlackVault's primary user workflow: users interact with BlackVault when the app is active in the foreground.

### 8.2 Architectural Decision: OPTION A (Foreground & Event-Driven Sync)
- **Selection**: **OPTION A — Foreground / Event-Driven Sync Only**.
- **Justification**: Event-driven foreground synchronization (Startup, Resume, Connectivity Restored, Post-Mutation, Manual Pull-to-Refresh) provides 100% data freshness whenever the user views the app, with zero native dependency complexity, zero battery drain, and cross-platform desktop/mobile parity.

---

## 9. Failure-State Matrix

| Condition / Error | HTTP Code / Trigger | Local Business Data | `sync_queue` Status | Cursor (`lastAppliedServerVersion`) | `retryCount` Action | Coordinator Action |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Offline** | No Network / Interface Down | Intact (Saved in SQLite) | `PENDING_SYNC` | Unchanged | No change | Pause sync cycle; wait for connectivity restore trigger |
| **Backend Unreachable / SocketException** | DNS / Connection Refused | Intact | `SYNC_FAILED` | Unchanged | Increments ($+1$) | Backoff retry; schedule follow-up probe |
| **Timeout (15s)** | HTTP Timeout | Intact | `SYNC_FAILED` | Unchanged | Increments ($+1$) | Backoff retry |
| **Authentication Required** | HTTP 401 | Intact | `PENDING_SYNC` (Error: Auth required) | Unchanged | No change | Pause auto-sync; notify AuthProvider / prompt login |
| **Client Validation Error** | HTTP 400 | Intact | `CONFLICT` | Unchanged | No change | Route to Conflict System |
| **Forbidden** | HTTP 403 | Intact | `CONFLICT` | Unchanged | No change | Route to Conflict System |
| **Stale Version Conflict** | HTTP 409 | Intact | `CONFLICT` $\rightarrow$ `sync_conflicts` | Unchanged | Reset to 0 if requeued | Pass through `ConflictRecoveryService` |
| **Unprocessable Entity** | HTTP 422 | Intact | `CONFLICT` | Unchanged | No change | Route to Conflict System |
| **Internal Server Error** | HTTP 500 | Intact | `SYNC_FAILED` | Unchanged | Increments ($+1$) | Exponential backoff retry |
| **Bad Gateway** | HTTP 502 | Intact | `SYNC_FAILED` | Unchanged | Increments ($+1$) | Exponential backoff retry |
| **Service Unavailable** | HTTP 503 | Intact | `SYNC_FAILED` | Unchanged | Increments ($+1$) | Exponential backoff retry |
| **Gateway Timeout** | HTTP 504 | Intact | `SYNC_FAILED` | Unchanged | Increments ($+1$) | Exponential backoff retry |
| **Malformed Response Body** | Invalid JSON / Missing `results` | Intact | `SYNC_FAILED` | Unchanged | Increments ($+1$) | Log error; retry |
| **Partial Push Batch** | Mixed `SYNCED` / `CONFLICT` / `FAILED` | Applied items `SYNCED`; Conflicted items `CONFLICT` | Mixed | Unchanged | Increments for failed items only | Process `SYNCED` & `CONFLICT` items; retry failed items |
| **Partial Pull Batch** | Error mid-pull batch | Intact (Rolls back SQLite transaction) | Intact | Unchanged (Rolls back transaction) | No change | Next pull resumes from previous `lastAppliedServerVersion` |
| **App Killed During Sync** | Process Terminated | Intact | Items remain `SYNCING` or `PENDING_SYNC` in SQLite | Unchanged | Reset `SYNCING` to `PENDING_SYNC` on startup | Startup recovery resets `SYNCING` items $\rightarrow$ `PENDING_SYNC` |
| **App Restart After Crash** | App Launch | Intact | Restored from SQLite `sync_queue` | Restored from SQLite `sync_metadata` | Preserved | Startup recovery verifies database integrity and triggers sync |

---

## 10. Dependency Audit

| Package | Status | Necessity Assessment |
| :--- | :--- | :--- |
| `connectivity_plus` | Recommended for Phase 8.7.2 | Provides passive OS network interface listeners across iOS, Android, macOS, Windows, Linux. |
| `http` | Currently Installed | Used for HTTP REST calls and health probe checks (`/api/health`). |
| `sqflite` / `sqflite_common_ffi` | Currently Installed | Used for SQLite local data and metadata persistence. |
| `workmanager` | NOT Needed | Omitted under Option A (Foreground / Event-driven architecture). |

---

## 11. Implementation Roadmap (Phases 8.7.2 – 8.7.5)

### Phase 8.7.2 — Connectivity & Network Reachability Service (COMPLETED)
- **Objective**: Created `ConnectivityService` ([`lib/services/connectivity_service.dart`](file:///d:/LOAN_REQUEST_AG/lib/services/connectivity_service.dart)) abstracting platform network interface detection (`connectivity_plus`) and unauthenticated HTTP health probes (`GET /api/health`).
- **Files Created**: `lib/services/connectivity_service.dart`, `test/connectivity_service_test.dart`.
- **Dependencies**: Added `connectivity_plus: ^6.1.4`.
- **Test Coverage**: 12 comprehensive unit and isolation test scenarios in [`test/connectivity_service_test.dart`](file:///d:/LOAN_REQUEST_AG/test/connectivity_service_test.dart).

### Phase 8.7.3 — Synchronization Coordinator & Concurrency Guard (COMPLETED)
- **Objective**: Created `SyncCoordinator` ([`lib/services/sync_coordinator.dart`](file:///d:/LOAN_REQUEST_AG/lib/services/sync_coordinator.dart)) implementing `requestSync()`, single-flight concurrency guard (`_isSyncRunning`), request coalescing (`_hasPendingSyncRequest`), connectivity preflight check, and PUSH $\rightarrow$ PULL execution ordering.
- **Files Created**: `lib/services/sync_coordinator.dart`, `test/sync_coordinator_test.dart`.
- **Test Coverage**: 12 comprehensive unit and concurrency test scenarios in [`test/sync_coordinator_test.dart`](file:///d:/LOAN_REQUEST_AG/test/sync_coordinator_test.dart).

### Phase 8.7.4 — App Lifecycle & Provider Event Integration (COMPLETED)
- **Objective**: Integrated `SyncCoordinator` into application MultiProvider scope in `main.dart`, created `AppLifecycleSyncObserver` ([`lib/widgets/app_lifecycle_sync_observer.dart`](file:///d:/LOAN_REQUEST_AG/lib/widgets/app_lifecycle_sync_observer.dart)) (`WidgetsBindingObserver` startup & resume triggers), `AuthProvider` (`postLogin` trigger), and `LoanProvider` (`postMutation` trigger).
- **Files Modified/Created**: `lib/main.dart`, `lib/providers/auth_provider.dart`, `lib/providers/loan_provider.dart`, `lib/services/sync_coordinator.dart`, `lib/widgets/app_lifecycle_sync_observer.dart`, `test/sync_lifecycle_test.dart`.
- **Test Coverage**: 10 comprehensive unit and widget lifecycle test scenarios in [`test/sync_lifecycle_test.dart`](file:///d:/LOAN_REQUEST_AG/test/sync_lifecycle_test.dart).

### Phase 8.7.5 — End-to-End Reliability Verification & Test Suite (COMPLETED)
- **Objective**: Comprehensive reliability audit across offline persistence, 3-tier connectivity, single-flight coordinator, lifecycle triggers, conflict recovery, versioning, and transaction boundaries.
- **Files Audited**: `lib/services/sync_coordinator.dart`, `lib/services/connectivity_service.dart`, `lib/services/sync_engine.dart`, `lib/services/conflict_recovery_service.dart`, `lib/repositories/sync_queue_repository.dart`.

### Phase 8.8.1 — Multi-Device & Offline-to-Online Integration Test Suite (COMPLETED)
- **Objective**: Created [`test/phase_8_8_e2e_integration_test.dart`](file:///d:/LOAN_REQUEST_AG/test/phase_8_8_e2e_integration_test.dart) covering 12 multi-device integration scenarios.
- **Files Created**: `test/phase_8_8_e2e_integration_test.dart`.
- **Test Coverage**: 12 comprehensive multi-device integration tests.

### Phase 8.8.2 — Network Boundary & Edge-Case Stress Testing (COMPLETED)
- **Objective**: Created [`test/phase_8_8_network_stress_test.dart`](file:///d:/LOAN_REQUEST_AG/test/phase_8_8_network_stress_test.dart) covering 33 network stress scenarios.
- **Files Created**: `test/phase_8_8_network_stress_test.dart`.
- **Test Coverage**: 33 deterministic network boundary, HTTP failure, concurrency, conflict recovery, idempotency, and atomicity stress tests.

---

## 12. Verification & Completion Status

- **Phase 8.7.1 Audit Status**: **COMPLETE**.
- **Phase 8.7.2 Connectivity Service Status**: **COMPLETE**.
- **Phase 8.7.3 SyncCoordinator Status**: **COMPLETE**.
- **Phase 8.7.4 App Lifecycle & Provider Status**: **COMPLETE**.
- **Phase 8.7.5 Reliability Audit Status**: **COMPLETE**.
- **Phase 8.8.1 Multi-Device Test Suite Status**: **COMPLETE**.
- **Phase 8.8.2 Network Stress Suite Status**: **COMPLETE**.
- **Phase 8.8.3 Final System Surgical Audit Status**: **COMPLETE**.
- **Phase 9.1 Loan Sync State Model & UI Badges Status**: **COMPLETE**.
- **Flutter Test Baseline**: 194 / 194 tests passed (187 baseline + 7 Phase 9.1 tests).
- **Backend Test Baseline**: 8 / 8 tests passed.
