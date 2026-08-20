import 'package:flutter/material.dart';
import 'login_screen.dart';
import 'AppColor.dart';
import '../services/auth_service.dart';

class FindAccountPage extends StatefulWidget {
  const FindAccountPage({super.key});

  @override
  State<FindAccountPage> createState() => _FindAccountPageState();
}

class _FindAccountPageState extends State<FindAccountPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final TextEditingController pwEmailController = TextEditingController();
  final AuthService _authService = AuthService();
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    pwEmailController.dispose();
    super.dispose();
  }

  /// 안내 팝업 공통 함수
  void _showResultDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        backgroundColor: AppColors.background,
        title: Text(
          title,
          style: const TextStyle(
            color: AppColors.text,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          content,
          style: const TextStyle(
            color: Colors.brown,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                    (route) => false,
              );
            },
            child: const Text(
              "로그인 화면으로 돌아가기",
              style: TextStyle(
                color: AppColors.point,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 비밀번호 찾기 (이메일 하나만 검증)
  Future<void> findPassword() async {
    final email = pwEmailController.text.trim();

    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이메일을 입력해주세요.')),
      );
      return;
    }

    if (_isSubmitting) return;

    setState(() {
      _isSubmitting = true;
    });

    final result = await _authService.requestPasswordReset(email: email);

    if (!mounted) return;
    setState(() {
      _isSubmitting = false;
    });

    if (result['success'] == true) {
      _showResultDialog(
        "요청 완료",
        "가입된 이메일이라면 임시 비밀번호를 발송했습니다.\n메일을 확인한 뒤 로그인해서 비밀번호를 변경해주세요.",
      );
    } else {
      _showResultDialog(
        "요청 실패",
        result['message'] ?? "비밀번호 찾기 요청을 처리하지 못했습니다.",
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        automaticallyImplyLeading: true, // 뒤로가기 버튼 활성화
        elevation: 0,
        backgroundColor: AppColors.background,
        centerTitle: true,
        iconTheme: const IconThemeData(color: AppColors.text),
        title: const Text(
          "계정 찾기",
          style: TextStyle(
            color: AppColors.text,
            fontWeight: FontWeight.bold,
          ),
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.point,
          labelColor: AppColors.text,
          unselectedLabelColor: Colors.brown,
          tabs: const [
            Tab(text: "안내"),
            Tab(text: "비밀번호 찾기"),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          /// 1 탭: 계정 안내 (이메일이 아이디임을 명시)
          SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                const SizedBox(height: 40),
                Container(
                  width: 85,
                  height: 85,
                  decoration: BoxDecoration(
                    color: AppColors.text,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.info_outline,
                    color: Colors.white,
                    size: 38,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  "아이디 안내",
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 20),

                // 줄바꿈을 문맥에 맞게 다듬었습니다
                const Text(
                  "Nosetag 플랫폼은 별도의 아이디를\n"
                      "사용하지 않고, 고객님이 가입하신\n"
                      "[이메일 주소]를 아이디로 사용합니다.",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.brown,
                    height: 1.6, // 줄 간격(Line Height)을 살짝 넓혀서 더 편하게 읽히게 했습니다
                    fontSize: 16,
                  ),
                ),

                const SizedBox(height: 40),
                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.text,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    onPressed: () => _tabController.animateTo(1),
                    child: const Text(
                      "비밀번호 찾으러 가기",
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),

          ///비번
          SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                const SizedBox(height: 40),
                Container(
                  width: 85,
                  height: 85,
                  decoration: BoxDecoration(
                    color: AppColors.text,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.lock_reset,
                    color: Colors.white,
                    size: 38,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  "비밀번호 찾기",
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  "가입하신 이메일 주소를 입력해주세요.",
                  style: TextStyle(
                    color: Colors.brown,
                  ),
                ),
                const SizedBox(height: 40),

                // 아이디 입력창 제거하고 이메일 입력창 하나만 남김!
                FindTextField(
                  controller: pwEmailController,
                  hint: "가입 이메일 입력 (예: petnose@test.com)",
                  icon: Icons.mail_outline,
                ),

                const SizedBox(height: 30),
                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.text,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    onPressed: _isSubmitting ? null : findPassword,
                    child: _isSubmitting
                        ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white,
                      ),
                    )
                        : const Text(
                      "비밀번호 찾기",
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
        ],
      ),
    );
  }
}

/// 공용 텍스트필드
class FindTextField extends StatelessWidget {
  final String hint;
  final IconData icon;
  final bool obscure;
  final TextEditingController? controller;

  const FindTextField({
    super.key,
    required this.hint,
    required this.icon,
    this.obscure = false,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(
          icon,
          color: AppColors.point,
        ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 18),
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
            width: 1.5,
          ),
        ),
      ),
    );
  }
}
