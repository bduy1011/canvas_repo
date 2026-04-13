import 'node_chat_service.dart';

/// Coordinates multi-turn conversation for node creation
class NodeAdditionCoordinator {
  late ExtractedNodeInfo _accumulated;
  late List<String> _missingFields;
  int _turnCount = 0;
  final int _maxTurns = 10;

  NodeAdditionCoordinator() {
    reset();
  }

  void reset() {
    _accumulated = ExtractedNodeInfo();
    _missingFields = [];
    _turnCount = 0;
    _updateMissingFields();
  }

  void _updateMissingFields() {
    _missingFields = [];
    if (_accumulated.fullName == null || _accumulated.fullName!.isEmpty) {
      _missingFields.add('fullName');
    }
    if (_accumulated.sex == null || _accumulated.sex!.isEmpty) {
      _missingFields.add('sex');
    }
  }

  /// Process user input and return a bot response
  /// Returns tuple: (bot response text, is conversation complete)
  (String, bool) processUserInput(String userInput) {
    _turnCount++;

    if (_turnCount > _maxTurns) {
      return (
        'Cuộc trò chuyện quá dài. Vui lòng hoàn tạo node bằng tay.',
        true,
      );
    }

    // Extract new information
    final extracted = NodeChatService.extractNodeInfo(userInput);
    _mergeExtracted(extracted);
    _updateMissingFields();

    // Generate response
    if (_missingFields.isEmpty) {
      final validation = NodeChatService.validateNodeInfo(_accumulated);
      if (validation.isEmpty) {
        return ('✅ Hoàn tất! Sẵn sàng thêm node.', true);
      } else {
        return ('❌ Lỗi: ${validation.values.join(", ")}', false);
      }
    }

    final nextPrompt = _getNextPrompt();
    return (nextPrompt, false);
  }

  void _mergeExtracted(ExtractedNodeInfo extracted) {
    if (extracted.fullName != null && extracted.fullName!.isNotEmpty) {
      _accumulated.fullName = extracted.fullName;
    }
    if (extracted.sex != null && extracted.sex!.isNotEmpty) {
      _accumulated.sex = extracted.sex;
    }
    if (extracted.birthday != null && extracted.birthday!.isNotEmpty) {
      _accumulated.birthday = extracted.birthday;
    }
    if (extracted.deathDay != null && extracted.deathDay!.isNotEmpty) {
      _accumulated.deathDay = extracted.deathDay;
    }
    if (extracted.parentId != null && extracted.parentId!.isNotEmpty) {
      _accumulated.parentId = extracted.parentId;
    }
    if (extracted.motherId != null && extracted.motherId!.isNotEmpty) {
      _accumulated.motherId = extracted.motherId;
    }
    if (extracted.description != null && extracted.description!.isNotEmpty) {
      _accumulated.description = extracted.description;
    }
    if (extracted.spouseId != null && extracted.spouseId!.isNotEmpty) {
      _accumulated.spouseId = extracted.spouseId;
    }
    if (extracted.aliasName != null && extracted.aliasName!.isNotEmpty) {
      _accumulated.aliasName = extracted.aliasName;
    }
    if (extracted.familyNameGroup != null &&
        extracted.familyNameGroup!.isNotEmpty) {
      _accumulated.familyNameGroup = extracted.familyNameGroup;
    }
    if (extracted.cityProvince != null && extracted.cityProvince!.isNotEmpty) {
      _accumulated.cityProvince = extracted.cityProvince;
    }
    if (extracted.district != null && extracted.district!.isNotEmpty) {
      _accumulated.district = extracted.district;
    }
    if (extracted.wards != null && extracted.wards!.isNotEmpty) {
      _accumulated.wards = extracted.wards;
    }
    if (extracted.addressFull != null && extracted.addressFull!.isNotEmpty) {
      _accumulated.addressFull = extracted.addressFull;
    }
    if (extracted.confirmedAlive) {
      _accumulated.confirmedAlive = true;
    }
  }

  String _getNextPrompt() {
    if (_accumulated.fullName == null || _accumulated.fullName!.isEmpty) {
      return '📝 Tên của người này là gì?';
    }
    if (_accumulated.sex == null || _accumulated.sex!.isEmpty) {
      return '👤 ${_accumulated.fullName} là Nam hay Nữ?';
    }

    // Optional fields
    if (_accumulated.birthday == null || _accumulated.birthday!.isEmpty) {
      return '📅 Ngày sinh của ${_accumulated.fullName}? (dd/mm/yyyy hoặc chỉ năm, hoặc "bỏ qua")';
    }

    return '✨ Có thông tin thêm không? (Cha, mẹ, ngày mất...) hoặc gõ "xong"';
  }

  ExtractedNodeInfo get accumulated => _accumulated;
  List<String> get missingRequired => _missingFields;
  int get turnCount => _turnCount;
  bool get isComplete => _missingFields.isEmpty;

  /// Get all extracted data including optional fields
  Map<String, dynamic> toJson() {
    return _accumulated.toNodeJson();
  }
}
