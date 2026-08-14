import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../models/device_binding.dart';
import '../models/scan_record.dart';
import '../providers/scan_provider.dart';

/// 历史记录页面 - 卡号记录 / 设备绑定
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();
  List<ScanRecord> _filteredRecords = [];
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    context.read<ScanProvider>().loadRecords();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描记录'),
        centerTitle: true,
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '卡号记录'),
            Tab(text: '设备绑定'),
          ],
        ),
        actions: _tabController.index == 0 ? _buildCardActions() : _buildBindingActions(),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildCardsTab(),
          _buildBindingsTab(),
        ],
      ),
    );
  }

  // ==================== 卡号记录 Tab ====================

  List<Widget> _buildCardActions() {
    return [
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        onSelected: (value) => _handleMenuAction(value),
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'export_text',
            child: Row(
              children: [
                Icon(Icons.text_snippet),
                SizedBox(width: 12),
                Text('导出为文本'),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'export_csv',
            child: Row(
              children: [
                Icon(Icons.table_chart),
                SizedBox(width: 12),
                Text('导出为CSV'),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'save_local',
            child: Row(
              children: [
                Icon(Icons.save_alt),
                SizedBox(width: 12),
                Text('保存到本地'),
              ],
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'clear_all',
            child: Row(
              children: [
                Icon(Icons.delete_sweep, color: Colors.red),
                SizedBox(width: 12),
                Text('清空所有', style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ],
      ),
      IconButton(
        icon: const Icon(Icons.search),
        onPressed: () => _showSearch(),
      ),
    ];
  }

  Widget _buildCardsTab() {
    return Column(
      children: [
        // 统计信息
        Consumer<ScanProvider>(
          builder: (context, provider, child) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                border: Border(
                  bottom: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              child: Row(
                children: [
                  _buildStatChip('今日', provider.todayCount, Colors.blue),
                  const SizedBox(width: 16),
                  _buildStatChip('总计', provider.totalCount, Colors.green),
                  const Spacer(),
                  if (provider.records.isNotEmpty)
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('复制全部'),
                      onPressed: () => _copyAllRecords(provider),
                    ),
                ],
              ),
            );
          },
        ),

        // 搜索栏
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '搜索卡号...',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _filteredRecords = []);
                      },
                    )
                  : null,
            ),
            onChanged: (value) {
              _filterRecords(value);
            },
          ),
        ),

        // 记录列表
        Expanded(
          child: Consumer<ScanProvider>(
            builder: (context, provider, child) {
              if (provider.isLoading) {
                return const Center(child: CircularProgressIndicator());
              }

              final records = _searchController.text.isEmpty
                  ? provider.records
                  : _filteredRecords;

              if (records.isEmpty) {
                return _buildEmptyState(
                  icon: Icons.inbox_outlined,
                  title: '暂无记录',
                  subtitle: '点击下方扫描按钮开始',
                );
              }

              return ListView.builder(
                itemCount: records.length,
                itemBuilder: (context, index) {
                  final record = records[index];
                  return _RecordListTile(
                    record: record,
                    onDelete: () => _deleteRecord(context, record),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _handleMenuAction(String value) async {
    switch (value) {
      case 'export_text':
        await _exportAsText();
        break;
      case 'export_csv':
        await _exportAsCsv();
        break;
      case 'save_local':
        await _saveToLocal();
        break;
      case 'clear_all':
        await _confirmClearAll();
        break;
    }
  }

  void _filterRecords(String query) {
    if (query.isEmpty) {
      setState(() => _filteredRecords = []);
      return;
    }
    final provider = context.read<ScanProvider>();
    final filtered = provider.records
        .where((r) => r.cardNumber.contains(query))
        .toList();
    setState(() => _filteredRecords = filtered);
  }

  void _showSearch() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('搜索'),
        content: TextField(
          controller: _searchController,
          decoration: const InputDecoration(
            hintText: '输入卡号关键词',
          ),
        ),
        actions: [
          TextButton(
            child: const Text('取消'),
            onPressed: () => Navigator.pop(context),
          ),
          TextButton(
            child: const Text('搜索'),
            onPressed: () {
              Navigator.pop(context);
              _filterRecords(_searchController.text);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _deleteRecord(BuildContext context, ScanRecord record) async {
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除卡号 ${record.cardNumber} 吗？'),
        actions: [
          TextButton(
            child: const Text('取消'),
            onPressed: () => Navigator.pop(context, false),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context, true);
              context.read<ScanProvider>().deleteRecord(record.id!);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _copyAllRecords(ScanProvider provider) async {
    final records = provider.records;
    if (records.isEmpty) return;

    final text = records.map((r) => r.cardNumber).join('\n');
    await Clipboard.setData(ClipboardData(text: text));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制全部卡号到剪贴板'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _exportAsText() async {
    final provider = context.read<ScanProvider>();
    final text = await provider.exportToText();
    if (text != null && text.isNotEmpty && mounted) {
      await Share.share(text, subject: '流量卡扫描记录');
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有记录可导出')),
      );
    }
  }

  Future<void> _exportAsCsv() async {
    final provider = context.read<ScanProvider>();
    final csv = await provider.exportToCsv();
    if (csv != null && csv.isNotEmpty && mounted) {
      await Share.share(csv, subject: '流量卡扫描记录.csv');
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有记录可导出')),
      );
    }
  }

  Future<void> _saveToLocal() async {
    final provider = context.read<ScanProvider>();
    if (provider.records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有记录可保存')),
      );
      return;
    }

    await _writeFileToStorage(
      csvProvider: () => provider.exportToCsv(),
      fileNameBuilder: () =>
          '流量卡扫描_${_timestamp()}.csv',
      emptyMessage: '没有记录可保存',
    );
  }

  Future<void> _confirmClearAll() async {
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清空'),
        content: const Text('确定要清空所有卡号记录吗？此操作不可撤销。'),
        actions: [
          TextButton(
            child: const Text('取消'),
            onPressed: () => Navigator.pop(context, false),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context, true);
              context.read<ScanProvider>().deleteAllRecords();
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  // ==================== 设备绑定 Tab ====================

  List<Widget> _buildBindingActions() {
    return [
      PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        onSelected: (value) => _handleBindingAction(value),
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'export_csv',
            child: Row(
              children: [
                Icon(Icons.table_chart),
                SizedBox(width: 12),
                Text('导出为CSV'),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'save_local',
            child: Row(
              children: [
                Icon(Icons.save_alt),
                SizedBox(width: 12),
                Text('保存到本地'),
              ],
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'clear_all',
            child: Row(
              children: [
                Icon(Icons.delete_sweep, color: Colors.red),
                SizedBox(width: 12),
                Text('清空绑定', style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ],
      ),
    ];
  }

  Widget _buildBindingsTab() {
    return Column(
      children: [
        // 统计信息
        Consumer<ScanProvider>(
          builder: (context, provider, child) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                border: Border(
                  bottom: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              child: Row(
                children: [
                  _buildStatChip('已绑定', provider.bindingCount, Colors.green),
                  const SizedBox(width: 16),
                  _buildStatChip('设备', provider.bindings.length, Colors.blue),
                  const Spacer(),
                  if (provider.bindings.isNotEmpty)
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 18),
                      label: const Text('复制全部'),
                      onPressed: () => _copyAllBindings(provider),
                    ),
                ],
              ),
            );
          },
        ),

        // 绑定列表
        Expanded(
          child: Consumer<ScanProvider>(
            builder: (context, provider, child) {
              if (provider.isLoading) {
                return const Center(child: CircularProgressIndicator());
              }

              final bindings = provider.bindings;

              if (bindings.isEmpty) {
                return _buildEmptyState(
                  icon: Icons.link_off,
                  title: '暂无绑定',
                  subtitle: '在扫描页选择"绑定"模式，先扫设备二维码再扫流量卡',
                );
              }

              return ListView.builder(
                itemCount: bindings.length,
                itemBuilder: (context, index) {
                  final binding = bindings[index];
                  return _BindingListTile(
                    binding: binding,
                    onDelete: () => _deleteBinding(context, binding),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _handleBindingAction(String value) async {
    switch (value) {
      case 'export_csv':
        await _exportBindingsAsCsv();
        break;
      case 'save_local':
        await _saveBindingsToLocal();
        break;
      case 'clear_all':
        await _confirmClearBindings();
        break;
    }
  }

  Future<void> _exportBindingsAsCsv() async {
    final provider = context.read<ScanProvider>();
    final csv = await provider.exportBindingsToCsv();
    if (csv != null && csv.isNotEmpty && mounted) {
      await Share.share(csv, subject: '设备绑定记录.csv');
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有绑定记录可导出')),
      );
    }
  }

  Future<void> _saveBindingsToLocal() async {
    final provider = context.read<ScanProvider>();
    if (provider.bindings.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有绑定记录可保存')),
      );
      return;
    }

    await _writeFileToStorage(
      csvProvider: () => provider.exportBindingsToCsv(),
      fileNameBuilder: () => '设备绑定_${_timestamp()}.csv',
      emptyMessage: '没有绑定记录可保存',
    );
  }

  Future<void> _copyAllBindings(ScanProvider provider) async {
    final bindings = provider.bindings;
    if (bindings.isEmpty) return;

    final text = bindings
        .map((b) => '${b.deviceCode},${b.cardNumber}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制全部绑定到剪贴板'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _deleteBinding(BuildContext context, DeviceBinding binding) async {
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认解绑'),
        content: Text('确定要解绑设备 ${binding.deviceCode} 与流量卡 ${binding.cardNumber} 吗？'),
        actions: [
          TextButton(
            child: const Text('取消'),
            onPressed: () => Navigator.pop(context, false),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context, true);
              context.read<ScanProvider>().deleteBinding(binding.id!);
            },
            child: const Text('解绑'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearBindings() async {
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清空'),
        content: const Text('确定要清空所有设备绑定记录吗？此操作不可撤销。'),
        actions: [
          TextButton(
            child: const Text('取消'),
            onPressed: () => Navigator.pop(context, false),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context, true);
              context.read<ScanProvider>().deleteAllBindings();
            },
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }

  // ==================== 公共工具 ====================

  /// 写入 CSV 到外部存储
  Future<void> _writeFileToStorage({
    required Future<String?> Function() csvProvider,
    required String Function() fileNameBuilder,
    required String emptyMessage,
  }) async {
    try {
      final directory = await getExternalStorageDirectory();
      if (directory == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无法访问存储目录')),
          );
        }
        return;
      }

      final file = File('${directory.path}/${fileNameBuilder()}');
      final csv = await csvProvider();
      if (csv == null) return;

      await file.writeAsString(csv);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已保存到: ${file.path}'),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: '分享',
              onPressed: () async {
                await Share.shareXFiles([XFile(file.path)]);
              },
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('保存失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('保存失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _timestamp() {
    final now = DateTime.now();
    return '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildStatChip(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color.withValues(alpha: 0.8),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            count.toString(),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡号记录列表项
class _RecordListTile extends StatelessWidget {
  final ScanRecord record;
  final VoidCallback onDelete;

  const _RecordListTile({
    required this.record,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: Colors.blue.shade100,
        child: const Icon(
          Icons.sim_card,
          color: Colors.blue,
          size: 20,
        ),
      ),
      title: Text(
        record.cardNumber,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      subtitle: Text(record.formattedTime),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: record.cardNumber));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已复制到剪贴板'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除',
            color: Colors.red.shade400,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

/// 设备绑定列表项
class _BindingListTile extends StatelessWidget {
  final DeviceBinding binding;
  final VoidCallback onDelete;

  const _BindingListTile({
    required this.binding,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: Colors.green.shade100,
        child: const Icon(
          Icons.link,
          color: Colors.green,
          size: 20,
        ),
      ),
      title: Text(
        binding.deviceCode,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            binding.cardNumber,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'monospace',
              color: Colors.green,
              fontSize: 12,
            ),
          ),
          Text(
            binding.formattedTime,
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: '复制',
            onPressed: () {
              Clipboard.setData(ClipboardData(
                text: '设备码: ${binding.deviceCode}\n流量卡: ${binding.cardNumber}',
              ));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已复制到剪贴板'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '解绑',
            color: Colors.red.shade400,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
