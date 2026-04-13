import 'dart:typed_data';

/// Giá trị đặc biệt: người dùng xác nhận không có quan hệ (cha/mẹ/vợ chồng).
const String kNoRelationMarker = '__NO_RELATION__';

/// Extracted node information from user input — căn chỉnh trường gần với
/// `family-tree-500node.json` (NodeCode, FullName, CityProvince, …).
class ExtractedNodeInfo {
  String? fullName;
  String? aliasName;
  String? sex; // Nam, Nữ
  String? birthday;
  String? deathDay;
  String? description;
  String? parentId;
  String? motherId;
  String? spouseId;
  Uint8List? imageBytes;
  String? imageUrl;
  int? level;
  int? branch;
  int? hand;
  String? familyNameGroup;

  /// Tỉnh/TP — map JSON `CityProvince`
  String? cityProvince;

  /// Huyện — map JSON `Dicstrict` (đúng theo file mẫu)
  String? district;

  /// Xã/phường — map `Wards`
  String? wards;

  /// Chuỗi địa chỉ đầy đủ — map `AddressFull`
  String? addressFull;

  /// Người dùng nói rõ còn sống / chưa mất (bổ sung cho slot trạng thái).
  bool confirmedAlive;

  ExtractedNodeInfo({
    this.fullName,
    this.aliasName,
    this.sex,
    this.birthday,
    this.deathDay,
    this.description,
    this.parentId,
    this.motherId,
    this.spouseId,
    this.imageBytes,
    this.imageUrl,
    this.level,
    this.branch,
    this.hand,
    this.familyNameGroup,
    this.cityProvince,
    this.district,
    this.wards,
    this.addressFull,
    this.confirmedAlive = false,
  });

  bool get isValid => fullName != null && fullName!.trim().isNotEmpty;

  /// Chuẩn hoá theo schema gia phả (một node phẳng, không cây con lồng).
  Map<String, dynamic> toNodeJson() => {
    'NodeCode': 'AUTO_${DateTime.now().millisecondsSinceEpoch}',
    'FullName': fullName ?? '',
    'AliasName': aliasName ?? fullName ?? '',
    'Sex': sex ?? '',
    'FamilyNameGroup': familyNameGroup ?? '',
    'Parent': parentId ?? '',
    'MotherID': motherId ?? '',
    'Level': level ?? 0,
    'Branch': branch ?? 0,
    'Hand': hand ?? 1,
    'CityProvince': cityProvince,
    'Dicstrict': district,
    'Wards': wards,
    'AddressFull': addressFull,
    'Birthday': birthday != null && birthday!.isNotEmpty
        ? '${birthday}T00:00:00'
        : null,
    'DeadDay': deathDay != null && deathDay!.isNotEmpty
        ? '${deathDay}T00:00:00'
        : null,
    'Description': description != null && description!.isNotEmpty
        ? description
        : null,
    'Image': imageUrl ?? '',
    'MultipleMediaList': '[]',
    'MarriedHist': null,
    'Siblings': null,
    'IsDeleted': false,
    'IsDead': deathDay != null && deathDay!.isNotEmpty,
    'Children': <dynamic>[],
    'HasImage':
        imageBytes != null || (imageUrl != null && imageUrl!.isNotEmpty),
    'SpouseID': spouseId ?? '',
  };

  ExtractedNodeInfo copyWith({
    String? fullName,
    String? aliasName,
    String? sex,
    String? birthday,
    String? deathDay,
    String? description,
    String? parentId,
    String? motherId,
    String? spouseId,
    Uint8List? imageBytes,
    String? imageUrl,
    int? level,
    int? branch,
    int? hand,
    String? familyNameGroup,
    String? cityProvince,
    String? district,
    String? wards,
    String? addressFull,
    bool? confirmedAlive,
  }) {
    return ExtractedNodeInfo(
      fullName: fullName ?? this.fullName,
      aliasName: aliasName ?? this.aliasName,
      sex: sex ?? this.sex,
      birthday: birthday ?? this.birthday,
      deathDay: deathDay ?? this.deathDay,
      description: description ?? this.description,
      parentId: parentId ?? this.parentId,
      motherId: motherId ?? this.motherId,
      spouseId: spouseId ?? this.spouseId,
      imageBytes: imageBytes ?? this.imageBytes,
      imageUrl: imageUrl ?? this.imageUrl,
      level: level ?? this.level,
      branch: branch ?? this.branch,
      hand: hand ?? this.hand,
      familyNameGroup: familyNameGroup ?? this.familyNameGroup,
      cityProvince: cityProvince ?? this.cityProvince,
      district: district ?? this.district,
      wards: wards ?? this.wards,
      addressFull: addressFull ?? this.addressFull,
      confirmedAlive: confirmedAlive ?? this.confirmedAlive,
    );
  }
}

/// Service to extract node information from natural language
class NodeChatService {
  static final Map<String, List<String>> _fieldSynonyms = {
    'fullName': [
      'tên',
      'ten',
      'họ tên',
      'ho ten',
      'đặt tên',
      'dat ten',
      'người này tên',
      'nguoi nay ten',
      'gọi là',
      'goi la',
    ],
    'sex': [
      'giới tính',
      'gioi tinh',
      'nam hay nữ',
      'nam hay nu',
      'giới',
      'gioi',
      'phái',
      'phai',
      'male',
      'female',
    ],
    'birthday': [
      'ngày sinh',
      'ngay sinh',
      'sinh',
      'sinh năm',
      'sinh nam',
      'birthday',
      'born',
      'dob',
      'năm sinh',
      'nam sinh',
    ],
    'deathDay': [
      'ngày mất',
      'ngay mat',
      'qua đời',
      'qua doi',
      'mất',
      'mat',
      'từ trần',
      'tu tran',
      'death',
      'died',
    ],
    'parentId': [
      'cha',
      'bố',
      'bo',
      'phụ thân',
      'phu than',
      'father',
      'dad',
      'người cha',
      'nguoi cha',
    ],
    'motherId': [
      'mẹ',
      'me',
      'mẫu thân',
      'mau than',
      'mother',
      'mom',
      'người mẹ',
      'nguoi me',
    ],
  };

  /// Extract structured node info from user input
  /// Supports Vietnamese and English
  static ExtractedNodeInfo extractNodeInfo(String userInput) {
    final info = ExtractedNodeInfo();
    final text = userInput.toLowerCase().trim();
    final normalized = _normalizeSemanticText(userInput);

    // Extract full name (usually first meaningful word)
    // Look for patterns like "tên là [name]", "tên [name]", "[name]"
    info.fullName = _extractName(userInput);

    // Extract sex
    if (_matchesAny(normalized, _fieldSynonyms['sex']!) ||
        text.contains('nữ') ||
        text.contains('em gái') ||
        text.contains('chị gái') ||
        text.contains('bà') ||
        text.contains('cô')) {
      info.sex = 'Nữ';
    } else if (normalized.contains('nam') ||
        text.contains('anh') ||
        text.contains('em trai') ||
        text.contains('ông') ||
        text.contains('chú')) {
      info.sex = 'Nam';
    } else if (normalized.contains('female') ||
        normalized.contains('girl') ||
        normalized.contains('woman')) {
      info.sex = 'Nữ';
    } else if (normalized.contains('male') ||
        normalized.contains('boy') ||
        normalized.contains('man')) {
      info.sex = 'Nam';
    }

    // Extract birthday (formats: dd/mm/yyyy, dd-mm-yyyy, yyyy-mm-dd)
    info.birthday = _extractDate(text, [
      'sinh',
      'birthday',
      'born',
      'dob',
      'năm sinh',
      'nam sinh',
    ], allowStandaloneDate: true);

    // Extract death day
    info.deathDay = _extractDate(text, [
      'mất',
      'chết',
      'death',
      'died',
      'deadday',
      'qua đời',
      'tu tran',
    ], allowStandaloneDate: false);

    // Extract age/generation level
    final levelMatch = RegExp(
      r'thế hệ (\d+)|level (\d+)|generation (\d+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (levelMatch != null) {
      final num =
          levelMatch.group(1) ?? levelMatch.group(2) ?? levelMatch.group(3);
      info.level = int.tryParse(num ?? '0');
    }

    // Extract parent/father
    info.parentId = _extractRelativeName(text, ['cha', 'father', 'bố', 'papa']);

    // Extract mother
    info.motherId = _extractRelativeName(text, ['mẹ', 'mother', 'má', 'mama']);

    // Extract spouse
    info.spouseId = _extractRelativeName(text, [
      'vợ',
      'chồng',
      'wife',
      'husband',
      'partner',
      'spouse',
    ]);

    // Extract description/notes
    info.description = _extractDescription(userInput);

    final alias = _extractAlias(userInput);
    if (alias != null && alias.isNotEmpty) {
      info.aliasName = alias;
    }

    _extractAddressFields(info, userInput);

    if (_detectAliveConfirmation(normalized)) {
      info.confirmedAlive = true;
    }

    return info;
  }

  static String? _extractAlias(String input) {
    final patterns = [
      RegExp(r'biệt\s+danh\s+(?:là\s*)?([^\n,;]+)', caseSensitive: false),
      RegExp(
        r'tên\s+thường\s+gọi\s+(?:là\s*)?([^\n,;]+)',
        caseSensitive: false,
      ),
      RegExp(r'còn\s+gọi\s+là\s+([^\n,;]+)', caseSensitive: false),
      RegExp(r'alias\s*[:/]\s*([^\n,;]+)', caseSensitive: false),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(input);
      if (m != null) {
        final s = m.group(1)?.trim();
        if (s != null && s.isNotEmpty) {
          return s;
        }
      }
    }
    return null;
  }

  static void _extractAddressFields(ExtractedNodeInfo info, String input) {
    final prov = RegExp(
      r'(?:tỉnh|thành\s+phố|thanh\s+pho|tp\.?)\s*[:/]?\s*([^\n,;]+)',
      caseSensitive: false,
    ).firstMatch(input);
    if (prov != null) {
      final v = prov.group(1)?.trim();
      if (v != null && v.isNotEmpty) {
        info.cityProvince = v;
      }
    }
    final dist = RegExp(
      r'huyện\s*[:/]?\s*([^\n,;]+)',
      caseSensitive: false,
    ).firstMatch(input);
    if (dist != null) {
      final v = dist.group(1)?.trim();
      if (v != null && v.isNotEmpty) {
        info.district = v;
      }
    }
    final ward = RegExp(
      r'(?:xã|phường|thi\s+trấn)\s*[:/]?\s*([^\n,;]+)',
      caseSensitive: false,
    ).firstMatch(input);
    if (ward != null) {
      final v = ward.group(1)?.trim();
      if (v != null && v.isNotEmpty) {
        info.wards = v;
      }
    }
    final full = RegExp(
      r'địa\s+chỉ\s*(?:đầy\s+đủ|full)?\s*[:/]?\s*([^\n]+)',
      caseSensitive: false,
    ).firstMatch(input);
    if (full != null) {
      final v = full.group(1)?.trim();
      if (v != null && v.isNotEmpty) {
        info.addressFull = v;
      }
    }
  }

  static bool _detectAliveConfirmation(String normalized) {
    return matchesAnySemantic(normalized, [
      'con song',
      'van con song',
      'chua mat',
      'chua chet',
      'chua qua doi',
      'van song',
      'song khoe',
      'chua he mat',
      'chua biet mat',
      'song tot',
    ]);
  }

  /// Đã trả lời quan hệ (có NodeCode / tên map được / hoặc "không có").
  static bool relationFieldAnswered(String? value) {
    if (value == null) {
      return false;
    }
    return value.isNotEmpty || value == kNoRelationMarker;
  }

  /// Ngưỡng ~90% — đủ để gợi ý tạo node (vẫn cần họ tên + giới tính hợp lệ).
  static const double schemaReadyThreshold = 0.9;

  /// Tỉ lệ 0–1 theo trọng số trường (gần với schema JSON gia phả).
  static double computeSchemaCompletionRatio(
    ExtractedNodeInfo info, {
    required bool imageStepAnswered,
  }) {
    var earned = 0.0;
    const total = 100.0;
    void add(bool ok, double w) {
      if (ok) {
        earned += w;
      }
    }

    add(info.fullName?.trim().isNotEmpty == true, 17);
    add(info.sex == 'Nam' || info.sex == 'Nữ', 12);
    add(info.birthday?.trim().isNotEmpty == true, 12);
    add(relationFieldAnswered(info.parentId), 11);
    add(relationFieldAnswered(info.motherId), 11);
    add(relationFieldAnswered(info.spouseId), 9);
    add(imageStepAnswered, 6);
    add((info.deathDay?.trim().isNotEmpty == true) || info.confirmedAlive, 6);
    add(info.description?.trim().isNotEmpty == true, 6);
    add(
      (info.aliasName?.trim().isNotEmpty == true) ||
          (info.familyNameGroup?.trim().isNotEmpty == true),
      5,
    );
    add(
      (info.cityProvince?.trim().isNotEmpty == true) ||
          (info.addressFull?.trim().isNotEmpty == true),
      5,
    );

    return earned / total;
  }

  /// Gợi ý trường còn thiếu (để bot hỏi tiếp).
  static List<String> schemaMissingHints(
    ExtractedNodeInfo info, {
    required bool imageStepAnswered,
  }) {
    final m = <String>[];
    if (info.fullName?.trim().isEmpty != false) {
      m.add('họ tên');
    }
    if (info.sex != 'Nam' && info.sex != 'Nữ') {
      m.add('giới tính');
    }
    if (info.birthday?.trim().isEmpty != false) {
      m.add('ngày sinh hoặc năm sinh');
    }
    if (!relationFieldAnswered(info.parentId)) {
      m.add('cha (NodeCode / tên trong cây / "không có")');
    }
    if (!relationFieldAnswered(info.motherId)) {
      m.add('mẹ (NodeCode / tên / "không có")');
    }
    if (!relationFieldAnswered(info.spouseId)) {
      m.add('vợ/chồng (NodeCode / tên / "không có")');
    }
    if (!imageStepAnswered) {
      m.add('ảnh đại diện (có / không)');
    }
    if (info.deathDay?.trim().isEmpty != false && !info.confirmedAlive) {
      m.add('ngày mất hoặc xác nhận còn sống');
    }
    if (info.description?.trim().isEmpty != false) {
      m.add('mô tả / tiểu sử ngắn');
    }
    if (info.aliasName?.trim().isEmpty != false &&
        info.familyNameGroup?.trim().isEmpty != false) {
      m.add('biệt danh hoặc dòng họ');
    }
    if (info.cityProvince?.trim().isEmpty != false &&
        info.addressFull?.trim().isEmpty != false) {
      m.add('tỉnh/TP hoặc địa chỉ');
    }
    return m;
  }

  /// Extract name from input
  static String? _extractName(String input) {
    final trimmed = input.trim();
    if (RegExp(r'^\d+(?:[\s./-]\d+)*$').hasMatch(trimmed)) {
      return null;
    }

    final semantic = _normalizeSemanticText(input);
    if (_isGreetingOnly(semantic)) {
      return null;
    }
    final patterns = [
      RegExp(
        r'tên(?:\s+là|\s+là)?\s+([a-zàáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ\s]+)',
        caseSensitive: false,
      ),
      RegExp(
        r'(?:ho ten|ten|goi la|nguoi nay ten)\s+([a-z\s]+)',
        caseSensitive: false,
      ),
      RegExp(r'name\s+([a-zA-Z\s]+)', caseSensitive: false),
      RegExp(
        r'^([a-zàáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ\s]+)[,.]',
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(
        semantic.contains('ten') || semantic.contains('goi la')
            ? semantic
            : input,
      );
      if (match != null) {
        final name = _cleanupCapturedText(match.group(1) ?? '');
        if (name.isNotEmpty) {
          if (RegExp(r'^\d+$').hasMatch(name.replaceAll(RegExp(r'\s+'), ''))) {
            continue;
          }
          return _toTitleCase(name);
        }
      }
    }

    // Fallback only for short, name-like utterances. This avoids treating
    // unrelated responses such as "không có ảnh" as a person name.
    final parts = input.split(RegExp(r'[,\.\?!;]'));
    if (parts.isNotEmpty) {
      final firstPart = parts.first.trim();
      final normalizedFirstPart = _normalizeSemanticText(firstPart);
      final tokenCount = normalizedFirstPart
          .split(' ')
          .where((token) => token.isNotEmpty)
          .length;
      if (firstPart.isNotEmpty &&
          tokenCount <= 6 &&
          !_isKeyword(firstPart) &&
          !RegExp(r'^\d+$').hasMatch(firstPart) &&
          !_looksLikeIntroOnly(normalizedFirstPart) &&
          !_looksLikeNonNameResponse(normalizedFirstPart)) {
        return firstPart;
      }
    }

    return null;
  }

  /// Extract date in various formats
  static String? _extractDate(
    String text,
    List<String> keywords, {
    bool allowStandaloneDate = true,
  }) {
    for (final keyword in keywords) {
      final pattern = RegExp(
        '${RegExp.escape(keyword)}(?:[:\\s]+|\\s+là\\s+|\\s+)(\\d{1,2}[-/]\\d{1,2}[-/]\\d{4}|\\d{4}[-/]\\d{1,2}[-/]\\d{1,2}|\\d{4})',
        caseSensitive: false,
      );
      final match = pattern.firstMatch(_normalizeSemanticText(text));
      if (match != null) {
        return _normalizeDate(match.group(1) ?? '');
      }
    }

    if (allowStandaloneDate) {
      // Look for standalone date patterns when field context allows it.
      final datePattern = RegExp(
        r'(\d{1,2}[-/]\d{1,2}[-/]\d{4}|\d{4}[-/]\d{1,2}[-/]\d{1,2})',
      );
      final match = datePattern.firstMatch(text);
      if (match != null) {
        return _normalizeDate(match.group(0) ?? '');
      }
    }

    return null;
  }

  /// Normalize date to yyyy-mm-dd format
  static String _normalizeDate(String date) {
    date = date.trim();
    if (date.isEmpty) return '';

    // yyyy-mm-dd already normalized
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) return date;

    // Convert dd/mm/yyyy or dd-mm-yyyy to yyyy-mm-dd
    final parts = date.split(RegExp(r'[-/]'));
    if (parts.length == 3) {
      if (parts[0].length == 4) {
        // yyyy-mm-dd format
        return '${parts[0]}-${parts[1].padLeft(2, '0')}-${parts[2].padLeft(2, '0')}';
      } else {
        // dd-mm-yyyy format
        return '${parts[2]}-${parts[1].padLeft(2, '0')}-${parts[0].padLeft(2, '0')}';
      }
    }

    // Just year
    if (parts.length == 1 && parts[0].length == 4) {
      return '${parts[0]}-01-01';
    }

    return date;
  }

  /// Extract relative's name (parent, mother, etc.)
  static String? _extractRelativeName(String text, List<String> keywords) {
    final normalized = _normalizeSemanticText(text);
    for (final keyword in keywords) {
      final pattern = RegExp(
        '${RegExp.escape(keyword)}(?:[:\\s]+|\\s+là\\s+|\\s+)([a-zàáảãạăằắẳẵặâầấẩẫậèéẻẽẹêềếểễệìíỉĩịòóỏõọôồốổỗộơờớởỡợùúủũụưừứửữựỳýỷỹỵđ\\s]+)',
        caseSensitive: false,
      );
      final match = pattern.firstMatch(normalized);
      if (match != null) {
        final value = match.group(1)?.trim();
        if (value != null &&
            value.isNotEmpty &&
            !RegExp(r'^\d+$').hasMatch(value.replaceAll(RegExp(r'\s+'), ''))) {
          return value;
        }
      }
    }
    return null;
  }

  /// Extract description/notes
  static String _extractDescription(String input) {
    // Remove known keywords and return remaining text
    final cleaned = input
        .replaceAll(RegExp(r'tên.*?[,\.]', caseSensitive: false), '')
        .replaceAll(RegExp(r'sinh.*?[,\.]', caseSensitive: false), '')
        .replaceAll(RegExp(r'mất.*?[,\.]', caseSensitive: false), '')
        .replaceAll(RegExp(r'(nam|nữ|male|female)', caseSensitive: false), '')
        .trim();

    return cleaned.isEmpty ? '' : cleaned;
  }

  /// Check if text is a keyword (should not be treated as name)
  static bool _isKeyword(String text) {
    final keywords = [
      'tên',
      'sinh',
      'mất',
      'cha',
      'mẹ',
      'name',
      'birth',
      'death',
      'father',
      'mother',
    ];
    return keywords.any((kw) => text.toLowerCase().contains(kw));
  }

  static bool _isGreetingOnly(String text) {
    final greetingHints = ['xin chao', 'chao', 'hello', 'hi', 'hey'];
    if (!greetingHints.any(text.contains)) {
      return false;
    }
    return !_fieldSynonyms.values.any(
      (phrases) => phrases.any(
        (phrase) => text.contains(_normalizeSemanticText(phrase)),
      ),
    );
  }

  static bool _looksLikeIntroOnly(String text) {
    final introHints = [
      'toi muon tao',
      'muon tao',
      'tao node',
      'tao 1 node',
      'them node',
      'them thanh vien',
      'tao 1 node ten la',
      'xin chao',
      'chao ban',
    ];
    return introHints.any(text.contains);
  }

  static bool _looksLikeNonNameResponse(String text) {
    final hints = [
      'khong co',
      'khong',
      'co anh',
      'khong co anh',
      'khong dung anh',
      'khong co hinh',
      'da mat',
      'chet roi',
      'con song',
      'nam sinh',
      'ngay sinh',
      'gioi tinh',
      'cha',
      'me',
      'vo',
      'chong',
      'anh',
      'hinh',
    ];
    return hints.any(text.contains);
  }

  static String _cleanupCapturedText(String text) {
    return text
        .replaceAll(RegExp(r'^(la|cua)\s+', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _toTitleCase(String text) {
    return text
        .split(' ')
        .where((part) => part.trim().isNotEmpty)
        .map((word) => word[0].toUpperCase() + word.substring(1))
        .join(' ');
  }

  static bool _matchesAny(String text, List<String> phrases) {
    return phrases.any(
      (phrase) => text.contains(_normalizeSemanticText(phrase)),
    );
  }

  static bool matchesAnySemantic(String text, List<String> phrases) {
    final normalizedText = _normalizeSemanticText(text);
    final textTokens = normalizedText
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toSet();

    for (final phrase in phrases) {
      final normalizedPhrase = _normalizeSemanticText(phrase);
      if (normalizedPhrase.isEmpty) continue;

      if (normalizedText.contains(normalizedPhrase)) {
        return true;
      }

      final phraseTokens = normalizedPhrase
          .split(' ')
          .where((token) => token.isNotEmpty)
          .toList();
      if (phraseTokens.isEmpty) continue;

      final overlap = phraseTokens.where(textTokens.contains).length;
      final ratio = overlap / phraseTokens.length;

      if (phraseTokens.length <= 2 && overlap == phraseTokens.length) {
        return true;
      }
      if (phraseTokens.length >= 3 && ratio >= 0.7) {
        return true;
      }
    }

    return false;
  }

  static String normalizeSemanticText(String input) =>
      _normalizeSemanticText(input);

  static String _normalizeSemanticText(String input) {
    var text = input.toLowerCase().trim();
    const replacements = {
      'á': 'a',
      'à': 'a',
      'ả': 'a',
      'ã': 'a',
      'ạ': 'a',
      'ă': 'a',
      'ắ': 'a',
      'ằ': 'a',
      'ẳ': 'a',
      'ẵ': 'a',
      'ặ': 'a',
      'â': 'a',
      'ấ': 'a',
      'ầ': 'a',
      'ẩ': 'a',
      'ẫ': 'a',
      'ậ': 'a',
      'é': 'e',
      'è': 'e',
      'ẻ': 'e',
      'ẽ': 'e',
      'ẹ': 'e',
      'ê': 'e',
      'ế': 'e',
      'ề': 'e',
      'ể': 'e',
      'ễ': 'e',
      'ệ': 'e',
      'í': 'i',
      'ì': 'i',
      'ỉ': 'i',
      'ĩ': 'i',
      'ị': 'i',
      'ó': 'o',
      'ò': 'o',
      'ỏ': 'o',
      'õ': 'o',
      'ọ': 'o',
      'ô': 'o',
      'ố': 'o',
      'ồ': 'o',
      'ổ': 'o',
      'ỗ': 'o',
      'ộ': 'o',
      'ơ': 'o',
      'ớ': 'o',
      'ờ': 'o',
      'ở': 'o',
      'ỡ': 'o',
      'ợ': 'o',
      'ú': 'u',
      'ù': 'u',
      'ủ': 'u',
      'ũ': 'u',
      'ụ': 'u',
      'ư': 'u',
      'ứ': 'u',
      'ừ': 'u',
      'ử': 'u',
      'ữ': 'u',
      'ự': 'u',
      'ý': 'y',
      'ỳ': 'y',
      'ỷ': 'y',
      'ỹ': 'y',
      'ỵ': 'y',
      'đ': 'd',
    };
    replacements.forEach((from, to) {
      text = text.replaceAll(from, to);
    });

    // Normalize common colloquial shortcuts to improve intent matching.
    text = text
        .replaceAll(
          RegExp(r'\bko\b|\bk\b|\bkhum\b|\bkh\b|\bkhg\b|\bhok\b|\bhem\b'),
          'khong',
        )
        .replaceAll(RegExp(r'\bgioi tnh\b|\bgioi tinh\b'), 'gioi tinh')
        .replaceAll(RegExp(r'\bngay sinh nhat\b'), 'ngay sinh')
        .replaceAll(RegExp(r'\bsinh nhat\b'), 'ngay sinh')
        .replaceAll(RegExp(r'\bck\b'), 'chong')
        .replaceAll(RegExp(r'\bvk\b|\bbx\b'), 'vo')
        .replaceAll(RegExp(r'\box\b'), 'chong')
        .replaceAll(RegExp(r'\bcap nhat\b|\bupdate\b'), 'cap nhat')
        .replaceAll(
          RegExp(r'\bdoi\s+sang\b|\bsua\s+thanh\b|\bchuyen\s+sang\b'),
          'doi thanh',
        )
        .replaceAll(RegExp(r'\btu vong\b|\bhy sinh\b'), 'da mat')
        .replaceAll(
          RegExp(r'\bcon\s+song\s+khoe\b|\bvan\s+khoe\b'),
          'con song',
        );

    text = text.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }

  /// Generate follow-up questions based on extracted info
  static List<String> generateFollowUpQuestions(ExtractedNodeInfo info) {
    final questions = <String>[];

    if (info.fullName == null || info.fullName!.isEmpty) {
      questions.add('Tên người này là gì?');
    }
    if (info.sex == null || info.sex!.isEmpty) {
      questions.add('Người này là nam hay nữ?');
    }
    if (info.birthday == null || info.birthday!.isEmpty) {
      questions.add('Ngày sinh của người này là khi nào? (dd/mm/yyyy)');
    }
    if (info.parentId == null || info.parentId!.isEmpty) {
      questions.add('Cha của người này là ai? (NodeCode)');
    }
    if (info.motherId == null || info.motherId!.isEmpty) {
      questions.add('Mẹ của người này là ai? (NodeCode)');
    }

    return questions;
  }

  /// Validate extracted info for completeness
  static Map<String, String> validateNodeInfo(ExtractedNodeInfo info) {
    final errors = <String, String>{};

    if (info.fullName == null || info.fullName!.trim().isEmpty) {
      errors['fullName'] = 'Tên là bắt buộc';
    }
    if (info.sex == null || info.sex!.trim().isEmpty) {
      errors['sex'] = 'Giới tính là bắt buộc (Nam/Nữ)';
    } else if (!['Nam', 'Nữ'].contains(info.sex)) {
      errors['sex'] = 'Giới tính chỉ có thể là Nam hoặc Nữ';
    }

    if (info.birthday != null && info.birthday!.isNotEmpty) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(info.birthday!)) {
        errors['birthday'] = 'Ngày sinh không hợp lệ (yyyy-mm-dd)';
      }
    }

    if (info.deathDay != null && info.deathDay!.isNotEmpty) {
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(info.deathDay!)) {
        errors['deathDay'] = 'Ngày mất không hợp lệ (yyyy-mm-dd)';
      }
    }

    return errors;
  }
}
