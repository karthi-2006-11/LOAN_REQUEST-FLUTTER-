import 'dart:convert';
import 'package:shelf/shelf.dart';
import '../middleware/auth_middleware.dart';
import '../models/idempotency_record.dart';
import '../models/loan_server_model.dart';
import '../repositories/idempotency_repository.dart';
import '../repositories/loan_backend_repository.dart';

class LoanController {
  final LoanBackendRepository loanRepository;
  final IdempotencyRepository idempotencyRepository;

  LoanController({
    required this.loanRepository,
    required this.idempotencyRepository,
  });

  /// GET /api/loans - Retrieve list of loans for current user (or all loans if ADMIN)
  Future<Response> getLoans(Request request) async {
    final authUser = getAuthUser(request);
    if (authUser == null) {
      return _jsonResponse(401, {'success': false, 'error': {'code': 'UNAUTHORIZED', 'message': 'Authentication required'}});
    }

    try {
      final List<LoanServerModel> loans;
      if (authUser.role == 'ADMIN') {
        loans = await loanRepository.getAllLoans();
      } else {
        loans = await loanRepository.getCustomerLoans(authUser.userId);
      }

      return _jsonResponse(200, {
        'success': true,
        'data': loans.map((l) => l.toJson()).toList(),
      });
    } catch (e) {
      return _jsonResponse(500, {'success': false, 'error': {'code': 'SERVER_ERROR', 'message': e.toString()}});
    }
  }

  /// GET /api/loans/:id - Find loan by ID with data isolation checks
  Future<Response> getLoanById(Request request, String id) async {
    final authUser = getAuthUser(request);
    if (authUser == null) {
      return _jsonResponse(401, {'success': false, 'error': {'code': 'UNAUTHORIZED', 'message': 'Authentication required'}});
    }

    try {
      final loan = await loanRepository.getLoanById(id);
      if (loan == null) {
        return _jsonResponse(404, {'success': false, 'error': {'code': 'NOT_FOUND', 'message': 'Loan application not found'}});
      }

      // Customer data isolation check: Customer can only read their own loan
      if (authUser.role != 'ADMIN' && loan.userId != authUser.userId) {
        return _jsonResponse(403, {'success': false, 'error': {'code': 'FORBIDDEN', 'message': 'Access to this loan is denied'}});
      }

      return _jsonResponse(200, {'success': true, 'data': loan.toJson()});
    } catch (e) {
      return _jsonResponse(500, {'success': false, 'error': {'code': 'SERVER_ERROR', 'message': e.toString()}});
    }
  }

  /// POST /api/loans - Create new loan application (Customer endpoint) with Idempotency support
  Future<Response> createLoan(Request request) async {
    final authUser = getAuthUser(request);
    if (authUser == null) {
      return _jsonResponse(401, {'success': false, 'error': {'code': 'UNAUTHORIZED', 'message': 'Authentication required'}});
    }

    final clientOpId = request.headers['x-client-operation-id'];

    // 1. Idempotency Check
    if (clientOpId != null && clientOpId.isNotEmpty) {
      final existingRecord = await idempotencyRepository.findByClientOperationId(clientOpId);
      if (existingRecord != null) {
        return Response(
          existingRecord.responseCode,
          body: existingRecord.responsePayload,
          headers: {'content-type': 'application/json', 'x-idempotent-replay': 'true'},
        );
      }
    }

    try {
      final bodyStr = await request.readAsString();
      if (bodyStr.isEmpty) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_BODY', 'message': 'Request body is empty'}});
      }

      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final amount = (body['amount'] as num?)?.toDouble();
      final tenureMonths = body['tenureMonths'] as int?;
      final purpose = (body['purpose'] as String?)?.trim();
      final priority = (body['priority'] as String?)?.toLowerCase() ?? 'medium';
      final userName = (body['userName'] as String?)?.trim() ?? 'Customer User';
      final deviceId = body['deviceId'] as String?;

      if (amount == null || amount <= 0) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_AMOUNT', 'message': 'Amount must be greater than 0'}});
      }
      if (tenureMonths == null || tenureMonths <= 0) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_TENURE', 'message': 'Tenure must be greater than 0'}});
      }
      if (purpose == null || purpose.isEmpty) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_PURPOSE', 'message': 'Purpose is required'}});
      }

      // Security: Customer CANNOT set status (Status defaults to 'pending')
      final id = body['id'] as String? ?? 'LOAN-${DateTime.now().millisecondsSinceEpoch}';
      final now = DateTime.now();

      final newLoan = LoanServerModel(
        id: id,
        userId: authUser.userId,
        userName: userName,
        amount: amount,
        tenureMonths: tenureMonths,
        purpose: purpose,
        priority: priority,
        status: 'pending',
        deviceId: deviceId,
        version: 1,
        createdAt: now,
        updatedAt: now,
      );

      final created = await loanRepository.createLoan(newLoan);
      final responseMap = {'success': true, 'data': created.toJson()};
      final responseStr = jsonEncode(responseMap);

      // Save Idempotency record if operation ID provided
      if (clientOpId != null && clientOpId.isNotEmpty) {
        await idempotencyRepository.saveRecord(IdempotencyRecord(
          clientOperationId: clientOpId,
          entityId: created.id,
          operationType: 'CREATE_LOAN',
          responseCode: 201,
          responsePayload: responseStr,
          createdAt: now,
        ));
      }

      return _jsonResponse(201, responseMap);
    } catch (e) {
      return _jsonResponse(500, {'success': false, 'error': {'code': 'SERVER_ERROR', 'message': e.toString()}});
    }
  }

  /// PATCH /api/loans/:id - Update loan (Customer field updates vs Admin status approvals)
  Future<Response> updateLoan(Request request, String id) async {
    final authUser = getAuthUser(request);
    if (authUser == null) {
      return _jsonResponse(401, {'success': false, 'error': {'code': 'UNAUTHORIZED', 'message': 'Authentication required'}});
    }

    try {
      final existingLoan = await loanRepository.getLoanById(id);
      if (existingLoan == null) {
        return _jsonResponse(404, {'success': false, 'error': {'code': 'NOT_FOUND', 'message': 'Loan application not found'}});
      }

      final bodyStr = await request.readAsString();
      final body = jsonDecode(bodyStr) as Map<String, dynamic>;

      // Customer Permissions vs Admin Permissions Enforcement
      if (authUser.role != 'ADMIN') {
        // Customer can only update their own loan
        if (existingLoan.userId != authUser.userId) {
          return _jsonResponse(403, {'success': false, 'error': {'code': 'FORBIDDEN', 'message': 'Access to this loan is denied'}});
        }

        // Customer CANNOT modify admin-owned status field
        if (body.containsKey('status')) {
          return _jsonResponse(403, {'success': false, 'error': {'code': 'FORBIDDEN_FIELD', 'message': 'Customers cannot modify loan status'}});
        }

        // Customer can only edit loan if status is 'pending'
        if (existingLoan.status != 'pending') {
          return _jsonResponse(409, {'success': false, 'error': {'code': 'CONFLICT', 'message': 'Cannot edit loan after admin decision'}});
        }
      }

      final updated = existingLoan.copyWith(
        amount: (body['amount'] as num?)?.toDouble(),
        tenureMonths: body['tenureMonths'] as int?,
        purpose: body['purpose'] as String?,
        priority: body['priority'] as String?,
        status: authUser.role == 'ADMIN' ? body['status'] as String? : null, // Admin only
        version: existingLoan.version + 1,
        updatedAt: DateTime.now(),
      );

      final saved = await loanRepository.updateLoan(updated);
      return _jsonResponse(200, {'success': true, 'data': saved.toJson()});
    } catch (e) {
      return _jsonResponse(500, {'success': false, 'error': {'code': 'SERVER_ERROR', 'message': e.toString()}});
    }
  }

  Response _jsonResponse(int statusCode, Map<String, dynamic> body) {
    return Response(
      statusCode,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json'},
    );
  }
}
