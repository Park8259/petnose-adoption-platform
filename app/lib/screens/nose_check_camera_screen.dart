import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'dart:convert';
import 'dart:io';
import 'AppColor.dart';
import 'nose_check_result_screen.dart';
import '../services/api_config.dart';

class NoseCheckCameraScreen extends StatefulWidget {
  final int postId;

  const NoseCheckCameraScreen({
    super.key,
    required this.postId,
  });

  @override
  State<NoseCheckCameraScreen> createState() => _NoseCheckCameraScreenState();
}

class _NoseCheckCameraScreenState extends State<NoseCheckCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitializing = true;
  bool _isTakingPhoto = false;

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    setState(() => _isInitializing = true);

    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _isInitializing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('카메라 권한을 허용해주세요')),
        );
      }
      return;
    }

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _isInitializing = false);
        return;
      }

      final camera = _cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      _controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await _controller!.initialize();
      if (mounted) setState(() => _isInitializing = false);
    } catch (e) {
      debugPrint('카메라 초기화 오류: $e');
      if (mounted) {
        setState(() => _isInitializing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('카메라를 열 수 없습니다: $e')),
        );
      }
    }
  }

  // ── API 호출 공통 ─────────────────────────────────────────────
  Future<void> _submitImage(File imageFile) async {
    setState(() => _isTakingPhoto = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('access_token') ?? '';

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiConfig.api(
            '/adoption-posts/${widget.postId}/handover-verifications')),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.files.add(
        await http.MultipartFile.fromPath(
          'nose_image',
          imageFile.path,
          contentType: MediaType('image', 'jpeg'),
        ),
      );

      final streamed = await request.send().timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamed);

      if (!mounted) return;
      setState(() => _isTakingPhoto = false);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NoseCheckResultScreen(
              isMatched: data['matched'] == true,
              similarityScore:
              (data['similarity_score'] as num?)?.toDouble(),
              threshold: (data['threshold'] as num?)?.toDouble(),
              message: data['message'] ?? '',
            ),
          ),
        );
      } else {
        final data = jsonDecode(response.body);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(data['message'] ?? '비문 확인에 실패했습니다.')),
        );
      }
    } catch (e) {
      setState(() => _isTakingPhoto = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류가 발생했습니다: $e')),
        );
      }
    }
  }

  // ── 카메라 촬영 ───────────────────────────────────────────────
  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isTakingPhoto) return;

    final xFile = await controller.takePicture();
    await _submitImage(File(xFile.path));
  }

  // ── 갤러리 선택 ───────────────────────────────────────────────
  Future<void> _pickFromGallery() async {
    if (_isTakingPhoto) return;

    try {
      final xFile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1500,
        maxHeight: 1500,
        imageQuality: 90,
      );
      if (xFile == null) return;
      await _submitImage(File(xFile.path));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('갤러리를 열 수 없습니다.')),
        );
      }
    }
  }

  Widget _buildCameraPreview() {
    if (_isInitializing) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: Text('카메라를 사용할 수 없습니다.',
            style: TextStyle(color: Colors.white54)),
      );
    }
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: controller.value.previewSize!.height,
          height: controller.value.previewSize!.width,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(),

          // 상단 그라데이션
          Positioned(
            top: 0, left: 0, right: 0, height: 140,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
            ),
          ),

          // 하단 그라데이션
          Positioned(
            bottom: 0, left: 0, right: 0, height: 280,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
            ),
          ),

          // 앱바
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_ios_new,
                          color: Colors.white),
                    ),
                    const Expanded(
                      child: Text(
                        '비문 확인',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
            ),
          ),

          // 코 가이드
          Center(
            child: CustomPaint(
              size: const Size(280, 220),
              painter: NoseGuidePainter(),
            ),
          ),

          // 하단 버튼 영역
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '게시글의 강아지와 실제 강아지의 비문을 비교합니다',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 24),

                    // 갤러리 + 촬영 버튼 + 빈 공간(대칭)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // 갤러리 버튼
                        GestureDetector(
                          onTap: _isTakingPhoto ? null : _pickFromGallery,
                          child: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white24,
                              border: Border.all(
                                  color: Colors.white54, width: 1.5),
                            ),
                            child: const Icon(Icons.photo_library,
                                color: Colors.white, size: 26),
                          ),
                        ),

                        // 촬영 버튼
                        GestureDetector(
                          onTap: _isTakingPhoto ? null : _takePhoto,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(
                                  color: AppColors.darkBrown, width: 4),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.3),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: _isTakingPhoto
                                ? const Padding(
                              padding: EdgeInsets.all(20),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: AppColors.darkBrown,
                              ),
                            )
                                : const Icon(Icons.camera_alt,
                                color: AppColors.darkBrown, size: 34),
                          ),
                        ),

                        // 대칭 맞추기용 빈 공간
                        const SizedBox(width: 52, height: 52),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NoseGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white60
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    final path = Path();
    path.moveTo(size.width * 0.5, size.height);
    path.quadraticBezierTo(size.width * 0.05, size.height * 0.72,
        size.width * 0.12, size.height * 0.22);
    path.quadraticBezierTo(size.width * 0.22, 0, size.width * 0.5, 0);
    path.quadraticBezierTo(size.width * 0.78, 0, size.width * 0.88,
        size.height * 0.22);
    path.quadraticBezierTo(size.width * 0.95, size.height * 0.72,
        size.width * 0.5, size.height);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(NoseGuidePainter oldDelegate) => false;
}