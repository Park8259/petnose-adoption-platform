import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'AppColor.dart';

class NoseAuthCameraScreen extends StatefulWidget {
  const NoseAuthCameraScreen({super.key});

  @override
  State<NoseAuthCameraScreen> createState() => _NoseAuthCameraScreenState();
}

class _NoseAuthCameraScreenState extends State<NoseAuthCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isInitializing = true;
  bool _isTakingPhoto = false;

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

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isTakingPhoto) return;

    setState(() => _isTakingPhoto = true);

    try {
      await controller.takePicture();
      setState(() => _isTakingPhoto = false);

      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('인증 완료'),
            content: const Text('비문 인증이 완료되었습니다.'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.pop(context, true);
                },
                child: const Text('확인'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      setState(() => _isTakingPhoto = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('촬영에 실패했습니다: $e')),
        );
      }
    }
  }

  Widget _buildCameraPreview() {
    if (_isInitializing) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: Text('카메라를 사용할 수 없습니다.', style: TextStyle(color: Colors.white54)),
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
          // 카메라 배경
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
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                    ),
                    const Expanded(
                      child: Text(
                        '비문 촬영',
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

          // 하단 버튼
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '코를 가이드 안에 맞춰주세요',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 20),
                    GestureDetector(
                      onTap: _isTakingPhoto ? null : _takePhoto,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          border: Border.all(color: AppColors.darkBrown, width: 4),
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
                            : const Icon(Icons.camera_alt, color: AppColors.darkBrown, size: 34),
                      ),
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
    path.quadraticBezierTo(size.width * 0.05, size.height * 0.72, size.width * 0.12, size.height * 0.22);
    path.quadraticBezierTo(size.width * 0.22, 0, size.width * 0.5, 0);
    path.quadraticBezierTo(size.width * 0.78, 0, size.width * 0.88, size.height * 0.22);
    path.quadraticBezierTo(size.width * 0.95, size.height * 0.72, size.width * 0.5, size.height);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(NoseGuidePainter oldDelegate) => false;
}