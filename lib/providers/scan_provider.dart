import 'package:flutter/foundation.dart';
import '../models/device_binding.dart';
import '../models/scan_record.dart';
import '../services/database_service.dart';

/// 扫描状态管理
class ScanProvider extends ChangeNotifier {
  final DatabaseService _db = DatabaseService();
  
  List<ScanRecord> _records = [];
  List<DeviceBinding> _bindings = [];
  bool _isLoading = false;
  String? _error;
  int _todayCount = 0;
  int _totalCount = 0;
  int _bindingCount = 0;

  // Getters
  List<ScanRecord> get records => _records;
  List<DeviceBinding> get bindings => _bindings;
  bool get isLoading => _isLoading;
  String? get error => _error;
  int get todayCount => _todayCount;
  int get totalCount => _totalCount;
  int get bindingCount => _bindingCount;

  /// 加载所有记录
  Future<void> loadRecords() async {
    _isLoading = true;
    notifyListeners();

    try {
      _records = await _db.getAllRecords();
      _todayCount = await _db.getTodayCount();
      _totalCount = await _db.getTotalCount();
      _bindings = await _db.getAllBindings();
      _bindingCount = await _db.getBindingCount();
      _error = null;
    } catch (e) {
      _error = '加载记录失败: $e';
      debugPrint(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 添加新记录
  Future<bool> addRecord(ScanRecord record) async {
    try {
      final id = await _db.insertRecord(record);
      debugPrint('插入记录成功, ID: $id');
      await loadRecords(); // 刷新列表
      return true;
    } catch (e) {
      _error = '保存记录失败: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// 删除记录
  Future<bool> deleteRecord(int id) async {
    try {
      await _db.deleteRecord(id);
      await loadRecords();
      return true;
    } catch (e) {
      _error = '删除记录失败: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// 清空所有记录
  Future<bool> deleteAllRecords() async {
    try {
      await _db.deleteAllRecords();
      await loadRecords();
      return true;
    } catch (e) {
      _error = '清空记录失败: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// 新增或更新设备-卡绑定
  Future<BindingResult> addBinding(DeviceBinding binding) async {
    try {
      final result = await _db.upsertBinding(binding);
      await loadRecords();
      return result;
    } catch (e) {
      _error = '保存绑定失败: $e';
      debugPrint(_error);
      notifyListeners();
      return BindingResult.success;
    }
  }

  /// 删除单条绑定
  Future<bool> deleteBinding(int id) async {
    try {
      await _db.deleteBinding(id);
      await loadRecords();
      return true;
    } catch (e) {
      _error = '删除绑定失败: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// 清空所有绑定
  Future<bool> deleteAllBindings() async {
    try {
      await _db.deleteAllBindings();
      await loadRecords();
      return true;
    } catch (e) {
      _error = '清空绑定失败: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// 导出绑定数据为 CSV
  Future<String?> exportBindingsToCsv() async {
    try {
      return await _db.exportBindingsToCsv();
    } catch (e) {
      _error = '导出失败: $e';
      notifyListeners();
      return null;
    }
  }

  /// 更新记录备注
  Future<bool> updateNotes(int id, String notes) async {
    try {
      await _db.updateNotes(id, notes);
      await loadRecords();
      return true;
    } catch (e) {
      _error = '更新备注失败: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// 搜索记录
  Future<void> searchRecords(String keyword) async {
    if (keyword.isEmpty) {
      await loadRecords();
      return;
    }

    _isLoading = true;
    notifyListeners();

    try {
      _records = await _db.searchRecords(keyword);
    } catch (e) {
      _error = '搜索失败: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 导出为 CSV
  Future<String?> exportToCsv() async {
    try {
      return await _db.exportToCsv();
    } catch (e) {
      _error = '导出失败: $e';
      notifyListeners();
      return null;
    }
  }

  /// 导出为文本
  Future<String?> exportToText() async {
    try {
      return await _db.exportToText();
    } catch (e) {
      _error = '导出失败: $e';
      notifyListeners();
      return null;
    }
  }

  /// 清除错误
  void clearError() {
    _error = null;
    notifyListeners();
  }
}
