import 'AppData.dart';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'AppColor.dart';
import 'dog_register_complete_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/dog_service.dart';
import '../services/api_config.dart';
import '../services/post_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DogRegisterCameraScreen extends StatefulWidget {
  final String breed;
  final String gender;
  final String age;
  final String region;
  final String price;
  final String health;
  final String intro;
  final List<String> tags;
  final File? profileImage;
  final File faceCheckImage;

  const DogRegisterCameraScreen({
    super.key,
    required this.breed,
    required this.gender,
    required this.age,
    required this.region,
    required this.price,
    required this.health,
    required this.intro,
    required this.tags,
    this.profileImage,
    required this.faceCheckImage,
  });

  @override
  State<DogRegisterCameraScreen> createState() =>
      _DogRegisterCameraScreenState();
}

class _DogRegisterCameraScreenState extends State<DogRegisterCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];

  final List<File> _photos = [];

  bool _isInitializing = true;
  bool _isTakingPhoto = false;
  bool _isSubmitting = false;

  final DogService _dogService = DogService();
  final PostService _postService = PostService();
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('카메라 권한을 허용해주세요')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('카메라를 열 수 없습니다: $e')));
      }
    }
  }

  // ── 카메라 촬영 ───────────────────────────────────────────────
  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _isTakingPhoto ||
        _photos.length >= 5) {
      return;
    }

    setState(() => _isTakingPhoto = true);

    try {
      final XFile image = await controller.takePicture();
      setState(() {
        _photos.add(File(image.path));
        _isTakingPhoto = false;
      });

      if (_photos.length >= 5 && mounted) {
        await Future.delayed(const Duration(milliseconds: 400));
        if (!mounted) return;
        await _submitDogRegister();
      }
    } catch (e) {
      setState(() => _isTakingPhoto = false);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('촬영에 실패했습니다: $e')));
    }
  }

  // ── 갤러리에서 최대 (5 - 현재장수)장 선택 ───────────────────
  Future<void> _pickFromGallery() async {
    if (_isTakingPhoto || _photos.length >= 5) return;

    final remaining = 5 - _photos.length;

    try {
      final List<XFile> picked = await _picker.pickMultiImage(
        maxWidth: 1500,
        maxHeight: 1500,
        imageQuality: 90,
      );

      if (picked.isEmpty) return;

      // 최대 remaining장만 추가
      final toAdd = picked.take(remaining).map((x) => File(x.path)).toList();

      setState(() => _photos.addAll(toAdd));

      if (_photos.length >= 5 && mounted) {
        await Future.delayed(const Duration(milliseconds: 400));
        if (!mounted) return;
        await _submitDogRegister();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('갤러리를 열 수 없습니다.')));
      }
    }
  }

  // ── 사진 한 장 삭제 ──────────────────────────────────────────
  void _removePhoto(int index) {
    setState(() => _photos.removeAt(index));
  }

  String _genderForApi(String gender) {
    if (gender == '수컷') return 'MALE';
    if (gender == '암컷') return 'FEMALE';
    return 'UNKNOWN';
  }

  Future<void> _submitDogRegister() async {
    if (_photos.isEmpty || _isSubmitting) return;
    setState(() => _isSubmitting = true);

    if (!widget.faceCheckImage.existsSync()) {
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('얼굴·코 확인용 정면 사진이 전달되지 않았습니다. 이전 단계에서 다시 선택해주세요.'),
        ),
      );
      return;
    }

    String accessToken = AppUser.accessToken;
    if (accessToken.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      accessToken = prefs.getString('access_token') ?? '';
      AppUser.accessToken = accessToken;
    }

    if (!mounted) return;
    if (ApiConfig.enableAuthHeader && accessToken.isEmpty) {
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('로그인 토큰이 아직 연결되지 않았습니다.')));
      return;
    }

    final result = await _dogService.registerDog(
      accessToken: accessToken,
      name: widget.breed.isNotEmpty ? widget.breed : '등록 강아지',
      breed: widget.breed,
      gender: _genderForApi(widget.gender),
      age: widget.age,
      price: widget.price,
      dogRegion: widget.region,
      health: widget.health,
      description: widget.intro,
      noseImages: _photos,
      profileImage: widget.profileImage,
      faceCheckImage: widget.faceCheckImage,
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    if (result['success'] == true) {
      final dogId = result['data']['dog_id'];
      final profileNoseMatchScore = _asDouble(
        result['data']['profile_nose_match_score'],
      );
      final registrationAllowed =
          result['data']['registration_allowed'] == true;

      if (!registrationAllowed) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result['data']['message'] ?? '기존 등록견과 동일 개체로 의심되어 등록이 제한됩니다.',
            ),
          ),
        );
        return;
      }

      if (widget.profileImage == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('대표 사진을 먼저 등록해주세요.')));
        return;
      }

      final postResult = await _postService.createPost(
        accessToken: accessToken,
        dogId: dogId.toString(),
        title: '${widget.breed} 가족을 찾습니다',
        content: widget.intro,
        profileImage: widget.profileImage!,
      );

      if (!mounted) return;

      if (postResult['success'] == true) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DogRegisterCompleteScreen(
              breed: widget.breed,
              gender: widget.gender,
              age: widget.age,
              region: widget.region,
              price: widget.price,
              health: widget.health,
              intro: widget.intro,
              tags: widget.tags,
              profileImage: widget.profileImage,
              profileNoseMatchScore: profileNoseMatchScore,
            ),
          ),
        );
      } else {
        final errorCode = postResult['error_code']?.toString();
        final postMessage = postResult['message'] ?? '분양글 생성 실패';
        final message = errorCode == 'DOG_OWNER_MISMATCH'
            ? '비문 인증은 완료되었지만 게시글 생성 권한 확인에 실패했습니다.'
            : '비문 인증은 완료되었지만 게시글 생성에 실패했습니다.';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$message\n$postMessage')));
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result['message'] ?? '강아지 등록에 실패했습니다.')),
      );
    }
  }

  double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
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
          _buildTopGradient(),
          _buildBottomGradient(),
          _buildAppBar(),
          _buildNoseGuideOverlay(),
          _buildBottomControls(),
        ],
      ),
    );
  }

  Widget _buildCameraPreview() {
    if (_isInitializing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.camera_alt, color: Colors.white54, size: 64),
            SizedBox(height: 12),
            Text('카메라를 사용할 수 없습니다.', style: TextStyle(color: Colors.white54)),
          ],
        ),
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

  Widget _buildTopGradient() => Positioned(
    top: 0,
    left: 0,
    right: 0,
    height: 140,
    child: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
    ),
  );

  Widget _buildBottomGradient() => Positioned(
    bottom: 0,
    left: 0,
    right: 0,
    height: 360,
    child: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
    ),
  );

  Widget _buildAppBar() => Positioned(
    top: 0,
    left: 0,
    right: 0,
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
  );

  Widget _buildNoseGuideOverlay() {
    final size = MediaQuery.of(context).size;
    return Positioned(
      top: size.height * 0.22,
      left: 0,
      right: 0,
      child: Center(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${_photos.length} / 5',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: 280,
              height: 220,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (_photos.isNotEmpty)
                    Opacity(
                      opacity: 0.5,
                      child: ClipOval(
                        child: Image.file(
                          _photos.last,
                          width: 250,
                          height: 190,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                  CustomPaint(
                    size: const Size(280, 220),
                    painter: NoseGuidePainter(
                      color: _photos.isEmpty ? Colors.white60 : AppColors.beige,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '코를 가이드 안에 맞춰주세요',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 찍힌 사진 썸네일 (탭하면 삭제)
              if (_photos.isNotEmpty) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_photos.length, (index) {
                    return GestureDetector(
                      onTap: () => _removePhoto(index),
                      child: Stack(
                        children: [
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white54,
                                width: 2,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.file(
                                _photos[index],
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            right: 0,
                            child: Container(
                              width: 16,
                              height: 16,
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close,
                                size: 11,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 20),
              ],

              // 갤러리 + 촬영 버튼
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 갤러리 버튼
                  GestureDetector(
                    onTap: (_photos.length < 5 && !_isTakingPhoto)
                        ? _pickFromGallery
                        : null,
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white24,
                        border: Border.all(color: Colors.white54, width: 1.5),
                      ),
                      child: Icon(
                        Icons.photo_library,
                        color: _photos.length < 5 ? Colors.white : Colors.grey,
                        size: 26,
                      ),
                    ),
                  ),

                  // 촬영 버튼
                  GestureDetector(
                    onTap: (_photos.length < 5 && !_isTakingPhoto)
                        ? _takePhoto
                        : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        border: Border.all(
                          color: _photos.length < 5
                              ? AppColors.darkBrown
                              : Colors.grey,
                          width: 4,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: _isTakingPhoto || _isSubmitting
                          ? const Padding(
                              padding: EdgeInsets.all(20),
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: AppColors.darkBrown,
                              ),
                            )
                          : Icon(
                              Icons.camera_alt,
                              color: _photos.length < 5
                                  ? AppColors.darkBrown
                                  : Colors.grey,
                              size: 34,
                            ),
                    ),
                  ),

                  // 대칭용 빈 공간
                  const SizedBox(width: 52, height: 52),
                ],
              ),

              const SizedBox(height: 18),
              const _GuideChips(),
            ],
          ),
        ),
      ),
    );
  }
}

class _GuideChips extends StatelessWidget {
  const _GuideChips();

  Widget _chip(String text) {
    return Container(
      width: 115,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _chip('여러 각도로'),
            const SizedBox(width: 8),
            _chip('밝은 곳에서'),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _chip('코를 가까이'),
            const SizedBox(width: 8),
            _chip('흔들림 없이'),
          ],
        ),
      ],
    );
  }
}

class NoseGuidePainter extends CustomPainter {
  final Color color;
  const NoseGuidePainter({this.color = Colors.white60});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    final path = Path();
    path.moveTo(size.width * 0.5, size.height);
    path.quadraticBezierTo(
      size.width * 0.05,
      size.height * 0.72,
      size.width * 0.12,
      size.height * 0.22,
    );
    path.quadraticBezierTo(size.width * 0.22, 0, size.width * 0.5, 0);
    path.quadraticBezierTo(
      size.width * 0.78,
      0,
      size.width * 0.88,
      size.height * 0.22,
    );
    path.quadraticBezierTo(
      size.width * 0.95,
      size.height * 0.72,
      size.width * 0.5,
      size.height,
    );
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(NoseGuidePainter oldDelegate) =>
      oldDelegate.color != color;
}
