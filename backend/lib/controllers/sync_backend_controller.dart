import 'dart:convert';
import 'package:shelf/shelf.dart';
import '../middleware/auth_middleware.dart';
import '../models/idempotency_record.dart';
import '../models/loan_server_model.dart';
import '../repositories/idempotency_repository.dart';
import '../repositories/loan_backend_repository.dart';

class SyncBackendController {
  final LoanBackendRepository loanRepository;
  final IdempotencyRepository idempotencyRepository;

  SyncBackendController({
    required this.loanRepository,
    required this.idempotencyRepository,
  });

  /// POST /api/sync/push - Handle device -> server push operations
  Future<Response> handlePush(Request request) async {
    final authUser = getAuthUser(request);
    if (authUser == null) {
      return _jsonResponse(401, {'success': false, 'error': {'code': 'UNAUTHORIZED', 'message': 'Authentication required'}});
    }

    try {
      final bodyStr = await request.readAsString();
      if (bodyStr.isEmpty) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_BODY', 'message': 'Request body is empty'}});
      }

      final body = jsonDecode(bodyStr) as Map<String, dynamic>;
      final operationsRaw = body['operations'];
      if (operationsRaw is! List) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_FORMAT', 'message': 'Field operations must be an array'}});
      }

      final List<Map<String, dynamic>> results = [];
      final db = await loanRepository.database.db;

      for (final op in operationsRaw) {
        if (op is! Map<String, dynamic>) continue;

        final clientOpId = op['clientOperationId'] as String?;
        final entityType = op['entityType'] as String?;
        final entityId = op['entityId'] as String?;
        final operation = op['operation'] as String?;
        final payload = op['payload'] is Map<String, dynamic>
            ? op['payload'] as Map<String, dynamic>
            : <String, dynamic>{};

        final originDeviceId = op['deviceId'] as String? ?? payload['deviceId'] as String?;
        final opBaseVersion = op['baseVersion'] as int? ?? payload['baseVersion'] as int?;

        if (clientOpId == null || clientOpId.isEmpty || entityType == null || operation == null || entityId == null) {
          results.add({
            'clientOperationId': clientOpId ?? 'UNKNOWN',
            'entityId': entityId ?? 'UNKNOWN',
            'status': 'FAILED',
            'message': 'Missing required operation fields',
          });
          continue;
        }

        // 1. Idempotency Check
        final existingRecord = await idempotencyRepository.findByClientOperationId(clientOpId);
        if (existingRecord != null) {
          results.add({
            'clientOperationId': clientOpId,
            'entityId': entityId,
            'status': 'SYNCED',
            'message': 'Idempotent replay: already processed',
          });
          continue;
        }

        // 2. Process Operation Transactionally
        String status = 'SYNCED';
        String message = 'Operation applied successfully';
        Map<String, dynamic>? serverState;

        try {
          await db.transaction((txn) async {
            if (entityType == 'loan') {
              if (operation == 'CREATE') {
                final amount = (payload['amount'] as num?)?.toDouble() ?? 0.0;
                final tenureMonths = (payload['tenureMonths'] as int?) ?? 12;
                final purpose = (payload['purpose'] as String?) ?? 'Loan';
                final priority = (payload['priority'] as String?) ?? 'medium';
                final userName = (payload['userName'] as String?) ?? 'Customer';

                final targetUserId = payload['userId'] as String? ?? authUser.userId;
                if (authUser.role != 'ADMIN' && targetUserId != authUser.userId) {
                  status = 'CONFLICT';
                  message = 'Forbidden: Cannot create loan for another user';
                  return;
                }

                final newLoan = LoanServerModel(
                  id: entityId,
                  userId: authUser.userId,
                  userName: userName,
                  amount: amount,
                  tenureMonths: tenureMonths,
                  purpose: purpose,
                  priority: priority,
                  status: 'pending',
                  deviceId: originDeviceId,
                  version: 1,
                  createdAt: DateTime.now(),
                  updatedAt: DateTime.now(),
                );

                await txn.insert('loans', newLoan.toSqlMap());
              } else if (operation == 'UPDATE') {
                final List<Map<String, dynamic>> existingList = await txn.query(
                  'loans',
                  where: 'id = ?',
                  whereArgs: [entityId],
                );

                if (existingList.isEmpty) {
                  status = 'FAILED';
                  message = 'Loan not found on server';
                  return;
                }

                final existingLoan = LoanServerModel.fromSqlMap(existingList.first);
                serverState = existingLoan.toJson();

                if (authUser.role != 'ADMIN') {
                  if (existingLoan.userId != authUser.userId) {
                    status = 'CONFLICT';
                    message = 'Forbidden: Access to this loan is denied';
                    return;
                  }

                  if (payload.containsKey('status')) {
                    status = 'CONFLICT';
                    message = 'Forbidden: Customers cannot modify loan status';
                    return;
                  }

                  if (existingLoan.status != 'pending') {
                    status = 'CONFLICT';
                    message = 'Conflict: Cannot edit loan after admin decision';
                    return;
                  }

                  if (opBaseVersion != null && opBaseVersion < existingLoan.version) {
                    status = 'CONFLICT';
                    message = 'Stale mutation: baseVersion ($opBaseVersion) is behind server version (${existingLoan.version})';
                    return;
                  }
                }

                final updatedStatus = authUser.role == 'ADMIN' && payload.containsKey('status')
                    ? payload['status'] as String
                    : existingLoan.status;

                await txn.update(
                  'loans',
                  {
                    if (payload.containsKey('amount')) 'amount': (payload['amount'] as num).toDouble(),
                    if (payload.containsKey('tenureMonths')) 'tenureMonths': payload['tenureMonths'],
                    if (payload.containsKey('purpose')) 'purpose': payload['purpose'],
                    if (payload.containsKey('priority')) 'priority': payload['priority'],
                    'status': updatedStatus,
                    'version': existingLoan.version + 1,
                    'updatedAt': DateTime.now().toIso8601String(),
                  },
                  where: 'id = ?',
                  whereArgs: [entityId],
                );
              } else if (operation == 'DELETE') {
                await txn.delete('loans', where: 'id = ?', whereArgs: [entityId]);
              }
            } else if (entityType == 'loan_activity') {
              await txn.insert('loan_activities', {
                'id': entityId,
                'loanId': payload['loanId'] ?? 'UNKNOWN',
                'userId': payload['userId'] ?? authUser.userId,
                'userName': payload['userName'] ?? 'User',
                'type': payload['type'] ?? 'system',
                'message': payload['message'] ?? '',
                'createdAt': payload['createdAt'] ?? DateTime.now().toIso8601String(),
              });
            } else if (entityType == 'notification') {
              if (operation == 'CREATE') {
                await txn.insert('notifications', {
                  'id': entityId,
                  'userId': payload['userId'] ?? authUser.userId,
                  'title': payload['title'] ?? '',
                  'message': payload['message'] ?? '',
                  'type': payload['type'] ?? 'system',
                  'loanId': payload['loanId'],
                  'createdAt': payload['createdAt'] ?? DateTime.now().toIso8601String(),
                  'isRead': (payload['isRead'] == true) ? 1 : 0,
                });
              } else if (operation == 'UPDATE') {
                if (payload.containsKey('isRead')) {
                  await txn.update(
                    'notifications',
                    {'isRead': (payload['isRead'] == true) ? 1 : 0},
                    where: 'id = ?',
                    whereArgs: [entityId],
                  );
                }
              } else if (operation == 'DELETE') {
                await txn.delete('notifications', where: 'id = ?', whereArgs: [entityId]);
              }
            }

            // Record Idempotency Record
            await txn.insert('idempotency_records', IdempotencyRecord(
              clientOperationId: clientOpId,
              entityId: entityId,
              operationType: '$entityType-$operation',
              responseCode: 200,
              responsePayload: jsonEncode({
                'status': status,
                'message': message,
                if (serverState != null) 'serverState': serverState,
              }),
              createdAt: DateTime.now(),
            ).toSqlMap());

            // Record Sync Change Log (with originDeviceId)
            if (status == 'SYNCED') {
              await txn.insert('sync_changes', {
                'entityType': entityType,
                'entityId': entityId,
                'operation': operation,
                'payload': jsonEncode(payload),
                'userId': authUser.userId,
                'originDeviceId': originDeviceId,
                'createdAt': DateTime.now().toIso8601String(),
              });
            }
          });
        } catch (e) {
          status = 'FAILED';
          message = e.toString();
        }

        results.add({
          'clientOperationId': clientOpId,
          'entityId': entityId,
          'status': status,
          'message': message,
          if (serverState != null) 'serverState': serverState,
        });
      }

      return _jsonResponse(200, {
        'success': true,
        'results': results,
      });
    } catch (e) {
      return _jsonResponse(500, {'success': false, 'error': {'code': 'SERVER_ERROR', 'message': e.toString()}});
    }
  }

  /// GET /api/sync/pull?since=<version>&limit=<limit>&deviceId=<deviceId>
  Future<Response> handlePull(Request request) async {
    final authUser = getAuthUser(request);
    if (authUser == null) {
      return _jsonResponse(401, {'success': false, 'error': {'code': 'UNAUTHORIZED', 'message': 'Authentication required'}});
    }

    try {
      final sinceStr = request.url.queryParameters['since'] ?? '0';
      final limitStr = request.url.queryParameters['limit'] ?? '50';

      final sinceVersion = int.tryParse(sinceStr);
      if (sinceVersion == null || sinceVersion < 0) {
        return _jsonResponse(400, {'success': false, 'error': {'code': 'INVALID_CURSOR', 'message': 'Query parameter since must be a non-negative integer'}});
      }

      var limit = int.tryParse(limitStr) ?? 50;
      if (limit <= 0) limit = 50;
      if (limit > 100) limit = 100;

      final db = await loanRepository.database.db;

      final List<Map<String, dynamic>> rawRows;
      if (authUser.role == 'ADMIN') {
        rawRows = await db.query(
          'sync_changes',
          where: 'serverVersion > ?',
          whereArgs: [sinceVersion],
          orderBy: 'serverVersion ASC',
          limit: limit + 1,
        );
      } else {
        rawRows = await db.query(
          'sync_changes',
          where: 'serverVersion > ? AND userId = ?',
          whereArgs: [sinceVersion, authUser.userId],
          orderBy: 'serverVersion ASC',
          limit: limit + 1,
        );
      }

      final hasMore = rawRows.length > limit;
      final itemsToReturn = hasMore ? rawRows.take(limit).toList() : rawRows;

      final List<Map<String, dynamic>> changes = itemsToReturn.map((r) {
        return {
          'serverVersion': r['serverVersion'],
          'entityType': r['entityType'],
          'entityId': r['entityId'],
          'operation': r['operation'],
          'payload': jsonDecode(r['payload'] as String),
          'userId': r['userId'],
          'originDeviceId': r['originDeviceId'],
          'createdAt': r['createdAt'],
        };
      }).toList();

      final nextVersion = changes.isNotEmpty
          ? (changes.last['serverVersion'] as int)
          : sinceVersion;

      return _jsonResponse(200, {
        'success': true,
        'changes': changes,
        'nextVersion': nextVersion,
        'hasMore': hasMore,
      });
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
