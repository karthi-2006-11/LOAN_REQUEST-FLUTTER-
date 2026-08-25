# BlackVault Central Backend Documentation

---

## 1. Overview
The BlackVault Central Backend is a lightweight, high-performance Dart (`Shelf`) REST API server. It provides server-side user authentication (Argon2id), role-based access control (RBAC), loan management, field ownership validation, idempotency deduplication, and database transaction safety.

---

## 2. Technology Stack & Directory Structure

- **Runtime**: Dart SDK (`>=3.0.0`)
- **HTTP Server**: `package:shelf`, `package:shelf_router`, `package:shelf_cors_headers`
- **Central Database**: SQLite (`backend_blackvault.db`) using `package:sqflite_common_ffi`
- **Password Security**: **Argon2id** Key Derivation Function (`package:argon2`)
- **Authentication**: JWT tokens (`package:dart_jsonwebtoken`)

```text
backend/
├── bin/
│   └── server.dart              # Entrypoint starting HTTP server
├── lib/
│   ├── config/
│   │   └── env_config.dart      # Environment configuration (PORT, JWT_SECRET, DB_PATH)
│   ├── controllers/
│   │   ├── auth_controller.dart # /api/auth/register, /api/auth/login
│   │   ├── health_controller.dart # /api/health
│   │   └── loan_controller.dart # /api/loans
│   ├── database/
│   │   └── backend_database.dart # SQLite database pool & schema setup
│   ├── middleware/
│   │   ├── auth_middleware.dart  # JWT verification & request context
│   │   ├── cors_middleware.dart  # CORS support
│   │   └── error_middleware.dart # Consistent JSON error handler
│   ├── models/
│   │   ├── user_server_model.dart
│   │   ├── loan_server_model.dart
│   │   └── idempotency_record.dart
│   ├── repositories/
│   │   ├── user_backend_repository.dart
│   │   ├── loan_backend_repository.dart
│   │   └── idempotency_repository.dart
│   ├── routes/
│   │   └── api_router.dart      # Route dispatching
│   ├── utils/
│   │   ├── jwt_util.dart        # JWT token generation & verification
│   │   └── password_util.dart   # Argon2id password hashing
│   └── app.dart                 # Application bootstrap class
├── test/
│   └── server_test.dart        # End-to-end backend tests
├── .env.example
└── pubspec.yaml
```

---

## 3. Configuration & Environment Variables

Create `.env` inside `backend/` using `.env.example`:

```env
PORT=8080
DATABASE_PATH=backend_blackvault.db
JWT_SECRET=blackvault_secure_jwt_secret_key_change_in_production
JWT_ISSUER=blackvault_backend
JWT_EXPIRATION=86400
ENVIRONMENT=development
```

---

## 4. Database Schema (`backend_blackvault.db`)

1. **`users`**: `id` (UUID), `email` (UNIQUE), `fullName`, `phone`, `role` (`CUSTOMER`/`ADMIN`), `passwordHash` (Argon2id string), `salt`, `createdAt`, `updatedAt`
2. **`loans`**: `id` (UUID), `userId` (FK), `userName`, `amount`, `tenureMonths`, `purpose`, `priority`, `status`, `deviceId`, `version`, `createdAt`, `updatedAt`
3. **`loan_activities`**: `id` (UUID), `loanId` (FK), `userId`, `userName`, `type`, `message`, `createdAt`
4. **`notifications`**: `id` (UUID), `userId`, `title`, `message`, `type`, `loanId`, `createdAt`, `isRead` (0/1)
5. **`idempotency_records`**: `clientOperationId` (PRIMARY KEY), `entityId`, `operationType`, `responseCode`, `responsePayload`, `createdAt`

---

## 5. Security & Authorization Rules

### Password Hashing (Argon2id)
- Passwords are salted and hashed using **Argon2id** (`$argon2id$v=19$m=4096,t=2,p=1$...`).
- Plain SHA-256 or MD5 is **never** used. `passwordHash` is never exposed in API responses.

### Role-Based Access Control (RBAC)
- `CUSTOMER`: Can read/create their own loans. Can update `amount`, `tenureMonths`, `purpose`, `priority` only while status is `pending`. Cannot alter `status`. Cannot view other customers' loans (`403 Forbidden`).
- `ADMIN`: Can view all loans across users and mutate `status` (`approved` / `rejected`).

### Idempotency Foundation
- Request header `X-Client-Operation-ID` allows client retry deduplication.
- Duplicate operations return previous HTTP responses with `X-Idempotent-Replay: true` header without creating duplicate database records.

---

## 6. API Endpoint Summary

| Endpoint | Method | Auth Required | Role | Description |
| :--- | :--- | :--- | :--- | :--- |
| `/api/health` | `GET` | No | Any | System & database health status |
| `/api/auth/register` | `POST` | No | Any | Register user with Argon2id password hashing |
| `/api/auth/login` | `POST` | No | Any | User login; issues JWT token |
| `/api/loans` | `GET` | Yes | Customer / Admin | Retrieve customer loans (or all loans if Admin) |
| `/api/loans/:id` | `GET` | Yes | Customer / Admin | Get loan by ID (enforces data isolation) |
| `/api/loans` | `POST` | Yes | Customer | Create loan (status defaults to `pending`) |
| `/api/loans/:id` | `PATCH` | Yes | Customer / Admin | Update loan (Customer fields vs Admin status) |
| `/api/sync/push` | `POST` | Yes | Customer / Admin | Process device -> server push operations with idempotency |
| `/api/sync/pull` | `GET` | Yes | Customer / Admin | Retrieve server changes after cursor (since, limit) |

---

## 7. Execution & Development Commands

```bash
# Navigate to backend directory
cd backend

# Install dependencies
dart pub get

# Run static analysis
dart analyze

# Run backend unit test suite
dart test

# Start local server
dart run bin/server.dart
```
