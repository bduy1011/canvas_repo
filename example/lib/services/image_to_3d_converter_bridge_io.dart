import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_3d_ar_converter_new/flutter_3d_ar_converter_new.dart';
import 'package:http/http.dart' as http;

import 'image_to_3d_converter_bridge.dart';

class _ImageTo3DConverterBridgeIo implements ImageTo3DConverterBridge {
  final Flutter3dArConverter _sdk = Flutter3dArConverter();
  final ImageTo3DConverter _converter = ImageTo3DConverter();
  static const String _apiBaseUrl = String.fromEnvironment(
    'THREED_API_BASE_URL',
    defaultValue: '',
  );
  static const String _apiKey = String.fromEnvironment(
    'THREED_API_KEY',
    defaultValue: '',
  );

  @override
  bool get isSupported => Platform.isAndroid || Platform.isIOS;

  @override
  Future<bool> initialize() async {
    if (!isSupported) return false;
    return _sdk.initialize();
  }

  @override
  Future<ImageTo3DResult?> pickAndConvert({
    required ThreeDModelKind kind,
    bool fromCamera = false,
  }) async {
    if (!isSupported) {
      return const ImageTo3DResult(
        success: false,
        message: 'Thiet bi hien tai khong ho tro image-to-3D converter.',
      );
    }

    final File? imageFile = await _converter.pickImage(fromCamera: fromCamera);
    if (imageFile == null) return null;

    final ModelType targetType = switch (kind) {
      ThreeDModelKind.furniture => ModelType.furniture,
      ThreeDModelKind.glasses => ModelType.glasses,
      ThreeDModelKind.object => ModelType.object,
    };

    final String? remoteModelPath = await _tryConvertViaRemoteApi(
      imageFile: imageFile,
      kind: kind,
    );
    if (remoteModelPath != null) {
      return ImageTo3DResult(
        success: true,
        modelPath: remoteModelPath,
        sourceImagePath: imageFile.path,
        message: 'Da tao model 3D qua remote API.',
      );
    }
    final ModelData? modelData = await _converter.convertImageTo3D(
      imageFile,
      targetType,
      additionalParams: <String, dynamic>{'quality': 'high', 'format': 'glb'},
    );

    if (modelData == null) {
      return ImageTo3DResult(
        success: false,
        sourceImagePath: imageFile.path,
        message: 'Khong the tao model 3D tu anh da chon.',
      );
    }

    final lowerModelPath = modelData.modelPath.toLowerCase();
    final looksLikeSdkSample =
        lowerModelPath.contains('/app_flutter/models/') ||
        lowerModelPath.contains('sample_object.glb');
    final bool modelLooksValid =
        !looksLikeSdkSample && await _looksLikeModelFile(modelData.modelPath);
    return ImageTo3DResult(
      success: true,
      modelPath: modelData.modelPath,
      sourceImagePath: imageFile.path,
      nativeModelData: modelData,
      message: modelLooksValid
          ? null
          : 'Package hien tai tao model demo placeholder. Can thay bang dich vu convert 3D that cho production.',
    );
  }

  @override
  Future<void> openArPreview({
    required BuildContext context,
    required Object nativeModelData,
    bool faceMode = false,
  }) async {
    final data = nativeModelData as ModelData;
    final Widget page = faceMode
        ? FaceARViewer(modelData: data)
        : ARViewer(modelData: data);

    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<bool> _looksLikeModelFile(String path) async {
    final File file = File(path);
    if (!await file.exists()) return false;
    if (await file.length() < 32) return false;

    final List<int> header = await file.openRead(0, 4).first;
    if (header.length < 4) return false;

    final String magic = String.fromCharCodes(header);
    if (magic == 'glTF') return true;

    return path.toLowerCase().endsWith('.obj') ||
        path.toLowerCase().endsWith('.glb') ||
        path.toLowerCase().endsWith('.gltf') ||
        path.toLowerCase().endsWith('.usdz') ||
        path.toLowerCase().endsWith('.fbx');
  }

  Future<String?> _tryConvertViaRemoteApi({
    required File imageFile,
    required ThreeDModelKind kind,
  }) async {
    final token = _apiKey.trim();
    final base = _apiBaseUrl.trim();
    final looksLikeMeshy =
        token.startsWith('msy_') ||
        token.startsWith('msy-') ||
        base.contains('meshy.ai');
    if (looksLikeMeshy) {
      return _tryConvertViaMeshyApi(imageFile: imageFile, kind: kind);
    }

    return _tryConvertViaCustomApi(imageFile: imageFile, kind: kind);
  }

  Future<String?> _tryConvertViaCustomApi({
    required File imageFile,
    required ThreeDModelKind kind,
  }) async {
    final base = _apiBaseUrl.trim();
    if (base.isEmpty) return null;
    final convertUri = Uri.parse('$base/convert');
    final request = http.MultipartRequest('POST', convertUri)
      ..fields['kind'] = kind.name
      ..files.add(await http.MultipartFile.fromPath('image', imageFile.path));
    final token = _apiKey.trim();
    if (token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }

    try {
      final streamed = await request.send().timeout(
        const Duration(seconds: 90),
      );
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) return null;
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;

      String? modelUrl = _pickString(decoded, const [
        'model_url',
        'modelUrl',
        'url',
      ]);
      String? jobId = _pickString(decoded, const ['job_id', 'jobId', 'id']);
      String? statusUrl = _pickString(decoded, const [
        'status_url',
        'statusUrl',
      ]);

      if (modelUrl == null && (jobId != null || statusUrl != null)) {
        final polled = await _pollForModelUrl(
          base: base,
          jobId: jobId,
          statusUrl: statusUrl,
          authToken: token,
        );
        modelUrl = polled;
      }
      if (modelUrl == null || modelUrl.isEmpty) return null;

      final downloaded = await _downloadModelFile(modelUrl, token);
      if (downloaded == null) return null;
      final ok = await _looksLikeModelFile(downloaded.path);
      return ok ? downloaded.path : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _tryConvertViaMeshyApi({
    required File imageFile,
    required ThreeDModelKind kind,
  }) async {
    final token = _apiKey.trim();
    if (token.isEmpty) return null;

    final bytes = await imageFile.readAsBytes();
    if (bytes.isEmpty) return null;
    final ext = imageFile.path.toLowerCase().endsWith('.png') ? 'png' : 'jpeg';
    final dataUri = 'data:image/$ext;base64,${base64Encode(bytes)}';

    final createResp = await http
        .post(
          Uri.parse('https://api.meshy.ai/openapi/v1/image-to-3d'),
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(<String, dynamic>{
            'image_url': dataUri,
            'ai_model': 'latest',
            'model_type': kind == ThreeDModelKind.object
                ? 'standard'
                : 'standard',
            'should_texture': true,
            'enable_pbr': true,
            'should_remesh': true,
            'target_formats': <String>['glb'],
            'image_enhancement': true,
            'remove_lighting': true,
          }),
        )
        .timeout(const Duration(seconds: 90));

    if (createResp.statusCode < 200 || createResp.statusCode >= 300) {
      return null;
    }
    final createJson = jsonDecode(createResp.body);
    if (createJson is! Map) return null;
    final taskId = _pickString(createJson, const ['result', 'id']);
    if (taskId == null || taskId.isEmpty) return null;

    for (var i = 0; i < 60; i++) {
      final statusResp = await http
          .get(
            Uri.parse('https://api.meshy.ai/openapi/v1/image-to-3d/$taskId'),
            headers: <String, String>{'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 30));
      if (statusResp.statusCode < 200 || statusResp.statusCode >= 300) {
        await Future<void>.delayed(const Duration(seconds: 3));
        continue;
      }
      final data = jsonDecode(statusResp.body);
      if (data is! Map) {
        await Future<void>.delayed(const Duration(seconds: 3));
        continue;
      }
      final status = (_pickString(data, const ['status']) ?? '')
          .toUpperCase()
          .trim();
      String? modelUrl;
      final modelUrls = data['model_urls'];
      if (modelUrls is Map) {
        final glb = modelUrls['glb'];
        if (glb is String && glb.trim().isNotEmpty) {
          modelUrl = glb.trim();
        }
      }
      modelUrl ??= _pickString(data, const ['model_url', 'modelUrl', 'url']);

      if (status == 'SUCCEEDED' && modelUrl != null && modelUrl.isNotEmpty) {
        final downloaded = await _downloadModelFile(modelUrl, token);
        if (downloaded == null) return null;
        return (await _looksLikeModelFile(downloaded.path))
            ? downloaded.path
            : null;
      }
      if (status == 'FAILED' || status == 'CANCELLED') return null;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return null;
  }

  Future<String?> _pollForModelUrl({
    required String base,
    String? jobId,
    String? statusUrl,
    required String authToken,
  }) async {
    Uri uri;
    if (statusUrl != null && statusUrl.trim().isNotEmpty) {
      uri = Uri.parse(statusUrl);
    } else if (jobId != null && jobId.trim().isNotEmpty) {
      uri = Uri.parse('$base/jobs/$jobId');
    } else {
      return null;
    }

    for (var i = 0; i < 40; i++) {
      try {
        final resp = await http
            .get(
              uri,
              headers: authToken.isEmpty
                  ? const <String, String>{}
                  : <String, String>{'Authorization': 'Bearer $authToken'},
            )
            .timeout(const Duration(seconds: 20));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        final data = jsonDecode(resp.body);
        if (data is! Map) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        final status = (_pickString(data, const ['status']) ?? '')
            .toLowerCase()
            .trim();
        final modelUrl = _pickString(data, const [
          'model_url',
          'modelUrl',
          'url',
        ]);
        if (modelUrl != null && modelUrl.isNotEmpty) return modelUrl;
        if (status == 'failed' || status == 'error') return null;
      } catch (_) {
        // retry
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  Future<File?> _downloadModelFile(String url, String authToken) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final resp = await http
        .get(
          uri,
          headers: authToken.isEmpty
              ? const <String, String>{}
              : <String, String>{'Authorization': 'Bearer $authToken'},
        )
        .timeout(const Duration(seconds: 90));
    if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
    if (resp.bodyBytes.isEmpty) return null;

    final extFromUrl = () {
      final p = uri.path.toLowerCase();
      if (p.endsWith('.glb')) return '.glb';
      if (p.endsWith('.gltf')) return '.gltf';
      if (p.endsWith('.obj')) return '.obj';
      if (p.endsWith('.fbx')) return '.fbx';
      return '';
    }();
    final ext = extFromUrl.isNotEmpty ? extFromUrl : '.glb';
    final file = File(
      '${Directory.systemTemp.path}/converted_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
    await file.writeAsBytes(resp.bodyBytes, flush: true);
    return file;
  }

  String? _pickString(Map data, List<String> keys) {
    for (final k in keys) {
      final v = data[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }
}

ImageTo3DConverterBridge createImageTo3DConverterBridgeImpl() =>
    _ImageTo3DConverterBridgeIo();
