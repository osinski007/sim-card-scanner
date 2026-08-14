import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/device_binding.dart';
import '../models/scan_record.dart';

/// 绑定操作结果
enum BindingResult {
  success,    // 新绑定
  updated,    // 同设备重复绑定，已替换旧卡
  cardTaken,  // 卡已被其他设备绑定
}

/// 数据库服务 - 本地存储扫描记录
class DatabaseService {
  static Database? _database;
  static const String _tableName = 'scan_records';
  static const String _bindingTableName = 'device_bindings';

  /// 获取数据库实例
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// 初始化数据库
  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'sim_scanner.db');

    return await openDatabase(
      path,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// 创建表
  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_tableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        card_number TEXT NOT NULL,
        raw_text TEXT NOT NULL,
        scanned_at TEXT NOT NULL,
        notes TEXT
      )
    ''');

    // 创建索引加速查询
    await db.execute('''
      CREATE INDEX idx_scanned_at ON $_tableName(scanned_at DESC)
    ''');

    await db.execute('''
      CREATE TABLE $_bindingTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_code TEXT NOT NULL UNIQUE,
        card_number TEXT NOT NULL UNIQUE,
        bound_at TEXT NOT NULL,
        notes TEXT
      )
    ''');
  }

  /// 数据库升级
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_bindingTableName (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          device_code TEXT NOT NULL UNIQUE,
          card_number TEXT NOT NULL UNIQUE,
          bound_at TEXT NOT NULL,
          notes TEXT
        )
      ''');
    }
  }

  /// 插入扫描记录
  Future<int> insertRecord(ScanRecord record) async {
    final db = await database;
    final map = record.toMap();
    map.remove('id'); // 插入时移除 id，让数据库自动生成
    return await db.insert(_tableName, map);
  }

  /// 获取所有记录（按时间倒序）
  Future<List<ScanRecord>> getAllRecords() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      _tableName,
      orderBy: 'scanned_at DESC',
    );
    return maps.map((map) => ScanRecord.fromMap(map)).toList();
  }

  /// 获取今天的记录数
  Future<int> getTodayCount() async {
    final db = await database;
    final today = DateTime.now();
    final todayStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $_tableName WHERE date(scanned_at) = ?',
      [todayStr],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// 获取总记录数
  Future<int> getTotalCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM $_tableName');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// 删除单条记录
  Future<int> deleteRecord(int id) async {
    final db = await database;
    return await db.delete(
      _tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 清空所有记录
  Future<int> deleteAllRecords() async {
    final db = await database;
    return await db.delete(_tableName);
  }

  /// 更新记录备注
  Future<int> updateNotes(int id, String notes) async {
    final db = await database;
    return await db.update(
      _tableName,
      {'notes': notes},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 搜索记录
  Future<List<ScanRecord>> searchRecords(String keyword) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      _tableName,
      where: 'card_number LIKE ? OR notes LIKE ?',
      whereArgs: ['%$keyword%', '%$keyword%'],
      orderBy: 'scanned_at DESC',
    );
    return maps.map((map) => ScanRecord.fromMap(map)).toList();
  }

  /// 导出为 CSV 格式
  Future<String> exportToCsv() async {
    final records = await getAllRecords();
    final buffer = StringBuffer();
    
    // 添加 UTF-8 BOM，让 Excel 正确识别中文
    buffer.write('\ufeff');
    
    // CSV 头
    buffer.writeln('序号,卡号,扫描时间,备注');
    
    // 数据行
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      buffer.writeln([
        i + 1,
        '="${r.cardNumber}"',  // 用 ="xxx" 格式，Excel会当作文本
        r.scannedAt.toString(),
        r.notes ?? '',
      ].join(','));
    }
    
    return buffer.toString();
  }

  /// 导出为纯文本（每行一个卡号）
  Future<String> exportToText() async {
    final records = await getAllRecords();
    return records.map((r) => r.cardNumber).join('\n');
  }

  /// 新增或更新设备-卡绑定（一对一：设备重复绑定新卡则替换）
  Future<BindingResult> upsertBinding(DeviceBinding binding) async {
    final db = await database;

    // 卡号是否已被其他设备占用
    final cardRows = await db.query(
      _bindingTableName,
      where: 'card_number = ? AND device_code != ?',
      whereArgs: [binding.cardNumber, binding.deviceCode],
      limit: 1,
    );
    if (cardRows.isNotEmpty) {
      return BindingResult.cardTaken;
    }

    final map = binding.toMap();
    map.remove('id');

    // 设备是否已有绑定
    final deviceRows = await db.query(
      _bindingTableName,
      where: 'device_code = ?',
      whereArgs: [binding.deviceCode],
      limit: 1,
    );
    if (deviceRows.isNotEmpty) {
      await db.update(
        _bindingTableName,
        map,
        where: 'device_code = ?',
        whereArgs: [binding.deviceCode],
      );
      return BindingResult.updated;
    }

    await db.insert(_bindingTableName, map);
    return BindingResult.success;
  }

  /// 获取所有绑定（按时间倒序）
  Future<List<DeviceBinding>> getAllBindings() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      _bindingTableName,
      orderBy: 'bound_at DESC',
    );
    return maps.map((map) => DeviceBinding.fromMap(map)).toList();
  }

  /// 获取绑定总数
  Future<int> getBindingCount() async {
    final db = await database;
    final result =
        await db.rawQuery('SELECT COUNT(*) as count FROM $_bindingTableName');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// 删除单条绑定
  Future<int> deleteBinding(int id) async {
    final db = await database;
    return await db.delete(
      _bindingTableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 清空所有绑定
  Future<int> deleteAllBindings() async {
    final db = await database;
    return await db.delete(_bindingTableName);
  }

  /// 导出绑定数据为 CSV（Excel 兼容）
  Future<String> exportBindingsToCsv() async {
    final bindings = await getAllBindings();
    final buffer = StringBuffer();

    // 添加 UTF-8 BOM，让 Excel 正确识别中文
    buffer.write('\ufeff');

    // CSV 头
    buffer.writeln('序号,设备码,流量卡号,绑定时间,备注');

    for (var i = 0; i < bindings.length; i++) {
      final b = bindings[i];
      buffer.writeln([
        i + 1,
        _csvEscape(b.deviceCode),
        _csvEscape(b.cardNumber),
        b.boundAt.toString(),
        _csvEscape(b.notes ?? ''),
      ].join(','));
    }

    return buffer.toString();
  }

  /// CSV 字段转义
  String _csvEscape(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
