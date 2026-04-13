import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:three_js/three_js.dart' as three;
import 'package:three_js_advanced_loaders/three_js_advanced_loaders.dart' as adv;
import 'package:three_js_math/three_js_math.dart' show RGBAFormat;

const String _kAltarGlbBundleDir = 'assets/altar_glb/';

/// Giam pixel ratio render Three.js tren Android/iOS (va emulator) de tang FPS, giu desktop day du hon.
double _altarThreeScreenResolution() {
  if (kIsWeb) {
    return 0.82;
  }
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return 0.62;
    default:
      return 1.0;
  }
}

const Map<String, String> _kVietnameseAssetNames = <String, String>{
  'wooden altar 3d model.glb': 'Bàn thờ gỗ',
  'ornate wooden altar 3d model.glb': 'Bàn thờ gỗ chạm khắc',
  'crystal pagoda 3d model.glb': 'Tháp pha lê',
  'golden lotus trophy 3d model.glb': 'Đài sen vàng',
  'ornate brass incense burner 3d model.glb': 'Lư hương đồng chạm khắc',
  'ornate framed plaque 3d model.glb': 'Hoành phi chạm khung',
  'ornate glass oil lamp 3d model.glb': 'Đèn dầu thủy tinh',
  'porcelain pedestal 3d model.glb': 'Đôn sứ',
  'porcelain sugar jar 3d model.glb': 'Hũ sứ',
  'porcelain vase 3d model.glb': 'Bình sứ',
  'porcelain vase 3d model (1).glb': 'Bình sứ mẫu 2',
};

String _prettyGlbDisplayName(String fileName) {
  final String mapped = _kVietnameseAssetNames[fileName.toLowerCase()] ?? '';
  if (mapped.isNotEmpty) {
    return mapped;
  }
  String s = fileName;
  if (s.toLowerCase().endsWith('.glb')) {
    s = s.substring(0, s.length - 4);
  }
  s = s.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) {
    return fileName;
  }
  return s[0].toUpperCase() + (s.length > 1 ? s.substring(1) : '');
}

Future<List<String>> _glbNamesFromFlutterBundle() async {
  final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final List<String> keys = manifest.listAssets();
  return keys
      .where(
        (String k) => k.startsWith(_kAltarGlbBundleDir) && k.toLowerCase().endsWith('.glb'),
      )
      .map((String k) => k.substring(_kAltarGlbBundleDir.length))
      .toList();
}

/// Quet thu muc altar_glb tren dia (dev) — bat ky file .glb nao bo vao deu hien trong menu.
List<String> _glbNamesFromDiskSearch() {
  final Set<String> out = <String>{};
  Directory dir = Directory.current;
  for (int i = 0; i < 8; i++) {
    final List<String> folders = <String>[
      p.join(dir.absolute.path, 'assets', 'altar_glb'),
      p.join(dir.absolute.path, 'example', 'assets', 'altar_glb'),
    ];
    for (final String folder in folders) {
      final Directory d = Directory(folder);
      if (!d.existsSync()) {
        continue;
      }
      for (final FileSystemEntity e in d.listSync()) {
        if (e is! File) {
          continue;
        }
        final String name = p.basename(e.path);
        if (name.startsWith('.')) {
          continue;
        }
        if (!name.toLowerCase().endsWith('.glb')) {
          continue;
        }
        out.add(name);
      }
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      break;
    }
    dir = parent;
  }
  return out.toList();
}

Future<List<AltarAsset>> discoverAltarLibraryAssets() async {
  final Set<String> names = <String>{};
  try {
    names.addAll(await _glbNamesFromFlutterBundle());
  } catch (e, st) {
    debugPrint('AssetManifest altar_glb: $e\n$st');
  }
  if (!kIsWeb) {
    names.addAll(_glbNamesFromDiskSearch());
  }
  final List<String> sorted = names.toList();
  const String altarFirst = 'wooden altar 3d model.glb';
  sorted.sort((String a, String b) {
    final bool aw = a == altarFirst;
    final bool bw = b == altarFirst;
    if (aw && !bw) {
      return -1;
    }
    if (!aw && bw) {
      return 1;
    }
    return a.toLowerCase().compareTo(b.toLowerCase());
  });
  return sorted
      .map(
        (String path) => AltarAsset(
          name: _prettyGlbDisplayName(path),
          path: path,
        ),
      )
      .toList();
}

class AltarAsset {
  final String name;
  final String path;

  const AltarAsset({required this.name, required this.path});
}

class AltarPlacedItem {
  final String id;
  final String assetPath;
  final String name;
  final double x;
  final double y;
  final double scale;
  final double lift;

  const AltarPlacedItem({
    required this.id,
    required this.assetPath,
    required this.name,
    required this.x,
    required this.y,
    required this.scale,
    required this.lift,
  });

  AltarPlacedItem copyWith({
    double? x,
    double? y,
    double? scale,
    double? lift,
  }) {
    return AltarPlacedItem(
      id: id,
      assetPath: assetPath,
      name: name,
      x: x ?? this.x,
      y: y ?? this.y,
      scale: scale ?? this.scale,
      lift: lift ?? this.lift,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'assetPath': assetPath,
    'name': name,
    'x': x,
    'y': y,
    'scale': scale,
    'lift': lift,
  };

  static AltarPlacedItem fromJson(Map<String, dynamic> json) {
    return AltarPlacedItem(
      id: json['id'] as String,
      assetPath: json['assetPath'] as String,
      name: json['name'] as String,
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      scale: (json['scale'] as num).toDouble(),
      lift: (json['lift'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class AltarSetupPage extends StatefulWidget {
  final String memberKey;
  final String memberName;

  const AltarSetupPage({
    super.key,
    required this.memberKey,
    required this.memberName,
  });

  @override
  State<AltarSetupPage> createState() => _AltarSetupPageState();
}

class _AltarSetupPageState extends State<AltarSetupPage> {
  List<AltarAsset> _libraryAssets = <AltarAsset>[];
  bool _libraryLoading = true;
  bool _showLibraryPanel = true;

  final List<AltarPlacedItem> _items = <AltarPlacedItem>[];
  String? _selectedItemId;
  bool _isSaving = false;
  bool _moveItemMode = false;

  @override
  void initState() {
    super.initState();
    _loadLayout();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    final List<AltarAsset> found = await discoverAltarLibraryAssets();
    if (!mounted) {
      return;
    }
    setState(() {
      _libraryAssets = found;
      _libraryLoading = false;
    });
  }

  String get _prefsKey => 'altar_layout_member_${widget.memberKey}';

  Future<void> _loadLayout() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      final List<AltarPlacedItem> loaded = decoded
          .whereType<Map<String, dynamic>>()
          .map(AltarPlacedItem.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(loaded);
      });
    } catch (_) {}
  }

  Future<void> _saveLayout() async {
    setState(() => _isSaving = true);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(
      _items.map((AltarPlacedItem item) => item.toJson()).toList(),
    );
    await prefs.setString(_prefsKey, encoded);
    if (!mounted) return;
    setState(() => _isSaving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Da luu bo cuc ban tho.')),
    );
  }

  void _addFromAsset(
    AltarAsset asset,
    Size zoneSize, {
    Offset? dropLocalPosition,
  }) {
    final String id = '${asset.path}_${DateTime.now().microsecondsSinceEpoch}';
    const double defaultScale = 1.0;
    final double maxX =
        (zoneSize.width - _itemWidth(defaultScale)).clamp(0, double.infinity);
    final double maxY =
        (zoneSize.height - _itemHeight(defaultScale)).clamp(0, double.infinity);
    final double spawnX = (dropLocalPosition?.dx ?? (zoneSize.width * 0.45)).clamp(0, maxX);
    final double spawnY = (dropLocalPosition?.dy ?? (zoneSize.height * 0.4)).clamp(0, maxY);
    setState(() {
      _items.add(
        AltarPlacedItem(
          id: id,
          assetPath: asset.path,
          name: asset.name,
          x: spawnX,
          y: spawnY,
          scale: defaultScale,
          lift: 0.0,
        ),
      );
      _selectedItemId = id;
    });
  }

  void _updateItem(AltarPlacedItem updated) {
    final int index = _items.indexWhere((AltarPlacedItem e) => e.id == updated.id);
    if (index < 0) return;
    final AltarPlacedItem current = _items[index];
    final bool changed = current.x != updated.x ||
        current.y != updated.y ||
        current.scale != updated.scale ||
        current.lift != updated.lift;
    if (!changed) {
      return;
    }
    setState(() => _items[index] = updated);
  }

  void _removeSelected() {
    if (_selectedItemId == null) return;
    setState(() {
      _items.removeWhere((AltarPlacedItem e) => e.id == _selectedItemId);
      _selectedItemId = null;
    });
  }

  double _itemWidth(double scale) => 140 * scale;
  double _itemHeight(double scale) => 140 * scale;
  /// Khung điện thờ: toàn bộ không gian scene là mô hình bàn thờ 3D này.
  static const String _altarBasePath = 'wooden altar 3d model.glb';

  /// Tim file .glb tren dia: thu muc hien tai + len cap den 8 cap (root repo).
  AltarPlacedItem? _resolveSelectedItem() {
    if (_items.isEmpty) {
      return null;
    }
    if (_selectedItemId != null) {
      for (final AltarPlacedItem item in _items) {
        if (item.id == _selectedItemId) {
          return item;
        }
      }
    }
    return _items.first;
  }

  String? _resolveModelPath(String assetPath) {
    if (kIsWeb) return null;
    final List<String> roots = <String>[];
    Directory dir = Directory.current;
    for (int i = 0; i < 8; i++) {
      roots.add(p.normalize(dir.absolute.path));
      final Directory parent = dir.parent;
      if (parent.path == dir.path) {
        break;
      }
      dir = parent;
    }
    final List<String> subdirs = <String>[
      p.join('media', 'altar_clean'),
      '',
      p.join('example', 'media', 'altar_clean'),
      p.join('assets', 'altar_glb'),
      p.join('example', 'assets', 'altar_glb'),
    ];
    for (final String root in roots) {
      for (final String sub in subdirs) {
        final String full =
            sub.isEmpty ? p.join(root, assetPath) : p.join(root, sub, assetPath);
        final File file = File(full);
        if (file.existsSync()) {
          return file.absolute.path;
        }
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final AltarPlacedItem? selected = _resolveSelectedItem();
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final bool isCompactLayout = screenWidth < 900;
    return Scaffold(
      appBar: AppBar(
        title: Text('Lập bàn thờ - ${widget.memberName}'),
        actions: <Widget>[
          IconButton(
            tooltip: _showLibraryPanel ? 'Ẩn thư viện' : 'Mở thư viện',
            onPressed: () => setState(() => _showLibraryPanel = !_showLibraryPanel),
            icon: Icon(_showLibraryPanel ? Icons.menu_open : Icons.menu),
          ),
          IconButton(
            tooltip: 'Xóa vật đang chọn',
            onPressed: selected == null ? null : _removeSelected,
            icon: const Icon(Icons.delete_outline),
          ),
          TextButton.icon(
            onPressed: _isSaving ? null : _saveLayout,
            icon: _isSaving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Lưu'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Builder(
        builder: (BuildContext context) {
          final Widget scenePane = LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Size zoneSize = Size(constraints.maxWidth, constraints.maxHeight);
              return Stack(
                children: <Widget>[
                  DragTarget<AltarAsset>(
                    onAcceptWithDetails: (DragTargetDetails<AltarAsset> details) {
                      final RenderBox? box = context.findRenderObject() as RenderBox?;
                      final Offset localDrop = box?.globalToLocal(details.offset) ??
                          Offset(zoneSize.width * 0.45, zoneSize.height * 0.4);
                      _addFromAsset(
                        details.data,
                        zoneSize,
                        dropLocalPosition: localDrop,
                      );
                    },
                    builder: (_, __, ___) {
                      return _AltarSceneView(
                        altarAssetFileName: _altarBasePath,
                        items: _items,
                        selectedItemId: _selectedItemId,
                        onTapItem: (String id) => setState(() => _selectedItemId = id),
                        zoneSize: zoneSize,
                        resolveModelPath: _resolveModelPath,
                        allowOrbit: !_moveItemMode,
                        moveItemMode: _moveItemMode,
                        moveTargetItem: selected,
                        onMovePlacedItem: _updateItem,
                      );
                    },
                  ),
                  if (_items.isNotEmpty)
                    Positioned(
                      top: 8,
                      right: 8,
                      width: isCompactLayout ? 260 : 300,
                      child: Builder(
                        builder: (BuildContext context) {
                          final AltarPlacedItem panelItem = _resolveSelectedItem()!;
                          return Material(
                            elevation: 6,
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    'Chọn vật trên bàn',
                                    style: Theme.of(context).textTheme.labelMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  DropdownButton<String>(
                                    isExpanded: true,
                                    value: panelItem.id,
                                    items: _items
                                        .map(
                                          (AltarPlacedItem e) => DropdownMenuItem<String>(
                                            value: e.id,
                                            child: Text(
                                              e.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (String? id) {
                                      if (id == null) return;
                                      setState(() => _selectedItemId = id);
                                    },
                                  ),
                                  const SizedBox(height: 6),
                                  SizedBox(
                                    height: 36,
                                    child: SegmentedButton<bool>(
                                      segments: const <ButtonSegment<bool>>[
                                        ButtonSegment<bool>(
                                          value: false,
                                          label: Text('Xoay'),
                                          icon: Icon(Icons.threed_rotation, size: 18),
                                        ),
                                        ButtonSegment<bool>(
                                          value: true,
                                          label: Text('Di chuyển'),
                                          icon: Icon(Icons.open_with, size: 18),
                                        ),
                                      ],
                                      selected: <bool>{_moveItemMode},
                                      onSelectionChanged: (Set<bool> values) {
                                        setState(() {
                                          _moveItemMode = values.first;
                                        });
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _moveItemMode
                                        ? 'Giữ chuột trái để kéo vật trên mặt bàn. Giữ Shift + kéo lên/xuống để nâng/hạ độ cao trong không gian.'
                                        : 'Kéo để xoay camera, rồi chuyển sang Di chuyển để sắp xếp.',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: const Color(0xFF64748B),
                                          fontSize: 11,
                                        ),
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: <Widget>[
                                      const Text('Tỉ lệ', style: TextStyle(fontSize: 12)),
                                      Expanded(
                                        child: Slider(
                                          min: 0.5,
                                          max: 2.5,
                                          value: panelItem.scale,
                                          divisions: 20,
                                          label: panelItem.scale.toStringAsFixed(2),
                                          onChanged: (double value) {
                                            final AltarPlacedItem active = panelItem;
                                            final double maxX =
                                                (zoneSize.width - _itemWidth(value)).clamp(
                                              0,
                                              double.infinity,
                                            );
                                            final double maxY =
                                                (zoneSize.height - _itemHeight(value)).clamp(
                                              0,
                                              double.infinity,
                                            );
                                            _updateItem(
                                              active.copyWith(
                                                scale: value,
                                                x: active.x.clamp(0, maxX),
                                                y: active.y.clamp(0, maxY),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: <Widget>[
                                      const Text('Độ cao', style: TextStyle(fontSize: 12)),
                                      Expanded(
                                        child: Slider(
                                          min: _AltarSceneViewState._minLift,
                                          max: _AltarSceneViewState._maxLift,
                                          value: panelItem.lift.clamp(
                                            _AltarSceneViewState._minLift,
                                            _AltarSceneViewState._maxLift,
                                          ),
                                          divisions: 32,
                                          label: panelItem.lift.toStringAsFixed(2),
                                          onChanged: (double value) {
                                            _updateItem(panelItem.copyWith(lift: value));
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              );
            },
          );

          final Widget libraryPane = _LibraryPanel(
            assets: _libraryAssets,
            loading: _libraryLoading,
            onClose: () => setState(() => _showLibraryPanel = false),
          );

          if (!isCompactLayout) {
            return Row(
              children: <Widget>[
                if (_showLibraryPanel) SizedBox(width: 280, child: libraryPane),
                if (_showLibraryPanel) const VerticalDivider(width: 1),
                Expanded(child: scenePane),
              ],
            );
          }

          final double panelWidth = (screenWidth * 0.82).clamp(240.0, 320.0);
          return Stack(
            children: <Widget>[
              Positioned.fill(child: scenePane),
              if (_showLibraryPanel)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: panelWidth,
                  child: SafeArea(
                    right: false,
                    child: Material(
                      elevation: 10,
                      color: const Color(0xFFF8FAFC),
                      child: libraryPane,
                    ),
                  ),
                ),
              if (!_showLibraryPanel)
                Positioned(
                  left: 12,
                  top: 12,
                  child: SafeArea(
                    bottom: false,
                    child: FloatingActionButton.small(
                      heroTag: 'open_library_panel',
                      onPressed: () => setState(() => _showLibraryPanel = true),
                      child: const Icon(Icons.menu),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _LibraryPanel extends StatelessWidget {
  final List<AltarAsset> assets;
  final bool loading;
  final VoidCallback? onClose;

  const _LibraryPanel({required this.assets, required this.loading, this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF8FAFC),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Thư viện (.glb)',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    if (onClose != null)
                      IconButton(
                        tooltip: 'Đóng thư viện',
                        onPressed: onClose,
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Bỏ file .glb vào example/assets/altar_glb/ rồi chạy lại ứng dụng.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                      ),
                ),
              ],
            ),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : assets.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'Chưa có file .glb trong assets/altar_glb/',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        itemCount: assets.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (BuildContext context, int index) {
                          final AltarAsset asset = assets[index];
                          return Draggable<AltarAsset>(
                            data: asset,
                            feedback: Material(
                              elevation: 2,
                              child: _AssetTile(asset: asset, compact: true),
                            ),
                            childWhenDragging: Opacity(
                              opacity: 0.4,
                              child: _AssetTile(asset: asset),
                            ),
                            child: _AssetTile(asset: asset),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _AltarSceneView extends StatefulWidget {
  final String altarAssetFileName;
  final List<AltarPlacedItem> items;
  final String? selectedItemId;
  final ValueChanged<String> onTapItem;
  final Size zoneSize;
  final String? Function(String assetPath) resolveModelPath;
  final bool allowOrbit;
  final bool moveItemMode;
  final AltarPlacedItem? moveTargetItem;
  final ValueChanged<AltarPlacedItem>? onMovePlacedItem;

  const _AltarSceneView({
    required this.altarAssetFileName,
    required this.items,
    required this.selectedItemId,
    required this.onTapItem,
    required this.zoneSize,
    required this.resolveModelPath,
    required this.allowOrbit,
    required this.moveItemMode,
    required this.moveTargetItem,
    required this.onMovePlacedItem,
  });

  @override
  State<_AltarSceneView> createState() => _AltarSceneViewState();
}

class _AltarSceneViewState extends State<_AltarSceneView> {
  /// Mặt phẳng đặt đồ (mặt bằng): chỉ XZ trong không gian 3D, Y = mặt trên bàn.
  static const double _altarSurfaceY = 1.2;
  static const double _altarPlaneHalfWidth = 1.65;
  static const double _altarPlaneHalfDepth = 0.9;
  static const double _minLift = -1.2;
  static const double _maxLift = 1.8;
  static const double _liftDragPerPixel = 0.01;

  /// Xoay model ban tho quanh Y. Doi neu mat chinh bi lat ra sau: thu 0, ±pi/2, pi.
  static const double _altarModelYawRad = -math.pi / 2;

  late three.ThreeJS _threeJs;
  late three.OrbitControls _controls;
  final adv.GLTFLoader _loader = adv.GLTFLoader();
  final Map<String, three.Object3D> _itemObjects = <String, three.Object3D>{};
  final Map<String, three.Object3D> _modelSceneCache = <String, three.Object3D>{};
  final Set<String> _warnedMissingGlb = <String>{};
  bool _ready = false;
  bool _isPointerDragging = false;
  /// Khoang cach (theo man hinh) tu diem bam toi goc tren-trai hop logic (_labelBox * scale).
  /// Giu co dinh trong mot lan keo de khong "nhay" tam vat ve con tro luc pointerDown.
  Offset? _moveGrabOffset;


  void _notifyLoadFailedOnce(String assetFileName) {
    if (_warnedMissingGlb.contains(assetFileName)) return;
    _warnedMissingGlb.add(assetFileName);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'Khong tai duoc: $assetFileName\n'
            'Dat file vao example/assets/altar_glb/ (flutter pub get + chay lai).',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    });
  }

  /// GLTF co the dung chung Material giua cac lan load — clone de moi mesh giu dung mau/map rieng.
  static bool get _preferSimpleGlbMaterials =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static three.Material _cloneSceneMaterial(three.Material source) {
    if (_preferSimpleGlbMaterials && source is three.MeshStandardMaterial) {
      return three.MeshLambertMaterial()..copy(source);
    }
    return source.clone();
  }

  static void _cloneMaterialsDeep(three.Object3D root) {
    root.traverse((three.Object3D o) {
      if (o is! three.Mesh) {
        return;
      }
      final dynamic m = o.material;
      if (m == null) {
        return;
      }
      if (m is List) {
        (o as dynamic).material = m.map((dynamic x) => _cloneSceneMaterial(x as three.Material)).toList();
      } else {
        o.material = _cloneSceneMaterial(m as three.Material);
      }
    });
  }

  static bool _samePlacedInventory(_AltarSceneView a, _AltarSceneView b) {
    if (a.items.length != b.items.length) {
      return false;
    }
    final Map<String, String> pathsA = <String, String>{
      for (final AltarPlacedItem i in a.items) i.id: i.assetPath,
    };
    final Map<String, String> pathsB = <String, String>{
      for (final AltarPlacedItem i in b.items) i.id: i.assetPath,
    };
    if (pathsA.length != pathsB.length) {
      return false;
    }
    for (final MapEntry<String, String> e in pathsA.entries) {
      if (pathsB[e.key] != e.value) {
        return false;
      }
    }
    return true;
  }

  /// Ten file thay the (doi ten file tren dia cho gon, hoac layout cu trong prefs).
  static List<String> _candidateGlbNames(String assetFileName) {
    final List<String> out = <String>[assetFileName];
    const Map<String, String> alt = <String, String>{
      'porcelain_vase_b.glb': 'porcelain vase 3d model (1).glb',
      'porcelain vase 3d model (1).glb': 'porcelain_vase_b.glb',
    };
    final String? a = alt[assetFileName];
    if (a != null && !out.contains(a)) {
      out.add(a);
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _threeJs = three.ThreeJS(
      settings: three.Settings(
        useSourceTexture: false,
        enableShadowMap: false,
        antialias: false,
        stencil: false,
        /// Giam VRAM / tranh loi D3D11 0x8007000E (het bo nho texture tren GPU).
        /// Tren mobile giam them de vuot thich ung khi xoay / keo vat.
        screenResolution: _altarThreeScreenResolution(),
        clearColor: 0xFF1a2230,
        clearAlpha: 1.0,
        renderOptions: <String, dynamic>{
          'format': RGBAFormat,
          'samples': 0,
        },
      ),
      setup: _setupScene,
      onSetupComplete: () {
        if (!mounted) return;
        setState(() => _ready = true);
      },
    );
  }

  @override
  void didUpdateWidget(covariant _AltarSceneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) {
      return;
    }
    if (oldWidget.allowOrbit != widget.allowOrbit) {
      _controls.enabled = widget.allowOrbit;
      _controls.enableRotate = widget.allowOrbit;
      _controls.enablePan = widget.allowOrbit;
      _controls.enableZoom = widget.allowOrbit;
      _controls.enableDamping = widget.allowOrbit;
    }
    if (_samePlacedInventory(oldWidget, widget) &&
        _itemObjects.length == widget.items.length) {
      _applyItemTransforms();
      return;
    }
    _syncSceneObjects();
  }

  Future<void> _setupScene() async {
    _threeJs.camera = three.PerspectiveCamera(
      42,
      _threeJs.width / _threeJs.height,
      0.3,
      120,
    );
    _threeJs.camera.position.setValues(0.0, 2.3, 5.8);
    _threeJs.camera.lookAt(three.Vector3(0, 1.2, 0));

    _threeJs.scene = three.Scene();
    _threeJs.scene.background = three.Color.fromHex32(0x1a2230);

    final three.AmbientLight ambient = three.AmbientLight(0xffffff, 0.55);
    _threeJs.scene.add(ambient);

    final three.DirectionalLight key = three.DirectionalLight(0xffffff, 1.35);
    key.position.setValues(2.0, 6.0, 5.0);
    _threeJs.scene.add(key);

    final three.DirectionalLight fill = three.DirectionalLight(0xffffff, 0.45);
    fill.position.setValues(-3.0, 4.0, -2.0);
    _threeJs.scene.add(fill);

    _controls = three.OrbitControls(_threeJs.camera, _threeJs.globalKey);
    _controls.enabled = widget.allowOrbit;
    _controls.enablePan = widget.allowOrbit;
    _controls.enableRotate = widget.allowOrbit;
    _controls.enableZoom = widget.allowOrbit;
    _controls.enableDamping = widget.allowOrbit;
    _controls.dampingFactor = 0.06;
    _controls.minDistance = 2.0;
    _controls.maxDistance = 20.0;
    _controls.minPolarAngle = 0.0;
    _controls.maxPolarAngle = math.pi;
    _controls.target.setValues(0.0, 1.2, 0.0);

    final three.Object3D? altarScene = await _loadModelScene(widget.altarAssetFileName);
    if (altarScene != null) {
      altarScene.position.setValues(0.0, 0.0, 0.0);
      altarScene.rotation.y = _altarModelYawRad;
      altarScene.scale.setValues(1.9, 1.9, 1.9);
      _threeJs.scene.add(altarScene);
    } else {
      _notifyLoadFailedOnce(widget.altarAssetFileName);
    }

    await _syncSceneObjects();
    _threeJs.addAnimationEvent((double dt) {
      _controls.update();
    });
  }

  void _applyItemTransforms() {
    for (final AltarPlacedItem item in widget.items) {
      final three.Object3D? obj = _itemObjects[item.id];
      if (obj == null) {
        continue;
      }
      final double nx = (item.x / widget.zoneSize.width) - 0.5;
      final double nz = (item.y / widget.zoneSize.height) - 0.5;
      final double wx = nx * 2 * _altarPlaneHalfWidth;
      final double wz = nz * 2 * _altarPlaneHalfDepth;
      // Keep drag axes screen-friendly: left/right maps to horizontal movement.
      obj.position.setValues(wx, _altarSurfaceY + item.lift + 0.03, wz);
      obj.rotation.y = _altarModelYawRad;
      final double s = 0.16 * item.scale;
      obj.scale.setValues(s, s, s);
    }
  }

  Future<void> _syncSceneObjects() async {
    final List<AltarPlacedItem> itemsSnapshot = List<AltarPlacedItem>.from(widget.items);
    final Set<String> activeIds = itemsSnapshot.map((AltarPlacedItem e) => e.id).toSet();
    final List<String> toRemove = _itemObjects.keys
        .where((String id) => !activeIds.contains(id))
        .toList();
    for (final String id in toRemove) {
      final three.Object3D? obj = _itemObjects.remove(id);
      if (obj != null) {
        _threeJs.scene.remove(obj);
      }
    }

    for (final AltarPlacedItem item in itemsSnapshot) {
      if (!_itemObjects.containsKey(item.id)) {
        final three.Object3D? obj = await _loadModelScene(item.assetPath);
        if (obj == null) {
          _notifyLoadFailedOnce(item.assetPath);
          continue;
        }
        obj.visible = true;
        _itemObjects[item.id] = obj;
        _threeJs.scene.add(obj);
      }
    }
    _applyItemTransforms();
  }

  /// Uu tien file tren dia; sau do `rootBundle` + fromBytes (on dinh hon fromAsset voi ten file la).
  Future<three.Object3D?> _loadModelScene(String assetFileName) async {
    for (final String name in _candidateGlbNames(assetFileName)) {
      final three.Object3D? cached = _modelSceneCache[name];
      if (cached != null) {
        return cached.clone(true);
      }
      final dynamic gltf = await _tryLoadSingleGlb(name);
      if (gltf == null) {
        continue;
      }
      final three.Object3D scene = gltf.scene as three.Object3D;
      _cloneMaterialsDeep(scene);
      _modelSceneCache[name] = scene;
      return scene.clone(true);
    }
    return null;
  }

  Future<dynamic> _tryLoadSingleGlb(String assetFileName) async {
    if (!kIsWeb) {
      final String? path = widget.resolveModelPath(assetFileName);
      if (path != null) {
        try {
          return await _loader.fromFile(File(path));
        } catch (e) {
          debugPrint('GLTF fromFile failed $path: $e');
        }
      }
    }
    try {
      final ByteData data = await rootBundle.load('assets/altar_glb/$assetFileName');
      return await _loader.fromBytes(data.buffer.asUint8List());
    } catch (e) {
      debugPrint('GLTF fromBytes failed assets/altar_glb/$assetFileName: $e');
      return null;
    }
  }

  static const double _labelBox = 140.0;

  static double _flutterLocalXToNdc(double px, double viewW) {
    if (viewW <= 0) {
      return 0;
    }
    return (px / viewW) * 2.0 - 1.0;
  }

  static double _flutterLocalYToNdc(double py, double viewH) {
    if (viewH <= 0) {
      return 0;
    }
    // Flutter local Y tang tu tren xuong duoi; NDC Y tang tu duoi len tren.
    return 1.0 - (py / viewH) * 2.0;
  }

  void _worldXZToItem(AltarPlacedItem target, double rx, double rz) {
    final void Function(AltarPlacedItem)? cb = widget.onMovePlacedItem;
    if (cb == null) {
      return;
    }
    final double c = math.cos(_altarModelYawRad);
    final double s0 = math.sin(_altarModelYawRad);
    final double wx = c * rx + s0 * rz;
    final double wz = -s0 * rx + c * rz;
    final double nx = wx / (2 * _altarPlaneHalfWidth);
    final double nz = wz / (2 * _altarPlaneHalfDepth);
    double itemX = (nx + 0.5) * widget.zoneSize.width;
    double itemY = (nz + 0.5) * widget.zoneSize.height;
    final double maxX =
        (widget.zoneSize.width - _labelBox * target.scale).clamp(0, double.infinity);
    final double maxY =
        (widget.zoneSize.height - _labelBox * target.scale).clamp(0, double.infinity);
    itemX = itemX.clamp(0, maxX);
    itemY = itemY.clamp(0, maxY);
    cb(target.copyWith(x: itemX, y: itemY));
  }

  /// Giao tia (unproject giong Raycaster) voi mat phang y = mat ban.
  three.Vector3? _intersectAltarPlaneFromLocal(
    three.PerspectiveCamera cam,
    double localX,
    double localY,
    double viewW,
    double viewH,
  ) {
    if (viewW <= 0 || viewH <= 0) {
      return null;
    }
    cam.updateMatrixWorld(true);
    final three.Vector3 origin = three.Vector3()..setFromMatrixPosition(cam.matrixWorld);
    final double ndcX = _flutterLocalXToNdc(localX, viewW);
    final double ndcY = _flutterLocalYToNdc(localY, viewH);
    final three.Vector3 p = three.Vector3(ndcX, ndcY, 0.5);
    p.unproject(cam);
    final double dx = p.x - origin.x;
    final double dy = p.y - origin.y;
    final double dz = p.z - origin.z;
    if (dy.abs() < 1e-9) {
      return null;
    }
    final double t = (_altarSurfaceY - origin.y) / dy;
    if (t <= 0) {
      return null;
    }
    return three.Vector3(origin.x + dx * t, _altarSurfaceY, origin.z + dz * t);
  }

  /// Dat vat theo diem con tro tren mat ban tho.
  void _moveTargetToPointer(PointerEvent e) {
    final AltarPlacedItem? target = widget.moveTargetItem;
    final void Function(AltarPlacedItem)? cb = widget.onMovePlacedItem;
    if (!widget.moveItemMode || target == null || cb == null) {
      return;
    }
    if (e is PointerMoveEvent && !_isPointerDragging) {
      return;
    }
    final Set<LogicalKeyboardKey> pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final bool shiftPressed = pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    if (shiftPressed && e is PointerMoveEvent) {
      final double nextLift =
          (target.lift - e.delta.dy * _liftDragPerPixel).clamp(_minLift, _maxLift);
      cb(target.copyWith(lift: nextLift));
      return;
    }
    final Offset cur = e.localPosition;
    final double boxW = _labelBox * target.scale;
    final double boxH = _labelBox * target.scale;
    final double maxX =
        (widget.zoneSize.width - boxW).clamp(0, double.infinity);
    final double maxY =
        (widget.zoneSize.height - boxH).clamp(0, double.infinity);

    final Offset grab = _moveGrabOffset ??
        Offset(cur.dx - target.x, cur.dy - target.y);
    final double nextX = (cur.dx - grab.dx).clamp(0, maxX);
    final double nextY = (cur.dy - grab.dy).clamp(0, maxY);
    cb(target.copyWith(x: nextX, y: nextY));
  }

  @override
  void dispose() {
    _threeJs.dispose();
    _controls.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget view = _threeJs.build();
    if (widget.moveItemMode && widget.moveTargetItem != null && widget.onMovePlacedItem != null) {
      // GestureDetector onPan* often loses to three_js Peripherals (ScaleGestureRecognizer).
      // Raw pointer move while primary button is down reliably moves the item on desktop.
      view = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (PointerDownEvent e) {
          if ((e.buttons & kPrimaryButton) == 0) {
            return;
          }
          _isPointerDragging = true;
          final AltarPlacedItem? t = widget.moveTargetItem;
          if (t != null) {
            final Offset cur = e.localPosition;
            _moveGrabOffset = Offset(cur.dx - t.x, cur.dy - t.y);
          }
          _moveTargetToPointer(e);
        },
        onPointerMove: (PointerMoveEvent e) {
          _moveTargetToPointer(e);
        },
        onPointerUp: (_) {
          _isPointerDragging = false;
          _moveGrabOffset = null;
        },
        onPointerCancel: (_) {
          _isPointerDragging = false;
          _moveGrabOffset = null;
        },
        child: view,
      );
    }
    return view;
  }
}

class _AssetTile extends StatelessWidget {
  final AltarAsset asset;
  final bool compact;

  const _AssetTile({required this.asset, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: compact ? 240 : double.infinity,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.view_in_ar_outlined),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(asset.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (!compact)
                    Text(
                      asset.path,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
