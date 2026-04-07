import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/scan_record.dart';

/// 数据库服务 - 本地存储扫描记录
class DatabaseService {
  static Database? _database;
  static const String _tableName = 'scan_records';

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
      version: 1,
      onCreate: _onCreate,
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
    
    // CSV 头
    buffer.writeln('序号,卡号,扫描时间,备注');
    
    // 数据行
    for (var i = 0; i < records.length; i++) {
      final r = records[i];
      buffer.writeln([
        i + 1,
        r.cardNumber,
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
}
