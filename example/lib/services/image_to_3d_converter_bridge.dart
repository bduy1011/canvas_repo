import 'package:flutter/material.dart';

import 'image_to_3d_converter_bridge_stub.dart'
    if (dart.library.io) 'image_to_3d_converter_bridge_io.dart';

enum ThreeDModelKind { furniture, glasses, object }

class ImageTo3DResult {
  final bool success;
  final String? modelPath;
  final String? sourceImagePath;
  final String? message;
  final Object? nativeModelData;

  const ImageTo3DResult({
    required this.success,
    this.modelPath,
    this.sourceImagePath,
    this.message,
    this.nativeModelData,
  });
}

abstract class ImageTo3DConverterBridge {
  bool get isSupported;

  Future<bool> initialize();

  Future<ImageTo3DResult?> pickAndConvert({
    required ThreeDModelKind kind,
    bool fromCamera,
  });

  Future<void> openArPreview({
    required BuildContext context,
    required Object nativeModelData,
    bool faceMode,
  });
}

ImageTo3DConverterBridge createImageTo3DConverterBridge() =>
    createImageTo3DConverterBridgeImpl();
