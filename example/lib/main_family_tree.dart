import 'package:flutter/material.dart';
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
  final String? gender; // 'M', 'F', or null
  final int generation;
  final int childCount;
  final String? fatherName;
  final String? motherName;
  final bool isHighlight;

  FamilyMember({
    required this.id,
    required this.name,
    required this.code,
    this.gender,
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

  final List<FamilyMember> mockMembers = [
    FamilyMember(
      id: 1,
      name: 'Phan Nhân Thọ',
      code: 'P001',
      gender: 'M',
      generation: 1,
      childCount: 1,
      isHighlight: false,
    ),
    FamilyMember(
      id: 2,
      name: 'Lai Thị Diễm',
      code: 'P001.v1',
      gender: 'F',
      generation: 1,
      childCount: 1,
      isHighlight: true,
    ),
    FamilyMember(
      id: 3,
      name: 'Phan Nhân Ái',
      code: 'P002',
      gender: 'M',
      generation: 2,
      childCount: 2,
      fatherName: 'Phan Nhân Thọ',
      motherName: 'Lai Thị Diễm',
      isHighlight: false,
    ),
    FamilyMember(
      id: 4,
      name: 'Lê Thị Quỳ',
      code: 'P002.v1',
      gender: 'F',
      generation: 2,
      childCount: 2,
      fatherName: 'Phan Nhân Thọ',
      motherName: 'Lai Thị Diễm',
      isHighlight: false,
    ),
    FamilyMember(
      id: 5,
      name: 'Phan Nhân Vương',
      code: 'P003',
      gender: 'M',
      generation: 3,
      childCount: 2,
      fatherName: 'Phan Nhân Ái',
      motherName: 'Lê Thị Quỳ',
      isHighlight: false,
    ),
    FamilyMember(
      id: 6,
      name: 'Phạm Thị Hương',
      code: 'P004',
      gender: 'F',
      generation: 3,
      childCount: 1,
      fatherName: 'Phan Nhân Ái',
      motherName: 'Lê Thị Quỳ',
      isHighlight: false,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: Column(
          children: [
            // ========== Header Section ==========
            _buildHeaderSection(),

            // ========== Quick Actions Section ==========
            _buildQuickActionsSection(),

            // ========== Category Selector ==========
            _buildCategorySelector(),

            // ========== Members Table Section ==========
            Expanded(child: _buildMembersTable()),
          ],
        ),
      ),
    );
  }

  FamilyMember? get _selectedMember {
    if (selectedMemberId < 0) return null;
    for (final FamilyMember member in mockMembers) {
      if (member.id == selectedMemberId) return member;
    }
    return null;
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
  }) {
    return GestureDetector(
      onTap: () {
        // Action handler
      },
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
              selected == null
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
            onPressed: _openAltarSetup,
            iconSize: 18,
            color: mutedTextColor,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          IconButton(
            icon: const Icon(Icons.expand_more),
            onPressed: () {},
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
  Widget _buildMembersTable() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
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
          _buildTableHeaderBar(),
          const Divider(height: 1, color: lightBorderColor),

          // Column headers
          _buildTableColumnHeaders(),
          const Divider(height: 1, color: lightBorderColor),

          // Members list
          Expanded(
            child: ListView.separated(
              itemCount: mockMembers.length,
              separatorBuilder: (context, index) =>
                  const Divider(height: 1, color: lightBorderColor),
              itemBuilder: (context, index) {
                final member = mockMembers[index];
                return _buildMemberRow(
                  member: member,
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

  // Table header bar với "Tổng: 532" và icons
  Widget _buildTableHeaderBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      color: Colors.white,
      child: Row(
        children: [
          Text(
            'Tổng: 532',
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
    required bool isSelected,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
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
                '${member.id}',
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
                      color: member.gender == 'M'
                          ? Colors.blue.shade200
                          : member.gender == 'F'
                          ? Colors.pink.shade200
                          : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(
                      child: Icon(
                        member.gender == 'M'
                            ? Icons.person
                            : member.gender == 'F'
                            ? Icons.person
                            : Icons.help,
                        size: 20,
                        color: Colors.white,
                      ),
                    ),
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

            // Chi (children count)
            SizedBox(
              width: 40,
              child: Center(
                child: Text(
                  '${member.childCount}',
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
}
