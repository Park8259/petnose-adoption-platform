import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';

import 'AppColor.dart';
import 'package:nosetag_app/services/auth_service.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  bool isChecked = false;
  bool isLoading = false;

  File? _profileImage;
  final ImagePicker _picker = ImagePicker();

  // 백엔드 명세에 맞추어 _idController 제거 (이메일 로그인 기반)
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _regionController = TextEditingController();

  final AuthService _authService = AuthService();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _regionController.dispose();
    super.dispose();
  }

  Future<void> _pickImageFromGallery() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1000,
        maxHeight: 1000,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _profileImage = File(image.path);
        });
        if (!mounted) return;
        Navigator.pop(context);
      }
    } catch (e) {
      _showSnackBar('이미지를 불러오는데 실패했습니다.');
    }
  }

  Future<void> _pickImageFromCamera() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1000,
        maxHeight: 1000,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _profileImage = File(image.path);
        });
        if (!mounted) return;
        Navigator.pop(context);
      }
    } catch (e) {
      _showSnackBar('카메라 실행 실패');
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _register() async {
    // 1. 유효성 검사 (Validation)
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();
    final region = _regionController.text.trim();

    if (!email.contains('@') || email.length < 5) {
      _showSnackBar('올바른 이메일 형식을 입력해주세요.');
      return;
    }

    if (password.length < 8) {
      _showSnackBar('비밀번호는 8자 이상이어야 합니다.');
      return;
    }

    if (name.isEmpty) {
      _showSnackBar('닉네임(이름)을 입력해주세요.');
      return;
    }

    if (phone.isEmpty) {
      _showSnackBar('전화번호를 입력해주세요.');
      return;
    }

    if (region.isEmpty) {
      _showSnackBar('지역을 입력해주세요.');
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final result = await _authService.register(
        email: email,
        password: password,
        name: name,
        phone: phone,
        region: region,
        profileImage: _profileImage,
      );

      setState(() {
        isLoading = false;
      });

      if (result['success']) {
        if (!mounted) return;


        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) {
            Future.delayed(
              const Duration(seconds: 2),
                  () {
                if (Navigator.canPop(context)) {
                  Navigator.pop(context); // 다이얼로그 닫기
                  Navigator.pop(context); // 가입화면 탈출 -> 로그인 화면으로 이동
                }
              },
            );

            return const Dialog(
              backgroundColor: Colors.transparent,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundColor: AppColors.point,
                      child: Icon(
                        Icons.check,
                        size: 50,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 16),
                    Text(
                      "가입 완료!",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      } else {
        _showSnackBar(result['message'] ?? '회원가입 실패');
      }
    } catch (e) {
      setState(() {
        isLoading = false;
      });
      _showSnackBar('서버와 통신 중 에러가 발생했습니다.');
    }
  }

  void _showImagePickerOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(20),
        ),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "프로필 사진 선택",
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text("갤러리에서 선택"),
                onTap: _pickImageFromGallery,
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text("카메라로 촬영"),
                onTap: _pickImageFromCamera,
              ),
              if (_profileImage != null)
                ListTile(
                  leading: const Icon(
                    Icons.delete,
                    color: Colors.red,
                  ),
                  title: const Text(
                    "프로필 사진 삭제",
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () {
                    setState(() {
                      _profileImage = null;
                    });
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "회원가입",
          style: TextStyle(
            color: AppColors.text,
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(
          color: AppColors.text,
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: 24,
          vertical: 20,
        ),
        child: Column(
          children: [
            Stack(
              children: [
                Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    color: AppColors.background,
                    borderRadius: BorderRadius.circular(55),
                    border: Border.all(
                      color: AppColors.text,
                      width: 5,
                    ),
                    image: _profileImage != null
                        ? DecorationImage(
                      image: FileImage(_profileImage!),
                      fit: BoxFit.cover,
                    )
                        : null,
                  ),
                  child: _profileImage == null
                      ? const Icon(
                    Icons.person_outline,
                    size: 45,
                    color: AppColors.text,
                  )
                      : null,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: _showImagePickerOptions,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppColors.point,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white,
                          width: 3,
                        ),
                      ),
                      child: const Icon(
                        Icons.camera_alt,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: _showImagePickerOptions,
              child: Text(
                _profileImage == null ? "프로필 사진 추가" : "프로필 사진 변경",
                style: const TextStyle(
                  color: Colors.brown,
                ),
              ),
            ),
            const SizedBox(height: 36),

            // 백엔드 명세에 맞춰 이메일을 가장 먼저 입력하도록 구성
            CustomTextField(
              hint: "이메일 (로그인 ID로 사용됩니다)",
              icon: Icons.email_outlined,
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 18),
            CustomTextField(
              hint: "비밀번호 (8자 이상)",
              icon: Icons.lock_outline,
              controller: _passwordController,
              obscure: true,
            ),
            const SizedBox(height: 18),
            CustomTextField(
              hint: "닉네임",
              icon: Icons.face_outlined,
              controller: _nameController,
            ),
            const SizedBox(height: 18),
            CustomTextField(
              hint: "전화번호 (예: 01012345678)",
              icon: Icons.phone_outlined,
              controller: _phoneController,
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 18),
            CustomTextField(
              hint: "지역 (예: 서울, 부산 등)",
              icon: Icons.location_on_outlined,
              controller: _regionController,
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Checkbox(
                  activeColor: AppColors.text,
                  value: isChecked,
                  onChanged: (value) {
                    setState(() {
                      isChecked = value!;
                    });
                  },
                ),
                const Expanded(
                  child: Text(
                    "이용약관 및 개인정보처리방침에 동의합니다.",
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.text,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onPressed: isLoading ? null : (isChecked ? _register : null),
                child: isLoading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text(
                  "가입 완료",
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CustomTextField extends StatelessWidget {
  final String hint;
  final IconData icon;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextEditingController? controller;

  const CustomTextField({
    super.key,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.keyboardType,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        prefixIcon: Icon(
          icon,
          color: AppColors.border,
        ),
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(
            color: AppColors.border,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(
            color: AppColors.point,
            width: 2,
          ),
        ),
      ),
    );
  }
}