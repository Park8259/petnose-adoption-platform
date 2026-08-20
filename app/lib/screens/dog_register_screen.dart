import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'AppColor.dart';
import 'dog_register_camera_screen.dart';
import '../models/profile_nose_preview_response.dart';
import '../services/dog_service.dart';

class DogRegisterScreen extends StatefulWidget {
  const DogRegisterScreen({super.key});

  @override
  State<DogRegisterScreen> createState() => _DogRegisterScreenState();
}

class _DogRegisterScreenState extends State<DogRegisterScreen> {
  final TextEditingController breedController = TextEditingController();
  final TextEditingController ageController = TextEditingController();
  final TextEditingController regionController = TextEditingController();
  final TextEditingController priceController = TextEditingController();
  final TextEditingController healthController = TextEditingController();
  final TextEditingController introController = TextEditingController();

  String selectedGender = '암컷';
  final List<File> _selectedImages = []; // ← 리스트로 변경
  File? _faceNoseCheckImage;
  bool _isCheckingFaceNose = false;
  ProfileNosePreviewResponse? _faceNosePreviewResult;
  String? _faceNosePreviewError;
  int _faceNosePreviewRequestSeq = 0;
  final ImagePicker _picker = ImagePicker();
  final DogService _dogService = DogService();
  static const int _maxImages = 5; // 최대 사진 수

  bool get _faceNoseCheckPassed {
    final response = _faceNosePreviewResult;
    return _faceNoseCheckImage != null &&
        !_isCheckingFaceNose &&
        response != null &&
        response.success &&
        response.extracted &&
        response.qualityPassed != false;
  }

  final List<String> hashtagOptions = [
    '귀여움',
    '활발함',
    '온순함',
    '애교많음',
    '사람좋아함',
    '산책좋아함',
    '장난꾸러기',
    '조용함',
    '건강함',
    '낯가림',
  ];

  final List<String> selectedTags = [];

  Future<void> _showFaceNoseImagePickerModal() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '얼굴·코 확인용 정면 사진',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 20),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _pickerIcon(Icons.camera_alt_rounded),
                  title: const Text(
                    '카메라로 촬영',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                  subtitle: const Text('얼굴과 코가 잘 보이도록 정면에서 찍어요'),
                  onTap: () async {
                    Navigator.pop(context);
                    await _pickFaceNoseImage(ImageSource.camera);
                  },
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _pickerIcon(Icons.photo_library_rounded),
                  title: const Text(
                    '갤러리에서 선택',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                  subtitle: const Text('얼굴과 코가 잘 보이는 사진을 골라요'),
                  onTap: () async {
                    Navigator.pop(context);
                    await _pickFaceNoseImage(ImageSource.gallery);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _pickerIcon(IconData icon) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.darkBrown.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: AppColors.darkBrown),
    );
  }

  Future<void> _pickFaceNoseImage(ImageSource source) async {
    final XFile? image = await _picker.pickImage(
      source: source,
      imageQuality: 85,
      maxWidth: 1500,
      maxHeight: 1500,
    );
    if (image == null) return;

    await _startFaceNosePreview(File(image.path));
  }

  Future<void> _startFaceNosePreview(File image) async {
    final requestSeq = ++_faceNosePreviewRequestSeq;
    setState(() {
      _faceNoseCheckImage = image;
      _isCheckingFaceNose = true;
      _faceNosePreviewResult = null;
      _faceNosePreviewError = null;
    });

    ProfileNosePreviewResponse response;
    try {
      response = await _dogService.previewProfileNose(image);
    } catch (_) {
      response = ProfileNosePreviewResponse.failure(
        message: '서버에 연결할 수 없습니다. 잠시 후 다시 시도해주세요.',
      );
    }

    if (!mounted ||
        requestSeq != _faceNosePreviewRequestSeq ||
        _faceNoseCheckImage?.path != image.path) {
      return;
    }

    final message = _profileNosePreviewMessage(response);
    final passed =
        response.success &&
        response.extracted &&
        response.qualityPassed != false;
    setState(() {
      _isCheckingFaceNose = false;
      _faceNosePreviewResult = response;
      _faceNosePreviewError = passed ? null : message;
    });

    if (!passed) _showSnack(message);
  }

  String _profileNosePreviewMessage(ProfileNosePreviewResponse response) {
    if (response.success &&
        response.extracted &&
        response.qualityPassed != false) {
      return '코 영역 확인 완료';
    }
    if (response.isDetectorUnavailable) {
      return response.message ?? '서버의 자동 코 검출기가 비활성화되어 있습니다. 시연 서버 설정을 확인해주세요.';
    }
    if (!response.success) {
      final serverMessage = response.message;
      final statusCode = response.httpStatusCode;
      if (statusCode == 400) {
        return serverMessage ?? '선택한 사진을 확인할 수 없습니다. 다른 사진을 선택해주세요.';
      }
      if (statusCode == 401 || statusCode == 403) {
        return serverMessage ?? '로그인 세션을 확인한 뒤 다시 시도해주세요.';
      }
      if (statusCode == 404) {
        return serverMessage ?? '서버의 프로필 미리보기 API 경로를 확인해주세요.';
      }
      if (statusCode == 503) {
        return serverMessage ?? '서버의 자동 코 검출기를 사용할 수 없습니다.';
      }
      if (statusCode != null && statusCode >= 500) {
        return serverMessage ?? '서버 오류로 코 영역을 확인하지 못했습니다. 잠시 후 다시 시도해주세요.';
      }
      return serverMessage ?? '서버에 연결할 수 없습니다. 잠시 후 다시 시도해주세요.';
    }
    final faceCheckMessage = response.faceCheckFailureMessage;
    if (faceCheckMessage != null) return faceCheckMessage;
    if (response.message != null) return response.message!;
    return '코 영역을 확인하지 못했습니다. 다른 사진을 선택해주세요.';
  }

  String get _faceNoseStatusText {
    if (_faceNoseCheckImage == null) {
      return '강아지 얼굴과 코가 잘 보이는 정면 사진을 1장 추가해주세요.';
    }
    if (_isCheckingFaceNose) {
      return '코 영역을 확인하는 중입니다...';
    }
    if (_faceNoseCheckPassed) {
      return '코 영역 확인 완료';
    }
    return _faceNosePreviewError ?? '얼굴·코 확인용 정면 사진의 코 영역 확인이 필요합니다.';
  }

  String? get _faceNoseDetailText {
    final response = _faceNosePreviewResult;
    if (_faceNoseCheckPassed) {
      final confidence = response?.confidence;
      final confidenceText = confidence == null
          ? null
          : '검출 신뢰도 ${(confidence * 100).toStringAsFixed(1)}%';
      if (confidenceText == null) {
        return '정면 사진이 인증 준비에 적합합니다.';
      }
      return '정면 사진이 인증 준비에 적합합니다.\n$confidenceText';
    }
    final reason = response?.effectiveFailureReason;
    if (kDebugMode && reason != null && reason.isNotEmpty) {
      return 'failure_reason: $reason';
    }
    return null;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  void _showImagePickerModal() {
    if (_selectedImages.length >= _maxImages) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('사진은 최대 $_maxImages장까지 등록할 수 있어요.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '사진 추가',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 20),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppColors.darkBrown.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.camera_alt_rounded,
                      color: AppColors.darkBrown,
                    ),
                  ),
                  title: const Text(
                    '카메라로 촬영',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                  subtitle: const Text('지금 바로 사진을 찍어요'),
                  onTap: () async {
                    Navigator.pop(context);
                    final XFile? photo = await _picker.pickImage(
                      source: ImageSource.camera,
                      imageQuality: 85,
                    );
                    if (photo != null) {
                      setState(() => _selectedImages.add(File(photo.path)));
                    }
                  },
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppColors.darkBrown.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.photo_library_rounded,
                      color: AppColors.darkBrown,
                    ),
                  ),
                  title: const Text(
                    '갤러리에서 선택',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                  subtitle: const Text('여러 장을 한 번에 선택할 수 있어요'),
                  onTap: () async {
                    Navigator.pop(context);
                    final int remaining = _maxImages - _selectedImages.length;
                    final List<XFile> images = await _picker.pickMultiImage(
                      imageQuality: 85,
                    );
                    if (images.isNotEmpty) {
                      final picked = images
                          .take(remaining)
                          .map((e) => File(e.path))
                          .toList();
                      if (!mounted) return;
                      setState(() => _selectedImages.addAll(picked));
                      if (images.length > remaining) {
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(
                            content: Text(
                              '최대 $_maxImages장까지만 등록돼요. ${images.length - remaining}장은 제외됐어요.',
                            ),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                      }
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 사진 삭제
  void _removeImage(int index) {
    setState(() => _selectedImages.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('강아지 등록'),
        backgroundColor: AppColors.darkBrown,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '분양할 강아지 정보를 입력해주세요',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.text,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '강아지 정보를 자세히 입력할수록 신뢰도가 올라갑니다.',
              style: TextStyle(fontSize: 13, color: Colors.brown),
            ),
            const SizedBox(height: 28),

            // ───── 사진 영역 ─────
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '강아지 사진',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_selectedImages.length}/$_maxImages',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 100,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      // 추가 버튼
                      if (_selectedImages.length < _maxImages)
                        GestureDetector(
                          onTap: _showImagePickerModal,
                          child: Container(
                            width: 100,
                            height: 100,
                            margin: const EdgeInsets.only(right: 10),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: AppColors.border,
                                width: 1.5,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.add_photo_alternate_rounded,
                                  size: 30,
                                  color: AppColors.darkBrown,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '사진 추가',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.darkBrown,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // 선택된 사진들
                      ..._selectedImages.asMap().entries.map((entry) {
                        final index = entry.key;
                        final file = entry.value;
                        return Stack(
                          children: [
                            Container(
                              width: 100,
                              height: 100,
                              margin: const EdgeInsets.only(right: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: AppColors.border),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(15),
                                child: Image.file(file, fit: BoxFit.cover),
                              ),
                            ),
                            // 대표 사진 뱃지
                            if (index == 0)
                              Positioned(
                                bottom: 6,
                                left: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.darkBrown,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text(
                                    '대표',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            // 삭제 버튼
                            Positioned(
                              top: 4,
                              right: 14,
                              child: GestureDetector(
                                onTap: () => _removeImage(index),
                                child: Container(
                                  width: 22,
                                  height: 22,
                                  decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.close,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),
            _buildFaceNoseCheckSection(),
            const SizedBox(height: 30),

            // 나머지 필드들은 기존과 동일
            _label('견종'),
            _textField(controller: breedController, hint: '예) 포메라니안'),
            const SizedBox(height: 18),
            _label('성별'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _genderButton('암컷')),
                const SizedBox(width: 10),
                Expanded(child: _genderButton('수컷')),
              ],
            ),
            const SizedBox(height: 18),
            _label('나이'),
            _textField(controller: ageController, hint: '예) 2살'),
            const SizedBox(height: 18),
            _label('지역'),
            _textField(controller: regionController, hint: '예) 서울'),
            const SizedBox(height: 18),
            _label('가격'),
            _textField(controller: priceController, hint: '예) 80만원'),
            const SizedBox(height: 18),
            _label('건강 및 접종 기록'),
            _textField(controller: healthController, hint: '예) 종합백신 완료'),
            const SizedBox(height: 18),
            _label('소개 / 분양 사유'),
            _multiTextField(
              controller: introController,
              hint: '강아지 성격이나 분양 사유를 입력해주세요',
            ),
            const SizedBox(height: 18),
            _label('해시태그 선택'),
            const SizedBox(height: 8),
            const Text(
              '최대 3개까지 선택할 수 있습니다.',
              style: TextStyle(fontSize: 12, color: Colors.brown),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: hashtagOptions.map((tag) {
                final bool isSelected = selectedTags.contains(tag);
                final bool isDisabled = !isSelected && selectedTags.length >= 3;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        selectedTags.remove(tag);
                      } else if (selectedTags.length < 3) {
                        selectedTags.add(tag);
                      }
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppColors.darkBrown
                          : isDisabled
                          ? Colors.grey.shade200
                          : Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isSelected
                            ? AppColors.darkBrown
                            : AppColors.border,
                      ),
                    ),
                    child: Text(
                      '#$tag',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: isSelected
                            ? Colors.white
                            : isDisabled
                            ? Colors.grey
                            : AppColors.text,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.darkBrown,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onPressed: _isCheckingFaceNose
                    ? null
                    : () async {
                        if (_selectedImages.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('강아지 대표 사진을 1장 이상 등록해주세요.'),
                            ),
                          );
                          return;
                        }

                        if (_faceNoseCheckImage == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('얼굴·코 확인용 정면 사진을 선택해주세요.'),
                            ),
                          );
                          return;
                        }

                        if (breedController.text.trim().isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('견종을 입력해주세요.')),
                          );
                          return;
                        }

                        if (introController.text.trim().isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('소개 / 분양 사유를 입력해주세요.'),
                            ),
                          );
                          return;
                        }

                        final faceCheckImage = _faceNoseCheckImage;
                        if (!_faceNoseCheckPassed || faceCheckImage == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('얼굴·코 확인용 정면 사진의 코 영역 확인이 필요합니다.'),
                            ),
                          );
                          return;
                        }

                        if (!mounted) return;
                        final navigator = Navigator.of(context);

                        navigator.push(
                          MaterialPageRoute(
                            builder: (_) => DogRegisterCameraScreen(
                              breed: breedController.text,
                              gender: selectedGender,
                              age: ageController.text,
                              region: regionController.text,
                              price: priceController.text,
                              health: healthController.text,
                              intro: introController.text,
                              tags: selectedTags,
                              profileImage: _selectedImages.isNotEmpty
                                  ? _selectedImages.first
                                  : null,
                              faceCheckImage: faceCheckImage,
                            ),
                          ),
                        );
                      },
                child: _isCheckingFaceNose
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        '비문 촬영하기',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }

  Widget _buildFaceNoseCheckSection() {
    final image = _faceNoseCheckImage;
    final statusMessage = _faceNoseStatusText;
    final detailMessage = _faceNoseDetailText;
    final statusColor = _faceNoseCheckPassed
        ? Colors.green.shade700
        : image == null
        ? Colors.brown
        : _isCheckingFaceNose
        ? AppColors.darkBrown
        : Colors.red.shade700;
    final statusIcon = _faceNoseCheckPassed
        ? Icons.check_circle_rounded
        : _isCheckingFaceNose
        ? Icons.hourglass_top_rounded
        : image == null
        ? Icons.info_outline_rounded
        : Icons.warning_amber_rounded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '얼굴·코 확인용 정면 사진',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: AppColors.text,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '강아지 얼굴과 코가 잘 보이는 정면 사진을 1장 추가해주세요.\n'
          '이 사진은 비문 인증 전 코 영역이 잘 보이는지 확인하는 데 사용돼요.\n'
          '여러 마리가 함께 나온 사진은 피해주세요.',
          style: TextStyle(fontSize: 12, color: Colors.brown, height: 1.45),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: _isCheckingFaceNose ? null : _showFaceNoseImagePickerModal,
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.border, width: 1.5),
                ),
                child: image == null
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(
                            Icons.add_a_photo_rounded,
                            size: 28,
                            color: AppColors.darkBrown,
                          ),
                          SizedBox(height: 6),
                          Text(
                            '사진 선택',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.darkBrown,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: Image.file(image, fit: BoxFit.cover),
                      ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(statusIcon, size: 18, color: statusColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          statusMessage,
                          style: TextStyle(
                            fontSize: 13,
                            color: statusColor,
                            fontWeight: FontWeight.w600,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (detailMessage != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      detailMessage,
                      style: TextStyle(
                        fontSize: 12,
                        color: _faceNoseCheckPassed
                            ? Colors.green.shade700
                            : Colors.grey.shade600,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _isCheckingFaceNose
                        ? null
                        : _showFaceNoseImagePickerModal,
                    icon: Icon(
                      image == null
                          ? Icons.photo_library_rounded
                          : Icons.refresh_rounded,
                      size: 18,
                    ),
                    label: Text(image == null ? '정면 사진 선택' : '다시 선택'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.darkBrown,
                      side: const BorderSide(color: AppColors.border),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _label(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: AppColors.text,
      ),
    );
  }

  Widget _textField({
    required TextEditingController controller,
    required String hint,
  }) {
    return TextField(
      controller: controller,

      decoration: InputDecoration(
        hintText: hint,

        filled: true,
        fillColor: Colors.white,

        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),

        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: AppColors.border),
        ),

        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.darkBrown, width: 1.5),
        ),
      ),
    );
  }

  Widget _multiTextField({
    required TextEditingController controller,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      maxLines: 5,

      decoration: InputDecoration(
        hintText: hint,

        filled: true,
        fillColor: Colors.white,

        contentPadding: const EdgeInsets.all(16),

        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: AppColors.border),
        ),

        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppColors.darkBrown, width: 1.5),
        ),
      ),
    );
  }

  Widget _genderButton(String gender) {
    final bool isSelected = selectedGender == gender;

    return GestureDetector(
      onTap: () {
        setState(() {
          selectedGender = gender;
        });
      },

      child: Container(
        height: 52,

        decoration: BoxDecoration(
          color: isSelected ? AppColors.darkBrown : Colors.white,

          borderRadius: BorderRadius.circular(16),

          border: Border.all(color: AppColors.border),
        ),

        alignment: Alignment.center,

        child: Text(
          gender,
          style: TextStyle(
            color: isSelected ? Colors.white : AppColors.text,

            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
