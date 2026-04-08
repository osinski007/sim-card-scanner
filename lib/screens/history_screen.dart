import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/scan_record.dart';
import '../providers/scan_provider.dart';

/// 历史记录页面
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<ScanRecord> _filteredRecords = [];

  @override
  void initState() {
    super.initState();
    context.read<ScanProvider>().loadRecords();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描记录'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'export_text') {
                _exportAsText();
              } else if (value == 'export_csv') {
                _exportAsCsv();
              } else if (value == 'clear_all') {
                _confirmClearAll();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'export_text',
                child: Text('导出文本'),
              ),
              const PopupMenuItem(
                value: 'export_csv',
                child: Text('导出CSV'),
              ),
              const PopupMenuItem(
                value: 'clear_all',
                child: Text('清空所有'),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => _showSearch(),
          ),
        ],
      ),
      body: Column(
        children: [
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
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.inbox_outlined,
                          size: 64,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '暂无记录',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '点击下方扫描按钮开始',
                          style: TextStyle(
                            color: Colors.grey.shade400,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
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
      ),
    );
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

  void _deleteRecord(BuildContext context, ScanRecord record) async {
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
            child: const Text('删除'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context, true);
              context.read<ScanProvider>().deleteRecord(record.id!);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _exportAsText() async {
    final provider = context.read<ScanProvider>();
    final text = await provider.exportToText();
    if (text != null && mounted) {
      await Share.share(text, subject: '流量卡扫描记录');
    }
  }

  Future<void> _exportAsCsv() async {
    final provider = context.read<ScanProvider>();
    final csv = await provider.exportToCsv();
    if (csv != null && mounted) {
      await Share.share(csv, subject: '流量卡扫描记录.csv');
    }
  }

  Future<void> _confirmClearAll() async {
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认清空'),
        content: const Text('确定要清空所有记录吗？此操作不可撤销。'),
        actions: [
          TextButton(
            child: const Text('取消'),
            onPressed: () => Navigator.pop(context, false),
          ),
          TextButton(
            child: const Text('清空'),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(context, true);
              context.read<ScanProvider>().deleteAllRecords();
            },
          ),
        ],
      ),
    );
  }
}

/// 记录列表项
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
                const SnackBar(content: Text('已复制到剪贴板')),
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
