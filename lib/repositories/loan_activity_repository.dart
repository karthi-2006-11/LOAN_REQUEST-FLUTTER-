import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/loan_activity_model.dart';

abstract class LoanActivityRepository {
  Future<LoanActivityModel> addActivity(LoanActivityModel activity);
  Future<List<LoanActivityModel>> getLoanActivities(String loanId);
  Future<List<LoanActivityModel>> getUserActivities(String userId);
  Future<List<LoanActivityModel>> getAllActivities();
}

class LocalLoanActivityRepository implements LoanActivityRepository {
  static const String _activitiesKey = 'key_loan_activity_data_v1';

  Future<List<LoanActivityModel>> _getAllActivitiesFromStorage() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_activitiesKey);
    if (jsonString == null || jsonString.isEmpty) {
      return [];
    }

    try {
      final List<dynamic> jsonList = jsonDecode(jsonString);
      return jsonList
          .map((item) => LoanActivityModel.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> _saveActivitiesToStorage(List<LoanActivityModel> activities) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = activities.map((a) => a.toJson()).toList();
    return await prefs.setString(_activitiesKey, jsonEncode(jsonList));
  }

  @override
  Future<LoanActivityModel> addActivity(LoanActivityModel activity) async {
    final activities = await _getAllActivitiesFromStorage();
    activities.insert(0, activity);
    await _saveActivitiesToStorage(activities);
    return activity;
  }

  @override
  Future<List<LoanActivityModel>> getLoanActivities(String loanId) async {
    final activities = await _getAllActivitiesFromStorage();
    return activities.where((a) => a.loanId == loanId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt)); // Chronological order
  }

  @override
  Future<List<LoanActivityModel>> getUserActivities(String userId) async {
    final activities = await _getAllActivitiesFromStorage();
    return activities.where((a) => a.userId == userId).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<List<LoanActivityModel>> getAllActivities() async {
    final activities = await _getAllActivitiesFromStorage();
    return activities..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }
}
