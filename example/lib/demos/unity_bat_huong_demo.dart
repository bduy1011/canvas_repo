import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_3d_controller/flutter_3d_controller.dart';

import '../services/image_to_3d_converter_bridge.dart';

class UnityBatHuongDemoPage extends StatefulWidget {
  final String? initialKeyword;

  const UnityBatHuongDemoPage({super.key, this.initialKeyword});

  @override
  State<UnityBatHuongDemoPage> createState() => _UnityBatHuongDemoPageState();
}

class _UnityBatHuongDemoPageState extends State<UnityBatHuongDemoPage> {
  final Flutter3DController _web3dController = Flutter3DController();
  final ImageTo3DConverterBridge _imageTo3dConverter =
      createImageTo3DConverterBridge();
  late final TextEditingController _keywordController;
  String _viewerModelSrc =
      'https://modelviewer.dev/shared-assets/models/Astronaut.glb';

  bool _viewerModelLoaded = false;
  bool _converterReady = false;
  bool _convertingImage = false;
  ThreeDModelKind _selectedModelKind = ThreeDModelKind.object;
  String? _conversionMessage;
  String? _latestModelPath;
  double _autoRotateSpeed = 20;

  @override
  void initState() {
    super.initState();
    _keywordController = TextEditingController(
      text: (widget.initialKeyword?.trim().isNotEmpty ?? false)
          ? widget.initialKeyword!.trim()
          : 'bat huong incense burner',
    );
    _initImageTo3DConverter();
  }

  bool get _isViewerPlatform {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  bool get _isImageTo3DPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  Future<void> _initImageTo3DConverter() async {
    if (!_isImageTo3DPlatform || !_imageTo3dConverter.isSupported) {
      return;
    }
    final bool ready = await _imageTo3dConverter.initialize();
    if (!mounted) return;
    setState(() {
      _converterReady = ready;
      if (!ready) {
        _conversionMessage =
            'Khoi tao AR that bai tren thiet bi nay. Ban van co the convert anh 2D -> 3D, nhung AR preview co the bi gioi han.';
      }
    });
  }

  Future<void> _rotateBy(double degrees) async {
    if (_isViewerPlatform) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keo/chuot de xoay truc tiep model 3D.')),
      );
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Xoay model trong AR preview sau khi tao model 3D.'),
      ),
    );
  }

  Future<void> _setAutoRotateSpeed(double value) async {
    setState(() => _autoRotateSpeed = value);

    if (_isViewerPlatform) {
      if (!_viewerModelLoaded) {
        // Defer controller actions until onLoad marks the model ready.
        return;
      }
      if (value <= 0) {
        _web3dController.pauseRotation();
      } else {
        _web3dController.startRotation(rotationSpeed: value.round());
      }
      return;
    }
  }

  Future<void> _loadModelByKeyword() async {
    final keyword = _keywordController.text.trim();
    if (keyword.isEmpty) return;

    if (_isViewerPlatform) {
      setState(() {
        _viewerModelLoaded = false;
        _viewerModelSrc = _resolveViewerModelSrc(keyword);
      });
      return;
    }

    setState(() {
      _conversionMessage =
          'Tim model bang tu khoa chi ap dung cho Web/Desktop viewer. Tren mobile hay dung convert anh 2D.';
    });
  }

  String _resolveViewerModelSrc(String keyword) {
    final trimmed = keyword.trim();
    if (!kIsWeb && File(trimmed).existsSync()) {
      return Uri.file(trimmed).toString();
    }
    final parsed = Uri.tryParse(trimmed);
    final looksLikeModelUrl =
        parsed != null &&
        parsed.hasScheme &&
        (trimmed.toLowerCase().endsWith('.glb') ||
            trimmed.toLowerCase().endsWith('.gltf') ||
            trimmed.toLowerCase().endsWith('.obj'));
    if (looksLikeModelUrl) return trimmed;

    // Public sample model for quick web validation.
    return 'https://modelviewer.dev/shared-assets/models/Astronaut.glb';
  }

  Future<void> _convertImageTo3D({required bool fromCamera}) async {
    if (!_isImageTo3DPlatform || !_imageTo3dConverter.isSupported) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Image-to-3D chi ho tro tren Android/iOS.'),
        ),
      );
      return;
    }

    setState(() {
      _convertingImage = true;
      _conversionMessage = null;
    });

    final ImageTo3DResult? result = await _imageTo3dConverter.pickAndConvert(
      kind: _selectedModelKind,
      fromCamera: fromCamera,
    );

    if (!mounted) return;

    if (result == null) {
      setState(() => _convertingImage = false);
      return;
    }

    if (!result.success || result.modelPath == null) {
      setState(() {
        _convertingImage = false;
        _conversionMessage =
            result.message ?? 'Khong tao duoc model 3D tu anh da chon.';
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_conversionMessage!)));
      return;
    }

    final lowerMsg = (result.message ?? '').toLowerCase();
    final lowerPath = result.modelPath!.toLowerCase();
    final looksLikeSupportedModel =
        lowerPath.endsWith('.glb') ||
        lowerPath.endsWith('.gltf') ||
        lowerPath.endsWith('.obj');
    final isPlaceholder =
        lowerMsg.contains('placeholder') || !looksLikeSupportedModel;
    final shouldBlockPlaceholder = isPlaceholder;

    setState(() {
      _convertingImage = false;
      _latestModelPath = result.modelPath;
      _keywordController.text = result.modelPath!;
      _conversionMessage = shouldBlockPlaceholder
          ? (result.message ??
                'Model local trong app storage co the khong doc duoc trong viewer WebView.')
          : (result.message ?? 'Da tao model 3D: ${result.modelPath}');
      _viewerModelLoaded = false;
      if (!shouldBlockPlaceholder) {
        _viewerModelSrc = _resolveViewerModelSrc(result.modelPath!);
      }
    });

    if (shouldBlockPlaceholder) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Model tra ve la placeholder, khong phai object 3D tu anh that.',
          ),
        ),
      );
      return;
    }

    if (result.nativeModelData != null && _converterReady) {
      await _imageTo3dConverter.openArPreview(
        context: context,
        nativeModelData: result.nativeModelData!,
        faceMode: _selectedModelKind == ThreeDModelKind.glasses,
      );
    } else if (result.nativeModelData != null && !_converterReady) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Da tao model 3D, nhung AR preview dang khong san sang tren thiet bi nay.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Do tho cung 3D - Bat huong')),
      body: !_isImageTo3DPlatform && !_isViewerPlatform
          ? const _UnsupportedPlatformView()
          : SafeArea(
              child: Column(
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                    child: Column(
                      children: <Widget>[
                        TextField(
                          controller: _keywordController,
                          decoration: const InputDecoration(
                            labelText: 'Tu khoa tim model 3D',
                            hintText: 'Vi du: bat huong, incense burner, altar',
                            border: OutlineInputBorder(),
                          ),
                          onSubmitted: (_) => _loadModelByKeyword(),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _loadModelByKeyword,
                                icon: const Icon(Icons.search),
                                label: const Text('Search model 3D'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  if (_isViewerPlatform) {
                                    if (!_viewerModelLoaded) return;
                                    _web3dController.stopRotation();
                                    _web3dController.resetCameraOrbit();
                                    setState(() => _autoRotateSpeed = 0);
                                    return;
                                  }
                                  setState(() {
                                    _conversionMessage =
                                        'Da reset trang thai local. Mo lai AR preview de thao tac model.';
                                  });
                                },
                                icon: const Icon(Icons.refresh),
                                label: const Text('Reset'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_isImageTo3DPlatform) ...<Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: InputDecorator(
                                  decoration: const InputDecoration(
                                    labelText: 'Loai model can tao',
                                    border: OutlineInputBorder(),
                                  ),
                                  child: DropdownButtonHideUnderline(
                                    child: DropdownButton<ThreeDModelKind>(
                                      isExpanded: true,
                                      value: _selectedModelKind,
                                      items:
                                          const <
                                            DropdownMenuItem<ThreeDModelKind>
                                          >[
                                            DropdownMenuItem<ThreeDModelKind>(
                                              value: ThreeDModelKind.object,
                                              child: Text('Object chung'),
                                            ),
                                            DropdownMenuItem<ThreeDModelKind>(
                                              value: ThreeDModelKind.furniture,
                                              child: Text('Noi that / ban tho'),
                                            ),
                                            DropdownMenuItem<ThreeDModelKind>(
                                              value: ThreeDModelKind.glasses,
                                              child: Text('Kinh / Face AR'),
                                            ),
                                          ],
                                      onChanged: _convertingImage
                                          ? null
                                          : (ThreeDModelKind? value) {
                                              if (value == null) return;
                                              setState(() {
                                                _selectedModelKind = value;
                                              });
                                            },
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _convertingImage
                                      ? null
                                      : () => _convertImageTo3D(
                                          fromCamera: false,
                                        ),
                                  icon: const Icon(Icons.image_outlined),
                                  label: Text(
                                    _convertingImage
                                        ? 'Dang convert...'
                                        : 'Chon anh 2D -> tao 3D',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _convertingImage
                                      ? null
                                      : () =>
                                            _convertImageTo3D(fromCamera: true),
                                  icon: const Icon(Icons.photo_camera_outlined),
                                  label: const Text('Chup anh -> tao 3D'),
                                ),
                              ),
                            ],
                          ),
                          if (_conversionMessage != null) ...<Widget>[
                            const SizedBox(height: 6),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                _conversionMessage!,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                          if (_latestModelPath != null) ...<Widget>[
                            const SizedBox(height: 4),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      'Model path: $_latestModelPath',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton(
                                    onPressed: () {
                                      final path = _latestModelPath!;
                                      final lowerPath = path.toLowerCase();
                                      final looksLikeSdkSample =
                                          lowerPath.contains(
                                            '/app_flutter/models/',
                                          ) ||
                                          lowerPath.contains(
                                            'sample_object.glb',
                                          );
                                      if (looksLikeSdkSample) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Model vua tao la sample placeholder. Hay kiem tra lai dich vu convert 3D va chay lai.',
                                            ),
                                          ),
                                        );
                                        return;
                                      }
                                      setState(() {
                                        _viewerModelLoaded = false;
                                        _viewerModelSrc =
                                            _resolveViewerModelSrc(path);
                                      });
                                    },
                                    child: const Text('Xem 3D'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ] else ...<Widget>[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Tinh nang image-to-3D tu flutter_3d_ar_converter khong ho tro Web/Desktop.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _rotateBy(-15),
                                child: const Text('Xoay trai'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => _rotateBy(15),
                                child: const Text('Xoay phai'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: <Widget>[
                            const Text('Toc do xoay tu dong'),
                            Expanded(
                              child: Slider(
                                min: 0,
                                max: 80,
                                divisions: 16,
                                value: _autoRotateSpeed,
                                label: _autoRotateSpeed.toStringAsFixed(0),
                                onChanged: _setAutoRotateSpeed,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _isViewerPlatform
                        ? Flutter3DViewer(
                            controller: _web3dController,
                            src: _viewerModelSrc,
                            enableTouch: true,
                            progressBarColor: Colors.indigo,
                            onProgress: (double progressValue) {
                              debugPrint('3D loading progress: $progressValue');
                            },
                            onLoad: (String modelAddress) {
                              debugPrint('3D loaded: $modelAddress');
                              _viewerModelLoaded = true;
                              if (_autoRotateSpeed > 0) {
                                _web3dController.startRotation(
                                  rotationSpeed: _autoRotateSpeed.round(),
                                );
                              }
                            },
                            onError: (String error) {
                              debugPrint(
                                '3D error: $error, src=$_viewerModelSrc',
                              );
                              _viewerModelLoaded = false;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Khong mo duoc model hien tai. Kiem tra lai server va duong dan model.',
                                  ),
                                ),
                              );
                            },
                          )
                        : const _MobileArHintView(),
                  ),
                ],
              ),
            ),
    );
  }
}

class _UnsupportedPlatformView extends StatelessWidget {
  const _UnsupportedPlatformView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'Nen tang hien tai chua ho tro xem 3D trong demo nay.\n'
          'Hay dung Web/Desktop viewer hoac Android/iOS de convert anh 2D -> 3D.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
  }
}

class _MobileArHintView extends StatelessWidget {
  const _MobileArHintView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(
          'Mobile mode dang su dung flutter_3d_ar_converter.\n'
          'Sau khi chon/chup anh 2D, app se tao model va mo AR preview.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
  }
}
