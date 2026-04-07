/// 扫描记录模型
class ScanRecord {
  final int? id;
  final String cardNumber;      // 卡号
  final String rawText;         // 原始识别文本
  final DateTime scannedAt;     // 扫描时间
  final String? notes;          // 备注

  ScanRecord({
    this.id,
    required this.cardNumber,
    required this.rawText,
    required this.scannedAt,
    this.notes,
  });

  /// 从数据库 Map 创建
  factory ScanRecord.fromMap(Map<String, dynamic> map) {
    return ScanRecord(
      id: map['id'] as int?,
      cardNumber: map['card_number'] as String,
      rawText: map['raw_text'] as String,
      scannedAt: DateTime.parse(map['scanned_at'] as String),
      notes: map['notes'] as String?,
    );
  }

  /// 转换为数据库 Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'card_number': cardNumber,
      'raw_text': rawText,
      'scanned_at': scannedAt.toIso8601String(),
      'notes': notes,
    };
  }

  /// 格式化显示时间
  String get formattedTime {
    final now = DateTime.now();
    final diff = now.difference(scannedAt);
    
    if (diff.inMinutes < 1) {
      return '刚刚';
    } else if (diff.inHours < 1) {
      return '${diff.inMinutes}分钟前';
    } else if (diff.inDays < 1) {
      return '${diff.inHours}小时前';
    } else {
      return '${scannedAt.month}/${scannedAt.day} ${scannedAt.hour}:${scannedAt.minute.toString().padLeft(2, '0')}';
    }
  }

  /// 复制并修改
  ScanRecord copyWith({
    int? id,
    String? cardNumber,
    String? rawText,
    DateTime? scannedAt,
    String? notes,
  }) {
    return ScanRecord(
      id: id ?? this.id,
      cardNumber: cardNumber ?? this.cardNumber,
      rawText: rawText ?? this.rawText,
      scannedAt: scannedAt ?? this.scannedAt,
      notes: notes ?? this.notes,
    );
  }

  @override
  String toString() => 'ScanRecord(id: $id, cardNumber: $cardNumber, scannedAt: $scannedAt)';
}
