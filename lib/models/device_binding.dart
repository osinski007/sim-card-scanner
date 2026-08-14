/// 设备-流量卡绑定记录模型
class DeviceBinding {
  final int? id;
  final String deviceCode;   // 设备二维码内容
  final String cardNumber;   // 流量卡条形码内容
  final DateTime boundAt;    // 绑定时间
  final String? notes;       // 备注

  DeviceBinding({
    this.id,
    required this.deviceCode,
    required this.cardNumber,
    required this.boundAt,
    this.notes,
  });

  /// 从数据库 Map 创建
  factory DeviceBinding.fromMap(Map<String, dynamic> map) {
    return DeviceBinding(
      id: map['id'] as int?,
      deviceCode: map['device_code'] as String,
      cardNumber: map['card_number'] as String,
      boundAt: DateTime.parse(map['bound_at'] as String),
      notes: map['notes'] as String?,
    );
  }

  /// 转换为数据库 Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'device_code': deviceCode,
      'card_number': cardNumber,
      'bound_at': boundAt.toIso8601String(),
      'notes': notes,
    };
  }

  /// 格式化显示时间
  String get formattedTime {
    final now = DateTime.now();
    final diff = now.difference(boundAt);

    if (diff.inMinutes < 1) {
      return '刚刚';
    } else if (diff.inHours < 1) {
      return '${diff.inMinutes}分钟前';
    } else if (diff.inDays < 1) {
      return '${diff.inHours}小时前';
    } else {
      return '${boundAt.month}/${boundAt.day} ${boundAt.hour}:${boundAt.minute.toString().padLeft(2, '0')}';
    }
  }

  @override
  String toString() =>
      'DeviceBinding(id: $id, deviceCode: $deviceCode, cardNumber: $cardNumber)';
}
