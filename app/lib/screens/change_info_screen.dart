import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'AppColor.dart';
import 'AppData.dart';
import '../services/api_config.dart';

class ChangeInfo extends StatefulWidget {
  const ChangeInfo({super.key});

  @override
  State<ChangeInfo> createState() => _ChangeInfoState();
}

class _ChangeInfoState extends State<ChangeInfo> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _regionController = TextEditingController();

  final TextEditingController _currentPasswordController =
  TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _newPasswordCheckController =
  TextEditingController();

  final ImagePicker _picker = ImagePicker();

  bool _isLoading = true;
  bool _isSaving = false;
  bool _isModified = false;

  String originalName = '';
  String originalPhone = '';
  String originalRegion = '';

  String? _profileImageUrl;
  File? _selectedProfileImage;

  @override
  void initState() {
    super.initState();
    _loadMyInfo();

    _nameController.addListener(_checkModified);
    _phoneController.addListener(_checkModified);
    _regionController.addListener(_checkModified);
  }

  Future<String> _getToken() async {
    if (AppUser.accessToken.isNotEmpty) return AppUser.accessToken;

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token') ?? '';
    AppUser.accessToken = token;
    return token;
  }

  Future<void> _loadMyInfo() async {
    final token = await _getToken();

    if (token.isEmpty) {
      _showSnackBar('로그인이 필요합니다.');
      setState(() => _isLoading = false);
      return;
    }

    try {
      final response = await http.get(
        Uri.parse(ApiConfig.api('/users/me')),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );

      final data = jsonDecode(utf8.decode(response.bodyBytes));

      if (response.statusCode == 200) {
        setState(() {
          _emailController.text = data['email'] ?? '';
          _nameController.text = data['display_name'] ?? '';
          _phoneController.text = data['contact_phone'] ?? '';
          _regionController.text = data['region'] ?? '';

          _profileImageUrl = data['profile_image_url'];

          originalName = _nameController.text;
          originalPhone = _phoneController.text;
          originalRegion = _regionController.text;

          _isLoading = false;
          _isModified = false;
        });
      } else {
        _showSnackBar(data['message'] ?? '내 정보를 불러오지 못했습니다.');
        setState(() => _isLoading = false);
      }
    } catch (e) {
      _showSnackBar('서버 연결 실패: $e');
      setState(() => _isLoading = false);
    }
  }

  void _checkModified() {
    setState(() {
      _isModified = _nameController.text != originalName ||
          _phoneController.text != originalPhone ||
          _regionController.text != originalRegion;
    });
  }

  Future<void> _saveChanges() async {
    final token = await _getToken();

    if (token.isEmpty) {
      _showSnackBar('로그인이 필요합니다.');
      return;
    }

    if (_nameController.text.trim().isEmpty) {
      _showSnackBar('닉네임을 입력해주세요.');
      return;
    }

    if (_phoneController.text.trim().isEmpty) {
      _showSnackBar('전화번호를 입력해주세요.');
      return;
    }

    if (_regionController.text.trim().isEmpty) {
      _showSnackBar('지역을 입력해주세요.');
      return;
    }

    setState(() => _isSaving = true);

    try {
      final response = await http.patch(
        Uri.parse(ApiConfig.api('/users/me/profile')),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'display_name': _nameController.text.trim(),
          'contact_phone': _phoneController.text.trim(),
          'region': _regionController.text.trim(),
        }),
      );

      final data = jsonDecode(utf8.decode(response.bodyBytes));

      if (response.statusCode == 200) {
        setState(() {
          originalName = data['display_name'] ?? _nameController.text;
          originalPhone = data['contact_phone'] ?? _phoneController.text;
          originalRegion = data['region'] ?? _regionController.text;
          _isModified = false;
        });

        _showSuccessDialog();
      } else {
        _showSnackBar(data['message'] ?? '회원정보 수정에 실패했습니다.');
      }
    } catch (e) {
      _showSnackBar('서버 연결 실패: $e');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _pickAndUploadProfileImage() async {
    final token = await _getToken();

    if (token.isEmpty) {
      _showSnackBar('로그인이 필요합니다.');
      return;
    }

    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;

    final file = File(picked.path);

    try {
      final request = http.MultipartRequest(
        'PATCH',
        Uri.parse(ApiConfig.api('/users/me/profile-image')),
      );

      request.headers['Authorization'] = 'Bearer $token';
      request.headers['Accept'] = 'application/json';

      final ext = file.path.split('.').last.toLowerCase();
      final mimeType = ext == 'png' ? 'image/png' : 'image/jpeg';

      request.files.add(
        await http.MultipartFile.fromPath(
          'profile_image',
          file.path,
          contentType: MediaType.parse(mimeType),
        ),
      );

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);
      final data = jsonDecode(utf8.decode(response.bodyBytes));

      if (response.statusCode == 200) {
        setState(() {
          _selectedProfileImage = file;
          _profileImageUrl = data['profile_image_url'];
        });

        _showSnackBar('프로필 사진이 변경되었습니다.');
      } else {
        _showSnackBar(data['message'] ?? '프로필 사진 변경에 실패했습니다.');
      }
    } catch (e) {
      _showSnackBar('서버 연결 실패: $e');
    }
  }

  Future<void> _changePassword() async {
    final token = await _getToken();

    if (token.isEmpty) {
      _showSnackBar('로그인이 필요합니다.');
      return;
    }

    if (_currentPasswordController.text.trim().isEmpty ||
        _newPasswordController.text.trim().isEmpty ||
        _newPasswordCheckController.text.trim().isEmpty) {
      _showSnackBar('비밀번호를 모두 입력해주세요.');
      return;
    }

    if (_newPasswordController.text != _newPasswordCheckController.text) {
      _showSnackBar('새 비밀번호가 일치하지 않습니다.');
      return;
    }

    try {
      final response = await http.patch(
        Uri.parse(ApiConfig.api('/users/me/password')),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'current_password': _currentPasswordController.text.trim(),
          'new_password': _newPasswordController.text.trim(),
        }),
      );

      final data = jsonDecode(utf8.decode(response.bodyBytes));

      if (response.statusCode == 200 && data['changed'] == true) {
        _currentPasswordController.clear();
        _newPasswordController.clear();
        _newPasswordCheckController.clear();

        if (mounted) Navigator.pop(context);
        _showSnackBar('비밀번호가 변경되었습니다.');
      } else {
        _showSnackBar(data['message'] ?? '비밀번호 변경에 실패했습니다.');
      }
    } catch (e) {
      _showSnackBar('서버 연결 실패: $e');
    }
  }

  void _showPasswordDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('비밀번호 변경'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomTextField(
                hint: '현재 비밀번호',
                icon: Icons.lock_outline,
                controller: _currentPasswordController,
                obscureText: true,
              ),
              const SizedBox(height: 12),
              CustomTextField(
                hint: '새 비밀번호',
                icon: Icons.lock_reset,
                controller: _newPasswordController,
                obscureText: true,
              ),
              const SizedBox(height: 12),
              CustomTextField(
                hint: '새 비밀번호 확인',
                icon: Icons.check_circle_outline,
                controller: _newPasswordCheckController,
                obscureText: true,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _currentPasswordController.clear();
                _newPasswordController.clear();
                _newPasswordCheckController.clear();
                Navigator.pop(context);
              },
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: _changePassword,
              child: const Text('변경'),
            ),
          ],
        );
      },
    );
  }

  ImageProvider? _getProfileImage() {
    if (_selectedProfileImage != null) {
      return FileImage(_selectedProfileImage!);
    }

    if (_profileImageUrl != null && _profileImageUrl!.isNotEmpty) {
      return NetworkImage(ApiConfig.fileUrl(_profileImageUrl!));
    }

    return null;
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (!mounted) return;
          Navigator.pop(context);
          Navigator.pop(context);
        });

        return const Dialog(
          backgroundColor: Colors.transparent,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: AppColors.point,
                  child: Icon(Icons.check, size: 50, color: Colors.white),
                ),
                SizedBox(height: 16),
                Text(
                  '수정 완료!',
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
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _regionController.dispose();

    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _newPasswordCheckController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profileImage = _getProfileImage();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          '회원정보 수정',
          style: TextStyle(
            color: AppColors.text,
            fontWeight: FontWeight.bold,
          ),
        ),
        iconTheme: const IconThemeData(color: AppColors.text),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Column(
          children: [
            GestureDetector(
              onTap: _pickAndUploadProfileImage,
              child: CircleAvatar(
                radius: 55,
                backgroundColor: AppColors.text,
                backgroundImage: profileImage,
                child: profileImage == null
                    ? const Icon(
                  Icons.person_outline,
                  size: 50,
                  color: Colors.white,
                )
                    : null,
              ),
            ),

            const SizedBox(height: 8),

            GestureDetector(
              onTap: _pickAndUploadProfileImage,
              child: const Text(
                '프로필 사진 변경',
                style: TextStyle(
                  color: AppColors.darkBrown,
                  fontSize: 13,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),

            const SizedBox(height: 28),

            CustomTextField(
              hint: '이메일',
              icon: Icons.email_outlined,
              controller: _emailController,
              enabled: false,
            ),

            const SizedBox(height: 18),

            CustomTextField(
              hint: '닉네임',
              icon: Icons.face_outlined,
              controller: _nameController,
            ),

            const SizedBox(height: 18),

            CustomTextField(
              hint: '전화번호',
              icon: Icons.phone_outlined,
              controller: _phoneController,
              keyboardType: TextInputType.phone,
            ),

            const SizedBox(height: 18),

            CustomTextField(
              hint: '지역',
              icon: Icons.location_on_outlined,
              controller: _regionController,
            ),

            const SizedBox(height: 36),

            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                  _isModified ? AppColors.text : Colors.grey[300],
                  foregroundColor:
                  _isModified ? Colors.white : Colors.grey[500],
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onPressed:
                (_isModified && !_isSaving) ? _saveChanges : null,
                child: _isSaving
                    ? const CircularProgressIndicator(color: Colors.white)
                    : Text(
                  _isModified ? '수정 완료' : '변경사항 없음',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton(
                onPressed: _showPasswordDialog,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: const Text(
                  '비밀번호 변경',
                  style: TextStyle(
                    color: AppColors.text,
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
  final TextInputType? keyboardType;
  final TextEditingController controller;
  final bool enabled;
  final bool obscureText;

  const CustomTextField({
    super.key,
    required this.hint,
    required this.icon,
    required this.controller,
    this.keyboardType,
    this.enabled = true,
    this.obscureText = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: keyboardType,
      obscureText: obscureText,
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: AppColors.border),
        hintText: hint,
        hintStyle: TextStyle(color: Colors.brown.withOpacity(0.5)),
        filled: true,
        fillColor: enabled ? Colors.white : Colors.grey.shade100,
        contentPadding: const EdgeInsets.symmetric(vertical: 18),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: AppColors.point, width: 2),
        ),
      ),
    );
  }
}