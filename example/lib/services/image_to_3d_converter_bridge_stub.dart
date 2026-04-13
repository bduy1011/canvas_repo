import 'package:flutter/material.dart';

import 'image_to_3d_converter_bridge.dart';

class _UnsupportedImageTo3DConverterBridge implements ImageTo3DConverterBridge {
  @override
  bool get isSupported => false;

  @override
  Future<bool> initialize() async => false;

  @override
  Future<ImageTo3DResult?> pickAndConvert({
    required ThreeDModelKind kind,
    bool fromCamera = false,
  }) async {
    return const ImageTo3DResult(
      success: false,
      message: 'Tinh nang chuyen anh 2D sang 3D chi ho tro tren Android/iOS.',
    );
  }

  @override
  Future<void> openArPreview({
    required BuildContext context,
    required Object nativeModelData,
    bool faceMode = false,
  }) async {}
}

ImageTo3DConverterBridge createImageTo3DConverterBridgeImpl() =>
    _UnsupportedImageTo3DConverterBridge();
