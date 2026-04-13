import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:canvas_kit/canvas_kit.dart';
import 'package:example/demos/unity_bat_huong_demo.dart';
import 'package:example/main_family_tree.dart';
import 'package:example/pages/altar_setup_page.dart';
import 'package:example/services/node_chat_service.dart';
import 'package:example/widgets/add_node_chat_dialog.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:vector_math/vector_math_64.dart' show Matrix4, Vector3;

// import 'family_tree_list_demo.dart';

class GettingStartedDemoPage extends StatefulWidget {
  const GettingStartedDemoPage({super.key});

  @override
  State<GettingStartedDemoPage> createState() => _GettingStartedDemoPageState();
}

class _DeleteSelectionIntent extends Intent {
  const _DeleteSelectionIntent();
}

enum _CanvasTool { cursor, hand, connect, pen, eraser, fill }

/// Shapes available for nodes (palette + clip path).
enum _NodeShape {
  rect,
  square,
  circle,
  oval,
  diamond,
  triangle,
  star,
  hexagon,
  trapezoid,
  parallelogram,
  arrowRight,
}

enum _EdgePort { left, top, right, bottom, spouseBottom }

enum _EdgeRoute { straight, bezier, orthogonal, familyTree, spouse }

enum _ConnectKind { defaultLink, parentToChild, spouse }

const double _kPortSize = 12;
const double _kPortRadius = _kPortSize / 2;
const String _kWebImageProxyTemplate = String.fromEnvironment(
  'WEB_IMAGE_PROXY_TEMPLATE',
  defaultValue: '',
);
const String _kWebImageFallbackProxyTemplate =
    'https://api.allorigins.win/raw?url={url}';
const String _kWebImageFallbackProxyTemplate2 = 'https://corsproxy.io/?{url}';
const String _kWebImageFallbackProxyTemplate3 =
    'https://images.weserv.nl/?url={urlNoScheme}&output=jpg';

/// Prefer package URI on web; fall back to plain `assets/...` for other targets.
const List<String> _kExportBackgroundAssetPaths = <String>[
  'packages/example/assets/background_graph.png',
  'assets/background_graph.png',
];

List<String> _resolveWebImageUrls(String rawUrl) {
  final url = rawUrl.trim();
  if (url.isEmpty) return const <String>[];
  if (!kIsWeb) return <String>[url];

  final urls = <String>[];
  final parsed = Uri.tryParse(url);
  final isCrossOrigin =
      parsed != null && parsed.hasScheme && parsed.host != Uri.base.host;

  final configuredTemplate = _kWebImageProxyTemplate.trim();
  if (!isCrossOrigin) {
    urls.add(url);
  } else if (configuredTemplate.isNotEmpty) {
    urls.add(_applyProxyTemplate(configuredTemplate, url));
  }

  if (isCrossOrigin) {
    urls.add(_applyProxyTemplate(_kWebImageFallbackProxyTemplate3, url));
    urls.add(_applyProxyTemplate(_kWebImageFallbackProxyTemplate, url));
    urls.add(_applyProxyTemplate(_kWebImageFallbackProxyTemplate2, url));
    urls.add(url);
  }

  final dedup = <String>{};
  final out = <String>[];
  for (final u in urls) {
    if (u.isEmpty) continue;
    if (dedup.add(u)) out.add(u);
  }
  return out;
}

String _applyProxyTemplate(String template, String url) {
  final encoded = Uri.encodeComponent(url);
  final noScheme = url.replaceFirst(
    RegExp(r'^https?://', caseSensitive: false),
    '',
  );
  final encodedNoScheme = Uri.encodeComponent(noScheme);
  if (template.contains('{urlNoScheme}')) {
    return template.replaceAll('{urlNoScheme}', encodedNoScheme);
  }
  if (template.contains('{url}')) {
    return template.replaceAll('{url}', encoded);
  }
  final sep = template.contains('?')
      ? (template.endsWith('?') || template.endsWith('&') ? '' : '&')
      : '?';
  return '$template${sep}url=$encoded';
}

String _resolveWebImageUrl(String rawUrl) {
  final url = rawUrl.trim();
  final urls = _resolveWebImageUrls(url);
  if (urls.isEmpty) return url;
  return urls.first;
}

bool _canLoadRemoteImageOnWeb(String rawUrl) {
  final url = rawUrl.trim();
  if (url.isEmpty) return false;
  return true;
}

Uint8List? _tryDecodeDataImageUrl(String rawUrl) {
  final text = rawUrl.trim();
  if (!text.startsWith('data:image/')) return null;
  final comma = text.indexOf(',');
  if (comma <= 0 || comma >= text.length - 1) return null;
  final header = text.substring(0, comma).toLowerCase();
  final payload = text.substring(comma + 1);
  if (header.contains(';base64')) {
    try {
      return base64Decode(payload);
    } catch (_) {
      return null;
    }
  }
  try {
    return Uint8List.fromList(Uri.decodeComponent(payload).codeUnits);
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> _downloadImageBytes(String requestUrl) async {
  final inline = _tryDecodeDataImageUrl(requestUrl);
  if (inline != null && inline.isNotEmpty) return inline;

  final uri = Uri.tryParse(requestUrl);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }

  try {
    final response = await http.get(
      uri,
      headers: const <String, String>{
        'Accept': 'image/*,*/*;q=0.8',
        'User-Agent': 'Mozilla/5.0 CanvasKitExporter/1.0',
      },
    );
    if (response.statusCode >= 200 &&
        response.statusCode < 300 &&
        response.bodyBytes.isNotEmpty) {
      return response.bodyBytes;
    }
  } catch (_) {
    // Fall back to bundle load below.
  }

  try {
    final data = await NetworkAssetBundle(uri).load(requestUrl);
    final bytes = data.buffer.asUint8List();
    if (bytes.isNotEmpty) return bytes;
  } catch (_) {
    // Ignore and report as null.
  }
  return null;
}

Path _edgePathForRoute(
  Offset p0,
  Offset p1,
  _EdgeRoute route, {
  double bend = 0,
  double elbow = 0.5,
}) {
  switch (route) {
    case _EdgeRoute.straight:
      return Path()
        ..moveTo(p0.dx, p0.dy)
        ..lineTo(p1.dx, p1.dy);
    case _EdgeRoute.bezier:
      final dx = p1.dx - p0.dx;
      final dy = p1.dy - p0.dy;
      final dir = dx >= 0 ? 1.0 : -1.0;
      final cDist = math.max(30, dx.abs() * 0.45);
      final arc = bend * math.max(18.0, (dx.abs() + dy.abs()) * 0.18);
      final c1 = p0 + Offset(cDist * dir, arc);
      final c2 = p1 - Offset(cDist * dir, arc);
      return Path()
        ..moveTo(p0.dx, p0.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p1.dx, p1.dy);
    case _EdgeRoute.orthogonal:
      final t = elbow.clamp(0.1, 0.9).toDouble();
      final midX = p0.dx + (p1.dx - p0.dx) * t;
      return Path()
        ..moveTo(p0.dx, p0.dy)
        ..lineTo(midX, p0.dy)
        ..lineTo(midX, p1.dy)
        ..lineTo(p1.dx, p1.dy);
    case _EdgeRoute.familyTree:
      final dy = p1.dy - p0.dy;
      double trunkY;
      final bendClamped = bend.isFinite ? bend.clamp(-1.0, 1.0) : 0.0;
      if (dy >= 36) {
        final ratio = (0.45 + bendClamped * 0.25).clamp(0.2, 0.8);
        trunkY = p0.dy + dy * ratio;
        trunkY = trunkY.clamp(p0.dy + 18, p1.dy - 18);
      } else if (dy > 0.1) {
        trunkY = p0.dy + dy * 0.5;
      } else {
        trunkY = p0.dy + (dy + 20) * 0.5;
      }
      return Path()
        ..moveTo(p0.dx, p0.dy)
        ..lineTo(p0.dx, trunkY)
        ..lineTo(p1.dx, trunkY)
        ..lineTo(p1.dx, p1.dy);
    case _EdgeRoute.spouse:
      // Always go down first, then across, then up for spouse connections
      final dy = p1.dy - p0.dy;
      // Keep spouse line a bit higher to avoid dropping too deep.
      final downOffset = math.max(30.0, (dy.abs() / 2).clamp(24.0, 52.0));
      final bendY = p0.dy + downOffset;
      return Path()
        ..moveTo(p0.dx, p0.dy)
        ..lineTo(p0.dx, bendY)
        ..lineTo(p1.dx, bendY)
        ..lineTo(p1.dx, p1.dy);
  }
}

class _NodeModel {
  final String id;
  Offset position;
  Size size;
  _NodeShape shape;
  String text;
  String bottomText;
  String outsideText;
  Color color;
  Color textColor;
  double textSize;
  Color bottomTextColor;
  double bottomTextSize;
  Color outsideTextColor;
  double outsideTextSize;
  Color borderColor;
  double borderWidth;
  double shadowOpacity;
  double shadowBlur;
  bool blink;
  Uint8List? imageBytes;
  String sex;
  String birthday;
  String description;
  String parentId;
  int? level;
  Map<String, String> metadata;

  _NodeModel({
    required this.id,
    required this.position,
    required this.size,
    required this.shape,
    required this.text,
    this.bottomText = '',
    this.outsideText = '',
    required this.color,
    this.textColor = Colors.white,
    this.textSize = 16,
    this.bottomTextColor = Colors.white,
    this.bottomTextSize = 11,
    this.outsideTextColor = const Color(0xDD000000),
    this.outsideTextSize = 12,
    this.borderColor = const Color(0x55000000),
    this.borderWidth = 1.5,
    this.shadowOpacity = 0.14,
    this.shadowBlur = 8.0,
    this.blink = false,
    this.imageBytes,
    this.sex = '',
    this.birthday = '',
    this.description = '',
    this.parentId = '',
    this.level,
    this.metadata = const <String, String>{},
  });

  _NodeModel clone() => _NodeModel(
    id: id,
    position: position,
    size: size,
    shape: shape,
    text: text,
    bottomText: bottomText,
    outsideText: outsideText,
    color: color,
    textColor: textColor,
    textSize: textSize,
    bottomTextColor: bottomTextColor,
    bottomTextSize: bottomTextSize,
    outsideTextColor: outsideTextColor,
    outsideTextSize: outsideTextSize,
    borderColor: borderColor,
    borderWidth: borderWidth,
    shadowOpacity: shadowOpacity,
    shadowBlur: shadowBlur,
    blink: blink,
    imageBytes: imageBytes == null ? null : Uint8List.fromList(imageBytes!),
    sex: sex,
    birthday: birthday,
    description: description,
    parentId: parentId,
    level: level,
    metadata: Map<String, String>.from(metadata),
  );
}

class _EdgeModel {
  final String from;
  final String to;
  final _EdgePort fromPort;
  final _EdgePort toPort;
  final _EdgeRoute route;
  final Color color;
  final bool dashed;
  final bool arrow;
  final bool animated;
  final double width;
  final double bend;
  final double elbow;
  final double labelT;
  final double labelOffset;
  final double labelSize;
  final Color labelColor;
  final String label;

  const _EdgeModel({
    required this.from,
    required this.to,
    required this.fromPort,
    required this.toPort,
    this.route = _EdgeRoute.bezier,
    this.color = const Color(0xFF607D8B),
    this.dashed = false,
    this.arrow = false,
    this.animated = false,
    this.width = 2.2,
    this.bend = 0,
    this.elbow = 0.5,
    this.labelT = 0.4,
    this.labelOffset = 10,
    this.labelSize = 12,
    this.labelColor = const Color(0xFF111111),
    this.label = '',
  });

  _EdgeModel copyWith({
    _EdgePort? fromPort,
    _EdgePort? toPort,
    _EdgeRoute? route,
    Color? color,
    bool? dashed,
    bool? arrow,
    bool? animated,
    double? width,
    double? bend,
    double? elbow,
    double? labelT,
    double? labelOffset,
    double? labelSize,
    Color? labelColor,
    String? label,
  }) {
    return _EdgeModel(
      from: from,
      to: to,
      fromPort: fromPort ?? this.fromPort,
      toPort: toPort ?? this.toPort,
      route: route ?? this.route,
      color: color ?? this.color,
      dashed: dashed ?? this.dashed,
      arrow: arrow ?? this.arrow,
      animated: animated ?? this.animated,
      width: width ?? this.width,
      bend: bend ?? this.bend,
      elbow: elbow ?? this.elbow,
      labelT: labelT ?? this.labelT,
      labelOffset: labelOffset ?? this.labelOffset,
      labelSize: labelSize ?? this.labelSize,
      labelColor: labelColor ?? this.labelColor,
      label: label ?? this.label,
    );
  }
}

class _GroupModel {
  final String id;
  String name;
  Color color;
  final Set<String> nodeIds;

  _GroupModel({
    required this.id,
    required this.name,
    required this.color,
    required this.nodeIds,
  });

  _GroupModel clone() =>
      _GroupModel(id: id, name: name, color: color, nodeIds: {...nodeIds});
}

/// Nét vẽ tay (world space), hiển thị phía trên nền và cạnh.
class _PenStroke {
  final List<Offset> points;
  final Color color;
  final double width;
  final bool highlighter;

  _PenStroke({
    required this.points,
    required this.color,
    required this.width,
    required this.highlighter,
  });

  _PenStroke clone() => _PenStroke(
    points: List<Offset>.from(points),
    color: color,
    width: width,
    highlighter: highlighter,
  );
}

class _TextNoteModel {
  final String id;
  Offset position;
  String text;
  double fontSize;
  Color color;
  bool bold;
  bool italic;

  _TextNoteModel({
    required this.id,
    required this.position,
    required this.text,
    this.fontSize = 20,
    this.color = const Color(0xFF1A1A1A),
    this.bold = false,
    this.italic = false,
  });

  _TextNoteModel clone() => _TextNoteModel(
    id: id,
    position: position,
    text: text,
    fontSize: fontSize,
    color: color,
    bold: bold,
    italic: italic,
  );
}

class _Snapshot {
  final List<_NodeModel> nodes;
  final List<_EdgeModel> edges;
  final List<_GroupModel> groups;
  final List<_TextNoteModel> textNotes;
  final Set<String> selectedIds;
  final int? selectedEdgeIndex;
  final List<_PenStroke> penStrokes;

  _Snapshot({
    required this.nodes,
    required this.edges,
    required this.groups,
    required this.textNotes,
    required this.selectedIds,
    required this.selectedEdgeIndex,
    required this.penStrokes,
  });
}

class _ImportedCanvasGraph {
  final List<_NodeModel> nodes;
  final List<_EdgeModel> edges;
  final Map<String, String> imageUrls;

  const _ImportedCanvasGraph({
    required this.nodes,
    required this.edges,
    this.imageUrls = const <String, String>{},
  });
}

class _GettingStartedDemoPageState extends State<GettingStartedDemoPage>
    with SingleTickerProviderStateMixin {
  late final CanvasKitController _controller;
  final GlobalKey _canvasDropKey = GlobalKey(debugLabel: 'canvas-drop-zone');
  final List<_NodeModel> _nodes = <_NodeModel>[];
  final List<_EdgeModel> _edges = <_EdgeModel>[];
  final List<_GroupModel> _groups = <_GroupModel>[];
  final List<_TextNoteModel> _textNotes = <_TextNoteModel>[];
  final List<_Snapshot> _undo = <_Snapshot>[];
  final List<_Snapshot> _redo = <_Snapshot>[];

  _CanvasTool _tool = _CanvasTool.cursor;
  _NodeShape _createShape = _NodeShape.rect;
  Color _createColor = const Color(0xFF5B8CFF);
  Set<String> _selectedIds = <String>{};
  int? _selectedEdgeIndex;
  int? _activeEdgeLabelDragIndex;
  String? _connectFromNodeId;
  String? _selectedTextId;
  String? _editingTextId;
  _ActivePortDrag? _activePortDrag;
  bool _showTextStylePanel = false;
  bool _showGeometricStrip = false;
  bool _showSearchBox = false;
  bool _shapeDragging = false;
  bool _multiSelect = false;
  int _nodeCounter = 1;
  int _groupCounter = 1;
  int _textCounter = 1;

  final List<_PenStroke> _penStrokes = <_PenStroke>[];
  List<Offset>? _activePenPoints;
  bool _eraserGestureActive = false;

  Color _penColor = const Color(0xFF1A1A1A);
  Color _fillColor = const Color(0xFF5B8CFF);
  double _penWidth = 3;
  double _eraserWidth = 28;
  bool _penHighlighter = false;
  late final AnimationController _edgeFxController;
  final ScrollController _primaryStripController = ScrollController();
  final ScrollController _geoStripController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _blinkTimer;
  Timer? _viewportImageDebounce;
  bool _isImportingImages = false;
  bool _isExportingPdf = false;
  int _loadedImageCount = 0;
  int _totalImageCount = 0;
  int _imageLoaderEpoch = 0;
  bool _imageLoaderRunning = false;
  final Map<String, String> _pendingImageUrlsByNode = <String, String>{};
  final Map<String, Uint8List> _imageBytesByUrlCache = <String, Uint8List>{};
  final Set<String> _queuedImageNodeIds = <String>{};
  final Set<String> _inFlightImageNodeIds = <String>{};
  final Map<String, Rect> _nodeBoundsById = <String, Rect>{};
  bool _nodeBoundsDirty = true;

  // Filter UI state
  String? _filterRootNodeId;
  int _filterGenerationDepth = 3;
  String? _filterBranchChildId;
  int? _filterBranchNumber;
  bool _showFilterPanel = false;
  Set<String>? _filteredNodeIds;
  Set<String>? _filteredEdgeIndices;

  static const List<Color> _paletteColors = <Color>[
    Color(0xFFFFFFFF),
    Color(0xFF1A1A1A),
    Color(0xFFE53935),
    Color(0xFF43A047),
    Color(0xFF1E88E5),
    Color(0xFFFDD835),
    Color(0xFF8E24AA),
    Color(0xFFFF7043),
    Color(0xFF78909C),
  ];

  bool get _isDrawTool =>
      _tool == _CanvasTool.pen ||
      _tool == _CanvasTool.eraser ||
      _tool == _CanvasTool.fill;

  double get _appBarToolHeight {
    if (_showGeometricStrip && _isDrawTool) return 156.0;
    if (_showGeometricStrip || _isDrawTool) return 108.0;
    return 56.0;
  }

  @override
  void initState() {
    super.initState();
    _controller = CanvasKitController();
    _controller.addListener(_onCanvasControllerNotify);
    _edgeFxController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _edgeFxController.addListener(() {
      if (!mounted) return;
      if (_edges.any((e) => e.animated) || _nodes.any((n) => n.blink)) {
        setState(() {});
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncEdgeFxTicker();
      }
    });
  }

  /// Chi chay AnimationController khi co canh noi dong / node nhap nhay — tiet kiem CPU tren mobile.
  void _syncEdgeFxTicker() {
    if (!mounted) {
      return;
    }
    final bool need =
        _edges.any((e) => e.animated) || _nodes.any((n) => n.blink);
    if (need) {
      if (!_edgeFxController.isAnimating) {
        _edgeFxController.repeat();
      }
    } else {
      _edgeFxController.stop();
      _edgeFxController.value = 0;
    }
  }

  void _onCanvasControllerNotify() {
    _onViewportMaybeChanged();
    setState(() {});
  }

  @override
  void dispose() {
    _blinkTimer?.cancel();
    _viewportImageDebounce?.cancel();
    _controller.removeListener(_onCanvasControllerNotify);
    _edgeFxController.dispose();
    _primaryStripController.dispose();
    _geoStripController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  String _nextNodeId() => 'n${_nodeCounter++}';
  String _nextGroupId() => 'g${_groupCounter++}';
  String _nextTextId() => 't${_textCounter++}';

  bool _isTextInputFocused() {
    final focusedWidget = FocusManager.instance.primaryFocus?.context?.widget;
    return focusedWidget is EditableText;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{},
      child: Actions(
        actions: <Type, Action<Intent>>{
          _DeleteSelectionIntent: CallbackAction<_DeleteSelectionIntent>(
            onInvoke: (intent) {
              if (_searchFocusNode.hasFocus || _isTextInputFocused()) {
                return null;
              }
              _deleteSelection();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(
              toolbarHeight: 0,
              automaticallyImplyLeading: false,
              bottom: PreferredSize(
                preferredSize: Size.fromHeight(_appBarToolHeight),
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  elevation: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildPrimaryToolStrip(context),
                      if (_showGeometricStrip) ...[
                        const Divider(height: 1),
                        _buildGeometricStrip(context),
                      ],
                      if (_isDrawTool) ...[
                        const Divider(height: 1),
                        _buildDrawOptionsStrip(context),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            body: Stack(
              children: [
                DragTarget<_NodeShape>(
                  key: _canvasDropKey,
                  onWillAcceptWithDetails: (details) => !_isDrawTool,
                  onAcceptWithDetails: (details) {
                    final ctx = _canvasDropKey.currentContext;
                    if (ctx == null) return;
                    final box = ctx.findRenderObject() as RenderBox;
                    final local = box.globalToLocal(details.offset);
                    final world = _controller.screenToWorld(local);
                    _addNodeAt(world, shape: details.data);
                  },
                  builder: (context, candidateData, rejectedData) {
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final viewportSize = Size(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        );
                        final worldViewport = _worldViewportRect(
                          viewportSize,
                          paddingWorld: 280,
                        );
                        final visibleNodes = _visibleNodesForViewport(
                          worldViewport,
                        );
                        final visibleNodeIds = visibleNodes
                            .map((n) => n.id)
                            .toSet();
                        final visibleEdges = _visibleEdgesForViewport(
                          worldViewport,
                          visibleNodeIds,
                        );
                        final visibleTextNotes =
                            _visibleTextNotesForViewport(worldViewport);
                        final selectedEdge =
                            _selectedEdgeIndex != null &&
                                _selectedEdgeIndex! >= 0 &&
                                _selectedEdgeIndex! < _edges.length
                            ? _edges[_selectedEdgeIndex!]
                            : null;
                        final visibleSelectedEdgeIndex =
                            selectedEdge == null
                            ? null
                            : visibleEdges.indexOf(selectedEdge);

                        return CanvasKit(
                          controller: _controller,
                          externalTransformNotifications: true,
                          interactionMode: _tool == _CanvasTool.hand
                                  ? InteractionMode.programmatic
                                  : InteractionMode.interactive,
                              enablePan: _tool == _CanvasTool.hand,
                              enableWheelZoom: true,
                              gestureOverlayBuilder: _tool == _CanvasTool.hand
                                  ? (t, c) => _HandPanOverlay(controller: c)
                                  : null,
                              backgroundBuilder: (transform) => Container(
                                color: const Color(0xFFF7F8FA),
                                child: CustomPaint(
                                  painter: _GridPainter(
                                    transform: transform,
                                    spacing: 50,
                                  ),
                                  size: Size.infinite,
                                ),
                              ),
                              foregroundLayers: [
                                (t) => _GroupPainter(
                                  transform: t,
                                  nodes: _nodes,
                                  groups: _groups,
                                ),
                                (t) => _EdgePainter(
                                  transform: t,
                                  nodes: _nodes,
                                  groups: _groups,
                                  edges: visibleEdges,
                                  selectedEdgeIndex:
                                      visibleSelectedEdgeIndex != null &&
                                          visibleSelectedEdgeIndex >= 0
                                      ? visibleSelectedEdgeIndex
                                      : null,
                                  fxValue: _edgeFxController.value,
                                ),
                              ],
                              children: [
                                ...visibleNodes.map(
                                  (node) => CanvasItem(
                                    id: node.id,
                                    worldPosition: node.position,
                                    estimatedSize: node.size,
                                    draggable: false,
                                    child: _NodeWidget(
                                      node: node,
                                      selected: _selectedIds.contains(node.id),
                                      tool: _tool,
                                      fxValue: _edgeFxController.value,
                                      onTap: () => _onNodeTap(node.id),
                                      onDoubleTapEdit: () => _editText(node),
                                      onSecondaryTapDown: (d) =>
                                          _showNodeMenu(node, d),
                                      onMoved: (deltaWorld) =>
                                          _moveNode(node.id, deltaWorld),
                                      onResize: (size) =>
                                          _resizeNode(node.id, size),
                                      onStartConnectFromPort: (port, kind) =>
                                          _startPortDrag(
                                            node.id,
                                            port,
                                            kind: kind,
                                          ),
                                    ),
                                  ),
                                ),
                                ...visibleTextNotes.map(
                                  (note) => CanvasItem(
                                    id: note.id,
                                    worldPosition: note.position,
                                    draggable: !_isDrawTool,
                                    onWorldMoved: (next) =>
                                        setState(() => note.position = next),
                                    child: _TextNoteWidget(
                                      note: note,
                                      selected: _selectedTextId == note.id,
                                      editing: _editingTextId == note.id,
                                      onTap: () {
                                        if (_isDrawTool) return;
                                        setState(() {
                                          _selectedTextId = note.id;
                                          _showTextStylePanel = true;
                                          _selectedIds.clear();
                                          _selectedEdgeIndex = null;
                                        });
                                      },
                                      onDoubleTap: () {
                                        if (_isDrawTool) return;
                                        setState(() {
                                          _selectedTextId = note.id;
                                          _editingTextId = note.id;
                                          _showTextStylePanel = true;
                                          _selectedIds.clear();
                                          _selectedEdgeIndex = null;
                                        });
                                      },
                                      onTextChanged: (v) => note.text = v,
                                      onSubmit: () => setState(() {
                                        _editingTextId = null;
                                        _selectedTextId = note.id;
                                        _showTextStylePanel = true;
                                      }),
                                    ),
                                  ),
                                ),
                              ],
                            );
                      },
                    );
                  },
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _PenStrokePainter(
                        transform: _controller.transform,
                        strokes: _penStrokes,
                        activePoints: _activePenPoints,
                        activeColor: _penHighlighter
                            ? _penColor.withValues(alpha: 0.42)
                            : _penColor,
                        activeWidth: _penHighlighter
                            ? _penWidth * 2.6
                            : _penWidth,
                        activeHighlighter: _penHighlighter,
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: _isDrawTool,
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (event) {
                        if (_activePortDrag != null) return;
                        final screen = event.localPosition;
                        final hitLabelEdge = _hitEdgeLabelAtScreen(screen);
                        if (hitLabelEdge != null) {
                          _undo.add(_captureSnapshot());
                          _redo.clear();
                          setState(() {
                            _selectedEdgeIndex = hitLabelEdge;
                            _selectedIds = {};
                            _selectedTextId = null;
                            _editingTextId = null;
                            _activeEdgeLabelDragIndex = hitLabelEdge;
                          });
                          return;
                        }
                        final hitNode = _hitNodeAtScreen(screen);
                        if (hitNode != null) {
                          return;
                        }
                        final hitGroup = _hitGroupAtScreen(screen);
                        if (hitGroup != null && _tool == _CanvasTool.connect) {
                          return;
                        }
                        final hitText = _hitTextAtScreen(screen);
                        if (hitText != null) {
                          setState(() {
                            _selectedTextId = hitText;
                            _showTextStylePanel = true;
                            _selectedIds.clear();
                            _selectedEdgeIndex = null;
                          });
                          return;
                        }
                        final hitEdge = _hitEdgeAtScreen(screen);
                        setState(() {
                          _selectedTextId = null;
                          _editingTextId = null;
                          _showTextStylePanel = false;
                          _selectedEdgeIndex = hitEdge;
                          if (hitEdge != null) {
                            _selectedIds = {};
                          } else if (_tool != _CanvasTool.connect) {
                            _connectFromNodeId = null;
                          }
                        });
                      },
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerMove: (event) {
                      if (_activeEdgeLabelDragIndex != null) {
                        _dragActiveEdgeLabel(event.localPosition);
                        return;
                      }
                      if (_activePortDrag == null) return;
                      setState(() {
                        _activePortDrag = _activePortDrag!.copyWith(
                          currentWorld: _controller.screenToWorld(
                            event.localPosition,
                          ),
                        );
                      });
                    },
                    onPointerUp: (event) {
                      if (_activeEdgeLabelDragIndex != null) {
                        setState(() => _activeEdgeLabelDragIndex = null);
                        return;
                      }
                      _finishPortDrag(event.localPosition);
                    },
                    onPointerCancel: (event) {
                      if (_activeEdgeLabelDragIndex != null) {
                        setState(() => _activeEdgeLabelDragIndex = null);
                        return;
                      }
                      if (_activePortDrag != null) {
                        setState(() => _activePortDrag = null);
                      }
                    },
                  ),
                ),
                if (_activePortDrag != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _ConnectPreviewPainter(
                          transform: _controller.transform,
                          activeDrag: _activePortDrag,
                        ),
                      ),
                    ),
                  ),
                if (_isDrawTool)
                  Positioned.fill(
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _onDrawPointerDown,
                      onPointerMove: _onDrawPointerMove,
                      onPointerUp: _onDrawPointerUp,
                      onPointerCancel: _onDrawPointerCancel,
                    ),
                  ),
                if (_shapeDragging)
                  IgnorePointer(
                    child: Container(
                      color: Colors.blue.withValues(alpha: 0.05),
                      alignment: Alignment.topCenter,
                      padding: const EdgeInsets.only(top: 12),
                      child: const Text(
                        'Drop shape on canvas to create object',
                        style: TextStyle(
                          color: Colors.blueAccent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                if (_singleSelectedNode != null && !_isDrawTool)
                  Positioned(
                    right: 12,
                    top: 12,
                    child: _buildNodeDetailsPanel(_singleSelectedNode!),
                  ),
                if (_showFilterPanel && !_isDrawTool)
                  Positioned(
                    left: 12,
                    top: 12,
                    child: _buildFilterPanel(context),
                  ),
                if (_isImportingImages)
                  Positioned(
                    left: 12,
                    bottom: 12,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.68),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Text(
                          'Loading images: $_loadedImageCount/$_totalImageCount',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_isExportingPdf)
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.22),
                      child: Center(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 14,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.2,
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text(
                                  'Đang tạo ảnh gia phả...',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: _openAddNodeDialog,
              tooltip: 'Thêm thành viên phả tộc',
              child: const Icon(Icons.person_add),
            ),
          ),
        ),
      ),
    );
  }

  /// Primary icon strip: scroll ngang, vùng chạm tối thiểu 48dp — phù hợp mobile.
  Widget _buildPrimaryToolStrip(BuildContext context) {
    void snack(String msg) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
    }

    final hasEdge =
        _selectedEdgeIndex != null &&
        _selectedEdgeIndex! >= 0 &&
        _selectedEdgeIndex! < _edges.length;
    final selectedEdge = hasEdge ? _edges[_selectedEdgeIndex!] : null;

    return SizedBox(
      height: 52,
      child: Scrollbar(
        controller: _primaryStripController,
        thumbVisibility: true,
        child: Listener(
          onPointerSignal: (event) {
            if (event is! PointerScrollEvent) return;
            if (!_primaryStripController.hasClients) return;
            final next = _primaryStripController.offset + event.scrollDelta.dy;
            final clamped = next.clamp(
              _primaryStripController.position.minScrollExtent,
              _primaryStripController.position.maxScrollExtent,
            );
            _primaryStripController.jumpTo(clamped.toDouble());
          },
          child: ListView(
            controller: _primaryStripController,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            children: [
              _toolBtn(
                Icons.near_me,
                _tool == _CanvasTool.cursor,
                'Cursor',
                () {
                  setState(() {
                    _tool = _CanvasTool.cursor;
                    _connectFromNodeId = null;
                  });
                },
              ),
              _toolBtn(
                Icons.pan_tool_alt,
                _tool == _CanvasTool.hand,
                'Hand',
                () {
                  setState(() {
                    _tool = _CanvasTool.hand;
                    _connectFromNodeId = null;
                  });
                },
              ),
              _toolBtn(
                Icons.account_tree,
                _tool == _CanvasTool.connect,
                'Nối node',
                () {
                  setState(() {
                    _tool = _CanvasTool.connect;
                    _connectFromNodeId = null;
                  });
                },
              ),
              _toolBtn(
                Icons.category_outlined,
                _showGeometricStrip,
                'Geo',
                () =>
                    setState(() => _showGeometricStrip = !_showGeometricStrip),
              ),
              _toolbarDivider(),
              _toolBtn(Icons.brush, _tool == _CanvasTool.pen, 'Pen', () {
                setState(() {
                  _tool = _CanvasTool.pen;
                  _connectFromNodeId = null;
                });
              }),
              _toolBtn(
                Icons.auto_fix_high,
                _tool == _CanvasTool.eraser,
                'Eraser',
                () {
                  setState(() {
                    _tool = _CanvasTool.eraser;
                    _connectFromNodeId = null;
                  });
                },
              ),
              _toolBtn(
                Icons.format_color_fill,
                _tool == _CanvasTool.fill,
                'Fill',
                () {
                  setState(() {
                    _tool = _CanvasTool.fill;
                    _connectFromNodeId = null;
                  });
                },
              ),
              _toolbarDivider(),
              IconButton(
                tooltip: 'Add object (center of screen)',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _addNodeAtCenter,
                icon: const Icon(Icons.add_box_outlined),
              ),
              IconButton(
                tooltip: 'Layers',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => snack('Layers: coming soon'),
                icon: const Icon(Icons.layers_outlined),
              ),
              IconButton(
                tooltip: 'Thêm text box vào canvas',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () {
                  _createTextNoteAtCenter();
                  setState(() => _showTextStylePanel = true);
                },
                icon: Icon(
                  Icons.text_fields,
                  color: _selectedTextId != null
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              if (_showTextStylePanel || _selectedTextId != null) ...[
                IconButton(
                  tooltip: 'Bold text',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: _selectedTextId == null
                      ? null
                      : () => _toggleTextBold(_selectedTextId!),
                  icon: const Icon(Icons.format_bold),
                ),
                IconButton(
                  tooltip: 'Italic text',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: _selectedTextId == null
                      ? null
                      : () => _toggleTextItalic(_selectedTextId!),
                  icon: const Icon(Icons.format_italic),
                ),
                IconButton(
                  tooltip: 'Text smaller',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: _selectedTextId == null
                      ? null
                      : () => _changeTextSize(_selectedTextId!, -2),
                  icon: const Icon(Icons.text_decrease),
                ),
                IconButton(
                  tooltip: 'Text larger',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: _selectedTextId == null
                      ? null
                      : () => _changeTextSize(_selectedTextId!, 2),
                  icon: const Icon(Icons.text_increase),
                ),
                IconButton(
                  tooltip: 'Text color',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: _selectedTextId == null
                      ? null
                      : () => _cycleTextColor(_selectedTextId!),
                  icon: const Icon(Icons.format_color_text),
                ),
              ],
              IconButton(
                tooltip: 'Import',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _importFamilyTreeJson,
                icon: const Icon(Icons.account_tree_outlined),
              ),
              IconButton(
                tooltip: 'Family Tree List',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    // builder: (context) => const FamilyTreeListDemoPage(),
                    builder: (context) => const FamilyTreePage(),
                  ),
                ),
                icon: const Icon(Icons.list),
              ),
              if (_showSearchBox)
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    onSubmitted: _searchAndFocusNode,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Search node...',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 6,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      suffixIcon: IconButton(
                        tooltip: 'Search node',
                        onPressed: () =>
                            _searchAndFocusNode(_searchController.text),
                        icon: const Icon(Icons.search, size: 18),
                      ),
                    ),
                  ),
                )
              else
                IconButton(
                  tooltip: 'Search node',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: _toggleSearchBox,
                  icon: const Icon(Icons.search),
                ),
              if (_showSearchBox)
                IconButton(
                  tooltip: 'Hide search',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: _toggleSearchBox,
                  icon: const Icon(Icons.close),
                ),
              IconButton(
                tooltip: 'Search & center node',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => _searchAndFocusNode(_searchController.text),
                icon: const Icon(Icons.center_focus_strong),
              ),
              IconButton(
                tooltip: 'Zoom in',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => _zoomBy(1.12),
                icon: const Icon(Icons.zoom_in),
              ),
              IconButton(
                tooltip: 'Zoom out',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => _zoomBy(1 / 1.12),
                icon: const Icon(Icons.zoom_out),
              ),
              IconButton(
                tooltip: 'Fit view',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () {
                  if (_nodes.isEmpty) return;
                  final size = MediaQuery.of(context).size;
                  final pts = _nodes
                      .map(
                        (n) =>
                            n.position +
                            Offset(n.size.width / 2, n.size.height / 2),
                      )
                      .toList();
                  _controller.fitToPositions(pts, size, padding: 48);
                },
                icon: const Icon(Icons.fit_screen),
              ),
              IconButton(
                tooltip: 'Save',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => snack('Save: wire up to your backend'),
                icon: const Icon(Icons.save_outlined),
              ),
              IconButton(
                tooltip: 'Export ảnh phả hệ (PNG)',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _isExportingPdf
                    ? null
                    : _exportDecorativeFamilyTreeImage,
                icon: _isExportingPdf
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.0),
                      )
                    : const Icon(Icons.image_outlined),
              ),
              _toolbarDivider(),
              IconButton(
                tooltip: 'Đổi màu nền object (chọn một hoặc nhiều object)',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _selectedIds.isEmpty ? null : _pickColorForSelection,
                icon: const Icon(Icons.palette_outlined),
              ),
              IconButton(
                tooltip: 'Upload image',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _selectedIds.length == 1
                    ? _uploadImageToSelected
                    : null,
                icon: const Icon(Icons.image_outlined),
              ),
              IconButton(
                tooltip: 'Border thinner',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _selectedIds.isEmpty
                    ? null
                    : () => _setSelectedNodeBorderWidth(-0.5),
                icon: const Icon(Icons.border_style),
              ),
              IconButton(
                tooltip: 'Border color',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _selectedIds.isEmpty
                    ? null
                    : _cycleSelectedNodeBorderColor,
                icon: const Icon(Icons.border_color),
              ),
              IconButton(
                tooltip: 'Border thicker',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _selectedIds.isEmpty
                    ? null
                    : () => _setSelectedNodeBorderWidth(0.5),
                icon: const Icon(Icons.border_outer),
              ),
              IconButton(
                tooltip: 'Toggle object shadow',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _selectedIds.isEmpty
                    ? null
                    : _toggleSelectedNodeShadow,
                icon: const Icon(Icons.layers),
              ),
              IconButton(
                tooltip: 'Node settings',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _selectedIds.isEmpty ? null : _openNodeSettings,
                icon: const Icon(Icons.tune),
              ),
              IconButton(
                tooltip: 'Group',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _selectedIds.length >= 2
                    ? () => _groupSelected()
                    : null,
                icon: const Icon(Icons.group_work_outlined),
              ),
              IconButton(
                tooltip: 'Rename group',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _currentGroupForSelection() == null
                    ? null
                    : () => _renameCurrentGroup(),
                icon: const Icon(Icons.drive_file_rename_outline),
              ),
              IconButton(
                tooltip: 'Ungroup',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _selectedIds.isNotEmpty ? _ungroupSelected : null,
                icon: const Icon(Icons.group_off_outlined),
              ),
              _toolbarDivider(),
              IconButton(
                tooltip: 'Route: Straight',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: hasEdge
                    ? () => _updateSelectedEdge(
                        (e) => e.copyWith(route: _EdgeRoute.straight),
                      )
                    : null,
                icon: Icon(
                  Icons.horizontal_rule,
                  color: selectedEdge?.route == _EdgeRoute.straight
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              IconButton(
                tooltip: 'Route: Bezier',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: hasEdge
                    ? () => _updateSelectedEdge(
                        (e) => e.copyWith(route: _EdgeRoute.bezier),
                      )
                    : null,
                icon: Icon(
                  Icons.show_chart,
                  color: selectedEdge?.route == _EdgeRoute.bezier
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              IconButton(
                tooltip: 'Route: Orthogonal',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: hasEdge
                    ? () => _updateSelectedEdge(
                        (e) => e.copyWith(route: _EdgeRoute.orthogonal),
                      )
                    : null,
                icon: Icon(
                  Icons.alt_route,
                  color: selectedEdge?.route == _EdgeRoute.orthogonal
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              IconButton(
                tooltip: 'Route: Family tree',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: hasEdge
                    ? () => _updateSelectedEdge(
                        (e) => e.copyWith(route: _EdgeRoute.familyTree),
                      )
                    : null,
                icon: Icon(
                  Icons.account_tree_outlined,
                  color: selectedEdge?.route == _EdgeRoute.familyTree
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              IconButton(
                tooltip: 'Toggle dashed',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: hasEdge
                    ? () => _updateSelectedEdge(
                        (e) => e.copyWith(dashed: !e.dashed),
                      )
                    : null,
                icon: const Icon(Icons.linear_scale),
              ),
              IconButton(
                tooltip: 'Toggle arrow',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: hasEdge
                    ? () => _updateSelectedEdge(
                        (e) => e.copyWith(arrow: !e.arrow),
                      )
                    : null,
                icon: const Icon(Icons.arrow_right_alt),
              ),
              IconButton(
                tooltip: 'Toggle blink',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: hasEdge
                    ? () => _updateSelectedEdge(
                        (e) => e.copyWith(animated: !e.animated),
                      )
                    : null,
                icon: const Icon(Icons.bolt),
              ),
              IconButton(
                tooltip: 'Edge color',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: hasEdge ? _pickSelectedEdgeColor : null,
                icon: const Icon(Icons.color_lens_outlined),
              ),
              IconButton(
                tooltip: 'Edit edge label',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: hasEdge ? _editSelectedEdgeLabel : null,
                icon: const Icon(Icons.edit_note),
              ),
              IconButton(
                tooltip: 'Edge settings',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: hasEdge ? _openEdgeSettings : null,
                icon: const Icon(Icons.settings_ethernet),
              ),
              IconButton(
                tooltip: 'Delete',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed:
                    (_selectedIds.isNotEmpty ||
                        _selectedEdgeIndex != null ||
                        _selectedTextId != null)
                    ? _deleteSelection
                    : null,
                icon: const Icon(Icons.delete_outline),
              ),
              IconButton(
                tooltip: 'Undo',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _undo.isEmpty ? null : _undoAction,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: 'Redo',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _redo.isEmpty ? null : _redoAction,
                icon: const Icon(Icons.redo),
              ),
              _toolbarDivider(),
              IconButton(
                tooltip: 'Bộ lọc',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () {
                  setState(() => _showFilterPanel = !_showFilterPanel);
                },
                icon: Icon(
                  Icons.filter_list,
                  color: _showFilterPanel
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
              ),
              IconButton(
                tooltip: 'Multi-select',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: () => setState(() => _multiSelect = !_multiSelect),
                icon: Icon(
                  _multiSelect
                      ? Icons.select_all
                      : Icons.check_box_outline_blank,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolbarDivider() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: SizedBox(
      height: 28,
      child: VerticalDivider(
        width: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    ),
  );

  /// Dải Geometric: cuộn ngang, chọn shape + kéo thả vào canvas (giống thanh tham chiếu).
  Widget _buildGeometricStrip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 6),
            child: Text(
              'Geometric',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Listener(
              onPointerSignal: (event) {
                if (event is! PointerScrollEvent) return;
                if (!_geoStripController.hasClients) return;
                final next = _geoStripController.offset + event.scrollDelta.dy;
                final clamped = next.clamp(
                  _geoStripController.position.minScrollExtent,
                  _geoStripController.position.maxScrollExtent,
                );
                _geoStripController.jumpTo(clamped.toDouble());
              },
              child: ListView.separated(
                controller: _geoStripController,
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                itemCount: _NodeShape.values.length,
                separatorBuilder: (_, __) => const SizedBox(width: 4),
                itemBuilder: (context, i) {
                  final shape = _NodeShape.values[i];
                  final selected = _createShape == shape;
                  return _shapeDragChip(shape, selected);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Bút / tẩy / tô: màu và độ dày trong một dải gọn, dễ chạm.
  Widget _buildDrawOptionsStrip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: SizedBox(
        height: 46,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              if (_tool == _CanvasTool.pen) ...[
                Text('Bút', style: labelStyle),
                const SizedBox(width: 8),
                ..._paletteColors.map(
                  (c) => _colorSwatch(
                    c,
                    _penColor == c,
                    () => setState(() => _penColor = c),
                  ),
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Highlight'),
                  selected: _penHighlighter,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) => setState(() => _penHighlighter = v),
                ),
                SizedBox(
                  width: 160,
                  child: Slider(
                    value: _penWidth,
                    min: 1,
                    max: 18,
                    divisions: 17,
                    label: '${_penWidth.round()} px',
                    onChanged: (v) => setState(() => _penWidth = v),
                  ),
                ),
              ] else if (_tool == _CanvasTool.eraser) ...[
                Text('Tẩy', style: labelStyle),
                const SizedBox(width: 10),
                SizedBox(
                  width: 220,
                  child: Slider(
                    value: _eraserWidth,
                    min: 12,
                    max: 72,
                    divisions: 30,
                    label: '${_eraserWidth.round()} px',
                    onChanged: (v) => setState(() => _eraserWidth = v),
                  ),
                ),
              ] else if (_tool == _CanvasTool.fill) ...[
                Text('Tô màu', style: labelStyle),
                const SizedBox(width: 8),
                ..._paletteColors.map(
                  (c) => _colorSwatch(
                    c,
                    _fillColor == c,
                    () => setState(() => _fillColor = c),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _colorSwatch(Color color, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Tooltip(
        message: '#${color.toARGB32().toRadixString(16).toUpperCase()}',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? Colors.blueAccent : Colors.black26,
                width: selected ? 2.5 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: Colors.blue.withValues(alpha: 0.35),
                        blurRadius: 4,
                      ),
                    ]
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _shapeDragChip(_NodeShape shape, bool selected) {
    final icon = _iconForShape(shape);
    return Draggable<_NodeShape>(
      data: shape,
      onDragStarted: () => setState(() {
        _shapeDragging = true;
        _createShape = shape;
      }),
      onDraggableCanceled: (_, __) => setState(() => _shapeDragging = false),
      onDragEnd: (_) => setState(() => _shapeDragging = false),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.blueAccent),
          ),
          child: Icon(icon, color: Colors.blueAccent),
        ),
      ),
      child: Material(
        color: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: () => setState(() => _createShape = shape),
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 44,
            height: 40,
            child: Icon(
              icon,
              size: 22,
              color: selected
                  ? Theme.of(context).colorScheme.onPrimaryContainer
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  void _addNodeAtCenter() {
    final size = MediaQuery.of(context).size;
    final world = _controller.screenToWorld(size.center(Offset.zero));
    _addNodeAt(world, shape: _createShape);
  }

  _NodeModel? get _singleSelectedNode {
    if (_selectedIds.length != 1) return null;
    final selectedId = _selectedIds.first;
    for (final node in _nodes) {
      if (node.id == selectedId) return node;
    }
    return null;
  }

  Size _canvasSize() {
    final ctx = _canvasDropKey.currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.size;
    }
    return MediaQuery.of(context).size;
  }

  // =============== FILTER LOGIC ===============

  /// Calculate the maximum tree depth from all nodes
  int _calculateMaxGenerationDepth() {
    if (_nodes.isEmpty) return 1;

    int maxDepth = 1;

    // For each potential root, calculate tree depth
    for (final rootNode in _nodes) {
      int depth = _calculateDepthFrom(rootNode.id);
      if (depth > maxDepth) {
        maxDepth = depth;
      }
    }

    // Return at least 1, max 15
    return maxDepth.clamp(1, 15);
  }

  /// Calculate tree depth starting from a specific node
  int _calculateDepthFrom(String nodeId, {Set<String>? visited}) {
    visited ??= <String>{};
    if (visited.contains(nodeId)) return 0;
    visited.add(nodeId);

    int maxChildDepth = 0;
    for (final edge in _edges) {
      if (edge.from == nodeId && edge.route == _EdgeRoute.familyTree) {
        final childDepth = 1 + _calculateDepthFrom(edge.to, visited: visited);
        if (childDepth > maxChildDepth) {
          maxChildDepth = childDepth;
        }
      }
    }
    return maxChildDepth;
  }

  /// Get all descendants of a node up to maxGenerations deep
  Set<String> _getDescendants(String rootNodeId, int maxGenerations) {
    final result = <String>{rootNodeId};
    final queue = <MapEntry<String, int>>[];
    queue.add(MapEntry(rootNodeId, 0));

    while (queue.isNotEmpty) {
      final entry = queue.removeAt(0);
      final nodeId = entry.key;
      final generation = entry.value;

      if (generation >= maxGenerations - 1) continue;

      // Find all children of this node (edges where from == nodeId and route is family-tree-like)
      for (final edge in _edges) {
        if (edge.from == nodeId && edge.route == _EdgeRoute.familyTree) {
          if (!result.contains(edge.to)) {
            result.add(edge.to);
            queue.add(MapEntry(edge.to, generation + 1));
          }
        }
      }
    }
    return result;
  }

  /// Get direct children of a node
  List<String> _getChildrenOfNode(String nodeId) {
    final children = <String>[];
    for (final edge in _edges) {
      if (edge.from == nodeId && edge.route == _EdgeRoute.familyTree) {
        if (!children.contains(edge.to)) {
          children.add(edge.to);
        }
      }
    }
    return children;
  }

  /// Get all descendants of a specific child branch
  Set<String> _getDescendantsBranch(
    String rootNodeId,
    String childId,
    int maxGenerations,
  ) {
    final result = <String>{rootNodeId, childId};
    final queue = <MapEntry<String, int>>[];
    queue.add(MapEntry(childId, 1));

    while (queue.isNotEmpty) {
      final entry = queue.removeAt(0);
      final nodeId = entry.key;
      final generation = entry.value;

      if (generation >= maxGenerations) continue;

      for (final edge in _edges) {
        if (edge.from == nodeId && edge.route == _EdgeRoute.familyTree) {
          if (!result.contains(edge.to)) {
            result.add(edge.to);
            queue.add(MapEntry(edge.to, generation + 1));
          }
        }
      }
    }
    return result;
  }

  int? _readNodeBranchNumber(_NodeModel node) {
    final raw = (node.metadata['Branch'] ?? node.metadata['branch'] ?? '')
        .trim();
    if (raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  List<int> _availableBranchNumbers() {
    final branches = <int>{};
    for (final node in _nodes) {
      final value = _readNodeBranchNumber(node);
      if (value != null && value > 0) {
        branches.add(value);
      }
    }
    final sorted = branches.toList()..sort();
    return sorted;
  }

  /// Apply the current filter and update _filteredNodeIds/_filteredEdgeIndices
  void _applyFilter() {
    if (_filterRootNodeId == null || _filterRootNodeId!.isEmpty) {
      setState(() {
        _filteredNodeIds = null;
        _filteredEdgeIndices = null;
      });
      return;
    }

    var visibleNodeIds =
        _filterBranchChildId != null && _filterBranchChildId!.isNotEmpty
        ? _getDescendantsBranch(
            _filterRootNodeId!,
            _filterBranchChildId!,
            _filterGenerationDepth,
          )
        : _getDescendants(_filterRootNodeId!, _filterGenerationDepth);

    // Additional chi filter: keep existing behavior and refine by Branch when selected.
    if (_filterBranchNumber != null) {
      visibleNodeIds = visibleNodeIds.where((id) {
        final node = _nodes.firstWhere(
          (n) => n.id == id,
          orElse: () => _NodeModel(
            id: '',
            position: const Offset(0, 0),
            size: const Size(0, 0),
            shape: _NodeShape.rect,
            text: '',
            color: Colors.transparent,
          ),
        );
        if (node.id.isEmpty) return false;
        return _readNodeBranchNumber(node) == _filterBranchNumber;
      }).toSet();
    }

    // Collect edge indices for visible edges
    final edgeIndices = <String>{};
    for (int i = 0; i < _edges.length; i++) {
      final edge = _edges[i];
      if (visibleNodeIds.contains(edge.from) &&
          visibleNodeIds.contains(edge.to)) {
        edgeIndices.add(i.toString());
      }
    }

    setState(() {
      _filteredNodeIds = visibleNodeIds;
      _filteredEdgeIndices = edgeIndices;
    });
  }

  /// Clear all filters
  void _clearFilter() {
    setState(() {
      _filterRootNodeId = null;
      _filterBranchChildId = null;
      _filterBranchNumber = null;
      _filterGenerationDepth = 3;
      _filteredNodeIds = null;
      _filteredEdgeIndices = null;
      _showFilterPanel = false;
    });
  }

  Rect _worldViewportRect(Size viewportSize, {double paddingWorld = 240}) {
    final a = _controller.screenToWorld(Offset.zero);
    final b = _controller.screenToWorld(
      Offset(viewportSize.width, viewportSize.height),
    );
    final left = math.min(a.dx, b.dx);
    final top = math.min(a.dy, b.dy);
    final right = math.max(a.dx, b.dx);
    final bottom = math.max(a.dy, b.dy);
    return Rect.fromLTRB(left, top, right, bottom).inflate(paddingWorld);
  }

  Rect _nodeRect(_NodeModel n) =>
      Rect.fromLTWH(n.position.dx, n.position.dy, n.size.width, n.size.height);

  void _markNodeBoundsDirty() {
    _nodeBoundsDirty = true;
  }

  void _ensureNodeBoundsCache() {
    if (!_nodeBoundsDirty && _nodeBoundsById.length == _nodes.length) return;
    _nodeBoundsById
      ..clear()
      ..addEntries(_nodes.map((n) => MapEntry(n.id, _nodeRect(n))));
    _nodeBoundsDirty = false;
  }

  List<_NodeModel> _visibleNodesForViewport(Rect worldViewport) {
    _ensureNodeBoundsCache();
    return _nodes
        .where((n) {
          // Apply filter if active
          if (_filteredNodeIds != null && !_filteredNodeIds!.contains(n.id)) {
            return false;
          }
          final rect = _nodeBoundsById[n.id] ?? _nodeRect(n);
          return rect.overlaps(worldViewport);
        })
        .toList(growable: false);
  }

  List<_EdgeModel> _visibleEdgesForViewport(
    Rect worldViewport,
    Set<String> visibleNodeIds,
  ) {
    final nodeById = {for (final n in _nodes) n.id: n};
    return _edges
        .where((e) {
          // Apply filter if active - both endpoints must be in filtered set
          if (_filteredNodeIds != null) {
            if (!_filteredNodeIds!.contains(e.from) ||
                !_filteredNodeIds!.contains(e.to)) {
              return false;
            }
          }
          if (visibleNodeIds.contains(e.from) ||
              visibleNodeIds.contains(e.to)) {
            return true;
          }
          final fromNode = nodeById[e.from];
          final toNode = nodeById[e.to];
          if (fromNode == null || toNode == null) return false;
          final fromCenter =
              fromNode.position +
              Offset(fromNode.size.width / 2, fromNode.size.height / 2);
          final toCenter =
              toNode.position +
              Offset(toNode.size.width / 2, toNode.size.height / 2);
          return Rect.fromPoints(
            fromCenter,
            toCenter,
          ).inflate(24).overlaps(worldViewport);
        })
        .toList(growable: false);
  }

  List<_TextNoteModel> _visibleTextNotesForViewport(Rect worldViewport) {
    return _textNotes
        .where((note) => worldViewport.contains(note.position))
        .toList(growable: false);
  }

  void _zoomBy(double factor) {
    final next = (_controller.scale * factor)
        .clamp(_controller.minZoom, _controller.maxZoom)
        .toDouble();
    final selectedNode = _singleSelectedNode;
    if (selectedNode == null) {
      _controller.setScale(next);
      return;
    }
    final center =
        selectedNode.position +
        Offset(selectedNode.size.width / 2, selectedNode.size.height / 2);
    _controller.setScale(next, focalWorld: center);
    _controller.centerOn(center, _canvasSize());
  }

  void _focusNode(
    _NodeModel node, {
    bool blink = false,
    double minScale = 1.2,
  }) {
    final center =
        node.position + Offset(node.size.width / 2, node.size.height / 2);
    final targetScale = math.max(_controller.scale, minScale);
    _controller.setScale(targetScale, focalWorld: center);
    _controller.centerOn(center, _canvasSize());
    if (!blink) return;
    _blinkTimer?.cancel();
    setState(() => node.blink = true);
    _syncEdgeFxTicker();
    _blinkTimer = Timer(const Duration(milliseconds: 2200), () {
      if (!mounted) return;
      setState(() => node.blink = false);
      _syncEdgeFxTicker();
    });
  }

  void _searchAndFocusNode(String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) return;
    _NodeModel? hit;
    for (final n in _nodes) {
      final hay =
          '${n.id} ${n.text} ${n.bottomText} ${n.outsideText} ${n.description} ${n.birthday}'
              .toLowerCase();
      if (hay.contains(query)) {
        hit = n;
        break;
      }
    }
    if (hit == null) {
      _showSnack('Không tìm thấy node chứa: "$query"');
      return;
    }
    setState(() {
      _selectedIds = {hit!.id};
      _selectedEdgeIndex = null;
      _selectedTextId = null;
      _editingTextId = null;
      _showTextStylePanel = false;
    });
    _focusNode(hit, blink: true, minScale: 1.35);
  }

  void _toggleSearchBox() {
    final next = !_showSearchBox;
    setState(() => _showSearchBox = next);
    if (!next) {
      _searchFocusNode.unfocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocusNode.requestFocus();
    });
  }

  Widget _buildNodeDetailsPanel(_NodeModel node) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    String valueOrDash(String value) =>
        value.trim().isEmpty ? '-' : value.trim();

    String cleanHtmlText(String raw) {
      var text = raw;
      text = text.replaceAll(
        RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false),
        '\n',
      );
      text = text.replaceAll(
        RegExp(r'<\s*/\s*p\s*>', caseSensitive: false),
        '\n',
      );
      text = text.replaceAll(RegExp(r'<\s*p[^>]*>', caseSensitive: false), '');
      text = text.replaceAll(RegExp(r'<[^>]+>'), '');
      text = text.replaceAll('&nbsp;', ' ');
      text = text.replaceAll('&amp;', '&');
      text = text.replaceAll('&lt;', '<');
      text = text.replaceAll('&gt;', '>');
      text = text.replaceAll('&quot;', '"');
      text = text.replaceAll('&#39;', "'");
      text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
      return text.trim();
    }

    final descriptionText = cleanHtmlText(node.description);

    final sex = node.sex.trim().toLowerCase();
    final isMale = sex == 'male' || sex == 'm' || sex == 'nam';
    final isFemale =
        sex == 'female' || sex == 'f' || sex == 'nu' || sex == 'nữ';
    final genderLabel = isMale
        ? 'Nam'
        : isFemale
        ? 'Nữ'
        : valueOrDash(node.sex);
    final hasDescription = descriptionText.isNotEmpty;
    final family = valueOrDash(node.metadata['FamilyNameGroup'] ?? '');
    final isDeadFlag =
        (node.metadata['IsDead'] ?? '').trim().toLowerCase() == 'true';
    String cleanPersonId(String raw) {
      final t = raw.trim();
      if (t.isEmpty || t.toLowerCase() == 'null') return '';
      return t;
    }

    String resolvePersonName(String rawId) {
      final id = cleanPersonId(rawId);
      if (id.isEmpty) return '-';
      for (final n in _nodes) {
        if (n.id != id) continue;
        final name = n.text.trim();
        if (name.isNotEmpty && name.toLowerCase() != 'null') return name;
      }
      return id;
    }

    final fatherId = cleanPersonId(node.parentId);
    final motherId = cleanPersonId(node.metadata['MotherID'] ?? '');
    String buildParentsDisplay() {
      final fatherName = fatherId.isEmpty ? '' : resolvePersonName(fatherId);
      final motherName = motherId.isEmpty ? '' : resolvePersonName(motherId);
      if (fatherName.isNotEmpty &&
          fatherName != '-' &&
          motherName.isNotEmpty &&
          motherName != '-') {
        return '$fatherName / $motherName';
      }
      if (fatherName.isNotEmpty && fatherName != '-') return fatherName;
      if (motherName.isNotEmpty && motherName != '-') return motherName;
      return '-';
    }

    final parentDisplay = buildParentsDisplay();

    String buildSpouseDisplay() {
      final spouseIds = <String>{};
      for (final e in _edges) {
        if (e.route != _EdgeRoute.spouse) continue;
        if (e.from == node.id && e.to != node.id) {
          spouseIds.add(e.to);
        } else if (e.to == node.id && e.from != node.id) {
          spouseIds.add(e.from);
        }
      }
      if (spouseIds.isEmpty) return '-';

      final names =
          spouseIds
              .map(resolvePersonName)
              .where((name) => name.trim().isNotEmpty && name.trim() != '-')
              .toList()
            ..sort();
      if (names.isEmpty) return '-';
      return names.join(', ');
    }

    final spouseDisplay = buildSpouseDisplay();

    String formatDisplayDate(String raw) {
      final text = raw.trim();
      if (text.isEmpty || text.toLowerCase() == 'null') return '-';

      final parsed = DateTime.tryParse(text);
      if (parsed != null) {
        final d = parsed.day.toString().padLeft(2, '0');
        final m = parsed.month.toString().padLeft(2, '0');
        final y = parsed.year.toString().padLeft(4, '0');
        return '$d/$m/$y';
      }

      final ymd = RegExp(
        r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})',
      ).firstMatch(text);
      if (ymd != null) {
        final y = ymd.group(1)!;
        final m = ymd.group(2)!.padLeft(2, '0');
        final d = ymd.group(3)!.padLeft(2, '0');
        return '$d/$m/$y';
      }

      return text;
    }

    String? extractYear(String raw) {
      final text = raw.trim();
      if (text.isEmpty || text == '-') return null;
      final hit = RegExp(r'(1[0-9]{3}|20[0-9]{2}|2100)').firstMatch(text);
      return hit?.group(0);
    }

    final birthRaw = node.birthday.trim().isNotEmpty
        ? node.birthday
        : (node.metadata['BirthdayTEXT'] ?? '');
    final birthDisplay = formatDisplayDate(birthRaw);
    final birthYear = extractYear(birthRaw);
    final deathRaw = <String>[
      node.metadata['DeadDay'] ?? '',
      node.metadata['DeathDate'] ?? '',
      node.metadata['DiedAt'] ?? '',
      node.metadata['YearOfDeath'] ?? '',
      node.metadata['NamMat'] ?? '',
      node.metadata['PassedAwayDate'] ?? '',
      node.metadata['LunarDeadDay'] ?? '',
    ].firstWhere((v) => v.trim().isNotEmpty, orElse: () => '');
    final deathYear = extractYear(deathRaw);
    final isDead = isDeadFlag || deathYear != null;

    final titleText = valueOrDash(node.text);
    final avatarLabel = titleText == '-' ? '?' : titleText.substring(0, 1);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.95, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.scale(
            scale: t,
            alignment: Alignment.topRight,
            child: child,
          ),
        );
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Card(
          elevation: 10,
          shadowColor: Colors.black.withValues(alpha: 0.22),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [scheme.primaryContainer, scheme.surface],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: scheme.primary.withValues(alpha: 0.16),
                        foregroundColor: scheme.primary,
                        child: Text(
                          avatarLabel.toUpperCase(),
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              titleText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.2,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Chi tiết node',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.textTheme.bodySmall?.color
                                    ?.withValues(alpha: 0.72),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                _buildNodeMetaChip(
                                  context,
                                  icon: isMale
                                      ? Icons.male_rounded
                                      : isFemale
                                      ? Icons.female_rounded
                                      : Icons.person_outline_rounded,
                                  label: genderLabel,
                                ),
                                _buildNodeMetaChip(
                                  context,
                                  icon: Icons.account_tree_outlined,
                                  label:
                                      'Đời ${valueOrDash(node.level?.toString() ?? '')}',
                                ),
                                if (isDead)
                                  _buildNodeMetaChip(
                                    context,
                                    icon: Icons.flag_outlined,
                                    label: 'Đã mất',
                                    danger: true,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Năm sinh: ${birthYear ?? '-'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: theme.textTheme.bodySmall?.color
                                          ?.withValues(alpha: 0.78),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    'Năm mất: ${isDead ? (deathYear ?? '?') : '-'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: isDead
                                          ? Colors.red.shade700
                                          : theme.textTheme.bodySmall?.color
                                                ?.withValues(alpha: 0.62),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Đóng',
                        visualDensity: VisualDensity.compact,
                        splashRadius: 18,
                        onPressed: () => setState(() => _selectedIds.clear()),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  children: [
                    _buildNodeDetailRow(context, label: 'ID', value: node.id),
                    _buildNodeDetailRow(
                      context,
                      label: 'Ngày sinh',
                      value: birthDisplay,
                    ),
                    _buildNodeDetailRow(
                      context,
                      label: 'Cha/Mẹ',
                      value: parentDisplay,
                    ),
                    _buildNodeDetailRow(
                      context,
                      label: 'Vợ/Chồng',
                      value: spouseDisplay,
                    ),
                    _buildNodeDetailRow(
                      context,
                      label: 'Dòng họ',
                      value: family,
                    ),
                    if (hasDescription)
                      _buildNodeDetailRow(
                        context,
                        label: 'Mô tả',
                        value: descriptionText,
                        multiline: true,
                      ),
                    if (!hasDescription)
                      _buildNodeDetailRow(
                        context,
                        label: 'Mô tả',
                        value: '-',
                        muted: true,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNodeMetaChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    bool danger = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = danger
        ? Colors.red.withValues(alpha: 0.12)
        : scheme.primary.withValues(alpha: 0.12);
    final fg = danger ? Colors.red.shade700 : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNodeDetailRow(
    BuildContext context, {
    required String label,
    required String value,
    bool multiline = false,
    bool muted = false,
  }) {
    final theme = Theme.of(context);
    final textColor = muted
        ? theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.58)
        : theme.textTheme.bodyMedium?.color;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: multiline
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.textTheme.bodySmall?.color?.withValues(
                  alpha: 0.72,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.45,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Text(
                  value.trim().isEmpty ? '-' : value.trim(),
                  maxLines: multiline ? 4 : 1,
                  overflow: multiline
                      ? TextOverflow.fade
                      : TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: textColor,
                    height: 1.28,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build the filter panel UI with professional styling and animations
  Widget _buildFilterPanel(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final childrenOfRoot = _filterRootNodeId != null
        ? _getChildrenOfNode(_filterRootNodeId!)
        : <String>[];
    final availableBranches = _availableBranchNumbers();
    final isFiltered = _filteredNodeIds != null;
    final maxGenerations = _calculateMaxGenerationDepth();

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.9, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (context, scale, child) {
        return Opacity(
          opacity: scale,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topLeft,
            child: child,
          ),
        );
      },
      child: Material(
        elevation: 12,
        borderRadius: BorderRadius.circular(16),
        color: scheme.surface,
        shadowColor: Colors.black.withValues(alpha: 0.25),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: SizedBox(
                width: 300,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header with close button
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: scheme.primary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.filter_list,
                                size: 20,
                                color: scheme.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Bộ lọc dòng họ',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: scheme.onSurface,
                                  ),
                                ),
                                Text(
                                  isFiltered ? 'Đang lọc' : 'Chưa áp dụng',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: isFiltered
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        InkWell(
                          onTap: () => setState(() => _showFilterPanel = false),
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              Icons.close,
                              color: scheme.onSurfaceVariant,
                              size: 22,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Divider(
                      color: scheme.outlineVariant.withValues(alpha: 0.2),
                    ),
                    const SizedBox(height: 20),

                    // Root node selector
                    _buildFilterSection(
                      context,
                      icon: Icons.account_tree,
                      label: 'Node gốc',
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: scheme.outline.withValues(alpha: 0.3),
                          ),
                        ),
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _filterRootNodeId,
                          hint: const Padding(
                            padding: EdgeInsets.only(left: 12),
                            child: Text('Chọn một node...'),
                          ),
                          underline: const SizedBox(),
                          items: _nodes.map((node) {
                            final display = node.text.isNotEmpty
                                ? '${node.text} (${node.id})'
                                : node.id;
                            return DropdownMenuItem(
                              value: node.id,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Text(
                                  display,
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                ),
                              ),
                            );
                          }).toList(),
                          onChanged: (value) {
                            setState(() {
                              _filterRootNodeId = value;
                              _filterBranchChildId = null;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Generation depth selector
                    _buildFilterSection(
                      context,
                      icon: Icons.layers,
                      label: 'Số đời (tối đa $maxGenerations từ dữ liệu)',
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: SliderTheme(
                                  data: SliderThemeData(
                                    trackHeight: 5,
                                    thumbShape: RoundSliderThumbShape(
                                      elevation: 4,
                                      enabledThumbRadius: 12,
                                    ),
                                    overlayShape: RoundSliderOverlayShape(
                                      overlayRadius: 20,
                                    ),
                                  ),
                                  child: Slider(
                                    value: _filterGenerationDepth
                                        .toDouble()
                                        .clamp(1, maxGenerations.toDouble()),
                                    min: 1,
                                    max: maxGenerations.toDouble(),
                                    divisions: maxGenerations > 1
                                        ? maxGenerations - 1
                                        : null,
                                    label:
                                        '${_filterGenerationDepth.clamp(1, maxGenerations)}',
                                    onChanged: (value) {
                                      setState(() {
                                        _filterGenerationDepth = value
                                            .toInt()
                                            .clamp(1, maxGenerations);
                                      });
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.primary.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '${_filterGenerationDepth.clamp(1, maxGenerations)}/$maxGenerations',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: scheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: List.generate(
                              maxGenerations,
                              (i) => Expanded(
                                child: Opacity(
                                  opacity:
                                      i <
                                          _filterGenerationDepth.clamp(
                                            1,
                                            maxGenerations,
                                          )
                                      ? 1
                                      : 0.3,
                                  child: Container(
                                    height: 4,
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: scheme.primary,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Branch (child of root) selector
                    if (_filterRootNodeId != null)
                      _buildFilterSection(
                        context,
                        icon: Icons.call_split,
                        label: 'Nhánh (theo node gốc)',
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: scheme.outline.withValues(alpha: 0.3),
                            ),
                          ),
                          child: childrenOfRoot.isEmpty
                              ? Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    'Không có nhánh con',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                )
                              : DropdownButton<String?>(
                                  isExpanded: true,
                                  value: _filterBranchChildId,
                                  hint: const Padding(
                                    padding: EdgeInsets.only(left: 12),
                                    child: Text('Tất cả các nhánh'),
                                  ),
                                  underline: const SizedBox(),
                                  items: [
                                    DropdownMenuItem(
                                      value: null,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          left: 12,
                                        ),
                                        child: Text(
                                          'Tất cả (${childrenOfRoot.length})',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ),
                                    ),
                                    ...childrenOfRoot.map((childId) {
                                      final childNode = _nodes.firstWhere(
                                        (n) => n.id == childId,
                                      );
                                      final display = childNode.text.isNotEmpty
                                          ? childNode.text
                                          : childId;
                                      return DropdownMenuItem(
                                        value: childId,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            left: 12,
                                          ),
                                          child: Text(
                                            display,
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 1,
                                          ),
                                        ),
                                      );
                                    }),
                                  ],
                                  onChanged: (value) {
                                    setState(() {
                                      _filterBranchChildId = value;
                                    });
                                  },
                                ),
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: scheme.errorContainer.withValues(alpha: 0.3),
                          border: Border.all(
                            color: scheme.error.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info, size: 18, color: scheme.error),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Chọn node gốc trước',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 20),

                    // Branch selector by branch number (chi)
                    _buildFilterSection(
                      context,
                      icon: Icons.share_outlined,
                      label: 'Chi số mấy',
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: scheme.outline.withValues(alpha: 0.3),
                          ),
                        ),
                        child: availableBranches.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(
                                  'Dữ liệu chưa có thông tin chi (Branch)',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              )
                            : DropdownButton<int?>(
                                isExpanded: true,
                                value: _filterBranchNumber,
                                hint: const Padding(
                                  padding: EdgeInsets.only(left: 12),
                                  child: Text('Tất cả các chi'),
                                ),
                                underline: const SizedBox(),
                                items: [
                                  DropdownMenuItem(
                                    value: null,
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 12),
                                      child: Text(
                                        'Tất cả (${availableBranches.length} chi)',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                  ),
                                  ...availableBranches.map((branch) {
                                    return DropdownMenuItem(
                                      value: branch,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                          left: 12,
                                        ),
                                        child: Text('Chi $branch'),
                                      ),
                                    );
                                  }),
                                ],
                                onChanged: (value) {
                                  setState(() {
                                    _filterBranchNumber = value;
                                  });
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              gradient: LinearGradient(
                                colors: [
                                  scheme.primary,
                                  scheme.primary.withValues(alpha: 0.85),
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: scheme.primary.withValues(alpha: 0.4),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ElevatedButton.icon(
                              onPressed: _applyFilter,
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                backgroundColor: Colors.transparent,
                                elevation: 0,
                                shadowColor: Colors.transparent,
                              ),
                              icon: Icon(
                                Icons.check_circle_outline,
                                color: Colors.white.withValues(alpha: 0.9),
                              ),
                              label: Text(
                                'Lọc',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.95),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _clearFilter,
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              side: BorderSide(
                                color: scheme.outline.withValues(alpha: 0.5),
                              ),
                            ),
                            icon: const Icon(Icons.restart_alt),
                            label: const Text('Xóa'),
                          ),
                        ),
                      ],
                    ),

                    // Status bar
                    if (isFiltered)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: scheme.primary.withValues(alpha: 0.08),
                            border: Border.all(
                              color: scheme.primary.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.done, size: 18, color: scheme.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Hiển thị ${_filteredNodeIds!.length} nodes của ${_nodes.length}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: scheme.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Build a filter section with icon and label
  Widget _buildFilterSection(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        child,
      ],
    );
  }

  Widget _toolBtn(
    IconData icon,
    bool selected,
    String tip,
    VoidCallback onPressed,
  ) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: tip,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? Colors.blue.withValues(alpha: 0.18)
                  : Colors.grey.shade200,
              border: Border.all(
                color: selected ? Colors.blue : Colors.grey.shade300,
              ),
            ),
            child: Icon(
              icon,
              size: 20,
              color: selected ? Colors.blue : Colors.black87,
            ),
          ),
        ),
      ),
    );
  }

  _NodeModel _nodeById(String id) => _nodes.firstWhere((n) => n.id == id);
  _TextNoteModel _textById(String id) =>
      _textNotes.firstWhere((t) => t.id == id);

  void _createTextNoteAtCenter() {
    final size = MediaQuery.of(context).size;
    final world = _controller.screenToWorld(size.center(Offset.zero));
    _commit(() {
      final id = _nextTextId();
      _textNotes.add(_TextNoteModel(id: id, position: world, text: 'Text'));
      _selectedTextId = id;
      _editingTextId = id;
      _showTextStylePanel = true;
      _selectedIds.clear();
      _selectedEdgeIndex = null;
      _connectFromNodeId = null;
    });
    setState(() {});
  }

  void _toggleTextBold(String id) {
    _commit(() {
      final note = _textById(id);
      note.bold = !note.bold;
    });
    setState(() {});
  }

  void _toggleTextItalic(String id) {
    _commit(() {
      final note = _textById(id);
      note.italic = !note.italic;
    });
    setState(() {});
  }

  void _changeTextSize(String id, double delta) {
    _commit(() {
      final note = _textById(id);
      note.fontSize = (note.fontSize + delta).clamp(10.0, 64.0);
    });
    setState(() {});
  }

  void _cycleTextColor(String id) {
    _commit(() {
      final note = _textById(id);
      final idx = _paletteColors.indexOf(note.color);
      final next = (idx + 1) % _paletteColors.length;
      note.color = _paletteColors[next];
    });
    setState(() {});
  }

  void _setSelectedNodeBorderWidth(double delta) {
    _commit(() {
      for (final id in _selectedIds) {
        final n = _nodeById(id);
        n.borderWidth = (n.borderWidth + delta).clamp(0.0, 8.0);
      }
    });
    setState(() {});
  }

  void _cycleSelectedNodeBorderColor() {
    _commit(() {
      for (final id in _selectedIds) {
        final n = _nodeById(id);
        final idx = _paletteColors.indexOf(n.borderColor);
        final next = (idx + 1) % _paletteColors.length;
        n.borderColor = _paletteColors[next];
      }
    });
    setState(() {});
  }

  void _toggleSelectedNodeShadow() {
    _commit(() {
      for (final id in _selectedIds) {
        final n = _nodeById(id);
        final enable = n.shadowOpacity <= 0;
        n.shadowOpacity = enable ? 0.16 : 0;
        n.shadowBlur = enable ? 10 : 0;
      }
    });
    setState(() {});
  }

  Future<void> _pickSelectedEdgeColor() async {
    final i = _selectedEdgeIndex;
    if (i == null || i < 0 || i >= _edges.length) return;
    final edge = _edges[i];
    final choices = <Color>[
      const Color(0xFF1C1C1E),
      const Color(0xFF8E8E93),
      const Color(0xFF5B8CFF),
      const Color(0xFF30B0C7),
      const Color(0xFF34C759),
      const Color(0xFFFF9500),
      const Color(0xFFFF3B30),
      const Color(0xFFAF52DE),
      const Color(0xFFFFFFFF),
    ];
    Color selected = edge.color;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edge color'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: choices
              .map(
                (c) => GestureDetector(
                  onTap: () {
                    selected = c;
                    Navigator.pop(context, true);
                  },
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: c == edge.color
                            ? Colors.blueAccent
                            : Colors.black26,
                        width: c == edge.color ? 2 : 1,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (ok != true) return;
    _updateSelectedEdge((e) => e.copyWith(color: selected));
  }

  Future<void> _openNodeSettings() async {
    if (_selectedIds.isEmpty) return;
    final ids = _selectedIds.toList();
    final sample = _nodeById(ids.first);
    final single = ids.length == 1;
    final bottomCtl = TextEditingController(
      text: single ? sample.bottomText : '',
    );
    final outsideCtl = TextEditingController(
      text: single ? sample.outsideText : '',
    );
    Uint8List? nextImage = single ? sample.imageBytes : null;
    var fill = sample.color;
    var border = sample.borderColor;
    var borderWidth = sample.borderWidth;
    var shadowOpacity = sample.shadowOpacity;
    var shadowBlur = sample.shadowBlur;
    var blink = sample.blink;
    var textColor = sample.textColor;
    var textSize = sample.textSize;
    var bottomTextColor = sample.bottomTextColor;
    var bottomTextSize = sample.bottomTextSize;
    var outsideTextColor = sample.outsideTextColor;
    var outsideTextSize = sample.outsideTextSize;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocalState) {
          Widget colorDot(Color c, Color selected, ValueChanged<Color> onPick) {
            return GestureDetector(
              onTap: () => onPick(c),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: c == selected ? Colors.blueAccent : Colors.black26,
                    width: c == selected ? 2 : 1,
                  ),
                ),
              ),
            );
          }

          return AlertDialog(
            title: const Text('Node settings'),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Fill color'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _paletteColors
                          .map(
                            (c) => colorDot(
                              c,
                              fill,
                              (v) => setLocalState(() => fill = v),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    const Text('Border color'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _paletteColors
                          .map(
                            (c) => colorDot(
                              c,
                              border,
                              (v) => setLocalState(() => border = v),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    Text('Border width: ${borderWidth.toStringAsFixed(1)}'),
                    Slider(
                      min: 0,
                      max: 10,
                      value: borderWidth,
                      onChanged: (v) => setLocalState(() => borderWidth = v),
                    ),
                    Text('Shadow opacity: ${shadowOpacity.toStringAsFixed(2)}'),
                    Slider(
                      min: 0,
                      max: 0.45,
                      value: shadowOpacity,
                      onChanged: (v) => setLocalState(() => shadowOpacity = v),
                    ),
                    Text('Shadow blur: ${shadowBlur.toStringAsFixed(1)}'),
                    Slider(
                      min: 0,
                      max: 28,
                      value: shadowBlur,
                      onChanged: (v) => setLocalState(() => shadowBlur = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Blink object'),
                      value: blink,
                      onChanged: (v) => setLocalState(() => blink = v),
                    ),
                    const SizedBox(height: 8),
                    const Text('Text trong object'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _paletteColors
                          .map(
                            (c) => colorDot(
                              c,
                              textColor,
                              (v) => setLocalState(() => textColor = v),
                            ),
                          )
                          .toList(),
                    ),
                    Text('Size: ${textSize.toStringAsFixed(0)}'),
                    Slider(
                      min: 10,
                      max: 36,
                      value: textSize,
                      onChanged: (v) => setLocalState(() => textSize = v),
                    ),
                    const SizedBox(height: 8),
                    const Text('Text dưới object'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _paletteColors
                          .map(
                            (c) => colorDot(
                              c,
                              bottomTextColor,
                              (v) => setLocalState(() => bottomTextColor = v),
                            ),
                          )
                          .toList(),
                    ),
                    Text('Size: ${bottomTextSize.toStringAsFixed(0)}'),
                    Slider(
                      min: 9,
                      max: 28,
                      value: bottomTextSize,
                      onChanged: (v) => setLocalState(() => bottomTextSize = v),
                    ),
                    const SizedBox(height: 8),
                    const Text('Text dưới cả khối'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _paletteColors
                          .map(
                            (c) => colorDot(
                              c,
                              outsideTextColor,
                              (v) => setLocalState(() => outsideTextColor = v),
                            ),
                          )
                          .toList(),
                    ),
                    Text('Size: ${outsideTextSize.toStringAsFixed(0)}'),
                    Slider(
                      min: 9,
                      max: 28,
                      value: outsideTextSize,
                      onChanged: (v) =>
                          setLocalState(() => outsideTextSize = v),
                    ),
                    if (single) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: () async {
                              final result = await FilePicker.platform
                                  .pickFiles(
                                    type: FileType.image,
                                    withData: true,
                                    allowMultiple: false,
                                  );
                              final bytes = result?.files.single.bytes;
                              if (bytes == null) return;
                              setLocalState(() => nextImage = bytes);
                            },
                            icon: const Icon(Icons.image_outlined),
                            label: const Text('Ảnh trong object'),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            tooltip: 'Gỡ ảnh',
                            onPressed: () =>
                                setLocalState(() => nextImage = null),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                      Text(
                        nextImage == null ? 'Chưa có ảnh' : 'Đã chọn ảnh',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: bottomCtl,
                        decoration: const InputDecoration(
                          labelText: 'Text dưới object',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: outsideCtl,
                        decoration: const InputDecoration(
                          labelText: 'Text dưới cả khối',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );

    bottomCtl.dispose();
    outsideCtl.dispose();
    if (ok != true) return;

    _commit(() {
      for (final id in ids) {
        final n = _nodeById(id);
        n.color = fill;
        n.borderColor = border;
        n.borderWidth = borderWidth;
        n.shadowOpacity = shadowOpacity;
        n.shadowBlur = shadowBlur;
        n.blink = blink;
        n.textColor = textColor;
        n.textSize = textSize;
        n.bottomTextColor = bottomTextColor;
        n.bottomTextSize = bottomTextSize;
        n.outsideTextColor = outsideTextColor;
        n.outsideTextSize = outsideTextSize;
      }
      if (single) {
        final n = _nodeById(ids.first);
        n.imageBytes = nextImage;
        n.bottomText = bottomCtl.text.trim();
        n.outsideText = outsideCtl.text.trim();
      }
    });
    setState(() {});
  }

  Future<void> _openEdgeSettings() async {
    final i = _selectedEdgeIndex;
    if (i == null || i < 0 || i >= _edges.length) return;
    final edge = _edges[i];
    var route = edge.route;
    var width = edge.width;
    var bend = edge.bend;
    var elbow = edge.elbow;
    var dashed = edge.dashed;
    var arrow = edge.arrow;
    var animated = edge.animated;
    var color = edge.color;
    var labelSize = edge.labelSize;
    var labelColor = edge.labelColor;
    var labelOffset = edge.labelOffset;
    final labelCtl = TextEditingController(text: edge.label);

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocalState) {
          Widget colorDot(Color c) {
            return GestureDetector(
              onTap: () => setLocalState(() => color = c),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: c == color ? Colors.blueAccent : Colors.black26,
                    width: c == color ? 2 : 1,
                  ),
                ),
              ),
            );
          }

          return AlertDialog(
            title: const Text('Edge settings'),
            content: SizedBox(
              width: 380,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Route'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('Bezier'),
                          selected: route == _EdgeRoute.bezier,
                          onSelected: (_) =>
                              setLocalState(() => route = _EdgeRoute.bezier),
                        ),
                        ChoiceChip(
                          label: const Text('Orthogonal'),
                          selected: route == _EdgeRoute.orthogonal,
                          onSelected: (_) => setLocalState(
                            () => route = _EdgeRoute.orthogonal,
                          ),
                        ),
                        ChoiceChip(
                          label: const Text('Straight'),
                          selected: route == _EdgeRoute.straight,
                          onSelected: (_) =>
                              setLocalState(() => route = _EdgeRoute.straight),
                        ),
                        ChoiceChip(
                          label: const Text('Family'),
                          selected: route == _EdgeRoute.familyTree,
                          onSelected: (_) => setLocalState(
                            () => route = _EdgeRoute.familyTree,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text('Line width: ${width.toStringAsFixed(1)}'),
                    Slider(
                      min: 1,
                      max: 8,
                      value: width,
                      onChanged: (v) => setLocalState(() => width = v),
                    ),
                    Text('Bend: ${bend.toStringAsFixed(2)}'),
                    Slider(
                      min: -1,
                      max: 1,
                      value: bend,
                      onChanged: (v) => setLocalState(() => bend = v),
                    ),
                    Text('Inner segment: ${elbow.toStringAsFixed(2)}'),
                    Slider(
                      min: 0.1,
                      max: 0.9,
                      value: elbow,
                      onChanged: (v) => setLocalState(() => elbow = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Arrow'),
                      value: arrow,
                      onChanged: (v) => setLocalState(() => arrow = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Dashed'),
                      value: dashed,
                      onChanged: (v) => setLocalState(() => dashed = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Blink'),
                      value: animated,
                      onChanged: (v) => setLocalState(() => animated = v),
                    ),
                    TextField(
                      controller: labelCtl,
                      decoration: const InputDecoration(
                        labelText: 'Text bám theo đường',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text('Text size: ${labelSize.toStringAsFixed(0)}'),
                    Slider(
                      min: 10,
                      max: 30,
                      value: labelSize,
                      onChanged: (v) => setLocalState(() => labelSize = v),
                    ),
                    Text('Text offset: ${labelOffset.toStringAsFixed(0)}'),
                    Slider(
                      min: -90,
                      max: 90,
                      value: labelOffset,
                      onChanged: (v) => setLocalState(() => labelOffset = v),
                    ),
                    const SizedBox(height: 6),
                    const Text('Text color'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _paletteColors
                          .map(
                            (c) => GestureDetector(
                              onTap: () => setLocalState(() => labelColor = c),
                              child: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: c,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: c == labelColor
                                        ? Colors.blueAccent
                                        : Colors.black26,
                                    width: c == labelColor ? 2 : 1,
                                  ),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 10),
                    const Text('Color'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _paletteColors.map(colorDot).toList(),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );

    if (ok == true) {
      _updateSelectedEdge(
        (e) => e.copyWith(
          route: route,
          width: width,
          bend: bend,
          elbow: elbow,
          dashed: dashed,
          arrow: arrow,
          animated: animated,
          color: color,
          labelSize: labelSize,
          labelColor: labelColor,
          labelOffset: labelOffset,
          label: labelCtl.text.trim(),
        ),
      );
    }
    labelCtl.dispose();
  }

  Future<void> _editSelectedEdgeLabel() async {
    final i = _selectedEdgeIndex;
    if (i == null || i < 0 || i >= _edges.length) return;
    final edge = _edges[i];
    final ctl = TextEditingController(text: edge.label);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edge label'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Nhập text trên đường connect',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _updateSelectedEdge((e) => e.copyWith(label: ctl.text.trim()));
  }

  _Snapshot _captureSnapshot() {
    return _Snapshot(
      nodes: _nodes.map((n) => n.clone()).toList(),
      edges: _edges.map((e) => e.copyWith()).toList(),
      groups: _groups.map((g) => g.clone()).toList(),
      textNotes: _textNotes.map((t) => t.clone()).toList(),
      selectedIds: {..._selectedIds},
      selectedEdgeIndex: _selectedEdgeIndex,
      penStrokes: _penStrokes.map((s) => s.clone()).toList(),
    );
  }

  void _commit(VoidCallback change) {
    _undo.add(_captureSnapshot());
    _redo.clear();
    change();
    _markNodeBoundsDirty();
    _syncEdgeFxTicker();
  }

  void _undoAction() {
    if (_undo.isEmpty) return;
    final current = _captureSnapshot();
    final prev = _undo.removeLast();
    _redo.add(current);
    setState(() => _restore(prev));
  }

  void _redoAction() {
    if (_redo.isEmpty) return;
    final current = _captureSnapshot();
    final next = _redo.removeLast();
    _undo.add(current);
    setState(() => _restore(next));
  }

  void _restore(_Snapshot s) {
    _nodes
      ..clear()
      ..addAll(s.nodes.map((n) => n.clone()));
    _edges
      ..clear()
      ..addAll(s.edges.map((e) => e.copyWith()));
    _groups
      ..clear()
      ..addAll(s.groups.map((g) => g.clone()));
    _textNotes
      ..clear()
      ..addAll(s.textNotes.map((t) => t.clone()));
    _selectedIds = {...s.selectedIds};
    _selectedEdgeIndex = s.selectedEdgeIndex;
    _selectedTextId = null;
    _editingTextId = null;
    _showTextStylePanel = false;
    _penStrokes
      ..clear()
      ..addAll(s.penStrokes.map((p) => p.clone()));
    _activePenPoints = null;
    _eraserGestureActive = false;
    _markNodeBoundsDirty();
    _syncEdgeFxTicker();
  }

  void _onDrawPointerDown(PointerDownEvent event) {
    final screen = event.localPosition;
    if (_tool == _CanvasTool.fill) {
      _applyFillAtScreen(screen);
      return;
    }
    if (_tool == _CanvasTool.eraser) {
      if (!_eraserGestureActive) {
        _undo.add(_captureSnapshot());
        _redo.clear();
        _eraserGestureActive = true;
      }
      _eraseAtScreen(screen);
      return;
    }
    if (_tool == _CanvasTool.pen) {
      final w = _controller.screenToWorld(screen);
      setState(() {
        _activePenPoints = <Offset>[w];
      });
    }
  }

  void _onDrawPointerMove(PointerMoveEvent event) {
    final screen = event.localPosition;
    if (_tool == _CanvasTool.eraser) {
      _eraseAtScreen(screen);
      return;
    }
    if (_tool != _CanvasTool.pen || _activePenPoints == null) return;
    final w = _controller.screenToWorld(screen);
    setState(() {
      _activePenPoints!.add(w);
    });
  }

  void _onDrawPointerUp(PointerUpEvent event) {
    if (_tool == _CanvasTool.eraser) {
      _eraserGestureActive = false;
      return;
    }
    if (_tool != _CanvasTool.pen) return;
    final pts = _activePenPoints;
    _activePenPoints = null;
    if (pts == null || pts.length < 2) {
      setState(() {});
      return;
    }
    final w = _penHighlighter ? _penWidth * 2.6 : _penWidth;
    final c = _penHighlighter ? _penColor.withValues(alpha: 0.42) : _penColor;
    _commit(() {
      _penStrokes.add(
        _PenStroke(
          points: List<Offset>.from(pts),
          color: c,
          width: w,
          highlighter: _penHighlighter,
        ),
      );
    });
    setState(() {});
  }

  void _onDrawPointerCancel(PointerCancelEvent event) {
    if (_tool == _CanvasTool.eraser) {
      _eraserGestureActive = false;
      return;
    }
    if (_tool == _CanvasTool.pen) {
      setState(() => _activePenPoints = null);
    }
  }

  void _applyFillAtScreen(Offset screen) {
    final world = _controller.screenToWorld(screen);
    for (final n in _nodes.reversed) {
      final local = world - n.position;
      final path = _shapePath(n.size, n.shape);
      if (path.contains(local)) {
        _commit(() => n.color = _fillColor);
        setState(() {});
        return;
      }
    }
  }

  void _eraseAtScreen(Offset screen) {
    final world = _controller.screenToWorld(screen);
    final scale = _controller.scale;
    final rWorld = _eraserWidth / (2 * scale);
    setState(() {
      _penStrokes.removeWhere((s) => _strokeIntersectsDisk(s, world, rWorld));
    });
  }

  static bool _strokeIntersectsDisk(_PenStroke s, Offset c, double r) {
    if (s.points.isEmpty) return false;
    if (s.points.length == 1) {
      return (s.points.single - c).distance <= r;
    }
    for (int i = 0; i < s.points.length - 1; i++) {
      if (_distPointToSegment(c, s.points[i], s.points[i + 1]) <= r) {
        return true;
      }
    }
    return false;
  }

  static double _distPointToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final ap = p - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 < 1e-12) return (p - a).distance;
    final t = ((ap.dx * ab.dx + ap.dy * ab.dy) / len2).clamp(0.0, 1.0);
    final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
    return (p - proj).distance;
  }

  Future<void> _importFamilyTreeJson() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (!mounted || picked == null || picked.files.isEmpty) return;

    final file = picked.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      _showSnack('Không đọc được dữ liệu file JSON.');
      return;
    }

    dynamic decoded;
    try {
      final jsonText = utf8.decode(bytes, allowMalformed: true);
      decoded = jsonDecode(jsonText);
    } catch (_) {
      _showSnack('JSON không hợp lệ.');
      return;
    }

    final imported = _parseImportedGraph(decoded);
    if (imported.nodes.isEmpty) {
      _showSnack('Không tìm thấy node hợp lệ trong file JSON.');
      return;
    }

    final totalImages = imported.imageUrls.length;

    _commit(() {
      _nodes
        ..clear()
        ..addAll(imported.nodes);
      _edges
        ..clear()
        ..addAll(imported.edges);
      _groups.clear();
      _textNotes.clear();
      _selectedIds.clear();
      _selectedEdgeIndex = null;
      _selectedTextId = null;
      _editingTextId = null;
      _showTextStylePanel = false;
      _activePortDrag = null;
      _connectFromNodeId = null;
      _syncNodeCounterFromCurrentData();
    });

    setState(() {
      _isImportingImages = totalImages > 0;
      _loadedImageCount = 0;
      _totalImageCount = totalImages;
    });
    _fitToAllNodes();
    _showSnack(
      totalImages > 0
          ? 'Đã import ${imported.nodes.length} nodes, ${imported.edges.length} edges. Đang tải ảnh theo lô...'
          : 'Đã import ${imported.nodes.length} nodes, ${imported.edges.length} edges.',
    );

    _startViewportImageLoading(imported.imageUrls);
    if (imported.nodes.length >= 500) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _runViewportCullingBenchmark(nodeCount: imported.nodes.length);
      });
    }
  }

  void _startViewportImageLoading(Map<String, String> imageUrls) {
    _imageLoaderEpoch++;
    _imageLoaderRunning = false;
    _pendingImageUrlsByNode
      ..clear()
      ..addAll(
        imageUrls.map((k, v) => MapEntry(k.trim(), v.trim()))
          ..removeWhere((k, v) => k.isEmpty || v.isEmpty),
      );
    _queuedImageNodeIds.clear();
    _inFlightImageNodeIds.clear();

    if (!mounted) return;
    setState(() {
      _totalImageCount = _pendingImageUrlsByNode.length;
      _loadedImageCount = 0;
      _isImportingImages = _pendingImageUrlsByNode.isNotEmpty;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshViewportImageQueue();
      _kickViewportImageLoader();
    });
  }

  void _onViewportMaybeChanged() {
    if (_pendingImageUrlsByNode.isEmpty) return;
    _viewportImageDebounce?.cancel();
    _viewportImageDebounce = Timer(const Duration(milliseconds: 80), () {
      if (!mounted) return;
      _refreshViewportImageQueue();
      _kickViewportImageLoader();
    });
  }

  void _refreshViewportImageQueue() {
    if (_pendingImageUrlsByNode.isEmpty) {
      if (mounted && _isImportingImages) {
        setState(() => _isImportingImages = false);
      }
      return;
    }

    final viewport = _worldViewportRect(_canvasSize(), paddingWorld: 180);
    final center = viewport.center;

    final candidates =
        _nodes
            .where((n) {
              if (!_pendingImageUrlsByNode.containsKey(n.id)) return false;
              if (_queuedImageNodeIds.contains(n.id)) return false;
              if (_inFlightImageNodeIds.contains(n.id)) return false;
              final rect = Rect.fromLTWH(
                n.position.dx,
                n.position.dy,
                n.size.width,
                n.size.height,
              );
              return rect.overlaps(viewport);
            })
            .toList(growable: false)
          ..sort((a, b) {
            final da =
                (a.position +
                        Offset(a.size.width / 2, a.size.height / 2) -
                        center)
                    .distanceSquared;
            final db =
                (b.position +
                        Offset(b.size.width / 2, b.size.height / 2) -
                        center)
                    .distanceSquared;
            return da.compareTo(db);
          });

    for (final node in candidates.take(50)) {
      _queuedImageNodeIds.add(node.id);
    }

    if (_queuedImageNodeIds.isNotEmpty && mounted && !_isImportingImages) {
      setState(() => _isImportingImages = true);
    }
  }

  List<String> _dequeueImageBatch({required int maxCount}) {
    final batch = <String>[];
    for (final id in _queuedImageNodeIds.toList(growable: false)) {
      if (batch.length >= maxCount) break;
      if (_inFlightImageNodeIds.contains(id)) continue;
      _queuedImageNodeIds.remove(id);
      _inFlightImageNodeIds.add(id);
      batch.add(id);
    }
    return batch;
  }

  Future<(String, Uint8List?)> _loadImageForNode(String nodeId) async {
    final raw = _pendingImageUrlsByNode[nodeId];
    if (raw == null || raw.isEmpty) return (nodeId, null);

    final inline = _tryDecodeDataImageUrl(raw);
    if (inline != null && inline.isNotEmpty) return (nodeId, inline);

    for (final requestUrl in _resolveWebImageUrls(raw)) {
      final cached = _imageBytesByUrlCache[requestUrl];
      if (cached != null && cached.isNotEmpty) return (nodeId, cached);

      try {
        final bytes = await _downloadImageBytes(requestUrl);
        if (bytes != null && bytes.isNotEmpty) {
          _imageBytesByUrlCache[requestUrl] = bytes;
          return (nodeId, bytes);
        }
      } catch (_) {
        // Ignore per-url download errors and try fallbacks.
      }
    }

    return (nodeId, null);
  }

  void _kickViewportImageLoader() {
    if (_imageLoaderRunning || _pendingImageUrlsByNode.isEmpty) return;
    _imageLoaderRunning = true;
    final epoch = _imageLoaderEpoch;

    unawaited(() async {
      try {
        while (mounted && epoch == _imageLoaderEpoch) {
          if (_pendingImageUrlsByNode.isEmpty) break;

          final batchIds = _dequeueImageBatch(maxCount: 8);
          if (batchIds.isEmpty) {
            if (_inFlightImageNodeIds.isEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 16));
            continue;
          }

          final results = await Future.wait(batchIds.map(_loadImageForNode));

          if (!mounted || epoch != _imageLoaderEpoch) return;

          setState(() {
            final nodeById = {for (final n in _nodes) n.id: n};
            for (final result in results) {
              final nodeId = result.$1;
              final bytes = result.$2;
              final node = nodeById[nodeId];
              if (node != null && bytes != null) {
                node.imageBytes = bytes;
              }
              if (_pendingImageUrlsByNode.remove(nodeId) != null) {
                _loadedImageCount = math.min(
                  _totalImageCount,
                  _loadedImageCount + 1,
                );
              }
              _inFlightImageNodeIds.remove(nodeId);
            }
            _isImportingImages =
                _pendingImageUrlsByNode.isNotEmpty &&
                (_queuedImageNodeIds.isNotEmpty ||
                    _inFlightImageNodeIds.isNotEmpty);
          });

          _refreshViewportImageQueue();
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      } finally {
        _imageLoaderRunning = false;
        if (mounted &&
            epoch == _imageLoaderEpoch &&
            _pendingImageUrlsByNode.isEmpty) {
          setState(() => _isImportingImages = false);
          _showSnack('Đã tải ảnh: $_loadedImageCount/$_totalImageCount');
        }
      }
    }());
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _exportDecorativeFamilyTreeImage() async {
    if (_isExportingPdf) return;
    if (mounted) {
      setState(() => _isExportingPdf = true);
    }
    try {
      if (_nodes.isEmpty) {
        _showSnack('Chưa có dữ liệu để export.');
        return;
      }

      final nodeById = <String, _NodeModel>{for (final n in _nodes) n.id: n};
      final familyEdges = _edges
          .where(
            (e) =>
                e.route == _EdgeRoute.familyTree &&
                nodeById.containsKey(e.from) &&
                nodeById.containsKey(e.to),
          )
          .toList(growable: false);
      final spouseEdges = _edges
          .where(
            (e) =>
                e.route == _EdgeRoute.spouse &&
                nodeById.containsKey(e.from) &&
                nodeById.containsKey(e.to),
          )
          .toList(growable: false);

      final childrenByParent = <String, List<String>>{};
      final parentsByChild = <String, List<String>>{};
      final incoming = <String, int>{for (final n in _nodes) n.id: 0};
      for (final e in familyEdges) {
        childrenByParent.putIfAbsent(e.from, () => <String>[]).add(e.to);
        parentsByChild.putIfAbsent(e.to, () => <String>[]).add(e.from);
        incoming[e.to] = (incoming[e.to] ?? 0) + 1;
        incoming.putIfAbsent(e.from, () => 0);
      }

      final depthById = <String, int>{};
      final roots =
          _nodes
              .where((n) => (incoming[n.id] ?? 0) == 0)
              .map((n) => n.id)
              .toList(growable: false)
            ..sort();
      final queue = List<String>.from(roots);
      for (final id in roots) {
        final levelHint = nodeById[id]?.level;
        depthById[id] = levelHint == null ? 0 : math.max(0, levelHint - 1);
      }
      var qi = 0;
      while (qi < queue.length) {
        final parentId = queue[qi++];
        final parentDepth = depthById[parentId] ?? 0;
        for (final childId in childrenByParent[parentId] ?? const <String>[]) {
          final hinted = nodeById[childId]?.level;
          final next = math.max(
            parentDepth + 1,
            hinted == null ? 0 : math.max(0, hinted - 1),
          );
          final prev = depthById[childId];
          if (prev == null || next > prev) {
            depthById[childId] = next;
            queue.add(childId);
          }
        }
      }

      final maxResolvedDepth = depthById.values.isEmpty
          ? 0
          : depthById.values.reduce(math.max);
      for (final n in _nodes) {
        depthById.putIfAbsent(n.id, () {
          final hinted = n.level;
          if (hinted != null) return math.max(0, hinted - 1);
          // Keep disconnected/unknown nodes in a reasonable band instead of
          // creating one new depth per node (which produces extremely tall exports).
          return maxResolvedDepth;
        });
      }

      final idsByDepth = <int, List<String>>{};
      for (final id in depthById.keys) {
        idsByDepth.putIfAbsent(depthById[id]!, () => <String>[]).add(id);
      }

      final orderedDepths = idsByDepth.keys.toList()..sort();
      final layoutByDepth = <int, List<String>>{};
      final orderIndexByDepth = <int, Map<String, int>>{};
      for (final d in orderedDepths) {
        final ids = idsByDepth[d]!.toList();
        if (d == 0) {
          ids.sort((a, b) {
            final ax = nodeById[a]!.position.dx;
            final bx = nodeById[b]!.position.dx;
            if ((ax - bx).abs() > 0.01) return ax.compareTo(bx);
            return nodeById[a]!.text.compareTo(nodeById[b]!.text);
          });
        } else {
          final prevOrder = orderIndexByDepth[d - 1] ?? const <String, int>{};
          ids.sort((a, b) {
            double anchor(String id) {
              final parents = parentsByChild[id] ?? const <String>[];
              final relevant = parents
                  .where((p) => depthById[p] == d - 1)
                  .map((p) => prevOrder[p]?.toDouble())
                  .whereType<double>()
                  .toList(growable: false);
              if (relevant.isEmpty) return 1e6 + nodeById[id]!.position.dx;
              return relevant.reduce((x, y) => x + y) / relevant.length;
            }

            final aa = anchor(a);
            final bb = anchor(b);
            if ((aa - bb).abs() > 0.0001) return aa.compareTo(bb);
            final ax = nodeById[a]!.position.dx;
            final bx = nodeById[b]!.position.dx;
            if ((ax - bx).abs() > 0.01) return ax.compareTo(bx);
            return nodeById[a]!.text.compareTo(nodeById[b]!.text);
          });
        }
        layoutByDepth[d] = ids;
        orderIndexByDepth[d] = {for (var i = 0; i < ids.length; i++) ids[i]: i};
      }

      const marginX = 90.0;
      const headerHeight = 180.0;
      var levelGapY = 88.0;
      var intraRowGapY = 24.0;

      final nodeCount = _nodes.length;
      // Wider layout for large trees → more nodes per row, shorter total height,
      // less "narrow column + empty sides" after scaling.
      final layoutCanvasWidth = math.min(
        16000.0,
        math.max(4800.0, 3200.0 + math.sqrt(nodeCount + 1) * 200.0),
      );
      // Slightly compact vertical rhythm when there are many nodes.
      if (nodeCount > 400) {
        levelGapY *= 0.72;
        intraRowGapY *= 0.72;
      }
      if (nodeCount > 900) {
        levelGapY *= 0.88;
        intraRowGapY *= 0.88;
      }

      int generationForNodeId(String id, int depth) {
        final hinted = nodeById[id]?.level;
        if (hinted != null && hinted > 0) return hinted;
        return depth + 1;
      }

      Size baseNodeSizeForDepth(int depth) {
        final sampleIds = layoutByDepth[depth] ?? const <String>[];
        final generation = sampleIds.isEmpty
            ? depth + 1
            : generationForNodeId(sampleIds.first, depth);
        if (generation <= 6) return const Size(170, 170); // square (larger)
        // Vertical child cards: about half width of square cards.
        return const Size(88, 196);
      }

      double baseGapXForDepth(int depth) {
        final sampleIds = layoutByDepth[depth] ?? const <String>[];
        final generation = sampleIds.isEmpty
            ? depth + 1
            : generationForNodeId(sampleIds.first, depth);
        if (generation <= 6) return 22;
        return 14;
      }

      Size nodeSizeForDepth(int depth) => baseNodeSizeForDepth(depth);
      double gapXForDepth(int depth) => baseGapXForDepth(depth);

      // Layout in a wide "virtual" width first; final export canvas size is set
      // after we know content bounds (tall trees need tall images).
      final canvasWidth = layoutCanvasWidth;
      var layoutTopY = math.max(headerHeight, canvasWidth * 0.14);

      final rawPlacedRectById = <String, Rect>{};
      var currentY = layoutTopY;
      for (final d in orderedDepths) {
        final ids = layoutByDepth[d]!;
        final size = nodeSizeForDepth(d);
        final gapX = gapXForDepth(d);
        final usableWidth = canvasWidth - marginX * 2;
        final maxPerRow = math.max(
          1,
          ((usableWidth + gapX) / (size.width + gapX)).floor(),
        );
        final chunkCount = math.max(1, (ids.length / maxPerRow).ceil());
        for (var chunk = 0; chunk < chunkCount; chunk++) {
          final start = chunk * maxPerRow;
          final end = math.min(ids.length, start + maxPerRow);
          final rowIds = ids.sublist(start, end);
          final rowWidth =
              rowIds.length * size.width +
              math.max(0, rowIds.length - 1) * gapX;
          var x = (canvasWidth - rowWidth) * 0.5;
          for (final id in rowIds) {
            rawPlacedRectById[id] = Rect.fromLTWH(
              x,
              currentY,
              size.width,
              size.height,
            );
            x += size.width + gapX;
          }
          currentY += size.height;
          if (chunk != chunkCount - 1) currentY += intraRowGapY;
        }
        currentY += levelGapY;
      }

      const minCanvasHeight = 3000.0;
      const bottomLayoutPad = 420.0;
      var canvasHeight = minCanvasHeight;
      if (rawPlacedRectById.isNotEmpty) {
        Rect b = rawPlacedRectById.values.first;
        for (final rect in rawPlacedRectById.values.skip(1)) {
          b = b.expandToInclude(rect);
        }
        canvasHeight = math.max(minCanvasHeight, b.bottom + bottomLayoutPad);
      }

      final placedRectById = <String, Rect>{};
      var layoutScale = 1.0;
      if (rawPlacedRectById.isNotEmpty) {
        Rect contentBounds = rawPlacedRectById.values.first;
        for (final rect in rawPlacedRectById.values.skip(1)) {
          contentBounds = contentBounds.expandToInclude(rect);
        }

        // Safe "content plate" inside decorative background — extra top inset so
        // the tree does not overlap the upper scroll / dragons (like reference).
        final safeRect = Rect.fromLTWH(
          canvasWidth * 0.12,
          canvasHeight * 0.28,
          canvasWidth * 0.76,
          canvasHeight * 0.62,
        );
        final sx = safeRect.width / math.max(1.0, contentBounds.width);
        final sy = safeRect.height / math.max(1.0, contentBounds.height);
        // Prefer not to shrink below ~0.28 so ~1000 nodes stay readable; very
        // large trees may still need a bit smaller — cap floor at 0.18.
        layoutScale = math.min(1.0, math.min(sx, sy)).clamp(0.18, 1.0);

        final scaledW = contentBounds.width * layoutScale;
        final scaledH = contentBounds.height * layoutScale;
        final targetTopLeft = Offset(
          safeRect.left + (safeRect.width - scaledW) / 2,
          safeRect.top + (safeRect.height - scaledH) / 2,
        );
        for (final entry in rawPlacedRectById.entries) {
          final r = entry.value;
          final left =
              (r.left - contentBounds.left) * layoutScale + targetTopLeft.dx;
          final top =
              (r.top - contentBounds.top) * layoutScale + targetTopLeft.dy;
          placedRectById[entry.key] = Rect.fromLTWH(
            left,
            top,
            r.width * layoutScale,
            r.height * layoutScale,
          );
        }
      }

      final exportPortraitById = <String, ui.Image>{};
      final exportPortraitBytesById = <String, Uint8List>{};
      String exportImageUrlForNode(_NodeModel node) {
        final md = node.metadata;
        return (md['ImageUrl'] ??
                md['imageUrl'] ??
                md['Avatar'] ??
                md['avatar'] ??
                md['PhotoUrl'] ??
                md['photoUrl'] ??
                '')
            .trim();
      }

      for (final node in _nodes) {
        Uint8List? bytes = node.imageBytes;
        if (bytes == null || bytes.isEmpty) {
          final rawUrl = exportImageUrlForNode(node);
          final inline = _tryDecodeDataImageUrl(rawUrl);
          if (inline != null && inline.isNotEmpty) {
            bytes = inline;
          }
        }
        if ((bytes == null || bytes.isEmpty)) {
          final rawUrl = exportImageUrlForNode(node);
          if (rawUrl.isNotEmpty && _canLoadRemoteImageOnWeb(rawUrl)) {
            for (final requestUrl in _resolveWebImageUrls(rawUrl)) {
              final cached = _imageBytesByUrlCache[requestUrl];
              if (cached != null && cached.isNotEmpty) {
                bytes = cached;
                break;
              }
              try {
                final fetched = await _downloadImageBytes(requestUrl);
                if (fetched != null && fetched.isNotEmpty) {
                  bytes = fetched;
                  _imageBytesByUrlCache[requestUrl] = bytes;
                  break;
                }
              } catch (_) {
                bytes = null;
              }
            }
          }
        }
        if (bytes == null || bytes.isEmpty) continue;
        if (node.imageBytes == null || node.imageBytes!.isEmpty) {
          node.imageBytes = bytes;
        }
        exportPortraitBytesById[node.id] = bytes;
        final img = await _decodeUiImageBytes(bytes);
        if (img != null) exportPortraitById[node.id] = img;
      }

      final svgText = await _buildFamilyTreeSvgExport(
        canvasWidth: canvasWidth,
        canvasHeight: canvasHeight,
        layoutScale: layoutScale,
        orderedDepths: orderedDepths,
        layoutByDepth: layoutByDepth,
        placedRectById: placedRectById,
        nodeById: nodeById,
        familyEdges: familyEdges,
        spouseEdges: spouseEdges,
        exportPortraitBytesById: exportPortraitBytesById,
      );
      final svgBytes = Uint8List.fromList(utf8.encode(svgText));

      final stamp = DateTime.now();
      final svgName =
          'gia_pha_${stamp.year.toString().padLeft(4, '0')}${stamp.month.toString().padLeft(2, '0')}${stamp.day.toString().padLeft(2, '0')}_${stamp.hour.toString().padLeft(2, '0')}${stamp.minute.toString().padLeft(2, '0')}.svg';
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Lưu SVG phả hệ',
        fileName: svgName,
        type: FileType.custom,
        allowedExtensions: const ['svg'],
        bytes: svgBytes,
        lockParentWindow: true,
      );
      if (savedPath == null) {
        _showSnack('Đã hủy lưu SVG.');
        return;
      }
      _showSnack(
        'Đã export SVG phả hệ. Node: ${placedRectById.length}/${_nodes.length} | Ảnh: ${exportPortraitById.length}/${_nodes.length}',
      );
      return;
    } finally {
      if (mounted) {
        setState(() => _isExportingPdf = false);
      } else {
        _isExportingPdf = false;
      }
    }
  }

  Future<String> _buildFamilyTreeSvgExport({
    required double canvasWidth,
    required double canvasHeight,
    required double layoutScale,
    required List<int> orderedDepths,
    required Map<int, List<String>> layoutByDepth,
    required Map<String, Rect> placedRectById,
    required Map<String, _NodeModel> nodeById,
    required List<_EdgeModel> familyEdges,
    required List<_EdgeModel> spouseEdges,
    required Map<String, Uint8List> exportPortraitBytesById,
  }) async {
    final backgroundBytes = await _loadExportBackgroundBytes();
    String esc(String s) => _xmlEscape(s);
    String hex(Color c) => _colorToHex(c);

    final rootDepth = orderedDepths.isEmpty ? 0 : orderedDepths.first;
    final rootIds = layoutByDepth[rootDepth] ?? const <String>[];
    final rootNode = rootIds.isEmpty ? null : nodeById[rootIds.first];
    final familyName = (rootNode?.metadata['FamilyNameGroup'] ?? '').trim();
    final rootName = (rootNode?.text ?? '').trim();
    final clanLabel = familyName.isNotEmpty
        ? 'Dòng Họ $familyName'
        : (rootName.isNotEmpty ? 'Dòng Họ $rootName' : 'Dòng Họ');
    final totalGenerationCount = orderedDepths.isEmpty
        ? 0
        : (orderedDepths.last - orderedDepths.first + 1);
    final bgScale = math.min(canvasWidth / 4200.0, canvasHeight / 2800.0);

    final sb = StringBuffer();
    sb.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 ${canvasWidth.toStringAsFixed(0)} ${canvasHeight.toStringAsFixed(0)}" preserveAspectRatio="xMidYMid meet">',
    );
    if (backgroundBytes != null && backgroundBytes.isNotEmpty) {
      sb.writeln(
        '<image href="data:image/png;base64,${base64Encode(backgroundBytes)}" x="0" y="0" width="${canvasWidth.toStringAsFixed(2)}" height="${canvasHeight.toStringAsFixed(2)}" preserveAspectRatio="none"/>',
      );
    } else {
      sb.writeln(
        '<rect x="0" y="0" width="${canvasWidth.toStringAsFixed(2)}" height="${canvasHeight.toStringAsFixed(2)}" fill="#FDF3EA"/>',
      );
    }

    sb.writeln(
      '<text x="${(canvasWidth * 0.5).toStringAsFixed(2)}" y="${(canvasHeight * 0.25).toStringAsFixed(2)}" text-anchor="middle" fill="#9A1E12" font-size="${(92 * bgScale).clamp(42, 128).toStringAsFixed(2)}" font-weight="900">${esc(clanLabel)}</text>',
    );
    sb.writeln(
      '<text x="${(canvasWidth * 0.075).toStringAsFixed(2)}" y="${(canvasHeight * 0.18).toStringAsFixed(2)}" text-anchor="start" fill="#7B1D14" font-size="${(40 * bgScale).clamp(20, 58).toStringAsFixed(2)}" font-weight="800">${esc('Tổng số đời: $totalGenerationCount')}</text>',
    );

    // Roman generation markers aligned in one fixed column.
    // Keep generation markers in a clean fixed column left of the red banner.
    final markerX = canvasWidth * 0.045;
    for (final d in orderedDepths) {
      final ids = layoutByDepth[d] ?? const <String>[];
      if (ids.isEmpty) continue;
      double minTop = double.infinity;
      double maxBottom = -double.infinity;
      for (final id in ids) {
        final r = placedRectById[id];
        if (r == null) continue;
        if (r.top < minTop) minTop = r.top;
        if (r.bottom > maxBottom) maxBottom = r.bottom;
      }
      if (!minTop.isFinite || !maxBottom.isFinite) continue;
      final y = (minTop + maxBottom) / 2;
      final roman = _toRoman(d + 1);
      sb.writeln(
        '<text x="${markerX.toStringAsFixed(2)}" y="${(y + 8).toStringAsFixed(2)}" text-anchor="middle" fill="#8A2B1A" stroke="#FFF4DD" stroke-width="${(2.4 * bgScale).clamp(1.0, 3.0).toStringAsFixed(2)}" paint-order="stroke" font-size="${(64 * bgScale).clamp(26, 84).toStringAsFixed(2)}" font-weight="900">${esc(roman)}</text>',
      );
    }

    for (final edge in familyEdges) {
      final parentRect = placedRectById[edge.from];
      final childRect = placedRectById[edge.to];
      if (parentRect == null || childRect == null) continue;
      final start = parentRect.bottomCenter;
      final end = childRect.topCenter;
      final yDelta = end.dy - start.dy;
      final trunkY = yDelta >= 0
          ? start.dy + math.max(16.0 * layoutScale, yDelta * 0.38)
          : start.dy + (yDelta * 0.5);
      sb.writeln(
        '<polyline points="${start.dx.toStringAsFixed(2)},${start.dy.toStringAsFixed(2)} ${start.dx.toStringAsFixed(2)},${trunkY.toStringAsFixed(2)} ${end.dx.toStringAsFixed(2)},${trunkY.toStringAsFixed(2)} ${end.dx.toStringAsFixed(2)},${end.dy.toStringAsFixed(2)}" fill="none" stroke="#8A2B1A" stroke-width="${(2.6 * layoutScale).clamp(1.1, 2.6).toStringAsFixed(2)}" stroke-linecap="round"/>',
      );
    }

    final spouseSeen = <String>{};
    for (final edge in spouseEdges) {
      final a = edge.from;
      final b = edge.to;
      final key = a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
      if (!spouseSeen.add(key)) continue;
      final rectA = placedRectById[a];
      final rectB = placedRectById[b];
      if (rectA == null || rectB == null) continue;
      final p0 = rectA.bottomCenter;
      final p1 = rectB.bottomCenter;
      final bendY = math.max(p0.dy, p1.dy) + 20 * layoutScale;
      sb.writeln(
        '<polyline points="${p0.dx.toStringAsFixed(2)},${p0.dy.toStringAsFixed(2)} ${p0.dx.toStringAsFixed(2)},${bendY.toStringAsFixed(2)} ${p1.dx.toStringAsFixed(2)},${bendY.toStringAsFixed(2)} ${p1.dx.toStringAsFixed(2)},${p1.dy.toStringAsFixed(2)}" fill="none" stroke="#B15A2D" stroke-width="${(2.2 * layoutScale).clamp(1.0, 2.2).toStringAsFixed(2)}" stroke-linecap="round"/>',
      );
    }

    for (final d in orderedDepths) {
      for (final id in layoutByDepth[d] ?? const <String>[]) {
        final node = nodeById[id];
        final rect = placedRectById[id];
        if (node == null || rect == null) continue;
        final generation = node.level ?? (d + 1);
        final isSquare = generation <= 6;
        final isTop = generation == 1;
        final fill = isTop ? const Color(0xFFFFF4E4) : const Color(0xFFFFFBF3);
        final border = isTop
            ? const Color(0xFFB2772D)
            : const Color(0xFF9D6A2D);
        final radius = (isSquare ? 14.0 : 10.0) * layoutScale;
        sb.writeln(
          '<rect x="${rect.left.toStringAsFixed(2)}" y="${rect.top.toStringAsFixed(2)}" width="${rect.width.toStringAsFixed(2)}" height="${rect.height.toStringAsFixed(2)}" rx="${radius.toStringAsFixed(2)}" ry="${radius.toStringAsFixed(2)}" fill="${hex(fill)}" stroke="${hex(border)}" stroke-width="${(2.4 * layoutScale).clamp(1.0, 2.4).toStringAsFixed(2)}"/>',
        );
        sb.writeln(
          '<circle cx="${rect.topCenter.dx.toStringAsFixed(2)}" cy="${rect.topCenter.dy.toStringAsFixed(2)}" r="${(4.6 * layoutScale).clamp(2.2, 4.6).toStringAsFixed(2)}" fill="#8A2B1A"/>',
        );
        sb.writeln(
          '<circle cx="${rect.bottomCenter.dx.toStringAsFixed(2)}" cy="${rect.bottomCenter.dy.toStringAsFixed(2)}" r="${(4.6 * layoutScale).clamp(2.2, 4.6).toStringAsFixed(2)}" fill="#8A2B1A"/>',
        );

        final bytes = exportPortraitBytesById[id];
        double nameTop = rect.top + 10 * layoutScale;
        if (bytes != null && bytes.isNotEmpty) {
          final portraitSize = math.min(
            rect.width * (isSquare ? 0.42 : 0.78),
            rect.height * (isSquare ? 0.30 : 0.34),
          );
          final px = rect.left + (rect.width - portraitSize) / 2;
          final py =
              nameTop +
              (isSquare ? 46.0 : 48.0) * layoutScale +
              6 * layoutScale;
          final clipId = 'clip_${id.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_')}';
          sb.writeln(
            '<defs><clipPath id="$clipId"><rect x="${px.toStringAsFixed(2)}" y="${py.toStringAsFixed(2)}" width="${portraitSize.toStringAsFixed(2)}" height="${portraitSize.toStringAsFixed(2)}" rx="${(8 * layoutScale).toStringAsFixed(2)}" ry="${(8 * layoutScale).toStringAsFixed(2)}"/></clipPath></defs>',
          );
          sb.writeln(
            '<image href="data:image/png;base64,${base64Encode(bytes)}" x="${px.toStringAsFixed(2)}" y="${py.toStringAsFixed(2)}" width="${portraitSize.toStringAsFixed(2)}" height="${portraitSize.toStringAsFixed(2)}" preserveAspectRatio="xMidYMid slice" clip-path="url(#$clipId)"/>',
          );
          sb.writeln(
            '<rect x="${px.toStringAsFixed(2)}" y="${py.toStringAsFixed(2)}" width="${portraitSize.toStringAsFixed(2)}" height="${portraitSize.toStringAsFixed(2)}" rx="${(8 * layoutScale).toStringAsFixed(2)}" ry="${(8 * layoutScale).toStringAsFixed(2)}" fill="none" stroke="#9D6A2D" stroke-width="${(1.1 * layoutScale).clamp(0.6, 1.1).toStringAsFixed(2)}"/>',
          );
        }

        final name = (node.text.trim().isEmpty ? node.id : node.text.trim());
        final nameFont = (isTop ? 18 : (isSquare ? 14 : 11.5)) * layoutScale;
        sb.writeln(
          '<text x="${(rect.left + rect.width / 2).toStringAsFixed(2)}" y="${(nameTop + nameFont).toStringAsFixed(2)}" text-anchor="middle" fill="#4C2517" font-size="${nameFont.toStringAsFixed(2)}" font-weight="700">${esc(name)}</text>',
        );

        final yearInfo = _buildExportNodeYearInfo(node);
        if (yearInfo.isNotEmpty) {
          final yearLines = yearInfo.split('\n');
          var yy = nameTop + (isSquare ? 70 : 78) * layoutScale;
          for (final line in yearLines) {
            sb.writeln(
              '<text x="${(rect.left + rect.width / 2).toStringAsFixed(2)}" y="${yy.toStringAsFixed(2)}" text-anchor="middle" fill="#6A3A22" font-size="${((isSquare ? 10.5 : 9.5) * layoutScale).toStringAsFixed(2)}" font-weight="600">${esc(line)}</text>',
            );
            yy += (12 * layoutScale);
          }
        }
      }
    }

    sb.writeln('</svg>');
    return sb.toString();
  }

  Future<Uint8List?> _loadExportBackgroundBytes() async {
    for (final path in _kExportBackgroundAssetPaths) {
      try {
        final data = await rootBundle.load(path);
        final bytes = data.buffer.asUint8List();
        if (bytes.isNotEmpty) return bytes;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  String _colorToHex(Color c) {
    final r = c.red.toRadixString(16).padLeft(2, '0');
    final g = c.green.toRadixString(16).padLeft(2, '0');
    final b = c.blue.toRadixString(16).padLeft(2, '0');
    return '#$r$g$b';
  }

  String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  String _toRoman(int n) {
    if (n <= 0) return '';
    final map = <int, String>{
      1000: 'M',
      900: 'CM',
      500: 'D',
      400: 'CD',
      100: 'C',
      90: 'XC',
      50: 'L',
      40: 'XL',
      10: 'X',
      9: 'IX',
      5: 'V',
      4: 'IV',
      1: 'I',
    };
    var x = n;
    final out = StringBuffer();
    for (final e in map.entries) {
      while (x >= e.key) {
        out.write(e.value);
        x -= e.key;
      }
    }
    return out.toString();
  }

  Future<ui.Image?> _decodeUiImageBytes(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  String _buildExportNodeYearInfo(_NodeModel node) {
    String extractYear(String raw) {
      final text = raw.trim();
      if (text.isEmpty) return '';
      final match = RegExp(r'(1[5-9]|20)\d{2}').firstMatch(text);
      return match?.group(0) ?? '';
    }

    final birthRaw = node.birthday.trim().isNotEmpty
        ? node.birthday
        : (node.metadata['BirthdayTEXT'] ?? '');
    final deathRaw = <String>[
      node.metadata['DeadDay'] ?? '',
      node.metadata['DeathDate'] ?? '',
      node.metadata['DiedAt'] ?? '',
      node.metadata['YearOfDeath'] ?? '',
      node.metadata['NamMat'] ?? '',
      node.metadata['PassedAwayDate'] ?? '',
      node.metadata['LunarDeadDay'] ?? '',
    ].join(' ');

    final birthYear = extractYear(birthRaw);
    final deathYear = extractYear(deathRaw);
    if (birthYear.isNotEmpty && deathYear.isNotEmpty) {
      return 'Sinh: $birthYear\nMất: $deathYear';
    }
    if (birthYear.isNotEmpty) return 'Sinh: $birthYear';
    if (deathYear.isNotEmpty) return 'Mất: $deathYear';
    return '';
  }

  void _fitToAllNodes() {
    if (_nodes.isEmpty) return;
    final size = MediaQuery.of(context).size;
    final pts = _nodes
        .map((n) => n.position + Offset(n.size.width / 2, n.size.height / 2))
        .toList();
    _controller.fitToPositions(pts, size, padding: 64);
  }

  void _syncNodeCounterFromCurrentData() {
    var maxN = 0;
    for (final n in _nodes) {
      final m = RegExp(r'^n(\\d+)$').firstMatch(n.id);
      if (m == null) continue;
      final value = int.tryParse(m.group(1) ?? '0') ?? 0;
      if (value > maxN) maxN = value;
    }
    _nodeCounter = math.max(_nodes.length + 1, maxN + 1);
  }

  _ImportedCanvasGraph _parseImportedGraph(dynamic jsonRoot) {
    final asMap = jsonRoot is Map ? Map<String, dynamic>.from(jsonRoot) : null;
    final explicitNodes = _firstList(asMap, const [
      'nodes',
      'vertexes',
      'vertices',
    ]);
    final explicitEdges = _firstList(asMap, const [
      'edges',
      'links',
      'connections',
    ]);
    if (explicitNodes.isNotEmpty) {
      return _parseExplicitGraph(explicitNodes, explicitEdges);
    }

    final people = _extractPeopleList(jsonRoot);
    return _parsePeopleGraph(people);
  }

  List<dynamic> _extractPeopleList(dynamic jsonRoot) {
    if (jsonRoot is List) return jsonRoot;
    if (jsonRoot is! Map) return const <dynamic>[];
    final map = Map<String, dynamic>.from(jsonRoot);
    final list = _firstList(map, const [
      'people',
      'members',
      'persons',
      'items',
      'data',
    ]);
    if (list.isNotEmpty) return list;

    final inner = map['data'];
    if (inner is Map) {
      final nested = _firstList(Map<String, dynamic>.from(inner), const [
        'people',
        'members',
        'persons',
        'items',
        'nodes',
      ]);
      if (nested.isNotEmpty) return nested;
    }
    return const <dynamic>[];
  }

  _ImportedCanvasGraph _parseExplicitGraph(
    List<dynamic> nodeList,
    List<dynamic> edgeList,
  ) {
    final nodes = <_NodeModel>[];
    final nodeIds = <String>{};
    final usedIds = <String>{};
    final missingPosIds = <String>{};
    final positions = <String, Offset>{};

    for (int i = 0; i < nodeList.length; i++) {
      final raw = nodeList[i];
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final id = _uniqueId(
        _readString(item, const ['id', 'key', 'uid', 'personId']) ??
            'n${i + 1}',
        usedIds,
      );
      nodeIds.add(id);

      final w = _readDouble(item, const ['width', 'w']).clamp(80.0, 520.0);
      final h = _readDouble(item, const ['height', 'h']).clamp(60.0, 360.0);
      final x = _readNum(item, const ['x', 'left', 'posX']);
      final y = _readNum(item, const ['y', 'top', 'posY']);
      if (x != null && y != null) {
        positions[id] = Offset(x.toDouble(), y.toDouble());
      } else {
        missingPosIds.add(id);
      }

      nodes.add(
        _NodeModel(
          id: id,
          position: const Offset(0, 0),
          size: Size(w, h),
          shape: _parseNodeShape(item['shape']),
          text:
              _readString(item, const ['text', 'name', 'title', 'label']) ?? id,
          sex: _readString(item, const ['sex', 'gender']) ?? '',
          birthday: _readString(item, const ['birthday', 'birthDate']) ?? '',
          description:
              _readString(item, const ['description', 'desc', 'note']) ?? '',
          parentId: _readString(item, const ['parentId', 'parent']) ?? '',
          level: _readNum(item, const ['level', 'generation'])?.toInt(),
          bottomText: _readString(item, const ['bottomText', 'subtitle']) ?? '',
          outsideText:
              _readString(item, const ['outsideText', 'caption']) ?? '',
          color: _parseColor(item['color'], const Color(0xFF5B8CFF)),
          borderColor: _parseColor(
            item['borderColor'],
            const Color(0xFF000000),
          ),
          borderWidth: _readDouble(item, const [
            'borderWidth',
          ]).clamp(0.0, 16.0),
          textColor: _parseColor(item['textColor'], const Color(0xFFFFFFFF)),
          textSize: _readDouble(item, const [
            'textSize',
            'fontSize',
          ]).clamp(8.0, 96.0),
          bottomTextColor: _parseColor(
            item['bottomTextColor'],
            const Color(0xFF2A2A2A),
          ),
          bottomTextSize: _readDouble(item, const [
            'bottomTextSize',
          ]).clamp(8.0, 72.0),
          outsideTextColor: _parseColor(
            item['outsideTextColor'],
            const Color(0xFF616161),
          ),
          outsideTextSize: _readDouble(item, const [
            'outsideTextSize',
          ]).clamp(8.0, 72.0),
          metadata: <String, String>{
            'FamilyNameGroup':
                _readString(item, const ['FamilyNameGroup', 'family']) ?? '',
            'Branch': _readString(item, const ['Branch', 'branch']) ?? '',
            'MotherID': _readString(item, const ['MotherID', 'motherId']) ?? '',
            'IsDead': (_readBool(item, const ['IsDead', 'isDead']) ?? false)
                ? 'true'
                : 'false',
            'DeadDay': _readString(item, const ['DeadDay', 'deadDay']) ?? '',
            'DeathDate':
                _readString(item, const [
                  'DeadDay',
                  'deadDay',
                  'Deathday',
                  'DeathDate',
                  'deathDate',
                  'deathday',
                  'DateOfDeath',
                  'dateOfDeath',
                  'dod',
                  'DOD',
                ]) ??
                '',
            'DiedAt':
                _readString(item, const ['DiedAt', 'diedAt', 'PassedAway']) ??
                '',
            'YearOfDeath':
                _readString(item, const ['YearOfDeath', 'deathYear']) ?? '',
            'NamMat': _readString(item, const ['NamMat', 'NamMatText']) ?? '',
            'PassedAwayDate': _readString(item, const ['PassedAwayDate']) ?? '',
            'LunarDeadDay': _readString(item, const ['LunarDeadDay']) ?? '',
            'BirthdayTEXT': _readString(item, const ['BirthdayTEXT']) ?? '',
          },
        ),
      );
    }

    final parsedEdges = <_EdgeModel>[];
    for (final raw in edgeList) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final from = _readString(item, const ['from', 'source', 'fromId']);
      final to = _readString(item, const ['to', 'target', 'toId']);
      if (from == null || to == null) continue;
      if (!nodeIds.contains(from) || !nodeIds.contains(to)) continue;
      parsedEdges.add(
        _EdgeModel(
          from: from,
          to: to,
          fromPort: _parseEdgePort(item['fromPort'], _EdgePort.right),
          toPort: _parseEdgePort(item['toPort'], _EdgePort.left),
          route: _parseEdgeRoute(item['route']),
          color: _parseColor(item['color'], const Color(0xFF4A4A4A)),
          width: _readDouble(item, const [
            'width',
            'strokeWidth',
          ]).clamp(0.5, 16.0),
          dashed: _parseBool(item['dashed']),
          arrow: _parseBool(item['arrow'], defaultValue: true),
          animated: _parseBool(item['animated']),
          label: _readString(item, const ['label']) ?? '',
        ),
      );
    }

    final nodeByIdForLabels = {for (final n in nodes) n.id: n};
    String cleanPersonId(String raw) {
      final t = raw.trim();
      if (t.isEmpty || t.toLowerCase() == 'null') return '';
      return t;
    }

    String resolvePersonName(String rawId) {
      final id = cleanPersonId(rawId);
      if (id.isEmpty) return '';
      final node = nodeByIdForLabels[id];
      if (node == null) return id;
      final name = node.text.trim();
      if (name.isEmpty || name.toLowerCase() == 'null') return id;
      return name;
    }

    String familyEdgeLabel(String fromId, String childId) {
      final child = nodeByIdForLabels[childId];
      if (child == null) return '';
      final father = resolvePersonName(fromId);
      final mother = resolvePersonName(child.metadata['MotherID'] ?? '');
      if (father.isNotEmpty && mother.isNotEmpty) {
        return 'Bố: $father • Mẹ: $mother';
      }
      if (father.isNotEmpty) return 'Bố: $father';
      if (mother.isNotEmpty) return 'Mẹ: $mother';
      return '';
    }

    for (int i = 0; i < parsedEdges.length; i++) {
      final e = parsedEdges[i];
      if (e.route != _EdgeRoute.familyTree) continue;
      if (e.label.trim().isNotEmpty) continue;
      final label = familyEdgeLabel(e.from, e.to);
      if (label.isEmpty) continue;
      parsedEdges[i] = e.copyWith(label: label, labelSize: 10, labelOffset: 14);
    }

    final parentPairs = parsedEdges
        .where((e) => e.route == _EdgeRoute.familyTree)
        .map((e) => MapEntry(e.from, e.to))
        .toList();
    final spousePairs = parsedEdges
        .where((e) => e.route == _EdgeRoute.spouse)
        .map((e) => MapEntry(e.from, e.to))
        .toList();
    final autoPos = _layoutTreeLike(
      nodeIds,
      parentPairs,
      spousePairs: spousePairs,
      sexById: {for (final n in nodes) n.id: n.sex},
      levelById: {
        for (final n in nodes)
          if (n.level != null) n.id: n.level!,
      },
    );
    for (final n in nodes) {
      n.position = positions[n.id] ?? autoPos[n.id] ?? const Offset(0, 0);
    }

    return _ImportedCanvasGraph(nodes: nodes, edges: parsedEdges);
  }

  _ImportedCanvasGraph _parsePeopleGraph(List<dynamic> people) {
    final nodes = <_NodeModel>[];
    final nodeById = <String, _NodeModel>{};
    final imageUrls = <String, String>{};
    final parentPairs = <MapEntry<String, String>>[];
    final spousePairs = <MapEntry<String, String>>[];
    final sexById = <String, String>{};
    final processedNodeCodes = <String>{};

    _NodeModel ensureSpouseNode(
      String id, {
      String name = '',
      String inferredSex = '',
      int? levelHint,
    }) {
      final existing = nodeById[id];
      if (existing != null) {
        if (name.trim().isNotEmpty &&
            (existing.text.trim().isEmpty || existing.text == existing.id)) {
          existing.text = name.trim();
        }
        if (inferredSex.trim().isNotEmpty && existing.sex.trim().isEmpty) {
          existing.sex = inferredSex.trim();
          existing.bottomText = inferredSex.trim();
          sexById[id] = _normalizeSex(inferredSex);
        }
        if (levelHint != null && existing.level == null) {
          existing.level = levelHint;
        }
        return existing;
      }
      final created = _NodeModel(
        id: id,
        position: const Offset(0, 0),
        size: const Size(170, 118),
        shape: _NodeShape.rect,
        text: name.trim().isEmpty ? id : name.trim(),
        sex: inferredSex,
        bottomText: inferredSex,
        level: levelHint,
        color: Colors.white,
        textColor: const Color(0xFF1E293B),
        borderColor: _generationNodeColor(levelHint, isDead: false),
        borderWidth: 2.0,
        metadata: const <String, String>{'virtualSpouse': 'true'},
      );
      nodes.add(created);
      nodeById[id] = created;
      processedNodeCodes.add(id);
      if (inferredSex.trim().isNotEmpty) {
        sexById[id] = _normalizeSex(inferredSex);
      }
      return created;
    }

    void addSpousePair(String a, String b) {
      if (a.trim().isEmpty || b.trim().isEmpty || a == b) return;
      final sa = sexById[a]?.toLowerCase() ?? '';
      final sb = sexById[b]?.toLowerCase() ?? '';
      final aMale = sa == 'male';
      final bMale = sb == 'male';
      if (aMale && !bMale) {
        spousePairs.add(MapEntry(a, b));
      } else if (bMale && !aMale) {
        spousePairs.add(MapEntry(b, a));
      } else if (a.compareTo(b) <= 0) {
        spousePairs.add(MapEntry(a, b));
      } else {
        spousePairs.add(MapEntry(b, a));
      }
    }

    /// Pass 1: Flatten tree and build nodes + mapping
    void flattenTree(Map<String, dynamic> item, [String? parentNodeCode]) {
      final nodeCode =
          _readString(item, const ['NodeCode', 'id', 'personId']) ??
          'node_${nodes.length}';
      if (processedNodeCodes.contains(nodeCode)) return;
      processedNodeCodes.add(nodeCode);

      // Use NodeCode as ID directly for simplicity
      final id = nodeCode;

      // Extract FullName
      final fullName =
          _readString(item, const ['FullName', 'name', 'title']) ?? id;

      final rawSex = _readString(item, const ['Sex', 'sex', 'gender']) ?? '';
      final normalizedSex = _normalizeSex(rawSex);
      sexById[id] = normalizedSex;

      final birthday =
          _readString(item, const ['Birthday', 'birthDate', 'dob']) ?? '';
      final birthdayText = _readString(item, const ['BirthdayTEXT']) ?? '';
      final deathDate =
          _readString(item, const [
            'DeadDay',
            'deadDay',
            'Deathday',
            'DeathDate',
            'deathDate',
            'deathday',
            'DateOfDeath',
            'dateOfDeath',
            'dod',
            'DOD',
          ]) ??
          '';
      final deadDay = _readString(item, const ['DeadDay', 'deadDay']) ?? '';
      final lunarDeadDay = _readString(item, const ['LunarDeadDay']) ?? '';
      final diedAt =
          _readString(item, const ['DiedAt', 'diedAt', 'PassedAway']) ?? '';
      final yearOfDeath =
          _readString(item, const ['YearOfDeath', 'deathYear']) ?? '';
      final namMat = _readString(item, const ['NamMat', 'NamMatText']) ?? '';
      final passedAwayDate = _readString(item, const ['PassedAwayDate']) ?? '';
      final description =
          _readString(item, const ['Description', 'description']) ?? '';
      final parentField = _readString(item, const ['Parent']) ?? '';
      final motherId = _readString(item, const ['MotherID', 'motherId']) ?? '';
      final level = _readNum(item, const ['Level', 'level'])?.toInt();

      final imageUrl = _readString(item, const [
        'Image',
        'image',
        'avatar',
        'ImageUrl',
        'imageUrl',
        'avatarUrl',
        'AvatarUrl',
        'photo',
        'Photo',
      ]);
      if (imageUrl != null && imageUrl.trim().isNotEmpty) {
        imageUrls[id] = imageUrl.trim();
      }

      // Create node with generation-based color and deceased gray
      final isDead = _readBool(item, const ['IsDead', 'isDead']) ?? false;
      final nodeColor = _generationNodeColor(level, isDead: isDead);
      final node = _NodeModel(
        id: id,
        position: const Offset(0, 0),
        size: const Size(170, 118),
        shape: _NodeShape.rect,
        text: fullName,
        sex: rawSex,
        birthday: birthday,
        description: description,
        parentId: parentField,
        level: level,
        bottomText: rawSex,
        outsideText: description,
        metadata: <String, String>{
          'FamilyNameGroup':
              _readString(item, const ['FamilyNameGroup', 'family']) ?? '',
          'Branch': _readString(item, const ['Branch', 'branch']) ?? '',
          'NodeCode': nodeCode,
          'MotherID': motherId,
          'IsDead': (isDead || deadDay.trim().isNotEmpty) ? 'true' : 'false',
          'DeadDay': deadDay,
          'DeathDate': deathDate,
          'DiedAt': diedAt,
          'YearOfDeath': yearOfDeath,
          'NamMat': namMat,
          'PassedAwayDate': passedAwayDate,
          'LunarDeadDay': lunarDeadDay,
          'BirthdayTEXT': birthdayText,
          'ImageUrl': imageUrl?.trim() ?? '',
        },
        color: Colors.white,
        textColor: const Color(0xFF1E293B),
        borderColor: nodeColor,
        borderWidth: 2.0,
      );

      nodes.add(node);
      nodeById[id] = node;

      // Track parent relationship from both sources
      if (parentNodeCode != null && parentNodeCode.isNotEmpty) {
        parentPairs.add(MapEntry(parentNodeCode, nodeCode));
      }

      if (parentField.isNotEmpty &&
          parentField != 'null' &&
          parentField != parentNodeCode) {
        parentPairs.add(MapEntry(parentField, nodeCode));
      }

      if (motherId.isNotEmpty && motherId != 'null') {
        if (!nodeById.containsKey(motherId)) {
          ensureSpouseNode(motherId, inferredSex: 'Nữ', levelHint: level);
        }
        if (parentField.isNotEmpty && parentField != 'null') {
          addSpousePair(parentField, motherId);
        }
      }

      void collectSpouses(dynamic raw) {
        if (raw == null) return;
        if (raw is String) {
          final split = raw
              .split(RegExp(r'[,;|]'))
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty);
          for (final spouseId in split) {
            addSpousePair(nodeCode, spouseId);
          }
          return;
        }
        if (raw is Map) {
          final spouseMap = Map<String, dynamic>.from(raw);
          final spouseId =
              _readString(spouseMap, const ['NodeCode', 'id', 'personId']) ??
              '';
          if (spouseId.isNotEmpty) {
            flattenTree(spouseMap);
            addSpousePair(nodeCode, spouseId);
          }
          return;
        }
        if (raw is List) {
          for (final item in raw) {
            collectSpouses(item);
          }
        }
      }

      collectSpouses(item['Spouse']);
      collectSpouses(item['Spouses']);
      collectSpouses(item['Wife']);
      collectSpouses(item['Wives']);
      collectSpouses(item['Husband']);
      collectSpouses(item['Husbands']);
      collectSpouses(item['Partner']);
      collectSpouses(item['Partners']);

      final marriedHist = item['MarriedHist'];
      if (marriedHist is String &&
          marriedHist.trim().isNotEmpty &&
          marriedHist.trim().toLowerCase() != 'null') {
        try {
          final decoded = jsonDecode(marriedHist);
          if (decoded is Map) {
            final map = Map<String, dynamic>.from(decoded);
            final list = map['node_list'];
            if (list is List) {
              for (final rawSpouse in list) {
                if (rawSpouse is! Map) continue;
                final spouseMap = Map<String, dynamic>.from(rawSpouse);
                final spouseId = _readString(spouseMap, const [
                  'node',
                  'NodeCode',
                  'id',
                  'personId',
                ]);
                if (spouseId == null || spouseId.trim().isEmpty) continue;
                final spouseName = _readString(spouseMap, const [
                  'node_name',
                  'name',
                  'FullName',
                ]);
                final inferred = normalizedSex == 'male'
                    ? 'Nữ'
                    : (normalizedSex == 'female' ? 'Nam' : '');
                ensureSpouseNode(
                  spouseId.trim(),
                  name: spouseName ?? '',
                  inferredSex: inferred,
                  levelHint: level,
                );
                addSpousePair(nodeCode, spouseId.trim());
              }
            }
          }
        } catch (_) {
          // Ignore malformed MarriedHist values.
        }
      }

      // Recursively process Children array
      final childrenRaw = item['Children'];
      if (childrenRaw is List) {
        for (final childRaw in childrenRaw) {
          if (childRaw is Map) {
            flattenTree(Map<String, dynamic>.from(childRaw), nodeCode);
          }
        }
      }
    }

    // Start flattening from root level
    for (final raw in people) {
      if (raw is Map) {
        flattenTree(Map<String, dynamic>.from(raw));
      }
    }

    final knownIds = nodes.map((n) => n.id).toSet();

    // Create edges from parent pairs
    final dedupParents = <String>{};
    final edges = <_EdgeModel>[];

    String cleanPersonId(String raw) {
      final t = raw.trim();
      if (t.isEmpty || t.toLowerCase() == 'null') return '';
      return t;
    }

    String resolvePersonName(String rawId) {
      final id = cleanPersonId(rawId);
      if (id.isEmpty) return '';
      final node = nodeById[id];
      if (node == null) return id;
      final name = node.text.trim();
      if (name.isEmpty || name.toLowerCase() == 'null') return id;
      return name;
    }

    String familyEdgeLabel(String fatherId, String childId) {
      final child = nodeById[childId];
      if (child == null) return '';
      final father = resolvePersonName(fatherId);
      final mother = resolvePersonName(child.metadata['MotherID'] ?? '');
      if (father.isNotEmpty && mother.isNotEmpty) {
        return 'Bố: $father • Mẹ: $mother';
      }
      if (father.isNotEmpty) return 'Bố: $father';
      if (mother.isNotEmpty) return 'Mẹ: $mother';
      return '';
    }

    for (final pair in parentPairs) {
      // Both should already be in knownIds (same as NodeCode)
      if (!knownIds.contains(pair.key) || !knownIds.contains(pair.value)) {
        continue;
      }
      final key = '${pair.key}->${pair.value}';
      if (!dedupParents.add(key)) continue;

      edges.add(
        _EdgeModel(
          from: pair.key,
          to: pair.value,
          fromPort: _EdgePort.bottom,
          toPort: _EdgePort.top,
          route: _EdgeRoute.familyTree,
          color: _generationEdgeColor(
            nodeById[pair.value]?.level,
            isDead: false,
          ),
          label: familyEdgeLabel(pair.key, pair.value),
          labelSize: 10,
          labelOffset: 14,
          arrow: true,
        ),
      );
    }

    final dedupSpouses = <String>{};
    for (final pair in spousePairs) {
      if (!knownIds.contains(pair.key) || !knownIds.contains(pair.value)) {
        continue;
      }
      final key = '${pair.key}<->${pair.value}';
      if (!dedupSpouses.add(key)) continue;

      final nodeA = nodeById[pair.key];
      final nodeB = nodeById[pair.value];
      final level = nodeA?.level ?? nodeB?.level ?? 0;
      final isDead =
          (nodeA?.metadata['IsDead'] == 'true') ||
          (nodeB?.metadata['IsDead'] == 'true');
      final edgeColor = _generationEdgeColor(level, isDead: isDead);

      edges.add(
        _EdgeModel(
          from: pair.key,
          to: pair.value,
          fromPort: _EdgePort.spouseBottom,
          toPort: _EdgePort.spouseBottom,
          route: _EdgeRoute.spouse,
          color: edgeColor,
          width: 2.6,
          arrow: false,
        ),
      );
    }

    // Auto-layout
    final autoPos = _layoutTreeLike(
      knownIds,
      parentPairs,
      spousePairs: spousePairs,
      sexById: sexById,
      levelById: {
        for (final n in nodes)
          if (n.level != null) n.id: n.level!,
      },
    );
    for (final n in nodes) {
      if (n.position == Offset.zero) {
        n.position = autoPos[n.id] ?? const Offset(0, 0);
      }
    }

    return _ImportedCanvasGraph(
      nodes: nodes,
      edges: edges,
      imageUrls: imageUrls,
    );
  }

  Map<String, Offset> _layoutTreeLike(
    Set<String> nodeIds,
    List<MapEntry<String, String>> parentPairs, {
    List<MapEntry<String, String>> spousePairs =
        const <MapEntry<String, String>>[],
    Map<String, String> sexById = const <String, String>{},
    Map<String, int> levelById = const <String, int>{},
  }) {
    final childrenByParent = <String, List<String>>{
      for (final id in nodeIds) id: <String>[],
    };
    final incoming = <String, int>{for (final id in nodeIds) id: 0};
    for (final pair in parentPairs) {
      if (!nodeIds.contains(pair.key) || !nodeIds.contains(pair.value)) {
        continue;
      }
      childrenByParent[pair.key]!.add(pair.value);
      incoming[pair.value] = (incoming[pair.value] ?? 0) + 1;
    }

    final roots = nodeIds.where((id) => (incoming[id] ?? 0) == 0).toList()
      ..sort();
    final queue = <String>[
      ...roots.isNotEmpty ? roots : nodeIds.toList()
        ..sort(),
    ];
    final depth = <String, int>{
      for (final id in queue) id: math.max(0, (levelById[id] ?? 1) - 1),
    };

    int idx = 0;
    while (idx < queue.length) {
      final p = queue[idx++];
      final nextDepth = (depth[p] ?? 0) + 1;
      for (final c in childrenByParent[p] ?? const <String>[]) {
        final prev = depth[c];
        final minByLevel = math.max(0, (levelById[c] ?? 1) - 1);
        final candidateDepth = math.max(nextDepth, minByLevel);
        if (prev == null || candidateDepth > prev) {
          depth[c] = candidateDepth;
          queue.add(c);
        }
      }
    }

    var fallbackDepth = depth.values.isEmpty
        ? 0
        : depth.values.reduce(math.max) + 1;
    for (final id in nodeIds) {
      depth.putIfAbsent(id, () {
        final levelHint = levelById[id];
        if (levelHint != null) return math.max(0, levelHint - 1);
        return fallbackDepth++;
      });
    }

    final spouseAdj = <String, Set<String>>{
      for (final id in nodeIds) id: <String>{},
    };
    for (final pair in spousePairs) {
      if (!nodeIds.contains(pair.key) || !nodeIds.contains(pair.value)) {
        continue;
      }
      spouseAdj[pair.key]!.add(pair.value);
      spouseAdj[pair.value]!.add(pair.key);
    }

    bool changed = true;
    int guard = 0;
    while (changed && guard < 8) {
      changed = false;
      guard++;
      for (final pair in spousePairs) {
        if (!nodeIds.contains(pair.key) || !nodeIds.contains(pair.value)) {
          continue;
        }
        final da = depth[pair.key] ?? 0;
        final db = depth[pair.value] ?? 0;
        if (da == db) continue;
        final target = math.max(da, db);
        if (da != target) {
          depth[pair.key] = target;
          changed = true;
        }
        if (db != target) {
          depth[pair.value] = target;
          changed = true;
        }
      }
    }

    final byDepth = <int, List<String>>{};
    for (final id in nodeIds) {
      byDepth.putIfAbsent(depth[id] ?? 0, () => <String>[]).add(id);
    }

    const spouseGap = 280.0;
    const componentGap = 200.0;
    const yStep = 260.0;
    final result = <String, Offset>{};
    final sortedDepths = byDepth.keys.toList()..sort();
    for (final d in sortedDepths) {
      final ids = byDepth[d]!..sort();
      final originalIndex = <String, int>{
        for (int i = 0; i < ids.length; i++) ids[i]: i,
      };
      final visited = <String>{};
      final components = <List<String>>[];

      for (final id in ids) {
        if (visited.contains(id)) continue;
        final stack = <String>[id];
        final component = <String>[];
        while (stack.isNotEmpty) {
          final current = stack.removeLast();
          if (!visited.add(current)) continue;
          component.add(current);
          for (final spouse in spouseAdj[current] ?? const <String>{}) {
            if ((depth[spouse] ?? -1) != d) continue;
            if (!visited.contains(spouse)) stack.add(spouse);
          }
        }
        components.add(_sortSpouseComponent(component, sexById));
      }

      components.sort(
        (a, b) => (originalIndex[a.first] ?? 0).compareTo(
          originalIndex[b.first] ?? 0,
        ),
      );

      final rowX = <String, double>{};
      double cursor = 0;
      for (int c = 0; c < components.length; c++) {
        final comp = components[c];
        for (int i = 0; i < comp.length; i++) {
          rowX[comp[i]] = cursor + i * spouseGap;
        }
        cursor += math.max(0.0, (comp.length - 1) * spouseGap);
        if (c < components.length - 1) {
          cursor += componentGap;
        }
      }

      final rowWidth = cursor;
      for (final id in ids) {
        final x = (rowX[id] ?? 0) - rowWidth / 2;
        final y = d * yStep;
        result[id] = Offset(x, y);
      }
    }
    return result;
  }

  List<String> _sortSpouseComponent(
    List<String> ids,
    Map<String, String> sexById,
  ) {
    final males = <String>[];
    final females = <String>[];
    final unknown = <String>[];
    for (final id in ids) {
      final sex = _normalizeSex(sexById[id] ?? '');
      if (sex == 'male') {
        males.add(id);
      } else if (sex == 'female') {
        females.add(id);
      } else {
        unknown.add(id);
      }
    }
    males.sort();
    females.sort();
    unknown.sort();
    return <String>[...males, ...females, ...unknown];
  }

  List<dynamic> _firstList(Map<String, dynamic>? map, List<String> keys) {
    if (map == null) return const <dynamic>[];
    for (final key in keys) {
      final value = map[key];
      if (value is List) return value;
    }
    return const <dynamic>[];
  }

  String _uniqueId(String raw, Set<String> used) {
    final base = raw.trim().isEmpty ? 'n${used.length + 1}' : raw.trim();
    var out = base;
    var n = 2;
    while (used.contains(out)) {
      out = '${base}_$n';
      n++;
    }
    used.add(out);
    return out;
  }

  String? _readString(Map<String, dynamic> item, List<String> keys) {
    for (final key in keys) {
      final v = item[key];
      if (v == null) continue;
      final text = v.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  num? _readNum(Map<String, dynamic> item, List<String> keys) {
    for (final key in keys) {
      final v = item[key];
      if (v is num) return v;
      if (v is String) {
        final p = num.tryParse(v.trim());
        if (p != null) return p;
      }
    }
    return null;
  }

  double _readDouble(Map<String, dynamic> item, List<String> keys) {
    final n = _readNum(item, keys);
    return n?.toDouble() ?? 0;
  }

  bool? _readBool(Map<String, dynamic> item, List<String> keys) {
    for (final key in keys) {
      final v = item[key];
      if (v != null) return _parseBool(v);
    }
    return null;
  }

  bool _parseBool(dynamic v, {bool defaultValue = false}) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final t = v.trim().toLowerCase();
      if (t == 'true' || t == '1' || t == 'yes') return true;
      if (t == 'false' || t == '0' || t == 'no') return false;
    }
    return defaultValue;
  }

  Color _parseColor(dynamic v, Color fallback) {
    if (v is int) {
      return Color(v > 0xFFFFFF ? v : (0xFF000000 | v));
    }
    if (v is String) {
      final text = v.trim().toLowerCase();
      if (text.isEmpty) return fallback;
      final named = <String, Color>{
        'red': Colors.red,
        'green': Colors.green,
        'blue': Colors.blue,
        'yellow': Colors.yellow,
        'orange': Colors.orange,
        'pink': Colors.pink,
        'purple': Colors.purple,
        'cyan': Colors.cyan,
        'teal': Colors.teal,
        'black': Colors.black,
        'white': Colors.white,
        'grey': Colors.grey,
        'gray': Colors.grey,
      };
      final hit = named[text];
      if (hit != null) return hit;
      final cleaned = text.replaceAll('#', '').replaceAll('0x', '');
      final value = int.tryParse(cleaned, radix: 16);
      if (value == null) return fallback;
      if (cleaned.length <= 6) return Color(0xFF000000 | value);
      if (cleaned.length == 8) return Color(value);
    }
    return fallback;
  }

  _NodeShape _parseNodeShape(dynamic v) {
    if (v is! String) return _NodeShape.rect;
    switch (v.trim().toLowerCase()) {
      case 'square':
        return _NodeShape.square;
      case 'circle':
        return _NodeShape.circle;
      case 'oval':
        return _NodeShape.oval;
      case 'diamond':
        return _NodeShape.diamond;
      case 'triangle':
        return _NodeShape.triangle;
      case 'star':
        return _NodeShape.star;
      case 'hexagon':
        return _NodeShape.hexagon;
      case 'trapezoid':
        return _NodeShape.trapezoid;
      case 'parallelogram':
        return _NodeShape.parallelogram;
      case 'arrowright':
      case 'arrow_right':
      case 'arrow-right':
        return _NodeShape.arrowRight;
      default:
        return _NodeShape.rect;
    }
  }

  _EdgePort _parseEdgePort(dynamic v, _EdgePort fallback) {
    if (v is! String) return fallback;
    switch (v.trim().toLowerCase()) {
      case 'left':
        return _EdgePort.left;
      case 'top':
        return _EdgePort.top;
      case 'right':
        return _EdgePort.right;
      case 'bottom':
        return _EdgePort.bottom;
      case 'spousebottom':
      case 'spouse_bottom':
      case 'partnerbottom':
      case 'partner_bottom':
        return _EdgePort.spouseBottom;
      default:
        return fallback;
    }
  }

  _EdgeRoute _parseEdgeRoute(dynamic v) {
    if (v is! String) return _EdgeRoute.bezier;
    switch (v.trim().toLowerCase()) {
      case 'straight':
      case 'line':
        return _EdgeRoute.straight;
      case 'orthogonal':
      case 'ortho':
        return _EdgeRoute.orthogonal;
      case 'family':
      case 'familytree':
      case 'family_tree':
      case 'tree':
        return _EdgeRoute.familyTree;
      case 'spouse':
      case 'marriage':
      case 'couple':
      case 'husbandwife':
      case 'husband_wife':
        return _EdgeRoute.spouse;
      default:
        return _EdgeRoute.bezier;
    }
  }

  Color _generationNodeColor(int? level, {required bool isDead}) {
    if (isDead) return const Color(0xFF9E9E9E);
    final gen = math.max(0, (level ?? 1) - 1);
    final hue = (204 + (gen * 27) % 108).toDouble();
    final lightness = (0.43 + (gen % 6) * 0.045).clamp(0.38, 0.68).toDouble();
    const saturation = 0.60;
    return HSLColor.fromAHSL(1, hue, saturation, lightness).toColor();
  }

  Color _generationEdgeColor(int? level, {required bool isDead}) {
    if (isDead) return const Color(0xFFBDBDBD);
    final nodeColor = _generationNodeColor(level, isDead: false);
    final hsl = HSLColor.fromColor(nodeColor);
    return hsl
        .withSaturation((hsl.saturation * 0.86).clamp(0.2, 1.0))
        .withLightness((hsl.lightness * 0.86).clamp(0.2, 0.72))
        .toColor();
  }

  String _normalizeSex(String raw) {
    final t = raw.trim().toLowerCase();
    if (t == 'male' || t == 'm' || t == 'nam' || t == 'man') return 'male';
    if (t == 'female' || t == 'f' || t == 'nu' || t == 'nữ' || t == 'woman') {
      return 'female';
    }
    return '';
  }

  void _addNodeAt(Offset world, {required _NodeShape shape, String text = ''}) {
    _commit(() {
      _nodes.add(
        _NodeModel(
          id: _nextNodeId(),
          position: world,
          size: const Size(150, 110),
          shape: shape,
          text: text,
          color: _createColor,
        ),
      );
      _selectedIds = {_nodes.last.id};
      _selectedEdgeIndex = null;
    });
    setState(() {});
  }

  void _onNodeTap(String id) {
    if (_tool == _CanvasTool.connect) {
      _onConnectTargetTap(id);
      return;
    }

    setState(() {
      _selectedTextId = null;
      _editingTextId = null;
      _showTextStylePanel = false;
      if (_multiSelect) {
        if (_selectedIds.contains(id)) {
          _selectedIds.remove(id);
        } else {
          _selectedIds.add(id);
        }
      } else {
        _selectedIds = {id};
      }
      _selectedEdgeIndex = null;
    });
  }

  bool _isNodeId(String id) => _nodes.any((n) => n.id == id);

  void _onConnectTargetTap(String targetId) {
    if (_connectFromNodeId == null) {
      setState(() {
        _connectFromNodeId = targetId;
        _selectedTextId = null;
        _editingTextId = null;
        _showTextStylePanel = false;
        _selectedIds = _isNodeId(targetId) ? {targetId} : <String>{};
        _selectedEdgeIndex = null;
      });
      return;
    }
    if (_connectFromNodeId != targetId) {
      _commit(() {
        final from = _connectFromNodeId!;
        final exists = _edges.any((e) => e.from == from && e.to == targetId);
        if (!exists) _edges.add(_buildEdge(from, targetId));
      });
    }
    setState(() {
      _connectFromNodeId = null;
      _selectedTextId = null;
      _editingTextId = null;
      _showTextStylePanel = false;
      _selectedIds = _isNodeId(targetId) ? {targetId} : <String>{};
      _selectedEdgeIndex = null;
    });
  }

  Offset _nodePortWorld(_NodeModel node, _EdgePort port) {
    switch (port) {
      case _EdgePort.left:
        return node.position + Offset(0, node.size.height / 2);
      case _EdgePort.top:
        return node.position + Offset(node.size.width / 2, 0);
      case _EdgePort.right:
        return node.position + Offset(node.size.width, node.size.height / 2);
      case _EdgePort.bottom:
        return node.position + Offset(node.size.width / 2, node.size.height);
      case _EdgePort.spouseBottom:
        return node.position +
            Offset(node.size.width / 2 + 18, node.size.height);
    }
  }

  _EdgePort _autoPortForEndpoint(String endpointId, Offset towardWorld) {
    for (final n in _nodes) {
      if (n.id != endpointId) continue;
      _EdgePort best = _EdgePort.right;
      double bestDist = double.infinity;
      for (final p in _EdgePort.values) {
        final d = (_nodePortWorld(n, p) - towardWorld).distance;
        if (d < bestDist) {
          bestDist = d;
          best = p;
        }
      }
      return best;
    }
    return _EdgePort.right;
  }

  _EdgeModel _buildEdge(String fromId, String toId) {
    final fromCenter = _endpointWorldCenter(fromId) ?? Offset.zero;
    final toCenter = _endpointWorldCenter(toId) ?? fromCenter;
    return _EdgeModel(
      from: fromId,
      to: toId,
      fromPort: _autoPortForEndpoint(fromId, toCenter),
      toPort: _autoPortForEndpoint(toId, fromCenter),
    );
  }

  void _startPortDrag(
    String nodeId,
    _EdgePort fromPort, {
    _ConnectKind kind = _ConnectKind.defaultLink,
  }) {
    if (_tool != _CanvasTool.connect) return;
    _NodeModel? n;
    for (final node in _nodes) {
      if (node.id == nodeId) {
        n = node;
        break;
      }
    }
    if (n == null) return;
    final start = _nodePortWorld(n, fromPort);
    setState(() {
      _activePortDrag = _ActivePortDrag(
        fromNodeId: nodeId,
        fromPort: fromPort,
        kind: kind,
        startWorld: start,
        currentWorld: start,
      );
      _selectedEdgeIndex = null;
      _selectedIds = {nodeId};
    });
  }

  _PortHit? _hitPortAtScreen(Offset screenPos) {
    const threshold = 26.0;
    _PortHit? best;
    double bestDist = threshold;
    for (final n in _nodes) {
      for (final p in _EdgePort.values) {
        final wp = _nodePortWorld(n, p);
        final sp = _controller.worldToScreen(wp);
        final d = (sp - screenPos).distance;
        if (d <= bestDist) {
          bestDist = d;
          best = _PortHit(endpointId: n.id, port: p);
        }
      }
    }
    if (best != null) return best;

    // Fallback UX: if user drops near a node body, snap to the nearest side port.
    for (final n in _nodes) {
      final p1 = _controller.worldToScreen(n.position);
      final p2 = _controller.worldToScreen(
        n.position + Offset(n.size.width, n.size.height),
      );
      final rect = Rect.fromPoints(p1, p2).inflate(24);
      if (!rect.contains(screenPos)) continue;
      final center = rect.center;
      final dx = screenPos.dx - center.dx;
      final dy = screenPos.dy - center.dy;
      final port = dx.abs() > dy.abs()
          ? (dx >= 0 ? _EdgePort.right : _EdgePort.left)
          : (dy >= 0 ? _EdgePort.bottom : _EdgePort.top);
      return _PortHit(endpointId: n.id, port: port);
    }
    return best;
  }

  String? _hitGroupBorderAtScreen(Offset screen) {
    const borderSlop = 12.0;
    for (final g in _groups.reversed) {
      final world = _groupWorldRect(g);
      if (world == null) continue;
      final p1 = _controller.worldToScreen(world.topLeft);
      final p2 = _controller.worldToScreen(world.bottomRight);
      final rect = Rect.fromPoints(p1, p2);
      final outer = rect.inflate(borderSlop);
      final inner = rect.deflate(borderSlop);
      if (!outer.contains(screen)) continue;
      if (rect.width <= borderSlop * 2 || rect.height <= borderSlop * 2) {
        return g.id;
      }
      if (!inner.contains(screen)) return g.id;
    }
    return null;
  }

  _PortHit? _hitConnectTargetAtScreen(Offset screenPos) {
    final groupBorderHit = _hitGroupBorderAtScreen(screenPos);
    if (groupBorderHit != null) {
      return _PortHit(endpointId: groupBorderHit, port: _EdgePort.right);
    }
    final portHit = _hitPortAtScreen(screenPos);
    if (portHit != null) return portHit;
    final groupHit = _hitGroupAtScreen(screenPos);
    if (groupHit != null) {
      return _PortHit(endpointId: groupHit, port: _EdgePort.right);
    }
    return null;
  }

  void _finishPortDrag(Offset screenPos) {
    final drag = _activePortDrag;
    if (drag == null) return;
    final target = _hitConnectTargetAtScreen(screenPos);
    if (target != null && target.endpointId != drag.fromNodeId) {
      if ((drag.kind == _ConnectKind.parentToChild ||
              drag.kind == _ConnectKind.spouse) &&
          !_isNodeId(target.endpointId)) {
        setState(() => _activePortDrag = null);
        return;
      }

      _commit(() {
        final resolvedRoute = switch (drag.kind) {
          _ConnectKind.parentToChild => _EdgeRoute.familyTree,
          _ConnectKind.spouse => _EdgeRoute.spouse,
          _ConnectKind.defaultLink => _EdgeRoute.bezier,
        };
        final resolvedFromPort = switch (drag.kind) {
          _ConnectKind.parentToChild => _EdgePort.bottom,
          _ConnectKind.spouse => _EdgePort.spouseBottom,
          _ConnectKind.defaultLink => drag.fromPort,
        };
        final resolvedToPort = switch (drag.kind) {
          _ConnectKind.parentToChild => _EdgePort.top,
          _ConnectKind.spouse => _EdgePort.spouseBottom,
          _ConnectKind.defaultLink => target.port,
        };

        final exists = _edges.any((e) {
          if (resolvedRoute == _EdgeRoute.spouse) {
            final sameDirection =
                e.from == drag.fromNodeId && e.to == target.endpointId;
            final reverseDirection =
                e.from == target.endpointId && e.to == drag.fromNodeId;
            return e.route == _EdgeRoute.spouse &&
                (sameDirection || reverseDirection);
          }
          return e.from == drag.fromNodeId &&
              e.to == target.endpointId &&
              e.fromPort == resolvedFromPort &&
              e.toPort == resolvedToPort;
        });
        if (!exists) {
          _edges.add(
            _EdgeModel(
              from: drag.fromNodeId,
              to: target.endpointId,
              fromPort: resolvedFromPort,
              toPort: resolvedToPort,
              route: resolvedRoute,
            ),
          );
        }
      });
    }
    setState(() => _activePortDrag = null);
  }

  void _updateSelectedEdge(_EdgeModel Function(_EdgeModel) mapper) {
    final i = _selectedEdgeIndex;
    if (i == null || i < 0 || i >= _edges.length) return;
    _commit(() {
      _edges[i] = mapper(_edges[i]);
    });
    setState(() {});
  }

  void _moveNode(String id, Offset deltaWorld) {
    if (_tool != _CanvasTool.cursor) return;
    final moving = _selectedIds.contains(id) ? _selectedIds : {id};
    setState(() {
      for (final nid in moving) {
        final n = _nodeById(nid);
        n.position += deltaWorld;
        _nodeBoundsById[nid] = _nodeRect(n);
      }
    });
  }

  void _resizeNode(String id, Size next) {
    setState(() {
      final node = _nodeById(id);
      node.size = next;
      _nodeBoundsById[id] = _nodeRect(node);
    });
  }

  Future<void> _showNodeMenu(_NodeModel node, TapDownDetails details) async {
    setState(() => _selectedIds = {node.id});
    _selectedEdgeIndex = null;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        details.globalPosition.dx,
        details.globalPosition.dy,
        details.globalPosition.dx,
        details.globalPosition.dy,
      ),
      items: const [
        PopupMenuItem(value: 'edit_text', child: Text('Sửa chữ')),
        PopupMenuItem(
          value: 'edit_bottom_text',
          child: Text('Sửa chữ dưới object'),
        ),
        PopupMenuItem(
          value: 'edit_outside_text',
          child: Text('Sửa chữ dưới cả khối'),
        ),
        PopupMenuItem(value: 'upload_image', child: Text('Ảnh từ máy')),
        PopupMenuItem(value: 'remove_image', child: Text('Gỡ ảnh')),
        PopupMenuItem(value: 'set_color', child: Text('Đổi màu nền')),
        PopupMenuItem(value: 'change_shape', child: Text('Đổi dạng hình…')),
        PopupMenuItem(value: 'create_altar_3d', child: Text('Tạo bàn thờ 3D')),
        PopupMenuItem(
          value: 'setup_altar_layout',
          child: Text('Lập bàn thờ (kéo-thả vật phẩm)'),
        ),
      ],
    );
    if (!mounted || selected == null) return;
    if (selected == 'edit_text') {
      _editText(node);
    } else if (selected == 'edit_bottom_text') {
      _editBottomText(node);
    } else if (selected == 'edit_outside_text') {
      _editOutsideText(node);
    } else if (selected == 'upload_image') {
      _uploadImage(node);
    } else if (selected == 'remove_image') {
      _commit(() => node.imageBytes = null);
      setState(() {});
    } else if (selected == 'set_color') {
      _pickColorForSelection();
    } else if (selected == 'change_shape') {
      await _pickShapeForNode(node);
    } else if (selected == 'create_altar_3d') {
      final keyword = node.text.trim().isNotEmpty
          ? '${node.text.trim()} bat huong altar'
          : 'bat huong incense burner';
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => UnityBatHuongDemoPage(initialKeyword: keyword),
        ),
      );
    } else if (selected == 'setup_altar_layout') {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AltarSetupPage(
            memberKey: node.id,
            memberName: node.text.trim().isEmpty ? 'Node ${node.id}' : node.text.trim(),
          ),
        ),
      );
    }
  }

  void _runViewportCullingBenchmark({required int nodeCount}) {
    if (_nodes.isEmpty || !mounted) return;
    final size = _canvasSize();
    final base = _worldViewportRect(size, paddingWorld: 280);
    final samples = 90;
    final sw = Stopwatch()..start();
    var visibleNodeAccum = 0;
    var visibleEdgeAccum = 0;

    for (var i = 0; i < samples; i++) {
      final dx = (i % 9 - 4) * 260.0;
      final dy = (i ~/ 9 - 4) * 180.0;
      final probe = base.shift(Offset(dx, dy));
      final visibleNodes = _visibleNodesForViewport(probe);
      final visibleIds = visibleNodes.map((n) => n.id).toSet();
      final visibleEdges = _visibleEdgesForViewport(probe, visibleIds);
      visibleNodeAccum += visibleNodes.length;
      visibleEdgeAccum += visibleEdges.length;
    }
    sw.stop();

    final avgNodes = (visibleNodeAccum / samples).toStringAsFixed(0);
    final avgEdges = (visibleEdgeAccum / samples).toStringAsFixed(0);
    final ms = sw.elapsedMilliseconds;
    _showSnack(
      'Perf culling: $nodeCount nodes | ${samples}x query = ${ms}ms | avg visible: $avgNodes nodes, $avgEdges edges',
    );
  }

  Future<void> _pickShapeForNode(_NodeModel node) async {
    final picked = await showModalBottomSheet<_NodeShape>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.92,
            ),
            itemCount: _NodeShape.values.length,
            itemBuilder: (context, i) {
              final s = _NodeShape.values[i];
              final sel = node.shape == s;
              return Material(
                color: sel
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  onTap: () => Navigator.pop(context, s),
                  borderRadius: BorderRadius.circular(12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(_iconForShape(s), size: 28),
                      const SizedBox(height: 4),
                      Text(
                        s.name,
                        style: Theme.of(context).textTheme.labelSmall,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _commit(() => node.shape = picked);
    setState(() {});
  }

  Future<void> _editText(_NodeModel node) async {
    final ctl = TextEditingController(text: node.text);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sửa chữ trong object'),
        content: TextField(
          controller: ctl,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Nhập nội dung hiển thị trên object',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _commit(() => node.text = ctl.text.trim());
    setState(() {});
  }

  Future<void> _editBottomText(_NodeModel node) async {
    final ctl = TextEditingController(text: node.bottomText);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sửa chữ dưới object'),
        content: TextField(
          controller: ctl,
          maxLines: 2,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Nhập text hiển thị bên dưới object',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _commit(() => node.bottomText = ctl.text.trim());
    setState(() {});
  }

  Future<void> _editOutsideText(_NodeModel node) async {
    final ctl = TextEditingController(text: node.outsideText);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sửa chữ dưới cả khối object'),
        content: TextField(
          controller: ctl,
          maxLines: 2,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Text nằm dưới toàn bộ object',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    _commit(() => node.outsideText = ctl.text.trim());
    setState(() {});
  }

  Future<void> _uploadImageToSelected() async {
    if (_selectedIds.length != 1) return;
    await _uploadImage(_nodeById(_selectedIds.first));
  }

  Future<void> _uploadImage(_NodeModel node) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    final bytes = result?.files.single.bytes;
    if (bytes == null) return;
    _commit(() => node.imageBytes = bytes);
    setState(() {});
  }

  Future<void> _pickColorForSelection() async {
    if (_selectedIds.isEmpty) return;
    final choices = <Color>[
      const Color(0xFFFFFFFF),
      const Color(0xFF5B8CFF),
      const Color(0xFF34C759),
      const Color(0xFFFF9500),
      const Color(0xFFAF52DE),
      const Color(0xFFFF3B30),
      const Color(0xFF30B0C7),
      const Color(0xFF8E8E93),
      const Color(0xFF1C1C1E),
    ];
    Color selected = _createColor;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Màu nền object'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: choices
              .map(
                (c) => GestureDetector(
                  onTap: () {
                    selected = c;
                    Navigator.pop(context, true);
                  },
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.black26),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
    );
    if (ok != true) return;
    _commit(() {
      _createColor = selected;
      for (final id in _selectedIds) {
        _nodeById(id).color = selected;
      }
    });
    setState(() {});
  }

  Future<void> _groupSelected() async {
    if (_selectedIds.length < 2) return;
    final ctl = TextEditingController(text: 'Group $_groupCounter');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Đặt tên group'),
        content: TextField(
          controller: ctl,
          decoration: const InputDecoration(
            labelText: 'Tên group',
            hintText: 'Ví dụ: Team A',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final groupName = ctl.text.trim().isEmpty
        ? 'Group $_groupCounter'
        : ctl.text.trim();
    _commit(() {
      _groups.add(
        _GroupModel(
          id: _nextGroupId(),
          name: groupName,
          color: Colors.indigo,
          nodeIds: {..._selectedIds},
        ),
      );
    });
    setState(() {});
  }

  _GroupModel? _currentGroupForSelection() {
    if (_selectedIds.isEmpty) return null;
    for (final g in _groups) {
      if (_selectedIds.any((id) => g.nodeIds.contains(id))) {
        return g;
      }
    }
    return null;
  }

  Future<void> _renameCurrentGroup() async {
    final g = _currentGroupForSelection();
    if (g == null) return;
    final ctl = TextEditingController(text: g.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename group'),
        content: TextField(
          controller: ctl,
          decoration: const InputDecoration(labelText: 'Group name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final next = ctl.text.trim();
    if (next.isEmpty) return;
    _commit(() => g.name = next);
    setState(() {});
  }

  void _ungroupSelected() {
    _commit(() {
      for (final g in _groups) {
        g.nodeIds.removeWhere((id) => _selectedIds.contains(id));
      }
      _groups.removeWhere((g) => g.nodeIds.length < 2);
      _removeDanglingEdges();
    });
    setState(() {});
  }

  void _deleteSelection() {
    if (_selectedIds.isEmpty &&
        _selectedEdgeIndex == null &&
        _selectedTextId == null) {
      return;
    }
    _commit(() {
      if (_selectedTextId != null) {
        _textNotes.removeWhere((t) => t.id == _selectedTextId);
        _selectedTextId = null;
        _editingTextId = null;
        _showTextStylePanel = false;
      } else if (_selectedIds.isNotEmpty) {
        final ids = {..._selectedIds};
        _nodes.removeWhere((n) => ids.contains(n.id));
        _edges.removeWhere((e) => ids.contains(e.from) || ids.contains(e.to));
        for (final g in _groups) {
          g.nodeIds.removeWhere(ids.contains);
        }
        _groups.removeWhere((g) => g.nodeIds.length < 2);
        _removeDanglingEdges();
        _selectedIds.clear();
      } else if (_selectedEdgeIndex != null &&
          _selectedEdgeIndex! >= 0 &&
          _selectedEdgeIndex! < _edges.length) {
        _edges.removeAt(_selectedEdgeIndex!);
      }
      _selectedEdgeIndex = null;
      _connectFromNodeId = null;
    });
    setState(() {});
  }

  String? _hitNodeAtScreen(Offset screen) {
    for (final n in _nodes.reversed) {
      final topLeft = _controller.worldToScreen(n.position);
      final rect = Rect.fromLTWH(
        topLeft.dx,
        topLeft.dy,
        n.size.width,
        n.size.height,
      );
      if (rect.inflate(4).contains(screen)) return n.id;
    }
    return null;
  }

  String? _hitTextAtScreen(Offset screen) {
    for (final t in _textNotes.reversed) {
      final topLeft = _controller.worldToScreen(t.position);
      final approxWidth = math.max(60.0, t.text.length * t.fontSize * 0.55);
      final rect = Rect.fromLTWH(
        topLeft.dx - 6,
        topLeft.dy - 6,
        approxWidth + 12,
        t.fontSize + 24,
      );
      if (rect.contains(screen)) return t.id;
    }
    return null;
  }

  Rect? _groupWorldRect(_GroupModel g) {
    final groupNodes = <_NodeModel>[];
    for (final id in g.nodeIds) {
      for (final n in _nodes) {
        if (n.id == id) {
          groupNodes.add(n);
          break;
        }
      }
    }
    if (groupNodes.length < 2) return null;
    final rects = groupNodes
        .map(
          (n) => Rect.fromLTWH(
            n.position.dx,
            n.position.dy,
            n.size.width,
            n.size.height,
          ),
        )
        .toList();
    final left = rects.map((r) => r.left).reduce((a, b) => a < b ? a : b);
    final top = rects.map((r) => r.top).reduce((a, b) => a < b ? a : b);
    final right = rects.map((r) => r.right).reduce((a, b) => a > b ? a : b);
    final bottom = rects.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
    return Rect.fromLTRB(left, top, right, bottom).inflate(26);
  }

  String? _hitGroupAtScreen(Offset screen) {
    for (final g in _groups.reversed) {
      final world = _groupWorldRect(g);
      if (world == null) continue;
      final p1 = _controller.worldToScreen(world.topLeft);
      final p2 = _controller.worldToScreen(world.bottomRight);
      final screenRect = Rect.fromPoints(p1, p2).inflate(8);
      if (screenRect.contains(screen)) return g.id;
    }
    return null;
  }

  bool _edgeEndpointExists(String id) {
    if (_nodes.any((n) => n.id == id)) return true;
    for (final g in _groups) {
      if (g.id == id) return _groupWorldRect(g) != null;
    }
    return false;
  }

  Offset? _endpointWorldCenter(String id) {
    for (final node in _nodes) {
      if (node.id == id) {
        return node.position +
            Offset(node.size.width / 2, node.size.height / 2);
      }
    }
    for (final group in _groups) {
      if (group.id == id) return _groupWorldRect(group)?.center;
    }
    return null;
  }

  Rect? _groupRectById(String id) {
    for (final g in _groups) {
      if (g.id == id) return _groupWorldRect(g);
    }
    return null;
  }

  Offset _pointOnRectBorderToward(Rect rect, Offset toward) {
    final c = rect.center;
    final dx = toward.dx - c.dx;
    final dy = toward.dy - c.dy;
    if (dx.abs() < 1e-6 && dy.abs() < 1e-6) return c;
    final hw = rect.width / 2;
    final hh = rect.height / 2;
    if (dx.abs() * hh > dy.abs() * hw) {
      final x = c.dx + (dx >= 0 ? hw : -hw);
      final y = c.dy + dy * (hw / dx.abs());
      return Offset(x, y);
    }
    final y = c.dy + (dy >= 0 ? hh : -hh);
    final x = c.dx + dx * (hh / dy.abs());
    return Offset(x, y);
  }

  (Offset, Offset)? _edgeWorldEndpoints(_EdgeModel e) {
    final fromCenter = _endpointWorldCenter(e.from);
    final toCenter = _endpointWorldCenter(e.to);
    if (fromCenter == null || toCenter == null) return null;
    Offset start = fromCenter;
    Offset end = toCenter;
    for (final n in _nodes) {
      if (n.id == e.from) {
        start = _nodePortWorld(n, e.fromPort);
      }
      if (n.id == e.to) {
        end = _nodePortWorld(n, e.toPort);
      }
    }
    final fromGroupRect = _groupRectById(e.from);
    if (fromGroupRect != null) {
      start = _pointOnRectBorderToward(fromGroupRect, toCenter);
    }
    final toGroupRect = _groupRectById(e.to);
    if (toGroupRect != null) {
      end = _pointOnRectBorderToward(toGroupRect, fromCenter);
    }
    return (start, end);
  }

  void _removeDanglingEdges() {
    _edges.removeWhere(
      (e) => !_edgeEndpointExists(e.from) || !_edgeEndpointExists(e.to),
    );
  }

  int? _hitEdgeAtScreen(Offset screen) {
    const threshold = 10.0;
    for (int i = _edges.length - 1; i >= 0; i--) {
      final e = _edges[i];
      final endpoints = _edgeWorldEndpoints(e);
      if (endpoints == null) continue;
      final p0 = _controller.worldToScreen(endpoints.$1);
      final p1 = _controller.worldToScreen(endpoints.$2);
      final path = _edgePathFromScreenPoints(p0, p1, e);
      for (final metric in path.computeMetrics()) {
        for (double d = 0; d <= metric.length; d += 10) {
          final tan = metric.getTangentForOffset(d);
          if (tan == null) continue;
          if ((tan.position - screen).distance <= threshold) return i;
        }
      }
    }
    return null;
  }

  Path _edgePathFromScreenPoints(Offset p0, Offset p1, _EdgeModel edge) {
    return _edgePathForRoute(
      p0,
      p1,
      edge.route,
      bend: edge.bend,
      elbow: edge.elbow,
    );
  }

  ui.PathMetric? _edgeMetricForScreen(_EdgeModel e) {
    final endpoints = _edgeWorldEndpoints(e);
    if (endpoints == null) return null;
    final p0 = _controller.worldToScreen(endpoints.$1);
    final p1 = _controller.worldToScreen(endpoints.$2);
    final path = _edgePathFromScreenPoints(p0, p1, e);
    final metrics = path.computeMetrics().toList(growable: false);
    if (metrics.isEmpty) return null;
    return metrics.first;
  }

  (Offset center, Rect hitRect)? _edgeLabelScreenCenter(int edgeIndex) {
    if (edgeIndex < 0 || edgeIndex >= _edges.length) return null;
    final e = _edges[edgeIndex];
    if (e.label.trim().isEmpty) return null;
    final metric = _edgeMetricForScreen(e);
    if (metric == null || metric.length <= 1) return null;
    final t = e.labelT.clamp(0.05, 0.95).toDouble();
    final tan = metric.getTangentForOffset(metric.length * t);
    if (tan == null) return null;
    var angle = tan.angle;
    if (angle > math.pi / 2 || angle < -math.pi / 2) {
      angle += math.pi;
    }
    final normal = Offset(-math.sin(angle), math.cos(angle));
    final center = tan.position + normal * e.labelOffset;
    final tp = TextPainter(
      text: TextSpan(
        text: e.label,
        style: TextStyle(
          color: e.labelColor,
          fontWeight: FontWeight.w600,
          fontSize: e.labelSize,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 260);
    final hitRect = Rect.fromCenter(
      center: center,
      width: tp.width + 20,
      height: tp.height + 18,
    );
    return (center, hitRect);
  }

  int? _hitEdgeLabelAtScreen(Offset screen) {
    for (int i = _edges.length - 1; i >= 0; i--) {
      final layout = _edgeLabelScreenCenter(i);
      if (layout == null) continue;
      if (layout.$2.contains(screen)) return i;
    }
    return null;
  }

  void _dragActiveEdgeLabel(Offset screen) {
    final i = _activeEdgeLabelDragIndex;
    if (i == null || i < 0 || i >= _edges.length) return;
    final e = _edges[i];
    final metric = _edgeMetricForScreen(e);
    if (metric == null || metric.length <= 1) return;

    double bestOffset = 0;
    double bestDist = double.infinity;
    const step = 6.0;
    for (double d = 0; d <= metric.length; d += step) {
      final tan = metric.getTangentForOffset(d);
      if (tan == null) continue;
      final dist = (tan.position - screen).distance;
      if (dist < bestDist) {
        bestDist = dist;
        bestOffset = d;
      }
    }
    final tan = metric.getTangentForOffset(bestOffset);
    if (tan == null) return;
    var angle = tan.angle;
    if (angle > math.pi / 2 || angle < -math.pi / 2) {
      angle += math.pi;
    }
    final normal = Offset(-math.sin(angle), math.cos(angle));
    final toPointer = screen - tan.position;
    final normalOffset = (toPointer.dx * normal.dx + toPointer.dy * normal.dy)
        .clamp(-120.0, 120.0);
    setState(() {
      _edges[i] = _edges[i].copyWith(
        labelT: (bestOffset / metric.length).clamp(0.05, 0.95),
        labelOffset: normalOffset.toDouble(),
      );
    });
  }

  /// Open the add node dialog for creating a new family tree member
  void _openAddNodeDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AddNodeChatDialog(
        availableNodeIds: _nodes.map((n) => n.id).toList(),
        availableNodeLabels: {for (final node in _nodes) node.id: node.text},
        availableNodeInfos: {
          for (final node in _nodes) node.id: _extractInfoFromNode(node),
        },
        onNodeCreated: _handleNewNodeCreated,
        onNodeUpdated: _handleNodeUpdated,
      ),
    );
  }

  ExtractedNodeInfo _extractInfoFromNode(_NodeModel node) {
    final md = node.metadata;
    final birthdayRaw = (md['Birthday'] ?? node.birthday).trim();
    final deathRaw = (md['DeadDay'] ?? '').trim();
    final isDead = (md['IsDead'] ?? '').trim().toLowerCase() == 'true';

    String normalizeDate(String raw) {
      if (raw.isEmpty) return '';
      final v = raw.contains('T') ? raw.split('T').first : raw;
      return v;
    }

    return ExtractedNodeInfo(
      fullName: node.text.trim().isEmpty ? null : node.text.trim(),
      aliasName: (md['AliasName'] ?? '').trim().isEmpty
          ? null
          : (md['AliasName'] ?? '').trim(),
      sex: node.sex.trim().isEmpty ? null : node.sex.trim(),
      birthday: normalizeDate(birthdayRaw).isEmpty
          ? null
          : normalizeDate(birthdayRaw),
      deathDay: normalizeDate(deathRaw).isEmpty
          ? null
          : normalizeDate(deathRaw),
      description: node.description.trim().isEmpty ? null : node.description,
      parentId: (md['Parent'] ?? node.parentId).trim().isEmpty
          ? null
          : (md['Parent'] ?? node.parentId).trim(),
      motherId: (md['MotherID'] ?? '').trim().isEmpty
          ? null
          : (md['MotherID'] ?? '').trim(),
      spouseId: (md['SpouseID'] ?? '').trim().isEmpty
          ? null
          : (md['SpouseID'] ?? '').trim(),
      imageBytes: node.imageBytes,
      imageUrl: (md['ImageUrl'] ?? '').trim().isEmpty
          ? null
          : (md['ImageUrl'] ?? '').trim(),
      level: node.level,
      branch: int.tryParse((md['Branch'] ?? '').trim()),
      hand: int.tryParse((md['Hand'] ?? '').trim()),
      familyNameGroup: (md['FamilyNameGroup'] ?? '').trim().isEmpty
          ? null
          : (md['FamilyNameGroup'] ?? '').trim(),
      cityProvince: (md['CityProvince'] ?? '').trim().isEmpty
          ? null
          : (md['CityProvince'] ?? '').trim(),
      district: (md['Dicstrict'] ?? '').trim().isEmpty
          ? null
          : (md['Dicstrict'] ?? '').trim(),
      wards: (md['Wards'] ?? '').trim().isEmpty
          ? null
          : (md['Wards'] ?? '').trim(),
      addressFull: (md['AddressFull'] ?? '').trim().isEmpty
          ? null
          : (md['AddressFull'] ?? '').trim(),
      confirmedAlive: !isDead,
    );
  }

  void _handleNodeUpdated(String nodeId, ExtractedNodeInfo info) {
    _commit(() {
      final node = _nodeById(nodeId);

      node.text = (info.fullName?.trim().isNotEmpty == true)
          ? info.fullName!.trim()
          : node.text;
      node.sex = (info.sex ?? node.sex).trim();
      node.birthday = (info.birthday ?? node.birthday).trim();
      node.description = (info.description ?? node.description).trim();
      node.parentId = _normalizePersonRef(info.parentId);
      node.imageBytes = info.imageBytes ?? node.imageBytes;
      node.bottomText = node.sex;
      node.outsideText = node.description;

      final md = Map<String, String>.from(node.metadata);
      void putOrRemove(String key, String value) {
        if (value.trim().isEmpty) {
          md.remove(key);
        } else {
          md[key] = value.trim();
        }
      }

      putOrRemove('Birthday', node.birthday);
      putOrRemove('DeadDay', info.deathDay ?? '');
      md['IsDead'] = (info.deathDay?.trim().isNotEmpty == true)
          ? 'true'
          : 'false';
      putOrRemove('Parent', _normalizePersonRef(info.parentId));
      putOrRemove('MotherID', _normalizePersonRef(info.motherId));
      putOrRemove('SpouseID', _normalizePersonRef(info.spouseId));
      putOrRemove('Description', node.description);
      putOrRemove('AliasName', info.aliasName ?? '');
      putOrRemove('FamilyNameGroup', info.familyNameGroup ?? '');
      putOrRemove('CityProvince', info.cityProvince ?? '');
      putOrRemove('Dicstrict', info.district ?? '');
      putOrRemove('Wards', info.wards ?? '');
      putOrRemove('AddressFull', info.addressFull ?? '');
      putOrRemove('ImageUrl', info.imageUrl ?? '');
      md['HasImage'] =
          ((node.imageBytes != null) ||
              (info.imageUrl?.trim().isNotEmpty == true))
          ? 'true'
          : 'false';

      node.metadata = md;

      final isDead = (md['IsDead'] ?? '').trim().toLowerCase() == 'true';
      node.borderColor = _generationNodeColor(node.level, isDead: isDead);

      final parentId = _normalizePersonRef(info.parentId);
      final motherId = _normalizePersonRef(info.motherId);
      final spouseId = _normalizePersonRef(info.spouseId);

      final expectedFamilyFrom = <String>{
        if (parentId.isNotEmpty) parentId,
        if (motherId.isNotEmpty) motherId,
      };
      _edges.removeWhere(
        (edge) =>
            edge.route == _EdgeRoute.familyTree &&
            edge.to == nodeId &&
            !expectedFamilyFrom.contains(edge.from),
      );

      if (spouseId.isEmpty) {
        _edges.removeWhere(
          (edge) =>
              edge.route == _EdgeRoute.spouse &&
              (edge.from == nodeId || edge.to == nodeId),
        );
      } else {
        _edges.removeWhere(
          (edge) =>
              edge.route == _EdgeRoute.spouse &&
              (edge.from == nodeId || edge.to == nodeId) &&
              edge.from != spouseId &&
              edge.to != spouseId,
        );
      }

      if (parentId.isNotEmpty) {
        _ensureRelationEdge(parentId, nodeId, route: _EdgeRoute.familyTree);
      }
      if (motherId.isNotEmpty) {
        _ensureRelationEdge(motherId, nodeId, route: _EdgeRoute.familyTree);
      }
      if (spouseId.isNotEmpty) {
        _ensureRelationEdge(spouseId, nodeId, route: _EdgeRoute.spouse);
      }
      _refreshFamilyEdgeLabelsForChild(nodeId);
      _syncFamilyLayoutFromEdges();
      _selectedIds = {nodeId};
    });

    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã cập nhật ${info.fullName ?? 'node'}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _normalizePersonRef(String? value) {
    if (value == null) return '';
    final v = value.trim();
    if (v.isEmpty || v == kNoRelationMarker) return '';
    return v;
  }

  int? _levelFromNode(String nodeId) {
    final node = _nodes
        .where((n) => n.id == nodeId)
        .cast<_NodeModel?>()
        .firstWhere((n) => n != null, orElse: () => null);
    return node?.level;
  }

  int _deriveLevelForNewNode(ExtractedNodeInfo nodeInfo) {
    final parentLevels = <int>[];
    for (final relationId in <String?>[nodeInfo.parentId, nodeInfo.motherId]) {
      final id = relationId?.trim() ?? '';
      if (id.isEmpty) continue;
      final level = _levelFromNode(id);
      if (level != null) parentLevels.add(level);
    }
    if (parentLevels.isNotEmpty) {
      return parentLevels.reduce(math.max) + 1;
    }

    final spouseId = nodeInfo.spouseId?.trim() ?? '';
    if (spouseId.isNotEmpty) {
      final spouseLevel = _levelFromNode(spouseId);
      if (spouseLevel != null) return spouseLevel;
    }

    return nodeInfo.level ?? 1;
  }

  void _syncFamilyLayoutFromEdges() {
    final nodeIds = _nodes.map((node) => node.id).toSet();
    final parentPairs = _edges
        .where((edge) => edge.route == _EdgeRoute.familyTree)
        .map((edge) => MapEntry(edge.from, edge.to))
        .toList();
    final spousePairs = _edges
        .where((edge) => edge.route == _EdgeRoute.spouse)
        .map((edge) => MapEntry(edge.from, edge.to))
        .toList();
    final sexById = {for (final node in _nodes) node.id: node.sex};
    final levelById = {
      for (final node in _nodes)
        if (node.level != null) node.id: node.level!,
    };
    final autoPos = _layoutTreeLike(
      nodeIds,
      parentPairs,
      spousePairs: spousePairs,
      sexById: sexById,
      levelById: levelById,
    );
    for (final node in _nodes) {
      node.position = autoPos[node.id] ?? node.position;
    }
  }

  void _ensureRelationEdge(
    String fromId,
    String toId, {
    required _EdgeRoute route,
  }) {
    if (fromId.trim().isEmpty || toId.trim().isEmpty || fromId == toId) {
      return;
    }
    final exists = _edges.any((edge) {
      if (edge.route != route) return false;
      if (route == _EdgeRoute.spouse) {
        return (edge.from == fromId && edge.to == toId) ||
            (edge.from == toId && edge.to == fromId);
      }
      return edge.from == fromId && edge.to == toId;
    });
    if (exists) return;

    final fromNode = _tryNodeById(fromId);
    final toNode = _tryNodeById(toId);
    if (fromNode == null || toNode == null) {
      return;
    }
    final level = toNode.level ?? fromNode.level;
    final isDead =
        (fromNode.metadata['IsDead'] ?? '').trim().toLowerCase() == 'true' ||
        (toNode.metadata['IsDead'] ?? '').trim().toLowerCase() == 'true';

    final familyLabel = route == _EdgeRoute.familyTree
        ? _buildFamilyEdgeLabel(toId)
        : '';

    _edges.add(
      _EdgeModel(
        from: fromId,
        to: toId,
        fromPort: route == _EdgeRoute.spouse
            ? _EdgePort.spouseBottom
            : _EdgePort.bottom,
        toPort: route == _EdgeRoute.spouse
            ? _EdgePort.spouseBottom
            : _EdgePort.top,
        route: route,
        color: _generationEdgeColor(level, isDead: isDead),
        label: familyLabel,
        labelSize: route == _EdgeRoute.familyTree ? 10 : 12,
        labelOffset: route == _EdgeRoute.familyTree ? 14 : 10,
        arrow: route != _EdgeRoute.spouse,
      ),
    );
  }

  _NodeModel? _tryNodeById(String id) {
    for (final node in _nodes) {
      if (node.id == id) return node;
    }
    return null;
  }

  String _resolveNodeDisplayName(String rawId) {
    final id = rawId.trim();
    if (id.isEmpty) return '';
    final node = _tryNodeById(id);
    if (node == null) return id;
    final name = node.text.trim();
    if (name.isEmpty || name.toLowerCase() == 'null') return id;
    return name;
  }

  String _buildFamilyEdgeLabel(String childId) {
    final child = _tryNodeById(childId);
    if (child == null) return '';
    final fatherId = child.parentId.trim();
    final motherId = (child.metadata['MotherID'] ?? '').trim();
    final father = _resolveNodeDisplayName(fatherId);
    final mother = _resolveNodeDisplayName(motherId);
    if (father.isNotEmpty && mother.isNotEmpty) {
      return 'Bố: $father • Mẹ: $mother';
    }
    if (father.isNotEmpty) return 'Bố: $father';
    if (mother.isNotEmpty) return 'Mẹ: $mother';
    return '';
  }

  void _refreshFamilyEdgeLabelsForChild(String childId) {
    final label = _buildFamilyEdgeLabel(childId);
    for (int i = 0; i < _edges.length; i++) {
      final edge = _edges[i];
      if (edge.route != _EdgeRoute.familyTree || edge.to != childId) {
        continue;
      }
      _edges[i] = edge.copyWith(label: label, labelSize: 10, labelOffset: 14);
    }
  }

  /// Handle the creation of a new node from chat dialog
  void _handleNewNodeCreated(ExtractedNodeInfo nodeInfo) {
    _commit(() {
      final newNodeId = _nextNodeId();
      final level = _deriveLevelForNewNode(nodeInfo);
      final size = const Size(170, 118);
      final basePosition = _controller.screenToWorld(
        MediaQuery.of(context).size.center(Offset.zero),
      );

      final metadata = <String, String>{};
      if (nodeInfo.birthday != null && nodeInfo.birthday!.isNotEmpty) {
        metadata['Birthday'] = nodeInfo.birthday!;
      }
      if (nodeInfo.deathDay != null && nodeInfo.deathDay!.isNotEmpty) {
        metadata['DeadDay'] = nodeInfo.deathDay!;
        metadata['IsDead'] = 'true';
      }
      if (nodeInfo.parentId != null && nodeInfo.parentId!.isNotEmpty) {
        metadata['Parent'] = nodeInfo.parentId!;
      }
      if (nodeInfo.motherId != null && nodeInfo.motherId!.isNotEmpty) {
        metadata['MotherID'] = nodeInfo.motherId!;
      }
      if (nodeInfo.spouseId != null && nodeInfo.spouseId!.isNotEmpty) {
        metadata['SpouseID'] = nodeInfo.spouseId!;
      }
      if (nodeInfo.imageUrl != null && nodeInfo.imageUrl!.isNotEmpty) {
        metadata['ImageUrl'] = nodeInfo.imageUrl!;
      }
      metadata['HasImage'] =
          ((nodeInfo.imageBytes != null) ||
              (nodeInfo.imageUrl != null && nodeInfo.imageUrl!.isNotEmpty))
          ? 'true'
          : 'false';
      if (nodeInfo.description != null && nodeInfo.description!.isNotEmpty) {
        metadata['Description'] = nodeInfo.description!;
      }
      if (nodeInfo.aliasName != null && nodeInfo.aliasName!.isNotEmpty) {
        metadata['AliasName'] = nodeInfo.aliasName!;
      }
      if (nodeInfo.familyNameGroup != null &&
          nodeInfo.familyNameGroup!.isNotEmpty) {
        metadata['FamilyNameGroup'] = nodeInfo.familyNameGroup!;
      }
      if (nodeInfo.cityProvince != null && nodeInfo.cityProvince!.isNotEmpty) {
        metadata['CityProvince'] = nodeInfo.cityProvince!;
      }
      if (nodeInfo.district != null && nodeInfo.district!.isNotEmpty) {
        metadata['Dicstrict'] = nodeInfo.district!;
      }
      if (nodeInfo.wards != null && nodeInfo.wards!.isNotEmpty) {
        metadata['Wards'] = nodeInfo.wards!;
      }
      if (nodeInfo.addressFull != null && nodeInfo.addressFull!.isNotEmpty) {
        metadata['AddressFull'] = nodeInfo.addressFull!;
      }
      if (nodeInfo.confirmedAlive &&
          (nodeInfo.deathDay == null || nodeInfo.deathDay!.isEmpty)) {
        metadata['IsDead'] = 'false';
      }

      final newNode = _NodeModel(
        id: newNodeId,
        position: basePosition + const Offset(40, 40),
        size: size,
        shape: _NodeShape.rect,
        text: nodeInfo.fullName ?? 'Không tên',
        color: Colors.white,
        textColor: const Color(0xFF1E293B),
        borderColor: _generationNodeColor(
          level,
          isDead: nodeInfo.deathDay != null && nodeInfo.deathDay!.isNotEmpty,
        ),
        borderWidth: 2.0,
        shadowBlur: 10.0,
        shadowOpacity: 0.16,
        sex: nodeInfo.sex ?? '',
        birthday: nodeInfo.birthday ?? '',
        description: nodeInfo.description ?? '',
        parentId: nodeInfo.parentId ?? '',
        imageBytes: nodeInfo.imageBytes,
        level: level,
        bottomText: nodeInfo.sex ?? '',
        outsideText: nodeInfo.description ?? '',
        metadata: metadata,
      );

      _nodes.add(newNode);
      if (nodeInfo.parentId != null && nodeInfo.parentId!.isNotEmpty) {
        _ensureRelationEdge(
          nodeInfo.parentId!,
          newNodeId,
          route: _EdgeRoute.familyTree,
        );
      }
      if (nodeInfo.motherId != null && nodeInfo.motherId!.isNotEmpty) {
        _ensureRelationEdge(
          nodeInfo.motherId!,
          newNodeId,
          route: _EdgeRoute.familyTree,
        );
      }
      if (nodeInfo.spouseId != null && nodeInfo.spouseId!.isNotEmpty) {
        _ensureRelationEdge(
          nodeInfo.spouseId!,
          newNodeId,
          route: _EdgeRoute.spouse,
        );
      }
      _refreshFamilyEdgeLabelsForChild(newNodeId);
      _syncFamilyLayoutFromEdges();
      _selectedIds = {newNodeId};
      _selectedEdgeIndex = null;
    });

    setState(() {});
    _fitToAllNodes();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã thêm ${nodeInfo.fullName}'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

class _ActivePortDrag {
  final String fromNodeId;
  final _EdgePort fromPort;
  final _ConnectKind kind;
  final Offset startWorld;
  final Offset currentWorld;

  const _ActivePortDrag({
    required this.fromNodeId,
    required this.fromPort,
    required this.kind,
    required this.startWorld,
    required this.currentWorld,
  });

  _ActivePortDrag copyWith({Offset? currentWorld}) => _ActivePortDrag(
    fromNodeId: fromNodeId,
    fromPort: fromPort,
    kind: kind,
    startWorld: startWorld,
    currentWorld: currentWorld ?? this.currentWorld,
  );
}

class _PortHit {
  final String endpointId;
  final _EdgePort port;
  const _PortHit({required this.endpointId, required this.port});
}

class _TextNoteWidget extends StatefulWidget {
  final _TextNoteModel note;
  final bool selected;
  final bool editing;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final ValueChanged<String> onTextChanged;
  final VoidCallback onSubmit;

  const _TextNoteWidget({
    required this.note,
    required this.selected,
    required this.editing,
    required this.onTap,
    required this.onDoubleTap,
    required this.onTextChanged,
    required this.onSubmit,
  });

  @override
  State<_TextNoteWidget> createState() => _TextNoteWidgetState();
}

class _TextNoteWidgetState extends State<_TextNoteWidget> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.note.text);
  }

  @override
  void didUpdateWidget(covariant _TextNoteWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.text != widget.note.text &&
        _controller.text != widget.note.text) {
      _controller.text = widget.note.text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: widget.note.fontSize,
      color: widget.note.color,
      fontWeight: widget.note.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: widget.note.italic ? FontStyle.italic : FontStyle.normal,
    );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: widget.onTap,
      onDoubleTap: widget.onDoubleTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 90),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.editing
                ? Colors.white.withValues(alpha: 0.9)
                : Colors.transparent,
            border: widget.selected
                ? Border.all(color: Colors.blueAccent.withValues(alpha: 0.7))
                : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: widget.editing
                ? SizedBox(
                    width: 200,
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      style: style,
                      minLines: 1,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Nhập text...',
                      ),
                      onChanged: widget.onTextChanged,
                      onSubmitted: (_) => widget.onSubmit(),
                    ),
                  )
                : Text(
                    widget.note.text,
                    style: style,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        ),
      ),
    );
  }
}

class _NodeWidget extends StatefulWidget {
  final _NodeModel node;
  final bool selected;
  final _CanvasTool tool;
  final double fxValue;
  final VoidCallback onTap;
  final VoidCallback onDoubleTapEdit;
  final ValueChanged<TapDownDetails> onSecondaryTapDown;
  final ValueChanged<Offset> onMoved;
  final ValueChanged<Size> onResize;
  final void Function(_EdgePort, _ConnectKind) onStartConnectFromPort;

  const _NodeWidget({
    required this.node,
    required this.selected,
    required this.tool,
    required this.fxValue,
    required this.onTap,
    required this.onDoubleTapEdit,
    required this.onSecondaryTapDown,
    required this.onMoved,
    required this.onResize,
    required this.onStartConnectFromPort,
  });

  @override
  State<_NodeWidget> createState() => _NodeWidgetState();
}

class _NodeWidgetState extends State<_NodeWidget> {
  Offset? _lastGlobal;
  Offset? _lastResizeGlobal;

  @override
  Widget build(BuildContext context) {
    final scope = CanvasKitScope.of(context);
    final s = widget.node.size;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeW = (s.width * dpr).clamp(64.0, 1024.0).round();
    final decodeH = (s.height * dpr).clamp(64.0, 1024.0).round();
    final path = _shapePath(s, widget.node.shape);
    final blinkPulse = widget.node.blink
        ? (0.55 + 0.45 * math.sin(widget.fxValue * math.pi * 2))
        : 1.0;
    final mainText = widget.node.text.trim();
    final bottomText = widget.node.bottomText.trim();
    String? extractYear(String raw) {
      final text = raw.trim();
      if (text.isEmpty || text == '-') return null;
      final hit = RegExp(r'(1[0-9]{3}|20[0-9]{2}|2100)').firstMatch(text);
      return hit?.group(0);
    }

    final birthRaw = widget.node.birthday.trim().isNotEmpty
        ? widget.node.birthday
        : (widget.node.metadata['BirthdayTEXT'] ?? '');
    final birthYear = extractYear(birthRaw);
    final deathRaw = <String>[
      widget.node.metadata['DeadDay'] ?? '',
      widget.node.metadata['DeathDate'] ?? '',
      widget.node.metadata['DiedAt'] ?? '',
      widget.node.metadata['YearOfDeath'] ?? '',
      widget.node.metadata['NamMat'] ?? '',
      widget.node.metadata['PassedAwayDate'] ?? '',
      widget.node.metadata['LunarDeadDay'] ?? '',
    ].firstWhere((v) => v.trim().isNotEmpty, orElse: () => '');
    final deathYear = extractYear(deathRaw);
    final isDeadFlag =
        (widget.node.metadata['IsDead'] ?? '').trim().toLowerCase() == 'true';
    final lifeYearsText = birthYear != null && deathYear != null
        ? '$birthYear - $deathYear'
        : birthYear != null && isDeadFlag
        ? '$birthYear - ?'
        : birthYear ?? (deathYear != null ? '? - $deathYear' : '');
    final imageCaption = mainText.isNotEmpty && bottomText.isNotEmpty
        ? '$mainText • $bottomText'
        : (mainText.isNotEmpty ? mainText : bottomText);
    final remoteImageUrl = _resolveWebImageUrl(
      (widget.node.metadata['ImageUrl'] ?? '').trim(),
    );
    final rawRemoteImageUrl = (widget.node.metadata['ImageUrl'] ?? '').trim();
    final remoteImageUrls = _resolveWebImageUrls(rawRemoteImageUrl);
    final canRenderRemoteImage =
        widget.node.imageBytes == null &&
        rawRemoteImageUrl.isNotEmpty &&
        _canLoadRemoteImageOnWeb(rawRemoteImageUrl) &&
        remoteImageUrl.isNotEmpty &&
        remoteImageUrls.isNotEmpty;

    final base = Stack(
      children: [
        ClipPath(
          clipper: _NodeShapeClipper(widget.node.shape),
          child: SizedBox(
            width: s.width,
            height: s.height,
            child: (widget.node.imageBytes != null || canRenderRemoteImage)
                ? Column(
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (widget.node.imageBytes != null)
                              Image.memory(
                                widget.node.imageBytes!,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.low,
                                cacheWidth: decodeW,
                                cacheHeight: decodeH,
                                gaplessPlayback: true,
                              )
                            else
                              _FallbackNetworkImage(
                                urls: remoteImageUrls,
                                fit: BoxFit.cover,
                                fallbackColor: widget.node.color.withValues(
                                  alpha: 0.88,
                                ),
                              ),
                            Container(
                              color: Colors.black.withValues(alpha: 0.18),
                            ),
                          ],
                        ),
                      ),
                      if (imageCaption.isNotEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          color: widget.node.borderColor.withValues(alpha: 0.9),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                imageCaption,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                              if (lifeYearsText.isNotEmpty)
                                Text(
                                  lifeYearsText,
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        color: widget.node.color.withValues(alpha: 0.88),
                      ),
                      Container(color: Colors.black.withValues(alpha: 0.05)),
                      if (mainText.isNotEmpty)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              mainText,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: widget.node.textColor,
                                fontWeight: FontWeight.w700,
                                fontSize: widget.node.textSize,
                              ),
                            ),
                          ),
                        ),
                      if (bottomText.isNotEmpty)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            color: widget.node.borderColor.withValues(
                              alpha: 0.9,
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  bottomText,
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: widget.node.bottomTextColor,
                                    fontWeight: FontWeight.w600,
                                    fontSize: widget.node.bottomTextSize,
                                  ),
                                ),
                                if (lifeYearsText.isNotEmpty)
                                  Text(
                                    lifeYearsText,
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: widget.node.bottomTextColor
                                          .withValues(alpha: 0.92),
                                      fontWeight: FontWeight.w500,
                                      fontSize: (widget.node.bottomTextSize - 1)
                                          .clamp(9.0, 18.0),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        )
                      else if (lifeYearsText.isNotEmpty)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            color: widget.node.borderColor.withValues(
                              alpha: 0.9,
                            ),
                            child: Text(
                              lifeYearsText,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: widget.node.bottomTextColor,
                                fontWeight: FontWeight.w500,
                                fontSize: (widget.node.bottomTextSize - 1)
                                    .clamp(9.0, 18.0),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        CustomPaint(
          size: s,
          painter: _NodeBorderPainter(
            path: path,
            selected: widget.selected,
            borderColor: widget.node.borderColor,
            borderWidth: widget.node.borderWidth,
            shadowOpacity: widget.node.shadowOpacity,
            shadowBlur: widget.node.shadowBlur,
          ),
        ),
      ],
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onDoubleTap: widget.tool == _CanvasTool.cursor
          ? widget.onDoubleTapEdit
          : null,
      onSecondaryTapDown: widget.onSecondaryTapDown,
      // Mobile/tablet equivalent of right-click context menu.
      onLongPressStart: widget.tool != _CanvasTool.cursor
          ? null
          : (d) {
              widget.onSecondaryTapDown(
                TapDownDetails(
                  globalPosition: d.globalPosition,
                  localPosition: d.localPosition,
                ),
              );
            },
      onPanStart: widget.tool != _CanvasTool.cursor
          ? null
          : (d) {
              _lastGlobal = d.globalPosition;
              scope.controller.beginDrag(widget.node.id);
            },
      onPanUpdate: widget.tool != _CanvasTool.cursor
          ? null
          : (d) {
              final prev = _lastGlobal ?? d.globalPosition;
              final screenDelta = d.globalPosition - prev;
              _lastGlobal = d.globalPosition;
              final worldDelta = scope.controller.deltaScreenToWorld(
                screenDelta,
              );
              widget.onMoved(worldDelta);
            },
      onPanEnd: widget.tool != _CanvasTool.cursor
          ? null
          : (_) {
              scope.controller.endDrag(widget.node.id);
              _lastGlobal = null;
            },
      onPanCancel: widget.tool != _CanvasTool.cursor
          ? null
          : () {
              scope.controller.endDrag(widget.node.id);
              _lastGlobal = null;
            },
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Opacity(opacity: blinkPulse.clamp(0.0, 1.0), child: base),
          if (widget.node.outsideText.trim().isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              top: s.height + 6,
              child: Text(
                widget.node.outsideText,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: widget.node.outsideTextColor,
                  fontSize: widget.node.outsideTextSize,
                ),
              ),
            ),
          if (widget.tool == _CanvasTool.connect) ...[
            _portDot(
              Offset(s.width / 2 - _kPortRadius, s.height - _kPortRadius),
              _EdgePort.bottom,
              _ConnectKind.parentToChild,
              color: const Color(0xFF1B8E3E),
            ),
            _portDot(
              Offset(s.width / 2 - _kPortRadius + 18, s.height - _kPortRadius),
              _EdgePort.spouseBottom,
              _ConnectKind.spouse,
              color: const Color(0xFFD81B60),
            ),
          ],
          if (widget.selected && widget.tool == _CanvasTool.cursor)
            Positioned(
              right: -8,
              bottom: -8,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) {
                  _lastResizeGlobal = d.globalPosition;
                  scope.controller.beginDrag('${widget.node.id}-resize');
                },
                onPanUpdate: (d) {
                  final prev = _lastResizeGlobal ?? d.globalPosition;
                  final screenDelta = d.globalPosition - prev;
                  _lastResizeGlobal = d.globalPosition;
                  final worldDelta = scope.controller.deltaScreenToWorld(
                    screenDelta,
                  );
                  final next = Size(
                    (widget.node.size.width + worldDelta.dx).clamp(90.0, 420.0),
                    (widget.node.size.height + worldDelta.dy).clamp(
                      70.0,
                      320.0,
                    ),
                  );
                  widget.onResize(next);
                },
                onPanEnd: (_) {
                  scope.controller.endDrag('${widget.node.id}-resize');
                  _lastResizeGlobal = null;
                },
                onPanCancel: () {
                  scope.controller.endDrag('${widget.node.id}-resize');
                  _lastResizeGlobal = null;
                },
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.blueAccent, width: 2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(Icons.open_in_full, size: 10),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _portDot(
    Offset offset,
    _EdgePort port,
    _ConnectKind kind, {
    required Color color,
  }) {
    return Positioned(
      left: offset.dx,
      top: offset.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => widget.onStartConnectFromPort(port, kind),
        onPanStart: (_) => widget.onStartConnectFromPort(port, kind),
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NodeBorderPainter extends CustomPainter {
  final Path path;
  final bool selected;
  final Color borderColor;
  final double borderWidth;
  final double shadowOpacity;
  final double shadowBlur;
  const _NodeBorderPainter({
    required this.path,
    required this.selected,
    required this.borderColor,
    required this.borderWidth,
    required this.shadowOpacity,
    required this.shadowBlur,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (shadowOpacity > 0 && shadowBlur > 0) {
      canvas.drawShadow(
        path,
        Colors.black.withValues(alpha: shadowOpacity),
        shadowBlur,
        true,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? borderWidth + 1.2 : borderWidth
        ..color = selected ? Colors.blueAccent : borderColor,
    );
  }

  @override
  bool shouldRepaint(covariant _NodeBorderPainter oldDelegate) =>
      oldDelegate.path != path ||
      oldDelegate.selected != selected ||
      oldDelegate.borderColor != borderColor ||
      oldDelegate.borderWidth != borderWidth ||
      oldDelegate.shadowOpacity != shadowOpacity ||
      oldDelegate.shadowBlur != shadowBlur;
}

class _NodeShapeClipper extends CustomClipper<Path> {
  final _NodeShape shape;
  const _NodeShapeClipper(this.shape);

  @override
  Path getClip(Size size) => _shapePath(size, shape);

  @override
  bool shouldReclip(covariant _NodeShapeClipper oldClipper) =>
      oldClipper.shape != shape;
}

class _FallbackNetworkImage extends StatefulWidget {
  final List<String> urls;
  final BoxFit fit;
  final Color fallbackColor;

  const _FallbackNetworkImage({
    required this.urls,
    required this.fit,
    required this.fallbackColor,
  });

  @override
  State<_FallbackNetworkImage> createState() => _FallbackNetworkImageState();
}

class _FallbackNetworkImageState extends State<_FallbackNetworkImage> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty || _index >= widget.urls.length) {
      return ColoredBox(color: widget.fallbackColor);
    }

    return Image.network(
      widget.urls[_index],
      fit: widget.fit,
      filterQuality: FilterQuality.low,
      webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
      errorBuilder: (_, __, ___) {
        if (_index < widget.urls.length - 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() => _index++);
          });
          return ColoredBox(color: widget.fallbackColor);
        }
        return ColoredBox(color: widget.fallbackColor);
      },
    );
  }
}

IconData _iconForShape(_NodeShape shape) {
  switch (shape) {
    case _NodeShape.rect:
      return Icons.crop_5_4;
    case _NodeShape.square:
      return Icons.crop_square;
    case _NodeShape.circle:
      return Icons.circle_outlined;
    case _NodeShape.oval:
      return Icons.radio_button_unchecked;
    case _NodeShape.diamond:
      return Icons.diamond_outlined;
    case _NodeShape.triangle:
      return Icons.change_history;
    case _NodeShape.star:
      return Icons.star_border;
    case _NodeShape.hexagon:
      return Icons.hexagon_outlined;
    case _NodeShape.trapezoid:
      return Icons.view_week_outlined;
    case _NodeShape.parallelogram:
      return Icons.view_day_outlined;
    case _NodeShape.arrowRight:
      return Icons.arrow_forward_ios;
  }
}

Path _shapePath(Size size, _NodeShape shape) {
  final w = size.width;
  final h = size.height;
  switch (shape) {
    case _NodeShape.rect:
      return Path()..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      );
    case _NodeShape.square:
      final side = math.min(w, h);
      final dx = (w - side) / 2;
      final dy = (h - side) / 2;
      return Path()..addRect(Rect.fromLTWH(dx, dy, side, side));
    case _NodeShape.circle:
      return Path()..addOval(Offset.zero & size);
    case _NodeShape.oval:
      return Path()..addOval(Offset.zero & size);
    case _NodeShape.diamond:
      return Path()
        ..moveTo(w / 2, 0)
        ..lineTo(w, h / 2)
        ..lineTo(w / 2, h)
        ..lineTo(0, h / 2)
        ..close();
    case _NodeShape.triangle:
      return Path()
        ..moveTo(w / 2, 0)
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
    case _NodeShape.star:
      return _starPath(size, 5);
    case _NodeShape.hexagon:
      return _regularPolygonPath(size, 6);
    case _NodeShape.trapezoid:
      final inset = w * 0.18;
      return Path()
        ..moveTo(inset, 0)
        ..lineTo(w - inset, 0)
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
    case _NodeShape.parallelogram:
      final skew = w * 0.22;
      return Path()
        ..moveTo(skew, 0)
        ..lineTo(w, 0)
        ..lineTo(w - skew, h)
        ..lineTo(0, h)
        ..close();
    case _NodeShape.arrowRight:
      return Path()
        ..moveTo(0, h * 0.22)
        ..lineTo(w * 0.52, h * 0.22)
        ..lineTo(w * 0.52, 0)
        ..lineTo(w, h * 0.5)
        ..lineTo(w * 0.52, h)
        ..lineTo(w * 0.52, h * 0.78)
        ..lineTo(0, h * 0.78)
        ..close();
  }
}

Path _starPath(Size size, int points) {
  final cx = size.width / 2;
  final cy = size.height / 2;
  final outerR = math.min(size.width, size.height) / 2 * 0.92;
  final innerR = outerR * 0.45;
  final path = Path();
  final n = points * 2;
  for (int i = 0; i < n; i++) {
    final r = i.isEven ? outerR : innerR;
    final angle = -math.pi / 2 + i * math.pi / points;
    final x = cx + r * math.cos(angle);
    final y = cy + r * math.sin(angle);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  path.close();
  return path;
}

Path _regularPolygonPath(Size size, int sides) {
  final cx = size.width / 2;
  final cy = size.height / 2;
  final r = math.min(size.width, size.height) / 2 * 0.9;
  final path = Path();
  for (int i = 0; i < sides; i++) {
    final angle = -math.pi / 2 + i * 2 * math.pi / sides;
    final x = cx + r * math.cos(angle);
    final y = cy + r * math.sin(angle);
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  path.close();
  return path;
}

class _GridPainter extends CustomPainter {
  final Matrix4 transform;
  final double spacing;
  const _GridPainter({required this.transform, required this.spacing});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final paint = Paint()
      ..color = Colors.grey.withValues(alpha: 0.22)
      ..strokeWidth = 1;

    final inv = Matrix4.inverted(transform);
    final w0 = _screenToWorld(inv, const Offset(0, 0));
    final w1 = _screenToWorld(inv, Offset(size.width, size.height));

    // Increase grid step when zoomed out hard to avoid drawing excessive lines.
    final scale = math.max(0.0001, transform.getMaxScaleOnAxis().abs());
    final minScreenSpacing = 18.0;
    final multiplier = math.max(
      1.0,
      (minScreenSpacing / (spacing * scale)).ceilToDouble(),
    );
    final step = spacing * multiplier;

    final left = math.min(w0.dx, w1.dx) - step * 2;
    final right = math.max(w0.dx, w1.dx) + step * 2;
    final top = math.min(w0.dy, w1.dy) - step * 2;
    final bottom = math.max(w0.dy, w1.dy) + step * 2;

    final startX = (left / step).floorToDouble() * step;
    final startY = (top / step).floorToDouble() * step;

    const maxLines = 5000;
    var drawnV = 0;
    for (double x = startX; x <= right && drawnV < maxLines; x += step) {
      final s = _worldToScreen(Offset(x, top));
      final e = _worldToScreen(Offset(x, bottom));
      canvas.drawLine(s, e, paint);
      drawnV++;
    }

    var drawnH = 0;
    for (double y = startY; y <= bottom && drawnH < maxLines; y += step) {
      final s = _worldToScreen(Offset(left, y));
      final e = _worldToScreen(Offset(right, y));
      canvas.drawLine(s, e, paint);
      drawnH++;
    }
  }

  Offset _worldToScreen(Offset worldPoint) {
    final v = Vector3(worldPoint.dx, worldPoint.dy, 0)..applyMatrix4(transform);
    return Offset(v.x, v.y);
  }

  Offset _screenToWorld(Matrix4 invTransform, Offset screenPoint) {
    final v = Vector3(screenPoint.dx, screenPoint.dy, 0)
      ..applyMatrix4(invTransform);
    return Offset(v.x, v.y);
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.transform != transform || oldDelegate.spacing != spacing;
}

class _PenStrokePainter extends CustomPainter {
  final Matrix4 transform;
  final List<_PenStroke> strokes;
  final List<Offset>? activePoints;
  final Color activeColor;
  final double activeWidth;
  final bool activeHighlighter;

  const _PenStrokePainter({
    required this.transform,
    required this.strokes,
    required this.activePoints,
    required this.activeColor,
    required this.activeWidth,
    required this.activeHighlighter,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      _paintPolyline(canvas, s.points, s.color, s.width);
    }
    if (activePoints != null) {
      if (activePoints!.length >= 2) {
        _paintPolyline(canvas, activePoints!, activeColor, activeWidth);
      } else if (activePoints!.length == 1) {
        final p = _worldToScreen(activePoints!.single);
        final r = (activeWidth * 0.48).clamp(1.2, 24.0);
        canvas.drawCircle(
          p,
          r,
          Paint()
            ..color = activeHighlighter
                ? activeColor.withValues(alpha: 0.45)
                : activeColor
            ..style = PaintingStyle.fill,
        );
      }
    }
  }

  void _paintPolyline(
    Canvas canvas,
    List<Offset> points,
    Color color,
    double width,
  ) {
    if (points.length < 2) return;
    final path = Path();
    for (int i = 0; i < points.length; i++) {
      final p = _worldToScreen(points[i]);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  Offset _worldToScreen(Offset worldPoint) {
    final v = Vector3(worldPoint.dx, worldPoint.dy, 0)..applyMatrix4(transform);
    return Offset(v.x, v.y);
  }

  @override
  bool shouldRepaint(covariant _PenStrokePainter oldDelegate) =>
      oldDelegate.transform != transform ||
      oldDelegate.strokes != strokes ||
      oldDelegate.activePoints != activePoints ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.activeWidth != activeWidth ||
      oldDelegate.activeHighlighter != activeHighlighter;
}

class _ConnectPreviewPainter extends CustomPainter {
  final Matrix4 transform;
  final _ActivePortDrag? activeDrag;

  const _ConnectPreviewPainter({
    required this.transform,
    required this.activeDrag,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final drag = activeDrag;
    if (drag == null) return;
    Offset w2s(Offset p) {
      final v = Vector3(p.dx, p.dy, 0)..applyMatrix4(transform);
      return Offset(v.x, v.y);
    }

    final p0 = w2s(drag.startWorld);
    final p1 = w2s(drag.currentWorld);
    final paint = Paint()
      ..color = Colors.blueAccent.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(p0.dx, p0.dy)
      ..lineTo(p1.dx, p1.dy);
    canvas.drawPath(path, paint);
    canvas.drawCircle(p0, 3.0, Paint()..color = paint.color);
  }

  @override
  bool shouldRepaint(covariant _ConnectPreviewPainter oldDelegate) =>
      oldDelegate.transform != transform ||
      oldDelegate.activeDrag != activeDrag;
}

class _EdgePainter extends CustomPainter {
  final Matrix4 transform;
  final List<_NodeModel> nodes;
  final List<_GroupModel> groups;
  final List<_EdgeModel> edges;
  final int? selectedEdgeIndex;
  final double fxValue;
  const _EdgePainter({
    required this.transform,
    required this.nodes,
    required this.groups,
    required this.edges,
    required this.selectedEdgeIndex,
    required this.fxValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final nodeById = {for (final n in nodes) n.id: n};
    final groupRectCache = <String, Rect?>{};

    Rect? groupWorldRect(_GroupModel g) {
      final cached = groupRectCache[g.id];
      if (cached != null) return cached;
      final groupNodes = <_NodeModel>[];
      for (final id in g.nodeIds) {
        final node = nodeById[id];
        if (node != null) groupNodes.add(node);
      }
      if (groupNodes.length < 2) return null;
      final rects = groupNodes
          .map(
            (n) => Rect.fromLTWH(
              n.position.dx,
              n.position.dy,
              n.size.width,
              n.size.height,
            ),
          )
          .toList();
      final left = rects.map((r) => r.left).reduce(math.min);
      final top = rects.map((r) => r.top).reduce(math.min);
      final right = rects.map((r) => r.right).reduce(math.max);
      final bottom = rects.map((r) => r.bottom).reduce(math.max);
      final rect = Rect.fromLTRB(left, top, right, bottom).inflate(26);
      groupRectCache[g.id] = rect;
      return rect;
    }

    Offset? endpointCenter(String id) {
      final node = nodeById[id];
      if (node != null) {
        return node.position +
            Offset(node.size.width / 2, node.size.height / 2);
      }
      for (final g in groups) {
        if (g.id == id) return groupWorldRect(g)?.center;
      }
      return null;
    }

    Offset nodePortPoint(String id, _EdgePort port) {
      final n = nodeById[id];
      if (n != null) {
        switch (port) {
          case _EdgePort.left:
            return n.position + Offset(0, n.size.height / 2);
          case _EdgePort.top:
            return n.position + Offset(n.size.width / 2, 0);
          case _EdgePort.right:
            return n.position + Offset(n.size.width, n.size.height / 2);
          case _EdgePort.bottom:
            return n.position + Offset(n.size.width / 2, n.size.height);
          case _EdgePort.spouseBottom:
            return n.position + Offset(n.size.width / 2 + 18, n.size.height);
        }
      }
      return endpointCenter(id) ?? Offset.zero;
    }

    Offset pointOnRectBorderToward(Rect rect, Offset toward) {
      final c = rect.center;
      final dx = toward.dx - c.dx;
      final dy = toward.dy - c.dy;
      if (dx.abs() < 1e-6 && dy.abs() < 1e-6) return c;
      final hw = rect.width / 2;
      final hh = rect.height / 2;
      if (dx.abs() * hh > dy.abs() * hw) {
        final x = c.dx + (dx >= 0 ? hw : -hw);
        final y = c.dy + dy * (hw / dx.abs());
        return Offset(x, y);
      }
      final y = c.dy + (dy >= 0 ? hh : -hh);
      final x = c.dx + dx * (hh / dy.abs());
      return Offset(x, y);
    }

    Rect? groupRectById(String id) {
      for (final g in groups) {
        if (g.id == id) return groupWorldRect(g);
      }
      return null;
    }

    final occupiedFamilyLabelRects = <Rect>[];
    final drawnFamilyLabelKeys = <String>{};

    for (int i = 0; i < edges.length; i++) {
      final e = edges[i];
      final fromCenter = endpointCenter(e.from);
      final toCenter = endpointCenter(e.to);
      if (fromCenter == null || toCenter == null) continue;
      var from = nodePortPoint(e.from, e.fromPort);
      var to = nodePortPoint(e.to, e.toPort);
      final fromGroupRect = groupRectById(e.from);
      if (fromGroupRect != null) {
        from = pointOnRectBorderToward(fromGroupRect, toCenter);
      }
      final toGroupRect = groupRectById(e.to);
      if (toGroupRect != null) {
        to = pointOnRectBorderToward(toGroupRect, fromCenter);
      }
      final selected = selectedEdgeIndex == i;
      final baseColor = selected ? Colors.redAccent : e.color;
      final pulse = e.animated
          ? (0.5 + 0.5 * math.sin(fxValue * math.pi * 2))
          : 1.0;
      final isSpouse = e.route == _EdgeRoute.spouse;
      final edgePaint = Paint()
        ..color = baseColor.withValues(
          alpha: (0.45 + pulse * 0.55).clamp(0.0, 1.0),
        )
        ..strokeWidth = selected ? e.width + 0.8 : e.width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final p0 = _worldToScreen(from);
      final p1 = _worldToScreen(to);

      // Safety check: skip if positions are invalid (NaN or infinite)
      if (!p0.dx.isFinite ||
          !p0.dy.isFinite ||
          !p1.dx.isFinite ||
          !p1.dy.isFinite) {
        continue;
      }

      final path = isSpouse
          ? () {
              // Route spouse edges in world-space so zoom keeps a stable shape.
              const spouseDropWorld = 30.0;
              final bendWorldY = math.max(from.dy, to.dy) + spouseDropWorld;
              final p0Down = _worldToScreen(Offset(from.dx, bendWorldY));
              final p1Down = _worldToScreen(Offset(to.dx, bendWorldY));
              return Path()
                ..moveTo(p0.dx, p0.dy)
                ..lineTo(p0Down.dx, p0Down.dy)
                ..lineTo(p1Down.dx, p1Down.dy)
                ..lineTo(p1.dx, p1.dy);
            }()
          : _edgePathForRoute(
              p0,
              p1,
              e.route,
              bend: e.bend.clamp(-1.0, 1.0), // Clamp bend to valid range
              elbow: e.elbow.clamp(0.0, 1.0),
            );

      if (e.dashed) {
        _drawDashedPath(canvas, path, edgePaint);
      } else {
        canvas.drawPath(path, edgePaint);
      }

      if (isSpouse) {
        // Spouse edge has no midpoint marker.
      } else if (e.arrow) {
        _drawArrowHead(canvas, path, edgePaint.color);
      } else {
        canvas.drawCircle(
          p1,
          selected ? 4.2 : 3.2,
          Paint()..color = edgePaint.color,
        );
      }

      if (e.label.trim().isNotEmpty) {
        final metrics = path.computeMetrics().toList(growable: false);
        if (metrics.isNotEmpty) {
          final metric = metrics.first;
          final tan = metric.getTangentForOffset(
            metric.length * e.labelT.clamp(0.05, 0.95),
          );
          if (tan != null) {
            final zoom = transform.getMaxScaleOnAxis().clamp(0.35, 2.2);
            final labelScale = (zoom * 0.9).clamp(0.58, 1.14);
            final isFamily = e.route == _EdgeRoute.familyTree;
            if (isFamily) {
              final familyLabelScale = zoom.clamp(0.3, 1.0);
              final pairMatch = RegExp(
                r'^Bố:\s*(.*?)\s*•\s*Mẹ:\s*(.*)$',
              ).firstMatch(e.label);
              final compactLabel = pairMatch != null
                  ? '${pairMatch.group(1)} · ${pairMatch.group(2)}'
                  : e.label
                        .replaceFirst(RegExp(r'^Bố:\s*'), '')
                        .replaceFirst(RegExp(r'^Mẹ:\s*'), '');
              final familyLabelKey = compactLabel.trim().toLowerCase();
              if (familyLabelKey.isNotEmpty &&
                  !drawnFamilyLabelKeys.add(familyLabelKey)) {
                continue;
              }
              final tp =
                  TextPainter(
                    text: TextSpan(
                      text: compactLabel,
                      style: TextStyle(
                        color: selected
                            ? Colors.red.shade700
                            : const Color(0xFF0F172A),
                        fontWeight: FontWeight.w700,
                        fontSize: ((e.labelSize + 1.0) * familyLabelScale)
                            .clamp(6.0, 16.0),
                        shadows: const [
                          Shadow(color: Colors.white, blurRadius: 1.5),
                        ],
                      ),
                    ),
                    textDirection: TextDirection.ltr,
                    maxLines: 1,
                    ellipsis: '…',
                  )..layout(
                    maxWidth: (220.0 * familyLabelScale).clamp(90.0, 220.0),
                  );

              Rect labelRectFor(Offset center) => Rect.fromCenter(
                center: center,
                width: tp.width + 8,
                height: tp.height + 6,
              );

              var labelCenter = tan.position + Offset(0, -(tp.height * 0.45));
              var labelRect = labelRectFor(labelCenter);
              const rowGap = 6.0;
              int guard = 0;
              while (guard < 24) {
                Rect? overlap;
                for (final r in occupiedFamilyLabelRects) {
                  if (r.overlaps(labelRect.inflate(1))) {
                    overlap = r;
                    break;
                  }
                }
                if (overlap == null) break;
                final nextCenterX =
                    overlap.right + rowGap + (labelRect.width / 2);
                labelCenter = Offset(nextCenterX, labelCenter.dy);
                labelRect = labelRectFor(labelCenter);
                guard++;
              }
              occupiedFamilyLabelRects.add(labelRect);

              tp.paint(
                canvas,
                Offset(
                  labelCenter.dx - tp.width / 2,
                  labelCenter.dy - tp.height / 2,
                ),
              );
            } else {
              var angle = tan.angle;
              if (angle > math.pi / 2 || angle < -math.pi / 2) {
                angle += math.pi;
              }
              final tp = TextPainter(
                text: TextSpan(
                  text: e.label,
                  style: TextStyle(
                    color: e.labelColor,
                    fontWeight: FontWeight.w600,
                    fontSize: (e.labelSize * labelScale).clamp(9.0, 22.0),
                    shadows: const [Shadow(color: Colors.white, blurRadius: 2)],
                  ),
                ),
                textDirection: TextDirection.ltr,
              )..layout(maxWidth: 220);
              final offsetY = -22.0 * labelScale; // Move label above line
              final labelPos = tan.position + Offset(0, offsetY);
              final bgRect = Rect.fromCenter(
                center: Offset.zero,
                width: tp.width + 12,
                height: tp.height + 10,
              );
              canvas.save();
              canvas.translate(labelPos.dx, labelPos.dy);
              canvas.rotate(angle);
              canvas.drawRect(bgRect, Paint()..color = Colors.white);
              canvas.drawRect(
                bgRect.deflate(0.5),
                Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1
                  ..color = baseColor.withValues(alpha: 0.6),
              );
              tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
              canvas.restore();
            }
          }
        }
      }
    }
  }

  void _drawDashedPath(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      const dash = 10.0;
      const gap = 6.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance += dash + gap;
      }
    }
  }

  void _drawArrowHead(Canvas canvas, Path path, Color color) {
    final metrics = path.computeMetrics().toList(growable: false);
    if (metrics.isEmpty) return;
    final m = metrics.last;
    final zoomScale = transform.getMaxScaleOnAxis().clamp(0.4, 3.0);
    final size = (11.0 * zoomScale).clamp(5.5, 26.0);
    final dirBackoff = (size * 0.75).clamp(6.0, 18.0);
    final tipTan = m.getTangentForOffset(math.max(0, m.length - 0.001));
    final dirTan = m.getTangentForOffset(math.max(0, m.length - dirBackoff));
    if (tipTan == null || dirTan == null) return;
    final dir = dirTan.vector;
    final len = math.max(1e-6, dir.distance);
    final ux = dir.dx / len;
    final uy = dir.dy / len;
    final tip = tipTan.position;
    final p1 = Offset(
      tip.dx - ux * size - uy * size * 0.55,
      tip.dy - uy * size + ux * size * 0.55,
    );
    final p2 = Offset(
      tip.dx - ux * size + uy * size * 0.55,
      tip.dy - uy * size - ux * size * 0.55,
    );
    final head = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(
      head,
      Paint()
        ..color = color.withValues(alpha: 1)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      head,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.95)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (1.2 * zoomScale).clamp(0.8, 2.2),
    );
  }

  Offset _worldToScreen(Offset worldPoint) {
    final v = Vector3(worldPoint.dx, worldPoint.dy, 0)..applyMatrix4(transform);
    return Offset(v.x, v.y);
  }

  @override
  bool shouldRepaint(covariant _EdgePainter oldDelegate) =>
      oldDelegate.transform != transform ||
      oldDelegate.nodes != nodes ||
      oldDelegate.groups != groups ||
      oldDelegate.edges != edges ||
      oldDelegate.selectedEdgeIndex != selectedEdgeIndex ||
      oldDelegate.fxValue != fxValue;
}

class _GroupPainter extends CustomPainter {
  final Matrix4 transform;
  final List<_NodeModel> nodes;
  final List<_GroupModel> groups;

  const _GroupPainter({
    required this.transform,
    required this.nodes,
    required this.groups,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final map = {for (final n in nodes) n.id: n};
    for (final g in groups) {
      final groupNodes = g.nodeIds
          .map((id) => map[id])
          .whereType<_NodeModel>()
          .toList();
      if (groupNodes.length < 2) continue;
      final rects = groupNodes
          .map(
            (n) => Rect.fromLTWH(
              n.position.dx,
              n.position.dy,
              n.size.width,
              n.size.height,
            ),
          )
          .toList();
      final left = rects.map((r) => r.left).reduce((a, b) => a < b ? a : b);
      final top = rects.map((r) => r.top).reduce((a, b) => a < b ? a : b);
      final right = rects.map((r) => r.right).reduce((a, b) => a > b ? a : b);
      final bottom = rects.map((r) => r.bottom).reduce((a, b) => a > b ? a : b);
      final world = Rect.fromLTRB(left, top, right, bottom).inflate(26);
      final p1 = _worldToScreen(world.topLeft);
      final p2 = _worldToScreen(world.bottomRight);
      final screen = Rect.fromPoints(p1, p2);
      final path = Path()
        ..addRRect(RRect.fromRectAndRadius(screen, const Radius.circular(14)));
      final dashed = Paint()
        ..color = g.color.withValues(alpha: 0.8)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, dashed);
      final tp = TextPainter(
        text: TextSpan(
          text: g.name,
          style: TextStyle(
            color: g.color,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, screen.topLeft + const Offset(6, -20));
    }
  }

  Offset _worldToScreen(Offset worldPoint) {
    final v = Vector3(worldPoint.dx, worldPoint.dy, 0)..applyMatrix4(transform);
    return Offset(v.x, v.y);
  }

  @override
  bool shouldRepaint(covariant _GroupPainter oldDelegate) =>
      oldDelegate.transform != transform ||
      oldDelegate.nodes != nodes ||
      oldDelegate.groups != groups;
}

class _HandPanOverlay extends StatefulWidget {
  final CanvasKitController controller;
  const _HandPanOverlay({required this.controller});

  @override
  State<_HandPanOverlay> createState() => _HandPanOverlayState();
}

class _HandPanOverlayState extends State<_HandPanOverlay> {
  double _initialScale = 1;
  Offset _focalWorld = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) return;
        final scaleDelta = event.scrollDelta.dy > 0 ? 0.9 : 1.1;
        final worldBefore = widget.controller.screenToWorld(
          event.localPosition,
        );
        widget.controller.setScale(
          widget.controller.scale * scaleDelta,
          focalWorld: worldBefore,
        );
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (d) {
          _initialScale = widget.controller.scale;
          _focalWorld = widget.controller.screenToWorld(d.localFocalPoint);
        },
        onScaleUpdate: (d) {
          if (d.pointerCount == 1) {
            final worldDelta = widget.controller.deltaScreenToWorld(
              d.focalPointDelta,
            );
            widget.controller.translateWorld(worldDelta);
            return;
          }
          final nextScale = _initialScale * d.scale;
          widget.controller.setScale(nextScale, focalWorld: _focalWorld);
          final currentScreen = widget.controller.worldToScreen(_focalWorld);
          final correction = widget.controller.deltaScreenToWorld(
            d.localFocalPoint - currentScreen,
          );
          widget.controller.translateWorld(correction);
        },
      ),
    );
  }
}
