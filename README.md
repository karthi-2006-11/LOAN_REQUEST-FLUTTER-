# BlackVault

BlackVault is a secure loan management platform built with Flutter, supporting customer loan applications, administrative review, loan lifecycle management, notifications, and activity history.

## Tagline
*Secure Loans. Smarter Decisions.*

## Key Features
- **Authentication & Security**: Secure SHA-256 hashed credential persistence, role-based routing (Customer / Administrator), and session management.
- **Loan Application & Lifecycle**: Intuitive loan request creation (₹500 to ₹50,000 range), real-time EMI repayment breakdown, and customer pending loan cancellation (`Pending` → `Cancelled`).
- **Administrative Console**: Comprehensive dashboard with live status counters, applicant search (Name, ID, Purpose), priority filter, multi-attribute sorting, and one-tap Approve/Reject decision processing.
- **Notification Center**: Real-time user and admin notification system with unread badges, tap-to-inspect navigation, and read state persistence.
- **Detailed Activity History Log**: Stored chronological event timeline tracking loan submissions, admin reviews, approvals, rejections, and customer cancellations.
- **Indian Market Ready**: All monetary values formatted strictly in Indian Rupees (`₹` / `INR`).

## Tech Stack
- **Framework**: Flutter / Dart
- **State Management**: Provider (`ChangeNotifier`)
- **Local Storage**: SharedPreferences
- **Formatting**: `intl` package (Indian Rupee `en_IN` formatting)
