import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'demos/getting_started_demo.dart';
import 'pages/altar_setup_page.dart';

void main() {
  runApp(const FamilyTreeApp());
}

class FamilyTreeApp extends StatelessWidget {
  const FamilyTreeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Phả Tộc',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A3A52),
          brightness: Brightness.light,
        ),
      ),
      home: const FamilyTreePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ============ Constants ============
const Color primaryNavyColor = Color(0xFF1A3A52);
const Color darkTextColor = Color(0xFF1F2937);
const Color mutedTextColor = Color(0xFF6B7280);
const Color lightBorderColor = Color(0xFFE5E7EB);
const Color lightBackgroundColor = Color(0xFFFAFAFA);
const Color highlightPinkColor = Color(0xFFFFE5EC);
const Color iconGrayColor = Color(0xFF9CA3AF);

// ============ Model ============
class FamilyMember {
  final int id;
  final String name;
  final String code;
  final String parentCode;
  final String? gender; // 'M', 'F', or null
  final String? imageUrl;
  final String branchKey;
  final int generation;
  final int childCount;
  final String? fatherName;
  final String? motherName;
  final bool isHighlight;

  FamilyMember({
    required this.id,
    required this.name,
    required this.code,
    required this.parentCode,
    this.gender,
    this.imageUrl,
    required this.branchKey,
    required this.generation,
    required this.childCount,
    this.fatherName,
    this.motherName,
    this.isHighlight = false,
  });
}

// ============ Main Page ============
class FamilyTreePage extends StatefulWidget {
  const FamilyTreePage({super.key});

  @override
  State<FamilyTreePage> createState() => _FamilyTreePageState();
}

class _FamilyTreePageState extends State<FamilyTreePage> {
  int selectedMemberId = -1;
  bool _isLoading = true;
  String? _sourceJson;
  bool _isListExpanded = false;

  final List<FamilyMember> members = <FamilyMember>[];

  @override
  void initState() {
    super.initState();
    _loadMembersFromJson();
  }

  @override
  Widget build(BuildContext context) {
    final bool isMobile = MediaQuery.sizeOf(context).width < 700;
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: Column(
          children: [
            // ========== Header Section ==========
            _buildHeaderSection(),

            if (!_isListExpanded) ...[
              // ========== Quick Actions Section ==========
              _buildQuickActionsSection(),

              // ========== Category Selector ==========
              _buildCategorySelector(),
            ],

            // ========== Members Table Section ==========
            Expanded(
              child: _buildMembersTable(
                expandedMode: _isListExpanded && isMobile,
              ),
            ),
          ],
        ),
      ),
    );
  }

  FamilyMember? get _selectedMember {
    if (selectedMemberId < 0) return null;
    for (final FamilyMember member in members) {
      if (member.id == selectedMemberId) return member;
    }
    return null;
  }

  List<_MemberListRow> _buildGroupedRows() {
    if (members.isEmpty) {
      return const <_MemberListRow>[];
    }
    final Map<int, int> generationCounts = <int, int>{};
    for (final FamilyMember member in members) {
      generationCounts[member.generation] =
          (generationCounts[member.generation] ?? 0) + 1;
    }
    final Map<int, Map<String, int>> branchOrderByGeneration =
        <int, Map<String, int>>{};
    for (final FamilyMember member in members) {
      final map = branchOrderByGeneration.putIfAbsent(
        member.generation,
        () => <String, int>{},
      );
      map.putIfAbsent(member.branchKey, () => map.length + 1);
    }

    final List<_MemberListRow> rows = <_MemberListRow>[];
    int? currentGeneration;
    int displayIndex = 0;
    for (final FamilyMember member in members) {
      if (currentGeneration != member.generation) {
        currentGeneration = member.generation;
        final branchMap =
            branchOrderByGeneration[currentGeneration] ?? const <String, int>{};
        rows.add(
          _MemberListRow.header(
            generation: currentGeneration,
            generationCount: generationCounts[currentGeneration] ?? 0,
            generationBranchCount: branchMap.length,
          ),
        );
      }
      displayIndex += 1;
      final int chiIndex =
          branchOrderByGeneration[member.generation]?[member.branchKey] ?? 0;
      rows.add(
        _MemberListRow.member(
          member,
          displayIndex: displayIndex,
          chiIndex: chiIndex,
        ),
      );
    }
    return rows;
  }

  Future<void> _loadMembersFromJson() async {
    setState(() => _isLoading = true);
    const paths = <String>[
      'testnode - Copy.json',
      'assets/testnode - Copy.json',
    ];
    String? jsonText;
    for (final path in paths) {
      try {
        jsonText = await rootBundle.loadString(path);
        break;
      } catch (_) {}
    }

    if (!mounted) return;
    if (jsonText == null) {
      setState(() {
        _isLoading = false;
        members.clear();
        selectedMemberId = -1;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Không đọc được file JSON dữ liệu gia phả.'),
        ),
      );
      return;
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (_) {
      setState(() {
        _isLoading = false;
        members.clear();
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('File JSON không hợp lệ.')));
      return;
    }

    final List<Map<String, dynamic>> rawNodes = <Map<String, dynamic>>[];
    void flatten(dynamic raw) {
      if (raw is! Map) return;
      final map = Map<String, dynamic>.from(raw);
      rawNodes.add(map);
      final children = map['Children'];
      if (children is List) {
        for (final child in children) {
          flatten(child);
        }
      }
    }

    if (decoded is List) {
      for (final item in decoded) {
        flatten(item);
      }
    } else if (decoded is Map) {
      final rootMap = Map<String, dynamic>.from(decoded);
      final list =
          rootMap['data'] ??
          rootMap['people'] ??
          rootMap['members'] ??
          rootMap['nodes'];
      if (list is List) {
        for (final item in list) {
          flatten(item);
        }
      }
    }

    final Map<String, Map<String, dynamic>> byCode = {
      for (final node in rawNodes)
        if ((node['NodeCode'] ?? '').toString().trim().isNotEmpty)
          (node['NodeCode']).toString().trim(): node,
    };
    final Map<String, String> parentByCode = {
      for (final entry in byCode.entries)
        entry.key: (entry.value['Parent'] ?? '').toString().trim(),
    };
    final Map<String, int> levelByCode = {
      for (final entry in byCode.entries)
        entry.key: int.tryParse((entry.value['Level'] ?? '1').toString()) ?? 1,
    };

    final List<FamilyMember> loaded = <FamilyMember>[];
    var index = 1;
    for (final node in rawNodes) {
      final String code = (node['NodeCode'] ?? '').toString().trim();
      if (code.isEmpty) continue;
      final String parentCode = (node['Parent'] ?? '').toString().trim();
      final String motherCode = (node['MotherID'] ?? '').toString().trim();
      final String fatherName = parentCode.isEmpty
          ? ''
          : (byCode[parentCode]?['FullName'] ?? '').toString().trim();
      final String motherName = motherCode.isEmpty
          ? ''
          : (byCode[motherCode]?['FullName'] ?? '').toString().trim();
      final int generation =
          int.tryParse((node['Level'] ?? '1').toString()) ?? 1;
      final List children = (node['Children'] is List)
          ? node['Children'] as List
          : const [];

      loaded.add(
        FamilyMember(
          id: index++,
          name: (node['FullName'] ?? code).toString(),
          code: code,
          parentCode: parentCode,
          gender: _normalizeGender((node['Sex'] ?? '').toString()),
          imageUrl: (node['Image'] ?? '').toString().trim().isEmpty
              ? null
              : (node['Image'] ?? '').toString().trim(),
          branchKey: _resolveBranchKey(
            code,
            parentByCode: parentByCode,
            levelByCode: levelByCode,
          ),
          generation: generation,
          childCount: children.length,
          fatherName: fatherName.isEmpty ? null : fatherName,
          motherName: motherName.isEmpty ? null : motherName,
          isHighlight:
              (node['Sex'] ?? '').toString().trim().toLowerCase() == 'nữ',
        ),
      );
    }

    loaded.sort((a, b) {
      final gen = a.generation.compareTo(b.generation);
      if (gen != 0) return gen;
      return a.code.compareTo(b.code);
    });

    setState(() {
      _sourceJson = jsonText;
      _isLoading = false;
      members
        ..clear()
        ..addAll(loaded);
      selectedMemberId = members.isEmpty ? -1 : members.first.id;
    });
  }

  String? _normalizeGender(String raw) {
    final text = raw.trim().toLowerCase();
    if (text == 'nam' || text == 'male' || text == 'm') return 'M';
    if (text == 'nữ' || text == 'nu' || text == 'female' || text == 'f') {
      return 'F';
    }
    return null;
  }

  String _resolveBranchKey(
    String code, {
    required Map<String, String> parentByCode,
    required Map<String, int> levelByCode,
  }) {
    String current = code;
    final Set<String> visited = <String>{current};
    while (true) {
      final String parent = (parentByCode[current] ?? '').trim();
      if (parent.isEmpty) {
        return current;
      }
      final int parentLevel = levelByCode[parent] ?? 1;
      if (parentLevel <= 1) {
        return current;
      }
      if (!visited.add(parent)) {
        return current;
      }
      current = parent;
    }
  }

  void _openSoDo() {
    final source = _sourceJson;
    if (source == null || source.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chưa có dữ liệu JSON để mở Sơ đồ.')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GettingStartedDemoPage(initialJsonText: source),
      ),
    );
  }

  Future<void> _openAltarSetup() async {
    final FamilyMember? member = _selectedMember;
    if (member == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hay chon 1 node thanh vien truoc.')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AltarSetupPage(
          memberKey: member.id.toString(),
          memberName: member.name,
        ),
      ),
    );
  }

  Future<void> _showNodeActions(FamilyMember member) async {
    setState(() {
      selectedMemberId = member.id;
    });
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.temple_buddhist_outlined),
                title: const Text('Lập bàn thờ'),
                subtitle: Text('Thiết lập cho ${member.name}'),
                onTap: () => Navigator.of(context).pop('altar_setup'),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Xem thông tin'),
                onTap: () => Navigator.of(context).pop('info'),
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('Đóng'),
                onTap: () => Navigator.of(context).pop('close'),
              ),
            ],
          ),
        );
      },
    );

    if (!mounted) return;
    if (action == 'altar_setup') {
      await _openAltarSetup();
    }
  }

  // Header với back button, tiêu đề, và 3 action buttons trên cùng hàng
  Widget _buildHeaderSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // Back button
          Container(
            decoration: BoxDecoration(
              color: lightBackgroundColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new),
              onPressed: () => Navigator.pop(context),
              iconSize: 18,
              color: darkTextColor,
              padding: const EdgeInsets.all(10),
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            ),
          ),
          const SizedBox(width: 12),
          // Title
          Text(
            'Phả tộc',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: darkTextColor,
              letterSpacing: -0.5,
            ),
          ),
          const Spacer(),
          // Action items (3 buttons) - aligned to right
          _buildTopActionItem(icon: Icons.print, label: 'In'),
          _buildTopActionItem(icon: Icons.info_outline, label: 'Thông tin'),
          _buildTopActionItem(icon: Icons.add_circle_outline, label: 'Thêm'),
        ],
      ),
    );
  }

  // Widget cho từng action item ở header - compact để fit cùng hàng
  Widget _buildTopActionItem({required IconData icon, required String label}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: GestureDetector(
        onTap: () {
          // Action handler
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: lightBackgroundColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: primaryNavyColor),
              const SizedBox(height: 2),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 7.5,
                  fontWeight: FontWeight.w600,
                  color: mutedTextColor,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 2 hàng quick actions (8 items total)
  Widget _buildQuickActionsSection() {
    final quickActions = [
      ('Audio book', Icons.headphones),
      ('Tư liệu', Icons.description),
      ('Nhà thờ', Icons.apartment),
      ('AI', Icons.smart_toy),
      ('Sơ đồ', Icons.account_tree_outlined),
      ('Ghép', Icons.merge_type),
      ('Thành viên', Icons.people),
      ('Sách', Icons.book),
    ];

    return Container(
      color: const Color(0xFFF8F9FA),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Column(
        children: [
          // Row 1 (items 0-3)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(
              4,
              (index) => _buildQuickActionItem(
                label: quickActions[index].$1,
                icon: quickActions[index].$2,
                onTap: quickActions[index].$1 == 'Sơ đồ' ? _openSoDo : null,
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Row 2 (items 4-7)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(
              4,
              (index) => _buildQuickActionItem(
                label: quickActions[index + 4].$1,
                icon: quickActions[index + 4].$2,
                onTap: quickActions[index + 4].$1 == 'Sơ đồ' ? _openSoDo : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Widget cho từng quick action
  Widget _buildQuickActionItem({
    required String label,
    required IconData icon,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ],
              border: Border.all(color: lightBorderColor, width: 0.5),
            ),
            child: Icon(icon, size: 32, color: primaryNavyColor),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: darkTextColor,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // Category selector card
  Widget _buildCategorySelector() {
    final FamilyMember? selected = _selectedMember;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: lightBorderColor, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _isLoading
                  ? 'Đang tải dữ liệu gia phả...'
                  : selected == null
                  ? 'Chua chon node thanh vien'
                  : '${selected.name} (${selected.code})',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: darkTextColor,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.temple_buddhist_outlined),
            tooltip: 'Lap ban tho',
            onPressed: _isLoading ? null : _openAltarSetup,
            iconSize: 18,
            color: mutedTextColor,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          IconButton(
            icon: Icon(
              _isListExpanded ? Icons.fullscreen_exit : Icons.fullscreen,
            ),
            onPressed: _isLoading
                ? null
                : () => setState(() => _isListExpanded = !_isListExpanded),
            iconSize: 18,
            color: mutedTextColor,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ],
      ),
    );
  }

  // Members table (header + list)
  Widget _buildMembersTable({required bool expandedMode}) {
    final List<_MemberListRow> rows = _buildGroupedRows();
    return Container(
      margin: expandedMode
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: expandedMode
            ? BorderRadius.zero
            : BorderRadius.circular(12),
        border: Border.all(color: lightBorderColor, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Table header bar
          _buildTableHeaderBar(expandedMode: expandedMode),
          const Divider(height: 1, color: lightBorderColor),

          // Column headers
          _buildTableColumnHeaders(),
          const Divider(height: 1, color: lightBorderColor),

          // Members list
          Expanded(
            child: ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (context, index) =>
                  const Divider(height: 1, color: lightBorderColor),
              itemBuilder: (context, index) {
                final row = rows[index];
                if (row.isHeader) {
                  return _buildGenerationHeaderRow(
                    generation: row.generation!,
                    generationCount: row.generationCount!,
                    generationBranchCount: row.generationBranchCount!,
                  );
                }
                final member = row.member!;
                return _buildMemberRow(
                  member: member,
                  displayIndex: row.displayIndex!,
                  chiIndex: row.chiIndex!,
                  isSelected: selectedMemberId == member.id,
                  onTap: () {
                    setState(() {
                      selectedMemberId = member.id;
                    });
                  },
                  onLongPress: () => _showNodeActions(member),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenerationHeaderRow({
    required int generation,
    required int generationCount,
    required int generationBranchCount,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      color: const Color(0xFFF1F5F9),
      child: Row(
        children: <Widget>[
          Icon(Icons.account_tree_outlined, size: 14, color: primaryNavyColor),
          const SizedBox(width: 6),
          Text(
            'Đời $generation',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: darkTextColor,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '($generationCount người - $generationBranchCount chi)',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: mutedTextColor,
            ),
          ),
        ],
      ),
    );
  }

  // Table header bar với "Tổng: 532" và icons
  Widget _buildTableHeaderBar({required bool expandedMode}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: Colors.white,
      child: Row(
        children: [
          Text(
            'Tổng: ${members.length}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: darkTextColor,
            ),
          ),
          const Spacer(),
          Container(
            decoration: BoxDecoration(
              color: lightBackgroundColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadMembersFromJson,
                  iconSize: 16,
                  color: mutedTextColor,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
                Container(width: 1, height: 20, color: lightBorderColor),
                IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {},
                  iconSize: 16,
                  color: mutedTextColor,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
                Container(width: 1, height: 20, color: lightBorderColor),
                IconButton(
                  icon: const Icon(Icons.filter_list),
                  onPressed: () {},
                  iconSize: 16,
                  color: mutedTextColor,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
                Container(width: 1, height: 20, color: lightBorderColor),
                IconButton(
                  icon: Icon(
                    expandedMode ? Icons.fullscreen_exit : Icons.fullscreen,
                  ),
                  tooltip: expandedMode
                      ? 'Thu gọn danh sách'
                      : 'Mở rộng danh sách',
                  onPressed: () =>
                      setState(() => _isListExpanded = !_isListExpanded),
                  iconSize: 16,
                  color: mutedTextColor,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Table column headers
  Widget _buildTableColumnHeaders() {
    return Container(
      color: Color(0xFFF8F9FA),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 35,
            child: Text(
              'STT',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: mutedTextColor,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              'Tên & Mã',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: mutedTextColor,
                letterSpacing: 0.3,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              'Đời',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: mutedTextColor,
                letterSpacing: 0.3,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              'Chi',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: mutedTextColor,
                letterSpacing: 0.3,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  // Individual member row
  Widget _buildMemberRow({
    required FamilyMember member,
    required int displayIndex,
    required int chiIndex,
    required bool isSelected,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
    final Color avatarColor = member.gender == 'M'
        ? Colors.blue.shade200
        : member.gender == 'F'
        ? Colors.pink.shade200
        : Colors.grey.shade200;
    final String avatarUrl = (member.imageUrl ?? '').trim();
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: member.isHighlight
              ? highlightPinkColor
              : isSelected
              ? Colors.blue.shade50
              : Colors.white,
          border: Border(
            bottom: BorderSide(color: lightBorderColor, width: 0.5),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // STT
            SizedBox(
              width: 35,
              child: Text(
                '$displayIndex',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: mutedTextColor,
                ),
              ),
            ),

            // Tên & Mã (with avatar)
            Expanded(
              flex: 2,
              child: Row(
                children: [
                  // Avatar
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: avatarColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: avatarUrl.isNotEmpty
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              avatarUrl,
                              width: 36,
                              height: 36,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  _buildGenderFallbackAvatar(
                                    member,
                                    avatarColor,
                                  ),
                            ),
                          )
                        : _buildGenderFallbackAvatar(member, avatarColor),
                  ),
                  const SizedBox(width: 10),

                  // Name, code, parent info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          member.name,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: darkTextColor,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '[${member.code}]',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w400,
                            color: mutedTextColor,
                          ),
                        ),
                        if (member.fatherName != null)
                          Text(
                            '[Cha: ${member.fatherName}]',
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w400,
                              color: mutedTextColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (member.motherName != null)
                          Text(
                            '[Mẹ: ${member.motherName}]',
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w400,
                              color: mutedTextColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Đời (generation with icon)
            SizedBox(
              width: 40,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                decoration: BoxDecoration(
                  color: lightBackgroundColor,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: lightBorderColor, width: 0.5),
                ),
                child: Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.account_tree, size: 13, color: mutedTextColor),
                      const SizedBox(width: 2),
                      Text(
                        '${member.generation}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: darkTextColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Chi (branch index inside generation)
            SizedBox(
              width: 40,
              child: Center(
                child: Text(
                  '$chiIndex',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: primaryNavyColor,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGenderFallbackAvatar(FamilyMember member, Color avatarColor) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: avatarColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Icon(
          member.gender == null ? Icons.help : Icons.person,
          size: 20,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _MemberListRow {
  const _MemberListRow.header({
    required this.generation,
    required this.generationCount,
    required this.generationBranchCount,
  }) : member = null,
       displayIndex = null,
       chiIndex = null;

  const _MemberListRow.member(
    this.member, {
    required this.displayIndex,
    required this.chiIndex,
  }) : generation = null,
       generationCount = null,
       generationBranchCount = null;

  final FamilyMember? member;
  final int? generation;
  final int? generationCount;
  final int? generationBranchCount;
  final int? displayIndex;
  final int? chiIndex;

  bool get isHeader => generation != null;
}
