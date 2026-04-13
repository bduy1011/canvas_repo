import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/node_chat_service.dart';

/// Dialog chat AI: thêm mới **và** cập nhật dần node theo schema JSON gia phả;
/// khi ~90% trường có trọng số được lấp + họ tên + giới tính thì có thể tạo node.
class AddNodeChatDialog extends StatefulWidget {
  final List<String> availableNodeIds;
  final Map<String, String> availableNodeLabels;
  final Map<String, ExtractedNodeInfo> availableNodeInfos;
  final Function(ExtractedNodeInfo) onNodeCreated;
  final Function(String nodeId, ExtractedNodeInfo updatedInfo)? onNodeUpdated;
  final ExtractedNodeInfo? initialInfo;
  final bool isUpdateMode;

  const AddNodeChatDialog({
    super.key,
    required this.availableNodeIds,
    required this.availableNodeLabels,
    required this.availableNodeInfos,
    required this.onNodeCreated,
    this.onNodeUpdated,
    this.initialInfo,
    this.isUpdateMode = false,
  });

  @override
  State<AddNodeChatDialog> createState() => _AddNodeChatDialogState();
}

class _AddNodeChatDialogState extends State<AddNodeChatDialog> {
  static final Map<String, _ChatDraftSnapshot> _draftSnapshots =
      <String, _ChatDraftSnapshot>{};

  late ExtractedNodeInfo _currentInfo;
  late List<ChatMessage> _messages;
  late TextEditingController _inputController;
  final ScrollController _chatScrollController = ScrollController();
  bool _isProcessing = false;
  final SpeechToText _speech = SpeechToText();
  bool _speechAvailable = false;
  bool _isListening = false;
  bool _voiceCommitted = false;
  String _voicePreview = '';
  bool? _hasImage;
  bool _awaitingDeathDate = false;
  bool _isUpdateFlow = false;
  bool _awaitingUpdateSelection = false;
  String? _activeUpdateNodeId;
  bool _persistDraftOnDispose = true;
  Uint8List? _selectedImageBytes;

  String get _draftKey => widget.isUpdateMode ? 'update' : 'add';
  // Windows desktop has intermittent SpeechToText plugin issues that can spam
  // keyboard assertions and empty JSON message errors.
  bool get _canUseSpeech => kIsWeb || _isMobilePlatform;
  bool get _isMobilePlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController();

    final draft = _draftSnapshots[_draftKey];
    if (draft != null) {
      _currentInfo = draft.currentInfo;
      _messages = draft.messages;
      _hasImage = draft.hasImage;
      _awaitingDeathDate = draft.awaitingDeathDate;
      _isUpdateFlow = draft.isUpdateFlow;
      _awaitingUpdateSelection = draft.awaitingUpdateSelection;
      _activeUpdateNodeId = draft.activeUpdateNodeId;
      _selectedImageBytes = draft.selectedImageBytes;
      _voicePreview = draft.voicePreview;
      _inputController.text = draft.pendingInput;
      _inputController.selection = TextSelection.fromPosition(
        TextPosition(offset: _inputController.text.length),
      );
    } else {
      _currentInfo = widget.initialInfo != null
          ? _copyInfo(widget.initialInfo!)
          : ExtractedNodeInfo();
      if (widget.initialInfo != null) {
        _hasImage =
            ((widget.initialInfo!.imageBytes != null) ||
                (widget.initialInfo!.imageUrl?.isNotEmpty == true))
            ? true
            : null;
      }

      final intro = widget.isUpdateMode
          ? 'Bạn đang ở chế độ cập nhật node. Hãy nói trường bạn muốn sửa (tên, giới tính, sinh, còn sống/đã mất, cha/mẹ/vợ-chồng, mô tả...).'
          : 'Xin chào! Bạn có thể chat nhiều lượt để bổ sung hoặc sửa thông tin; '
                'tôi chuẩn hoá theo schema gia phả (họ tên, giới tính, sinh, cha/mẹ, vợ/chồng, địa chỉ, mô tả…). '
                'Nếu thiếu trường quan trọng tôi sẽ hỏi lại; sau năm sinh tôi sẽ hỏi còn sống hay đã mất, '
                'nếu đã mất tôi sẽ hỏi năm/ngày mất. Khi mức hoàn thiện ~90% và đã có họ tên + Nam/Nữ, '
                'bạn bấm Tạo node hoặc gõ OK.';
      final next = _getNextQuestion();
      _messages = [
        ChatMessage(
          text: next.isEmpty ? intro : '$intro\n\n$next',
          isUser: false,
        ),
      ];
    }
  }

  ExtractedNodeInfo _copyInfo(ExtractedNodeInfo info) {
    return ExtractedNodeInfo(
      fullName: info.fullName,
      aliasName: info.aliasName,
      sex: info.sex,
      birthday: info.birthday,
      deathDay: info.deathDay,
      description: info.description,
      parentId: info.parentId,
      motherId: info.motherId,
      spouseId: info.spouseId,
      imageBytes: info.imageBytes,
      imageUrl: info.imageUrl,
      level: info.level,
      branch: info.branch,
      hand: info.hand,
      familyNameGroup: info.familyNameGroup,
      cityProvince: info.cityProvince,
      district: info.district,
      wards: info.wards,
      addressFull: info.addressFull,
      confirmedAlive: info.confirmedAlive,
    );
  }

  double get _completionRatio => NodeChatService.computeSchemaCompletionRatio(
    _currentInfo,
    imageStepAnswered: _hasImage != null,
  );

  bool get _canSubmitNode {
    if (_isUpdateFlow || widget.isUpdateMode) {
      return true;
    }
    final nameOk = _currentInfo.fullName?.trim().isNotEmpty == true;
    final sexOk = _currentInfo.sex == 'Nam' || _currentInfo.sex == 'Nữ';
    return nameOk &&
        sexOk &&
        _completionRatio >= NodeChatService.schemaReadyThreshold;
  }

  @override
  void dispose() {
    if (_persistDraftOnDispose) {
      _saveDraftSnapshot();
    } else {
      _clearDraftSnapshot();
    }
    _speech.stop();
    _chatScrollController.dispose();
    _inputController.dispose();
    super.dispose();
  }

  void _saveDraftSnapshot() {
    _draftSnapshots[_draftKey] = _ChatDraftSnapshot(
      currentInfo: _copyCurrentInfo(),
      messages: List<ChatMessage>.from(_messages),
      hasImage: _hasImage,
      awaitingDeathDate: _awaitingDeathDate,
      isUpdateFlow: _isUpdateFlow,
      awaitingUpdateSelection: _awaitingUpdateSelection,
      activeUpdateNodeId: _activeUpdateNodeId,
      selectedImageBytes: _selectedImageBytes,
      voicePreview: _voicePreview,
      pendingInput: _inputController.text,
    );
  }

  void _clearDraftSnapshot() {
    _draftSnapshots.remove(_draftKey);
  }

  void _clearRuntimeState({bool preserveChatHistory = false}) {
    _currentInfo = ExtractedNodeInfo();
    _isUpdateFlow = false;
    _awaitingUpdateSelection = false;
    _activeUpdateNodeId = null;
    _awaitingDeathDate = false;
    _hasImage = null;
    _selectedImageBytes = null;
    _voicePreview = '';
    _voiceCommitted = false;
    _inputController.clear();
    if (!preserveChatHistory) {
      _messages = [
        ChatMessage(
          text:
              'Xin chào! Bạn có thể chat nhiều lượt để bổ sung hoặc sửa thông tin; '
              'tôi chuẩn hoá theo schema gia phả (họ tên, giới tính, sinh, cha/mẹ, vợ/chồng, địa chỉ, mô tả…). '
              'Nếu thiếu trường quan trọng tôi sẽ hỏi lại; sau năm sinh tôi sẽ hỏi còn sống hay đã mất, '
              'nếu đã mất tôi sẽ hỏi năm/ngày mất. Khi mức hoàn thiện ~90% và đã có họ tên + Nam/Nữ, '
              'bạn bấm Tạo node hoặc gõ OK.\n\nTên đầy đủ của người này là gì?',
          isUser: false,
        ),
      ];
    }
  }

  void _enterUpdateFlow(String nodeId, ExtractedNodeInfo info) {
    _isUpdateFlow = true;
    _awaitingUpdateSelection = true;
    _activeUpdateNodeId = nodeId;
    _currentInfo = _copyInfo(info);
    _selectedImageBytes = info.imageBytes;
    _hasImage = info.imageBytes != null || (info.imageUrl?.isNotEmpty == true);
    _awaitingDeathDate = info.deathDay?.trim().isNotEmpty == true;
  }

  String _formatNodeSnapshot(ExtractedNodeInfo info, {required String nodeId}) {
    return [
      'Node: $nodeId',
      'Tên: ${info.fullName ?? '—'}',
      'Giới tính: ${info.sex ?? '—'}',
      'Dòng họ: ${info.familyNameGroup ?? '—'}',
      'Ngày sinh: ${info.birthday ?? '—'}',
      'Ngày mất: ${info.deathDay ?? (info.confirmedAlive ? 'còn sống' : '—')}',
      'Cha: ${_relationLabel(info.parentId)}',
      'Mẹ: ${_relationLabel(info.motherId)}',
      'Vợ/chồng: ${_relationLabel(info.spouseId)}',
      'Địa chỉ: ${info.addressFull ?? info.cityProvince ?? '—'}',
      'Mô tả: ${info.description ?? '—'}',
    ].join('\n');
  }

  String? _findNodeIdByQuery(String rawQuery) {
    final normalizedQuery = NodeChatService.normalizeSemanticText(rawQuery);
    if (normalizedQuery.isEmpty) return null;

    String? exactMatchId;
    for (final entry in widget.availableNodeInfos.entries) {
      final nodeId = entry.key;
      final info = entry.value;
      final candidates = <String>[
        nodeId,
        info.fullName ?? '',
        info.aliasName ?? '',
      ];
      final normalizedCandidates = candidates
          .map(NodeChatService.normalizeSemanticText)
          .where((candidate) => candidate.isNotEmpty)
          .toList();

      if (normalizedCandidates.any(
        (candidate) => candidate == normalizedQuery,
      )) {
        if (exactMatchId != null && exactMatchId != nodeId) {
          return null;
        } else {
          exactMatchId = nodeId;
        }
      }
    }

    return exactMatchId;
  }

  String? _extractUpdateTargetQuery(String input) {
    final normalized = NodeChatService.normalizeSemanticText(input);
    final patterns = [
      RegExp(
        r'(?:toi muon|muon|can|tôi muốn|cần|hay).{0,30}(?:cap nhat|update|sua|doi|thay).{0,30}(?:node)?(?:\s+ten\s+la|\s+ten|\s+name|\s+la)?\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'(?:cap nhat|update|sua|doi|thay)(?:\s+node)?(?:\s+ten\s+la|\s+ten|\s+name|\s+la)?\s+(.+)$',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(normalized);
      if (match != null) {
        final candidate = match.group(1)?.trim();
        if (candidate != null && candidate.isNotEmpty) {
          return candidate;
        }
      }
    }
    return null;
  }

  String? _detectRelationFieldFromInput(String normalizedInput) {
    if (NodeChatService.matchesAnySemantic(normalizedInput, const [
      'cha',
      'bo',
      'father',
      'dad',
      'phu than',
      'nguoi cha',
    ])) {
      return 'parentId';
    }
    if (NodeChatService.matchesAnySemantic(normalizedInput, const [
      'me',
      'mother',
      'mom',
      'mau than',
      'nguoi me',
    ])) {
      return 'motherId';
    }
    if (NodeChatService.matchesAnySemantic(normalizedInput, const [
      'vo',
      'chong',
      'wife',
      'husband',
      'partner',
      'spouse',
    ])) {
      return 'spouseId';
    }
    return null;
  }

  ExtractedNodeInfo _copyCurrentInfo() {
    return ExtractedNodeInfo(
      fullName: _currentInfo.fullName,
      aliasName: _currentInfo.aliasName,
      sex: _currentInfo.sex,
      birthday: _currentInfo.birthday,
      deathDay: _currentInfo.deathDay,
      description: _currentInfo.description,
      parentId: _currentInfo.parentId,
      motherId: _currentInfo.motherId,
      spouseId: _currentInfo.spouseId,
      imageBytes: _currentInfo.imageBytes,
      imageUrl: _currentInfo.imageUrl,
      level: _currentInfo.level,
      branch: _currentInfo.branch,
      hand: _currentInfo.hand,
      familyNameGroup: _currentInfo.familyNameGroup,
      cityProvince: _currentInfo.cityProvince,
      district: _currentInfo.district,
      wards: _currentInfo.wards,
      addressFull: _currentInfo.addressFull,
      confirmedAlive: _currentInfo.confirmedAlive,
    );
  }

  void _scrollToLatestMessage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_chatScrollController.hasClients) return;
      _chatScrollController.animateTo(
        _chatScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _pickImage() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (!mounted || picked == null || picked.files.isEmpty) return;
    final bytes = picked.files.single.bytes;
    if (bytes == null) return;

    setState(() {
      _selectedImageBytes = bytes;
      _hasImage = true;
      _messages.add(ChatMessage(text: 'Đã chọn ảnh cho node.', isUser: false));
      final nextQuestion = _getNextQuestion();
      if (nextQuestion.isNotEmpty) {
        _messages.add(ChatMessage(text: nextQuestion, isUser: false));
      }
    });
    _scrollToLatestMessage();
  }

  Future<void> _initSpeech() async {
    try {
      final available = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'done' || status == 'notListening') {
            final shouldCommit =
                !_voiceCommitted && _inputController.text.trim().isNotEmpty;
            setState(() => _isListening = false);
            if (shouldCommit) {
              _commitVoiceTranscript(_inputController.text);
            }
          }
        },
        onError: (error) {
          if (!mounted) return;
          setState(() => _isListening = false);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Mic lỗi: ${error.errorMsg}')));
        },
      );
      if (!mounted) return;
      setState(() => _speechAvailable = available);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _speechAvailable = false;
        _isListening = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_buildMicErrorMessage(e, isInitialize: true))),
      );
    }
  }

  Future<void> _toggleMic() async {
    if (!_canUseSpeech) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Mic chat hiện chỉ hỗ trợ trên mobile/web.'),
        ),
      );
      return;
    }

    try {
      if (_isMobilePlatform) {
        final hasPermission = await _ensureMobileMicPermission();
        if (!hasPermission) return;
      }

      if (!_speechAvailable) {
        await _initSpeech();
      }
      if (!_speechAvailable) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Không thể bật mic. Kiểm tra quyền truy cập microphone.',
            ),
          ),
        );
        return;
      }

      if (_isListening) {
        await _speech.stop();
        if (!mounted) return;
        setState(() => _isListening = false);
        return;
      }

      _voiceCommitted = false;
      _voicePreview = '';
      final started = await _speech.listen(
        onResult: (result) {
          if (!mounted) return;
          final recognized = result.recognizedWords.trim();
          setState(() {
            _inputController.text = recognized;
            _inputController.selection = TextSelection.fromPosition(
              TextPosition(offset: _inputController.text.length),
            );
            _voicePreview = recognized;
          });
          if (result.finalResult && recognized.isNotEmpty) {
            _commitVoiceTranscript(recognized);
          }
        },
        partialResults: true,
        cancelOnError: true,
      );

      if (!mounted) return;
      setState(() {
        _isListening = started;
        if (started) {
          _voiceCommitted = false;
          _voicePreview = '';
        }
      });
      if (!started) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không thể bắt đầu ghi âm.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isListening = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_buildMicErrorMessage(e))));
    }
  }

  String _buildMicErrorMessage(Object error, {bool isInitialize = false}) {
    if (_isWebNullBoolCastError(error)) {
      return 'Chrome chưa trả trạng thái microphone ổn định. Hãy bấm cho phép mic rồi thử lại.';
    }
    if (isInitialize) {
      return 'Không thể khởi tạo mic: $error';
    }
    return 'Mic gặp lỗi: $error';
  }

  bool _isWebNullBoolCastError(Object error) {
    if (!kIsWeb) return false;
    final message = error.toString().toLowerCase();
    return message.contains("type 'null' is not a subtype of type 'bool'");
  }

  Future<bool> _ensureMobileMicPermission() async {
    var status = await Permission.microphone.status;
    if (status.isGranted) return true;

    status = await Permission.microphone.request();
    if (status.isGranted) return true;

    if (!mounted) return false;
    final canOpenSettings = status.isPermanentlyDenied || status.isRestricted;
    await _showMicrophonePermissionDialog(canOpenSettings: canOpenSettings);
    return false;
  }

  Future<void> _showMicrophonePermissionDialog({
    required bool canOpenSettings,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Cần quyền microphone'),
          content: Text(
            canOpenSettings
                ? 'Bạn đã tắt quyền microphone. Vui lòng bật lại trong Cài đặt để dùng nhập giọng nói.'
                : 'Vui lòng cấp quyền microphone để sử dụng nhập giọng nói.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Để sau'),
            ),
            if (canOpenSettings)
              FilledButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await openAppSettings();
                },
                child: const Text('Mở cài đặt'),
              ),
          ],
        );
      },
    );
  }

  void _commitVoiceTranscript(String transcript) {
    final trimmed = transcript.trim();
    if (trimmed.isEmpty || _voiceCommitted) return;

    _voiceCommitted = true;
    if (!mounted) return;
    setState(() {
      _voicePreview = trimmed;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _handleUserText(trimmed, fromVoice: true);
    });
  }

  void _handleUserText(String rawText, {bool fromVoice = false}) {
    final input = rawText.trim();
    if (input.isEmpty || _isProcessing) return;

    setState(() {
      _isProcessing = true;
      if (fromVoice) {
        _voicePreview = '';
      }
      _messages.add(
        ChatMessage(text: fromVoice ? '🎤 $input' : input, isUser: true),
      );
    });

    final command = _normalizeCommand(input);
    _executeCommand(command, rawInput: input);
  }

  _NormalizedCommand _normalizeCommand(String input) {
    final lower = input.toLowerCase().trim();
    final normalized = NodeChatService.normalizeSemanticText(input);
    final pendingField = _pendingField();
    final isImageStep = !_isUpdateFlow && _pendingField() == 'image';
    final pendingRelationField = _pendingRelationField();

    if (!_isUpdateFlow) {
      final updateTargetQuery = _extractUpdateTargetQuery(input);
      if (updateTargetQuery != null) {
        final nodeId = _findNodeIdByQuery(updateTargetQuery);
        return _NormalizedCommand(
          type: _CommandType.switchToUpdateTarget,
          field: nodeId,
          value: updateTargetQuery,
        );
      }
    }

    if (NodeChatService.matchesAnySemantic(normalized, const [
      'ok',
      'xong',
      'xác nhận',
      'đồng ý',
      'thêm node',
      'thêm thành viên',
      'hoàn tất',
      'lưu lại',
      'ghi lại',
      'lưu',
      'save',
      'done',
      'hoàn thành',
    ])) {
      return const _NormalizedCommand(type: _CommandType.submit);
    }

    if (NodeChatService.matchesAnySemantic(normalized, const [
      'bắt đầu lại',
      'làm lại',
      'reset',
      'làm từ đầu',
      'nhập lại',
      'làm mới',
      'clear',
    ])) {
      return const _NormalizedCommand(type: _CommandType.reset);
    }

    if (NodeChatService.matchesAnySemantic(normalized, const [
      'đóng',
      'thoát',
      'hủy',
      'bỏ qua',
      'cancel',
    ])) {
      return const _NormalizedCommand(type: _CommandType.closeDialog);
    }

    if (_isGreetingOnlyInput(normalized)) {
      return const _NormalizedCommand(type: _CommandType.greeting);
    }

    // When the dialog is asking a specific relation (cha/me/vo-chong),
    // map generic "khong co" to that exact field instead of relying on
    // keyword order (which can accidentally hit parentId first).
    if (pendingRelationField != null && _isNoRelationAnswer(normalized)) {
      return _NormalizedCommand(
        type: _CommandType.updateField,
        field: pendingRelationField,
        value: kNoRelationMarker,
      );
    }

    // While asking a specific relation field, interpret free text as that
    // exact relation to avoid false intent detection from names (e.g. "Vo ...").
    if (pendingRelationField != null) {
      return _buildRelationCommand(
        field: pendingRelationField,
        input: input,
        normalized: normalized,
      );
    }

    if (isImageStep &&
        NodeChatService.matchesAnySemantic(normalized, const [
          'không có ảnh',
          'khong co anh',
          'không có hình',
          'khong co hinh',
          'không dùng ảnh',
          'khong dung anh',
          'bỏ qua ảnh',
          'bo qua anh',
          'không có',
          'ko có',
          'khong co',
          'không',
          'ko',
        ])) {
      return const _NormalizedCommand(type: _CommandType.imageNo);
    }

    if (isImageStep &&
        NodeChatService.matchesAnySemantic(normalized, const [
          'có ảnh',
          'co anh',
          'có hình',
          'co hinh',
          'upload ảnh',
          'upload hình',
        ])) {
      return const _NormalizedCommand(type: _CommandType.imageYes);
    }

    if (_shouldPreferFullExtraction(input, normalized)) {
      return const _NormalizedCommand(type: _CommandType.chatInput);
    }

    if (NodeChatService.matchesAnySemantic(normalized, const [
      'xin chào',
      'chào',
      'hello',
      'hi',
      'hey',
    ])) {
      // Keep processing so mixed inputs like "xin chào, tên là ..." still get parsed.
    }

    final shouldHandleLifeStatus =
        pendingRelationField == null &&
        (_isUpdateFlow ||
            pendingField == 'lifeStatus' ||
            pendingField == 'deathDay');
    if (shouldHandleLifeStatus) {
      final lifeStatusCommand = _buildLifeStatusCommand(input, normalized);
      if (lifeStatusCommand != null) {
        return lifeStatusCommand;
      }
    }

    if (RegExp(r'^\d{4}$').hasMatch(lower) ||
        RegExp(r'^\d{1,2}[/-]\d{1,2}[/-]\d{2,4}$').hasMatch(lower) ||
        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(lower)) {
      final date = NodeChatService.extractNodeInfo('sinh $input').birthday;
      if (date != null && date.isNotEmpty) {
        return _NormalizedCommand(
          type: _CommandType.updateField,
          field: 'birthday',
          value: date,
        );
      }
    }

    final nameIntent = NodeChatService.matchesAnySemantic(normalized, const [
      'sửa tên',
      'đổi tên',
      'đặt tên',
      'thay tên',
      'chỉnh tên',
      'đổi họ tên',
      'sửa họ tên',
      'rename',
    ]);
    final nameMatch = nameIntent
        ? RegExp(
            r'(?:(?:sửa|đổi|đặt|thay|chỉnh)\s+(?:họ\s+tên|tên)(?:\s+là|\s+thành)?\s+|rename\s+)(.+)$',
            caseSensitive: false,
          ).firstMatch(input)
        : null;
    if (nameMatch != null) {
      return _NormalizedCommand(
        type: _CommandType.updateField,
        field: 'fullName',
        value: nameMatch.group(1)?.trim(),
      );
    }

    final sexIntent = NodeChatService.matchesAnySemantic(normalized, const [
      'giới tính',
      'giới',
      'phái',
      'nam hay nữ',
      'trai hay gái',
      'gioi nao',
      'male',
      'female',
    ]);
    final sexMatch = sexIntent
        ? RegExp(
            r'(?:giới tính|gioi tinh|gender|gioi|phai|trai hay gai|gioi nao)(?:\s+là)?\s+(nam|nữ|nu|male|female|trai|gai)',
            caseSensitive: false,
          ).firstMatch(normalized)
        : null;
    if (sexMatch != null) {
      final raw = sexMatch.group(1) ?? '';
      final normalized =
          (raw == 'female' || raw == 'nữ' || raw == 'nu' || raw == 'gai')
          ? 'Nữ'
          : 'Nam';
      return _NormalizedCommand(
        type: _CommandType.updateField,
        field: 'sex',
        value: normalized,
      );
    }

    final birthdayIntent =
        NodeChatService.matchesAnySemantic(normalized, const [
          'ngày sinh',
          'sinh năm',
          'năm sinh',
          'sinh vào',
          'ngày chào đời',
          'born',
          'birthday',
          'dob',
        ]);
    final birthdayMatch = birthdayIntent
        ? RegExp(
            r'(?:ngay sinh|sinh nam|nam sinh|sinh vao|ngay chao doi|sinh|birthday|born|dob)(?:\s+là)?\s+([0-9]{1,2}[/-][0-9]{1,2}[/-][0-9]{2,4}|[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{4})',
            caseSensitive: false,
          ).firstMatch(normalized)
        : null;
    if (birthdayMatch != null) {
      final date = NodeChatService.extractNodeInfo(
        'sinh ${birthdayMatch.group(1)}',
      ).birthday;
      if (date != null && date.isNotEmpty) {
        return _NormalizedCommand(
          type: _CommandType.updateField,
          field: 'birthday',
          value: date,
        );
      }
    }

    final parentIntent = NodeChatService.matchesAnySemantic(normalized, const [
      'cha',
      'bố',
      'ba',
      'phụ thân',
      'father',
      'dad',
      'người cha',
    ]);
    final parentValue = _extractRelationValue(input, const [
      'cha',
      'bố',
      'ba',
      'phụ thân',
      'father',
      'dad',
      'người cha',
    ]);
    if (parentIntent || parentValue != null) {
      return _buildRelationCommand(
        field: 'parentId',
        input: input,
        normalized: normalized,
        value: parentValue,
      );
    }

    final motherIntent = NodeChatService.matchesAnySemantic(normalized, const [
      'mẹ',
      'má',
      'mẫu thân',
      'mother',
      'mom',
      'người mẹ',
    ]);
    final motherValue = _extractRelationValue(input, const [
      'mẹ',
      'má',
      'mẫu thân',
      'mother',
      'mom',
      'người mẹ',
    ]);
    if (motherIntent || motherValue != null) {
      return _buildRelationCommand(
        field: 'motherId',
        input: input,
        normalized: normalized,
        value: motherValue,
      );
    }

    final spouseIntent = NodeChatService.matchesAnySemantic(normalized, const [
      'vợ',
      'chồng',
      'ông xã',
      'bà xã',
      'ban doi',
      'wife',
      'husband',
      'partner',
      'spouse',
    ]);
    final spouseValue = _extractRelationValue(input, const [
      'vợ/chồng',
      'vợ chồng',
      'vo chong',
      'vợ',
      'chồng',
      'ông xã',
      'bà xã',
      'ban doi',
      'wife',
      'husband',
      'partner',
      'spouse',
    ]);
    if (spouseIntent || spouseValue != null) {
      return _buildRelationCommand(
        field: 'spouseId',
        input: input,
        normalized: normalized,
        value: spouseValue,
      );
    }

    return const _NormalizedCommand(type: _CommandType.chatInput);
  }

  bool _shouldPreferFullExtraction(String input, String normalized) {
    if (_isNoRelationAnswer(normalized)) {
      return false;
    }

    final extracted = NodeChatService.extractNodeInfo(input);
    var extractedCoreFieldCount = 0;

    if (extracted.fullName?.trim().isNotEmpty == true) {
      extractedCoreFieldCount++;
    }
    if (extracted.sex?.trim().isNotEmpty == true) {
      extractedCoreFieldCount++;
    }
    if (extracted.birthday?.trim().isNotEmpty == true) {
      extractedCoreFieldCount++;
    }
    if (extracted.deathDay?.trim().isNotEmpty == true) {
      extractedCoreFieldCount++;
    }

    if (extractedCoreFieldCount >= 2) {
      return true;
    }

    final hasStructuredHint = NodeChatService.matchesAnySemantic(
      normalized,
      const ['ten', 'ten la', 'gioi tinh', 'ngay sinh', 'sinh nam', 'nam sinh'],
    );
    final tokenCount = normalized.split(' ').where((e) => e.isNotEmpty).length;
    return hasStructuredHint && tokenCount >= 8 && extractedCoreFieldCount >= 1;
  }

  bool _isGreetingOnlyInput(String normalized) {
    final hasGreeting = NodeChatService.matchesAnySemantic(normalized, const [
      'xin chào',
      'chào',
      'hello',
      'hi',
      'hey',
    ]);
    if (!hasGreeting) return false;

    final hasStructuredDataHint =
        NodeChatService.matchesAnySemantic(normalized, const [
          'tên',
          'tên là',
          'ngày sinh',
          'sinh năm',
          'năm sinh',
          'giới tính',
          'nam',
          'nữ',
          'cha',
          'mẹ',
          'vợ',
          'chồng',
          'node',
        ]);
    if (hasStructuredDataHint) return false;

    final tokenCount = normalized.split(' ').where((e) => e.isNotEmpty).length;
    return tokenCount <= 4;
  }

  _NormalizedCommand _buildRelationCommand({
    required String field,
    required String input,
    required String normalized,
    String? value,
  }) {
    if (_isNoRelationAnswer(normalized)) {
      return _NormalizedCommand(
        type: _CommandType.updateField,
        field: field,
        value: kNoRelationMarker,
      );
    }

    final candidate = (value ?? input).trim();
    if (candidate.isEmpty) {
      return const _NormalizedCommand(type: _CommandType.chatInput);
    }

    return _NormalizedCommand(
      type: _CommandType.updateField,
      field: field,
      value: candidate,
    );
  }

  _NormalizedCommand? _buildLifeStatusCommand(String input, String normalized) {
    final hasAliveHint = NodeChatService.matchesAnySemantic(normalized, const [
      'còn sống',
      'con song',
      'vẫn sống',
      'van song',
      'vẫn khỏe',
      'con song khoe',
      'khỏe mạnh',
      'alive',
    ]);
    final hasDeathHint = NodeChatService.matchesAnySemantic(normalized, const [
      'đã mất',
      'da mat',
      'mất',
      'mat',
      'qua đời',
      'qua doi',
      'chết',
      'chet',
      'từ trần',
      'tu tran',
      'tử vong',
      'tu vong',
      'hy sinh',
      'không còn',
      'khong con',
    ]);

    if (hasAliveHint && !hasDeathHint) {
      return const _NormalizedCommand(
        type: _CommandType.updateField,
        field: 'confirmedAlive',
        value: 'true',
      );
    }

    if (!hasDeathHint) {
      return null;
    }

    final extractedDeath = NodeChatService.extractNodeInfo(input).deathDay;
    final fallbackDate = _extractBirthdayValue(input);
    final deathDate = (extractedDeath != null && extractedDeath.isNotEmpty)
        ? extractedDeath
        : fallbackDate;

    if (deathDate != null && deathDate.isNotEmpty) {
      return _NormalizedCommand(
        type: _CommandType.updateField,
        field: 'deathDay',
        value: deathDate,
      );
    }

    return const _NormalizedCommand(
      type: _CommandType.updateField,
      field: 'confirmedAlive',
      value: 'false',
    );
  }

  void _executeCommand(_NormalizedCommand command, {required String rawInput}) {
    switch (command.type) {
      case _CommandType.switchToUpdateTarget:
        final nodeId = command.field;
        final targetInfo = nodeId == null
            ? null
            : widget.availableNodeInfos[nodeId];
        if (nodeId == null || targetInfo == null) {
          setState(() {
            _messages.add(
              ChatMessage(
                text:
                    'Không tìm thấy node đó trong cây gia phả. Hãy thử nhập lại đúng tên node hoặc NodeCode.',
                isUser: false,
                isError: true,
              ),
            );
            _isProcessing = false;
            _inputController.clear();
          });
          _scrollToLatestMessage();
          return;
        }

        _enterUpdateFlow(nodeId, targetInfo);
        setState(() {
          _messages.add(
            ChatMessage(
              text:
                  'Tôi đã tìm thấy node cần cập nhật. Thông tin hiện tại:\n${_formatNodeSnapshot(targetInfo, nodeId: nodeId)}\n\nBạn muốn cập nhật phần nào? Hãy nói trực tiếp, ví dụ: "đổi tên thành...", "thêm mẹ là...", "mẹ không có", "cập nhật mô tả...".',
              isUser: false,
            ),
          );
          _isProcessing = false;
          _inputController.clear();
        });
        _scrollToLatestMessage();
        return;
      case _CommandType.submit:
        setState(() {
          _isProcessing = false;
          _inputController.clear();
        });
        _submitNode();
        return;
      case _CommandType.reset:
        setState(() {
          _currentInfo = ExtractedNodeInfo();
          _hasImage = null;
          _selectedImageBytes = null;
          _awaitingDeathDate = false;
          _messages.add(
            ChatMessage(text: 'Đã reset. Tên người này là gì?', isUser: false),
          );
          _isProcessing = false;
          _inputController.clear();
        });
        return;
      case _CommandType.greeting:
        setState(() {
          _messages.add(
            ChatMessage(
              text: _getNextQuestion().isEmpty
                  ? 'Xin chào. Bạn muốn thêm ai vào cây?'
                  : 'Xin chào. ${_getNextQuestion()}',
              isUser: false,
            ),
          );
          _isProcessing = false;
          _inputController.clear();
        });
        _scrollToLatestMessage();
        return;
      case _CommandType.imageYes:
        setState(() {
          _hasImage = true;
          _messages.add(
            ChatMessage(
              text:
                  'Được. Bấm "Chọn ảnh" bên dưới để upload, hoặc nói "không có" nếu bỏ qua.',
              isUser: false,
            ),
          );
          final nextQuestion = _getNextQuestion();
          if (nextQuestion.isNotEmpty) {
            _messages.add(ChatMessage(text: nextQuestion, isUser: false));
          }
          _isProcessing = false;
          _inputController.clear();
        });
        _scrollToLatestMessage();
        return;
      case _CommandType.imageNo:
        setState(() {
          _hasImage = false;
          _selectedImageBytes = null;
          _messages.add(ChatMessage(text: 'Đã bỏ qua ảnh.', isUser: false));
          final nextQuestion = _getNextQuestion();
          if (nextQuestion.isNotEmpty) {
            _messages.add(ChatMessage(text: nextQuestion, isUser: false));
          }
          _isProcessing = false;
          _inputController.clear();
        });
        _scrollToLatestMessage();
        return;
      case _CommandType.closeDialog:
        setState(() {
          _isProcessing = false;
          _inputController.clear();
        });
        if (mounted) {
          Navigator.pop(context);
        }
        return;
      case _CommandType.updateField:
        if (command.field != null && command.value != null) {
          if (command.field == 'confirmedAlive') {
            final isAlive = command.value == 'true';
            setState(() {
              _currentInfo.confirmedAlive = isAlive;
              if (isAlive) {
                _currentInfo.deathDay = '';
              }
              _messages.add(
                ChatMessage(
                  text:
                      'Đã cập nhật ${_fieldDisplayName(command.field!)}: ${isAlive ? 'còn sống' : 'đã mất'}. ${_footerAfterUpdate()}',
                  isUser: false,
                ),
              );
              _isProcessing = false;
              _inputController.clear();
            });
            _scrollToLatestMessage();
            return;
          }

          if (command.field == 'deathDay') {
            setState(() {
              _currentInfo.deathDay = command.value;
              _currentInfo.confirmedAlive = false;
              _messages.add(
                ChatMessage(
                  text:
                      'Đã cập nhật ${_fieldDisplayName(command.field!)}: ${command.value}. ${_footerAfterUpdate()}',
                  isUser: false,
                ),
              );
              _isProcessing = false;
              _inputController.clear();
            });
            _scrollToLatestMessage();
            return;
          }

          if (command.field == 'parentId' ||
              command.field == 'motherId' ||
              command.field == 'spouseId') {
            final relationResult = _resolveRelationReference(command.value!);
            if (relationResult == null) {
              setState(() {
                _messages.add(
                  ChatMessage(
                    text:
                        'Không có người này trong cây gia phả. Hãy nhập lại đúng NodeCode/tên trong cây, hoặc gõ "không có".',
                    isUser: false,
                    isError: true,
                  ),
                );
                _isProcessing = false;
                _inputController.clear();
              });
              _scrollToLatestMessage();
              return;
            }

            setState(() {
              _setFieldValue(command.field!, relationResult);
              final relationLabel = _relationLabel(relationResult);
              _messages.add(
                ChatMessage(
                  text:
                      '${command.field == 'parentId'
                          ? 'Cha'
                          : command.field == 'motherId'
                          ? 'Mẹ'
                          : 'Vợ/chồng'}: $relationLabel. ${_footerAfterUpdate()}',
                  isUser: false,
                ),
              );
              _isProcessing = false;
              _inputController.clear();
            });
            _scrollToLatestMessage();
            return;
          }

          setState(() {
            _setFieldValue(command.field!, command.value!);
            _messages.add(
              ChatMessage(
                text:
                    'Đã cập nhật ${_fieldDisplayName(command.field!)}: ${command.value}. ${_footerAfterUpdate()}',
                isUser: false,
              ),
            );
            _isProcessing = false;
            _inputController.clear();
          });
          _scrollToLatestMessage();
          return;
        }
        _extractAndReply(rawInput);
        return;
      case _CommandType.chatInput:
        _extractAndReply(rawInput);
        return;
    }
  }

  void _extractAndReply(String input) {
    final extracted = NodeChatService.extractNodeInfo(input);
    final normalizedInput = NodeChatService.normalizeSemanticText(input);
    final beforeMerge = _copyCurrentInfo();
    String? updateRelationField;

    final pendingField = _pendingField();
    final explicitName = _containsExplicitNameIntent(normalizedInput);
    if (!_isUpdateFlow && pendingField != 'fullName' && !explicitName) {
      extracted.fullName = null;
    }
    if (!_isUpdateFlow && pendingField == 'sex') {
      final parsedSex = _extractSexValue(input);
      if (parsedSex != null) {
        extracted.sex = parsedSex;
      }
    }
    if (!_isUpdateFlow && pendingField == 'birthday') {
      final parsedBirthday = _extractBirthdayValue(input);
      if (parsedBirthday != null) {
        extracted.birthday = parsedBirthday;
        extracted.fullName = null;
      }
    }

    final pendingRelationField = _pendingRelationField();
    if (!_isUpdateFlow && pendingRelationField != null) {
      final directRelation = _resolveRelationReference(input);
      if (directRelation != null) {
        if (pendingRelationField == 'parentId') {
          extracted.parentId = directRelation;
        } else if (pendingRelationField == 'motherId') {
          extracted.motherId = directRelation;
        } else if (pendingRelationField == 'spouseId') {
          extracted.spouseId = directRelation;
        }
      } else if (!_isNoRelationAnswer(normalizedInput)) {
        setState(() {
          _messages.add(
            ChatMessage(
              text:
                  'Không có người này trong cây gia phả. Hãy nhập lại đúng NodeCode/tên trong cây, hoặc gõ "không có".',
              isUser: false,
              isError: true,
            ),
          );
          _isProcessing = false;
          _inputController.clear();
        });
        _scrollToLatestMessage();
        return;
      }
    }

    if (_isUpdateFlow) {
      if (!_containsExplicitDescriptionIntent(normalizedInput)) {
        extracted.description = null;
      }
      updateRelationField = _detectRelationFieldFromInput(normalizedInput);
      if (updateRelationField != null) {
        final relationKeywords = updateRelationField == 'parentId'
            ? const [
                'người cha',
                'phụ thân',
                'father',
                'dad',
                'cha',
                'bố',
                'bo',
              ]
            : updateRelationField == 'motherId'
            ? const ['người mẹ', 'mẫu thân', 'mother', 'mom', 'mẹ', 'me']
            : const [
                'vợ/chồng',
                'vợ chồng',
                'vo chong',
                'husband',
                'wife',
                'partner',
                'spouse',
                'vợ',
                'vo',
                'chồng',
                'chong',
              ];
        final relationValue = _extractRelationValue(input, relationKeywords);
        if (updateRelationField == 'parentId') {
          extracted.parentId =
              relationValue ??
              (_isNoRelationAnswer(normalizedInput) ? kNoRelationMarker : null);
        } else if (updateRelationField == 'motherId') {
          extracted.motherId =
              relationValue ??
              (_isNoRelationAnswer(normalizedInput) ? kNoRelationMarker : null);
        } else if (updateRelationField == 'spouseId') {
          extracted.spouseId =
              relationValue ??
              (_isNoRelationAnswer(normalizedInput) ? kNoRelationMarker : null);
        }
      }
    }

    if (extracted.confirmedAlive) {
      _awaitingDeathDate = false;
    }
    if (extracted.deathDay != null && extracted.deathDay!.isNotEmpty) {
      _awaitingDeathDate = false;
    }
    if (_isDeathMentionOnly(normalizedInput) &&
        extracted.deathDay == null &&
        !extracted.confirmedAlive) {
      _awaitingDeathDate = true;
    }

    final shouldValidateParentRelation =
        pendingRelationField == 'parentId' || updateRelationField == 'parentId';
    final shouldValidateMotherRelation =
        pendingRelationField == 'motherId' || updateRelationField == 'motherId';
    final shouldValidateSpouseRelation =
        pendingRelationField == 'spouseId' || updateRelationField == 'spouseId';

    if (shouldValidateParentRelation && extracted.parentId != null) {
      final resolvedParent = _resolveRelationReference(extracted.parentId!);
      if (resolvedParent == null) {
        setState(() {
          _messages.add(
            ChatMessage(
              text:
                  'Không có người này trong cây gia phả. Hãy nhập lại đúng NodeCode/tên trong cây, hoặc gõ "không có".',
              isUser: false,
              isError: true,
            ),
          );
          _isProcessing = false;
          _inputController.clear();
        });
        _scrollToLatestMessage();
        return;
      }
      extracted.parentId = resolvedParent;
    }

    if (shouldValidateMotherRelation && extracted.motherId != null) {
      final resolvedMother = _resolveRelationReference(extracted.motherId!);
      if (resolvedMother == null) {
        setState(() {
          _messages.add(
            ChatMessage(
              text:
                  'Không có người này trong cây gia phả. Hãy nhập lại đúng NodeCode/tên trong cây, hoặc gõ "không có".',
              isUser: false,
              isError: true,
            ),
          );
          _isProcessing = false;
          _inputController.clear();
        });
        _scrollToLatestMessage();
        return;
      }
      extracted.motherId = resolvedMother;
    }

    if (shouldValidateSpouseRelation && extracted.spouseId != null) {
      final resolvedSpouse = _resolveRelationReference(extracted.spouseId!);
      if (resolvedSpouse == null) {
        setState(() {
          _messages.add(
            ChatMessage(
              text:
                  'Không có người này trong cây gia phả. Hãy nhập lại đúng NodeCode/tên trong cây, hoặc gõ "không có".',
              isUser: false,
              isError: true,
            ),
          );
          _isProcessing = false;
          _inputController.clear();
        });
        _scrollToLatestMessage();
        return;
      }
      extracted.spouseId = resolvedSpouse;
    }

    _mergeExtractedInfo(extracted);

    if (_isUpdateFlow) {
      _awaitingUpdateSelection = true;
    }

    final nextQuestion = _getNextQuestion();
    final pct = (_completionRatio * 100).round();
    final updatedFields = _collectUpdatedFieldLabels(beforeMerge, _currentInfo);
    final response = _isUpdateFlow
        ? updatedFields.isEmpty
              ? 'Tôi chưa nhận ra trường cần cập nhật. Hãy nói rõ trường cần đổi, ví dụ: "đổi tên thành...", "đổi ngày sinh...", "chuyển sang đã mất ngày 01/01/2014", "cập nhật mô tả...".'
              : 'Đã cập nhật: ${updatedFields.join(', ')}.${nextQuestion.isNotEmpty ? '\n\n$nextQuestion' : ''}'
        : nextQuestion.isEmpty
        ? 'Đã cập nhật từ câu của bạn (hoàn thiện ~$pct%).\n'
              '- Tên: ${_currentInfo.fullName}\n'
              '- Giới tính: ${_currentInfo.sex}\n'
              '- Ngày sinh: ${_currentInfo.birthday ?? '—'}\n'
              '- Ngày mất / còn sống: ${_currentInfo.deathDay?.isNotEmpty == true ? _currentInfo.deathDay! : (_currentInfo.confirmedAlive ? 'còn sống' : '—')}\n'
              '- Cha: ${_relationLabel(_currentInfo.parentId)}\n'
              '- Mẹ: ${_relationLabel(_currentInfo.motherId)}\n'
              '- Vợ/chồng: ${_relationLabel(_currentInfo.spouseId)}\n'
              '- Địa chỉ: ${_currentInfo.addressFull ?? _currentInfo.cityProvince ?? '—'}\n'
              '\n${_footerAfterUpdate()}'
        : nextQuestion;

    setState(() {
      _messages.add(ChatMessage(text: response, isUser: false));
      _inputController.clear();
      _isProcessing = false;
    });
    _scrollToLatestMessage();
  }

  String _footerAfterUpdate() {
    if (_isUpdateFlow) {
      return 'Bạn muốn cập nhật thêm phần nào nữa? (Ví dụ: tên, giới tính, ngày sinh, còn sống/đã mất, cha/mẹ/vợ-chồng, địa chỉ, mô tả, ảnh.)';
    }
    final next = _getNextQuestion();
    final pct = (_completionRatio * 100).round();
    if (!_canSubmitNode && !_isUpdateFlow && !widget.isUpdateMode) {
      return next.isEmpty
          ? 'Hoàn thiện ~$pct%. Bạn có thể bấm Tạo node hoặc gõ OK.'
          : '$next\n(Hoàn thiện ~$pct% — đã đủ để tạo node khi có họ tên + Nam/Nữ.)';
    }
    if (next.isEmpty) {
      final miss = NodeChatService.schemaMissingHints(
        _currentInfo,
        imageStepAnswered: _hasImage != null,
      ).take(4).join('; ');
      return 'Hoàn thiện ~$pct%. Còn thiếu: $miss';
    }
    return '$next (hiện ~$pct%)';
  }

  String? _pendingField() {
    if (_isUpdateFlow) {
      return null;
    }
    if (_currentInfo.fullName == null || _currentInfo.fullName!.isEmpty) {
      return 'fullName';
    }
    if (_currentInfo.sex == null || _currentInfo.sex!.isEmpty) {
      return 'sex';
    }
    if (_currentInfo.birthday == null || _currentInfo.birthday!.isEmpty) {
      return 'birthday';
    }
    if (_currentInfo.deathDay == null || _currentInfo.deathDay!.isEmpty) {
      if (!_currentInfo.confirmedAlive) {
        return _awaitingDeathDate ? 'deathDay' : 'lifeStatus';
      }
    }
    if (_hasImage == null) {
      return 'image';
    }
    if (!_isRelationAnswered(_currentInfo.parentId)) {
      return 'parentId';
    }
    if (!_isRelationAnswered(_currentInfo.motherId)) {
      return 'motherId';
    }
    if (!_isRelationAnswered(_currentInfo.spouseId)) {
      return 'spouseId';
    }
    return null;
  }

  String? _extractSexValue(String input) {
    final normalized = NodeChatService.normalizeSemanticText(input);
    final original = input.toLowerCase();

    if (RegExp(r'\b(nu|nữ|female|girl|woman)\b').hasMatch(normalized) ||
        original.contains('nữ') ||
        original.contains('nuh') ||
        original.contains('female')) {
      return 'Nữ';
    }

    if (RegExp(r'\b(nam|male|boy|man)\b').hasMatch(normalized) ||
        original.contains(' nam ') ||
        original.startsWith('nam ') ||
        original.contains(' nam,') ||
        original.contains(' nam.') ||
        original.contains('nam sinh') ||
        original.contains('nam là') ||
        original.contains('nam,') ||
        original.contains('nam.') ||
        original.contains('male')) {
      return 'Nam';
    }

    return null;
  }

  String? _pendingRelationField() {
    final pendingField = _pendingField();
    if (pendingField == 'parentId') {
      return 'parentId';
    }
    if (pendingField == 'motherId') {
      return 'motherId';
    }
    if (pendingField == 'spouseId') {
      return 'spouseId';
    }
    return null;
  }

  String? _extractBirthdayValue(String input) {
    final normalized = NodeChatService.normalizeSemanticText(input);

    final directDate = RegExp(
      r'(?:ngay\s+)?(\d{1,2})[/-](\d{1,2})[/-](\d{2,4}|\d{4})',
    ).firstMatch(normalized);
    if (directDate != null) {
      final day = directDate.group(1) ?? '';
      final month = directDate.group(2) ?? '';
      final year = directDate.group(3) ?? '';
      if (year.length == 4) {
        return '${year.padLeft(4, '0')}-${month.padLeft(2, '0')}-${day.padLeft(2, '0')}';
      }
    }

    final spokenDate = RegExp(
      r'(?:ngay\s+)?(\d{1,2})\s+thang\s+(\d{1,2})\s+nam\s+(\d{4})',
    ).firstMatch(normalized);
    if (spokenDate != null) {
      final day = spokenDate.group(1) ?? '';
      final month = spokenDate.group(2) ?? '';
      final year = spokenDate.group(3) ?? '';
      return '${year.padLeft(4, '0')}-${month.padLeft(2, '0')}-${day.padLeft(2, '0')}';
    }

    final yearOnly = RegExp(r'^(?:nam\s+)?(\d{4})$').firstMatch(normalized);
    if (yearOnly != null) {
      final year = yearOnly.group(1) ?? '';
      return '$year-01-01';
    }

    return null;
  }

  void _mergeExtractedInfo(ExtractedNodeInfo extracted) {
    if (extracted.fullName != null && extracted.fullName!.trim().isNotEmpty) {
      _currentInfo.fullName = extracted.fullName;
    }
    if (extracted.sex != null && extracted.sex!.isNotEmpty) {
      _currentInfo.sex = extracted.sex;
    }
    if (extracted.birthday != null && extracted.birthday!.isNotEmpty) {
      _currentInfo.birthday = extracted.birthday;
    }
    if (extracted.deathDay != null && extracted.deathDay!.isNotEmpty) {
      _currentInfo.deathDay = extracted.deathDay;
    }
    if (extracted.parentId != null) {
      _currentInfo.parentId = extracted.parentId;
    }
    if (extracted.motherId != null) {
      _currentInfo.motherId = extracted.motherId;
    }
    if (extracted.spouseId != null) {
      _currentInfo.spouseId = extracted.spouseId;
    }
    if (extracted.imageBytes != null) {
      _selectedImageBytes = extracted.imageBytes;
    }
    if (extracted.description != null &&
        extracted.description!.trim().isNotEmpty) {
      _currentInfo.description = extracted.description;
    }
    if (extracted.confirmedAlive) {
      _currentInfo.confirmedAlive = true;
    }
    if (extracted.cityProvince != null &&
        extracted.cityProvince!.trim().isNotEmpty) {
      _currentInfo.cityProvince = extracted.cityProvince;
    }
    if (extracted.district != null && extracted.district!.trim().isNotEmpty) {
      _currentInfo.district = extracted.district;
    }
    if (extracted.wards != null && extracted.wards!.trim().isNotEmpty) {
      _currentInfo.wards = extracted.wards;
    }
    if (extracted.addressFull != null &&
        extracted.addressFull!.trim().isNotEmpty) {
      _currentInfo.addressFull = extracted.addressFull;
    }
    if (extracted.familyNameGroup != null &&
        extracted.familyNameGroup!.trim().isNotEmpty) {
      _currentInfo.familyNameGroup = extracted.familyNameGroup;
    }
    if (extracted.aliasName != null && extracted.aliasName!.trim().isNotEmpty) {
      _currentInfo.aliasName = extracted.aliasName;
    }

    // Auto-extract family name group from full name if not set
    if ((_currentInfo.familyNameGroup == null ||
            _currentInfo.familyNameGroup!.isEmpty) &&
        _currentInfo.fullName != null &&
        _currentInfo.fullName!.isNotEmpty) {
      final firstName = _currentInfo.fullName!.trim().split(RegExp(r'\s+'))[0];
      if (firstName.isNotEmpty) {
        _currentInfo.familyNameGroup = firstName;
      }
    }
  }

  String _getNextQuestion() {
    if (_isUpdateFlow) {
      if (_activeUpdateNodeId == null) {
        return 'Bạn muốn cập nhật node tên là gì?';
      }
      if (_awaitingUpdateSelection) {
        return 'Bạn muốn cập nhật phần nào? Ví dụ: tên, giới tính, ngày sinh, còn sống/đã mất, cha/mẹ/vợ-chồng, địa chỉ, mô tả, ảnh.';
      }
      return 'Bạn muốn cập nhật thêm phần nào nữa?';
    }
    if (_currentInfo.fullName == null || _currentInfo.fullName!.isEmpty) {
      return 'Tên của người này là gì?';
    }
    if (_currentInfo.sex == null || _currentInfo.sex!.isEmpty) {
      return 'Người này là nam hay nữ? (Nam/Nữ)';
    }
    if (_currentInfo.birthday == null || _currentInfo.birthday!.isEmpty) {
      return 'Ngày sinh là khi nào? (dd/mm/yyyy hoặc chỉ năm)';
    }
    if (_currentInfo.deathDay == null || _currentInfo.deathDay!.isEmpty) {
      if (_currentInfo.confirmedAlive) {
        // continue
      } else if (_awaitingDeathDate) {
        return 'Người này mất năm nào? Nếu có ngày chính xác, bạn cho luôn ngày mất.';
      } else {
        return 'Người này còn sống hay đã mất? Nếu đã mất thì mất năm nào (hoặc ngày nào)?';
      }
    }
    if (_hasImage == null) {
      return 'Có ảnh cho node này không? Nếu có, bấm "Chọn ảnh" bên dưới hoặc nói "có ảnh"; không thì nói "không có".';
    }
    if (!_isRelationAnswered(_currentInfo.parentId)) {
      return 'Cha của người này là ai? (NodeCode, hoặc nói "không có")';
    }
    if (!_isRelationAnswered(_currentInfo.motherId)) {
      return 'Mẹ của người này là ai? (NodeCode, hoặc nói "không có")';
    }
    if (!_isRelationAnswered(_currentInfo.spouseId)) {
      return 'Vợ/chồng của người này là ai? (NodeCode, hoặc nói "không có")';
    }

    return '';
  }

  bool _containsExplicitNameIntent(String normalized) {
    return NodeChatService.matchesAnySemantic(normalized, const [
      'tên',
      'tên là',
      'họ tên',
      'goi la',
      'đặt tên',
      'dat ten',
      'đổi tên',
      'doi ten',
      'sửa tên',
      'sua ten',
    ]);
  }

  bool _containsExplicitDescriptionIntent(String normalized) {
    return NodeChatService.matchesAnySemantic(normalized, const [
      'mô tả',
      'mo ta',
      'mota',
      'tiểu sử',
      'tieu su',
      'ghi chú',
      'ghi chu',
      'ghi thêm',
      'description',
      'note',
      'bio',
    ]);
  }

  List<String> _collectUpdatedFieldLabels(
    ExtractedNodeInfo before,
    ExtractedNodeInfo after,
  ) {
    final updated = <String>[];

    void addIfChanged(String label, String? a, String? b) {
      final beforeValue = (a ?? '').trim();
      final afterValue = (b ?? '').trim();
      if (beforeValue != afterValue) {
        updated.add(label);
      }
    }

    addIfChanged('tên', before.fullName, after.fullName);
    addIfChanged('giới tính', before.sex, after.sex);
    addIfChanged('ngày sinh', before.birthday, after.birthday);
    addIfChanged('ngày mất', before.deathDay, after.deathDay);
    addIfChanged('cha', before.parentId, after.parentId);
    addIfChanged('mẹ', before.motherId, after.motherId);
    addIfChanged('vợ/chồng', before.spouseId, after.spouseId);
    addIfChanged('địa chỉ', before.addressFull, after.addressFull);
    addIfChanged('mô tả', before.description, after.description);

    if (before.confirmedAlive != after.confirmedAlive) {
      updated.add('tình trạng sống/mất');
    }

    return updated;
  }

  String _fieldDisplayName(String fieldName) {
    return switch (fieldName) {
      'fullName' => 'tên',
      'sex' => 'giới tính',
      'birthday' => 'ngày sinh',
      'deathDay' => 'ngày mất',
      'confirmedAlive' => 'tình trạng sống/mất',
      'parentId' => 'cha',
      'motherId' => 'mẹ',
      'spouseId' => 'vợ/chồng',
      'description' => 'mô tả',
      'addressFull' => 'địa chỉ',
      'cityProvince' => 'tỉnh/thành',
      'district' => 'quận/huyện',
      'wards' => 'phường/xã',
      _ => fieldName,
    };
  }

  bool _isDeathMentionOnly(String normalized) {
    final hasDeathHint = NodeChatService.matchesAnySemantic(normalized, const [
      'đã mất',
      'da mat',
      'mất',
      'mat',
      'chết',
      'chet',
      'qua đời',
      'qua doi',
    ]);
    if (!hasDeathHint) return false;

    final hasAliveHint = NodeChatService.matchesAnySemantic(normalized, const [
      'còn sống',
      'con song',
      'chưa mất',
      'chua mat',
      'chưa chết',
      'chua chet',
      'vẫn sống',
      'van song',
    ]);
    if (hasAliveHint) return false;

    final hasDate = RegExp(
      r'\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4}',
    ).hasMatch(normalized);
    return !hasDate;
  }

  void _submitNode() {
    if (!_canSubmitNode && !widget.isUpdateMode) {
      final miss = NodeChatService.schemaMissingHints(
        _currentInfo,
        imageStepAnswered: _hasImage != null,
      );
      setState(() {
        _messages.add(
          ChatMessage(
            text:
                'Chưa đủ điều kiện tạo node (cần họ tên + Nam/Nữ và hoàn thiện ~${(NodeChatService.schemaReadyThreshold * 100).round()}%). '
                'Hiện ~${(_completionRatio * 100).round()}%. Còn thiếu: ${miss.take(6).join('; ')}.',
            isUser: false,
            isError: true,
          ),
        );
      });
      _scrollToLatestMessage();
      return;
    }

    final normalizedInfo = ExtractedNodeInfo(
      fullName: _currentInfo.fullName,
      aliasName: _currentInfo.aliasName,
      sex: _currentInfo.sex,
      birthday: _currentInfo.birthday,
      deathDay: _currentInfo.deathDay,
      description: _currentInfo.description,
      parentId: _normalizeRelationValue(_currentInfo.parentId),
      motherId: _normalizeRelationValue(_currentInfo.motherId),
      imageUrl: _currentInfo.imageUrl,
      spouseId: _normalizeRelationValue(_currentInfo.spouseId),
      imageBytes: _selectedImageBytes,
      level: _currentInfo.level,
      branch: _currentInfo.branch,
      hand: _currentInfo.hand,
      familyNameGroup: _currentInfo.familyNameGroup,
      cityProvince: _currentInfo.cityProvince,
      district: _currentInfo.district,
      wards: _currentInfo.wards,
      addressFull: _currentInfo.addressFull,
      confirmedAlive: _currentInfo.confirmedAlive,
    );

    final errors = NodeChatService.validateNodeInfo(normalizedInfo);

    if (errors.isNotEmpty) {
      setState(() {
        _messages.add(
          ChatMessage(
            text: 'Lỗi: ${errors.values.join(', ')}',
            isUser: false,
            isError: true,
          ),
        );
      });
      return;
    }

    if (_isUpdateFlow && _activeUpdateNodeId != null) {
      widget.onNodeUpdated?.call(_activeUpdateNodeId!, normalizedInfo);
    } else {
      widget.onNodeCreated(normalizedInfo);
    }
    _persistDraftOnDispose = false;
    _clearDraftSnapshot();
    if (mounted) {
      Navigator.pop(context);
    }
  }

  void _editField(String fieldName) {
    showDialog(
      context: context,
      builder: (ctx) => _EditFieldDialog(
        fieldName: fieldName,
        currentValue: _getFieldValue(fieldName),
        onSave: (value) {
          setState(() {
            _setFieldValue(fieldName, value);
          });
        },
      ),
    );
  }

  String _getFieldValue(String fieldName) {
    return switch (fieldName) {
      'fullName' => _currentInfo.fullName ?? '',
      'sex' => _currentInfo.sex ?? '',
      'birthday' => _currentInfo.birthday ?? '',
      'deathDay' => _currentInfo.deathDay ?? '',
      'parentId' => _currentInfo.parentId ?? '',
      'motherId' => _currentInfo.motherId ?? '',
      'spouseId' => _currentInfo.spouseId ?? '',
      'description' => _currentInfo.description ?? '',
      'aliasName' => _currentInfo.aliasName ?? '',
      'familyNameGroup' => _currentInfo.familyNameGroup ?? '',
      'cityProvince' => _currentInfo.cityProvince ?? '',
      'district' => _currentInfo.district ?? '',
      'wards' => _currentInfo.wards ?? '',
      'addressFull' => _currentInfo.addressFull ?? '',
      _ => '',
    };
  }

  void _setFieldValue(String fieldName, String value) {
    switch (fieldName) {
      case 'fullName':
        _currentInfo.fullName = value;
        break;
      case 'sex':
        _currentInfo.sex = value;
        break;
      case 'birthday':
        _currentInfo.birthday = value;
        break;
      case 'deathDay':
        _currentInfo.deathDay = value;
        break;
      case 'parentId':
        _currentInfo.parentId = value;
        break;
      case 'motherId':
        _currentInfo.motherId = value;
        break;
      case 'spouseId':
        _currentInfo.spouseId = value;
        break;
      case 'description':
        _currentInfo.description = value;
        break;
      case 'aliasName':
        _currentInfo.aliasName = value;
        break;
      case 'familyNameGroup':
        _currentInfo.familyNameGroup = value;
        break;
      case 'cityProvince':
        _currentInfo.cityProvince = value;
        break;
      case 'district':
        _currentInfo.district = value;
        break;
      case 'wards':
        _currentInfo.wards = value;
        break;
      case 'addressFull':
        _currentInfo.addressFull = value;
        break;
    }
  }

  bool _isRelationAnswered(String? value) =>
      NodeChatService.relationFieldAnswered(value);

  String? _normalizeRelationValue(String? value) {
    if (value == null || value.isEmpty || value == kNoRelationMarker) {
      return '';
    }
    return value;
  }

  String _relationLabel(String? value) {
    if (value == null || value.isEmpty) {
      return '—';
    }
    if (value == kNoRelationMarker) {
      return 'không có';
    }
    final name = widget.availableNodeLabels[value];
    if (name != null && name.isNotEmpty) {
      return '$value ($name)';
    }
    return value;
  }

  bool _isNoRelationAnswer(String normalized) {
    return NodeChatService.matchesAnySemantic(normalized, const [
      'không có',
      'ko có',
      'khong co',
      'không biết',
      'ko biet',
      'khong biet',
      'không rõ',
      'ko ro',
      'khong ro',
      'không',
      'none',
      'null',
    ]);
  }

  String? _extractRelationValue(String input, List<String> keywords) {
    final normalized = NodeChatService.normalizeSemanticText(input);
    if (_isNoRelationAnswer(normalized)) {
      return kNoRelationMarker;
    }

    final normalizedKeywords =
        keywords
            .map(NodeChatService.normalizeSemanticText)
            .where((keyword) => keyword.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));

    for (final keyword in normalizedKeywords) {
      final pattern = RegExp(
        '(?:^|\\b)${RegExp.escape(keyword)}(?:\\s+là\\s+|\\s*:\\s*|\\s+)(.+)\$',
        caseSensitive: false,
      );
      final match = pattern.firstMatch(normalized);
      if (match != null) {
        final value = match.group(1)?.trim();
        if (value != null && value.isNotEmpty) {
          return value;
        }
      }
    }
    return null;
  }

  String? _resolveRelationReference(String rawValue) {
    final value = rawValue.trim();
    if (value.isEmpty) {
      return null;
    }

    if (value == kNoRelationMarker) {
      return kNoRelationMarker;
    }

    final normalized = NodeChatService.normalizeSemanticText(value);
    if (_isNoRelationAnswer(normalized)) {
      return kNoRelationMarker;
    }

    if (widget.availableNodeIds.isEmpty && widget.availableNodeLabels.isEmpty) {
      return null;
    }

    final queryVariants = _buildRelationQueryVariants(value);
    if (queryVariants.isEmpty) {
      return null;
    }

    final exactMatches = <String>{};

    for (final nodeId in widget.availableNodeIds) {
      final candidates = _buildNodeSearchCandidates(nodeId);
      for (final query in queryVariants) {
        if (query == nodeId.toLowerCase() || candidates.contains(query)) {
          exactMatches.add(nodeId);
        }
      }
    }

    if (exactMatches.length == 1) {
      return exactMatches.first;
    }

    return null;
  }

  Set<String> _buildNodeSearchCandidates(String nodeId) {
    final info = widget.availableNodeInfos[nodeId];
    final label = widget.availableNodeLabels[nodeId] ?? '';
    final rawCandidates = <String>[
      nodeId,
      label,
      info?.fullName ?? '',
      info?.aliasName ?? '',
      info?.familyNameGroup ?? '',
    ];

    final normalized = <String>{};
    for (final raw in rawCandidates) {
      final norm = NodeChatService.normalizeSemanticText(raw);
      if (norm.isNotEmpty) {
        normalized.add(norm);
      }
    }
    return normalized;
  }

  List<String> _buildRelationQueryVariants(String input) {
    final variants = <String>{};

    void addVariant(String raw) {
      final normalized = NodeChatService.normalizeSemanticText(raw)
          .replaceAll(RegExp(r'''^[\s"']+|[\s"']+$'''), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (normalized.isNotEmpty) {
        variants.add(normalized);
      }
    }

    addVariant(input);

    final normalizedInput = NodeChatService.normalizeSemanticText(input);

    final afterConnector = RegExp(
      r'(?:\b(?:la|ten la|la ten|ma|id|node|nodecode|thanh|sang|voi)\b\s*)(.+)$',
      caseSensitive: false,
    ).firstMatch(normalizedInput);
    if (afterConnector != null) {
      addVariant(afterConnector.group(1) ?? '');
    }

    final afterRelation = RegExp(
      r'^(?:\b(?:them|cap nhat|doi|sua|thay|gan|set)\b\s*)?(?:\b(?:cha|bo|ba|father|dad|me|mother|mom|vo|chong|wife|husband|spouse|partner|nguoi cha|nguoi me)\b\s*)(.+)$',
      caseSensitive: false,
    ).firstMatch(normalizedInput);
    if (afterRelation != null) {
      addVariant(afterRelation.group(1) ?? '');
    }

    for (final variant in variants.toList()) {
      final cleaned = variant
          .replaceFirst(
            RegExp(r'^(?:la|ten la|la ten|ma|id|node|nodecode)\s+'),
            '',
          )
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (cleaned.isNotEmpty && cleaned != variant) {
        variants.add(cleaned);
      }
    }

    return variants.toList();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.shade700,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    (_isUpdateFlow || widget.isUpdateMode)
                        ? 'Chat AI — cập nhật node'
                        : 'Chat AI — thêm node',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // Chat messages
            Expanded(
              child: Column(
                children: [
                  Material(
                    color: Colors.blue.shade50,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Hoàn thiện schema (~90% để tạo node)',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.blue.shade900,
                                ),
                              ),
                              Text(
                                '${(_completionRatio * 100).round()}%',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.blue.shade900,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: _completionRatio.clamp(0.0, 1.0),
                              minHeight: 8,
                              backgroundColor: Colors.blue.shade100,
                              color: _canSubmitNode
                                  ? Colors.green.shade600
                                  : Colors.blue.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      controller: _chatScrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: _messages.length,
                      itemBuilder: (ctx, i) => _buildChatMessage(_messages[i]),
                    ),
                  ),
                ],
              ),
            ),

            // Input area
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Colors.grey.shade300)),
              ),
              child: Column(
                children: [
                  // Quick field editor
                  if (_currentInfo.fullName != null &&
                      _currentInfo.fullName!.isNotEmpty)
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _QuickEditChip(
                            label: 'Tên: ${_currentInfo.fullName}',
                            onTap: () => _editField('fullName'),
                          ),
                          if (_currentInfo.sex != null)
                            _QuickEditChip(
                              label: 'Giới: ${_currentInfo.sex}',
                              onTap: () => _editField('sex'),
                            ),
                          if (_currentInfo.birthday != null &&
                              _currentInfo.birthday!.isNotEmpty)
                            _QuickEditChip(
                              label: 'Sinh: ${_currentInfo.birthday}',
                              onTap: () => _editField('birthday'),
                            ),
                          if (_currentInfo.cityProvince != null &&
                              _currentInfo.cityProvince!.isNotEmpty)
                            _QuickEditChip(
                              label: 'Tỉnh/TP',
                              onTap: () => _editField('cityProvince'),
                            ),
                          if (_currentInfo.addressFull != null &&
                              _currentInfo.addressFull!.isNotEmpty)
                            _QuickEditChip(
                              label: 'Địa chỉ',
                              onTap: () => _editField('addressFull'),
                            ),
                          _QuickEditChip(
                            label: 'Mô tả +',
                            onTap: () => _editField('description'),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  // Text input
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _inputController,
                          decoration: InputDecoration(
                            hintText: 'Nói hoặc gõ thông tin...',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _canUseSpeech
                                    ? (_isListening ? Icons.mic_off : Icons.mic)
                                    : Icons.mic_off,
                                color: !_canUseSpeech
                                    ? Colors.grey
                                    : _isListening
                                    ? Colors.red
                                    : null,
                              ),
                              tooltip: !_canUseSpeech
                                  ? 'Mic tắt trên web'
                                  : _isListening
                                  ? 'Dừng ghi âm'
                                  : 'Bật ghi âm',
                              onPressed: _isProcessing || !_canUseSpeech
                                  ? null
                                  : _toggleMic,
                            ),
                          ),
                          enabled: !_isProcessing,
                          onSubmitted: _isProcessing ? null : _handleUserText,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FloatingActionButton(
                        mini: true,
                        onPressed: _isProcessing
                            ? null
                            : () {
                                _handleUserText(_inputController.text);
                              },
                        child: const Icon(Icons.send),
                      ),
                    ],
                  ),
                  if (_voicePreview.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Text(
                          'Đã nhận: $_voicePreview',
                          style: TextStyle(
                            color: Colors.orange.shade900,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: _isProcessing ? null : _pickImage,
                        icon: const Icon(Icons.image_outlined),
                        label: const Text('Chọn ảnh'),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _selectedImageBytes != null
                            ? 'Đã có ảnh'
                            : _hasImage == false
                            ? 'Không dùng ảnh'
                            : 'Chưa chọn ảnh',
                        style: TextStyle(
                          color: _selectedImageBytes != null
                              ? Colors.green.shade700
                              : Colors.grey.shade700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Action buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _persistDraftOnDispose = false;
                            _currentInfo = ExtractedNodeInfo();
                            _clearRuntimeState();
                          });
                          _clearDraftSnapshot();
                          _scrollToLatestMessage();
                        },
                        child: const Text('Bắt đầu lại'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _isProcessing || !_canSubmitNode
                            ? null
                            : _submitNode,
                        icon: const Icon(Icons.check),
                        label: Text(
                          (_isUpdateFlow || widget.isUpdateMode)
                              ? 'Lưu cập nhật'
                              : 'Tạo node',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatMessage(ChatMessage msg) {
    return Align(
      alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.7,
        ),
        decoration: BoxDecoration(
          color: msg.isUser
              ? Colors.blue.shade100
              : msg.isError
              ? Colors.red.shade100
              : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          msg.text,
          style: TextStyle(
            color: msg.isError ? Colors.red.shade900 : Colors.black87,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

class ChatMessage {
  final String text;
  final bool isUser;
  final bool isError;

  ChatMessage({required this.text, this.isUser = false, this.isError = false});
}

enum _CommandType {
  chatInput,
  submit,
  reset,
  greeting,
  closeDialog,
  imageYes,
  imageNo,
  switchToUpdateTarget,
  updateField,
}

class _NormalizedCommand {
  final _CommandType type;
  final String? field;
  final String? value;

  const _NormalizedCommand({required this.type, this.field, this.value});
}

class _ChatDraftSnapshot {
  final ExtractedNodeInfo currentInfo;
  final List<ChatMessage> messages;
  final bool? hasImage;
  final bool awaitingDeathDate;
  final bool isUpdateFlow;
  final bool awaitingUpdateSelection;
  final String? activeUpdateNodeId;
  final Uint8List? selectedImageBytes;
  final String voicePreview;
  final String pendingInput;

  const _ChatDraftSnapshot({
    required this.currentInfo,
    required this.messages,
    required this.hasImage,
    required this.awaitingDeathDate,
    required this.isUpdateFlow,
    required this.awaitingUpdateSelection,
    required this.activeUpdateNodeId,
    required this.selectedImageBytes,
    required this.voicePreview,
    required this.pendingInput,
  });
}

class _QuickEditChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _QuickEditChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ActionChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        onPressed: onTap,
      ),
    );
  }
}

class _EditFieldDialog extends StatefulWidget {
  final String fieldName;
  final String currentValue;
  final Function(String) onSave;

  const _EditFieldDialog({
    required this.fieldName,
    required this.currentValue,
    required this.onSave,
  });

  @override
  State<_EditFieldDialog> createState() => _EditFieldDialogState();
}

class _EditFieldDialogState extends State<_EditFieldDialog> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fieldLabels = {
      'fullName': 'Tên đầy đủ',
      'sex': 'Giới tính (Nam/Nữ)',
      'birthday': 'Ngày sinh (yyyy-mm-dd)',
      'deathDay': 'Ngày chết (yyyy-mm-dd)',
      'parentId': 'Node ID của cha',
      'motherId': 'Node ID của mẹ',
      'spouseId': 'Node ID vợ/chồng',
      'aliasName': 'Biệt danh / tên thường gọi',
      'familyNameGroup': 'Dòng họ',
      'cityProvince': 'Tỉnh / Thành phố',
      'district': 'Huyện',
      'wards': 'Xã / Phường',
      'addressFull': 'Địa chỉ đầy đủ',
      'description': 'Mô tả / tiểu sử',
    };

    return AlertDialog(
      title: Text(
        'Chỉnh sửa: ${fieldLabels[widget.fieldName] ?? widget.fieldName}',
      ),
      content: TextField(
        controller: _controller,
        maxLines:
            widget.fieldName == 'description' ||
                widget.fieldName == 'addressFull'
            ? 3
            : 1,
        decoration: InputDecoration(
          hintText: 'Nhập giá trị',
          border: const OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        ElevatedButton(
          onPressed: () {
            widget.onSave(_controller.text);
            Navigator.pop(context);
          },
          child: const Text('Lưu'),
        ),
      ],
    );
  }
}
