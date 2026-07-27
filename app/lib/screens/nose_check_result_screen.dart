import 'package:flutter/material.dart';
import 'AppColor.dart';
import 'nose_check_camera_screen.dart';
import 'board_screen.dart';

class NoseCheckResultScreen extends StatelessWidget {
  final bool isMatched;
  final double? similarityScore;
  final double? threshold;
  final String message;

  const NoseCheckResultScreen({
    super.key,
    required this.isMatched,
    this.similarityScore,
    this.threshold,
    this.message = '',
  });

  @override
  Widget build(BuildContext context) {
    final scoreText = similarityScore != null
        ? '유사도: ${(similarityScore! * 100).toStringAsFixed(1)}%'
        : '';

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('비문 확인 결과'),
        backgroundColor: AppColors.darkBrown,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(
                builder: (_) => const MainScreen(initialIndex: 2),
              ),
                  (route) => false,
            );
          },
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 35, 22, 22),
        child: Column(
          children: [
            CircleAvatar(
              radius: 55,
              backgroundColor: isMatched
                  ? Colors.green.withOpacity(0.15)
                  : Colors.red.withOpacity(0.15),
              child: Icon(
                isMatched ? Icons.check : Icons.close,
                size: 55,
                color: isMatched ? Colors.green : Colors.redAccent,
              ),
            ),

            const SizedBox(height: 24),

            Text(
              isMatched ? '동일 개체 확인!' : '비문이 일치하지 않습니다',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: isMatched ? Colors.green : Colors.redAccent,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 16),

            Text(
              message.isNotEmpty
                  ? message
                  : isMatched
                  ? '촬영한 비문이 등록된 강아지와 일치합니다.'
                  : '촬영한 비문이 등록된 강아지와 일치하지 않습니다.',
              style: const TextStyle(
                fontSize: 15,
                color: AppColors.text,
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 32),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: isMatched
                      ? Colors.green.shade200
                      : Colors.red.shade200,
                ),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Icon(Icons.pets_rounded,
                            color: AppColors.text, size: 36),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isMatched ? '동일 개체 확인' : '불일치',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: AppColors.text,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              isMatched
                                  ? '등록된 비문과 동일합니다'
                                  : '등록된 비문과 다릅니다',
                              style: TextStyle(
                                fontSize: 13,
                                color: isMatched
                                    ? Colors.green
                                    : Colors.redAccent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  if (scoreText.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        scoreText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isMatched ? Colors.green : Colors.redAccent,
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 18),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      isMatched
                          ? '게시글의 강아지와 실제 강아지가 동일한 개체로 확인되었습니다.'
                          : '환경이나 위치에 따라 인식이 달라질 수 있습니다.\n다시 촬영해주세요.',
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.text,
                        height: 1.6,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                  isMatched ? AppColors.darkBrown : Colors.redAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onPressed: () {
                  if (isMatched) {
                    Navigator.pushAndRemoveUntil(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const MainScreen(initialIndex: 2),
                      ),
                          (route) => false,
                    );
                  } else {
                    Navigator.pop(context);
                  }
                },
                child: Text(
                  isMatched ? '확인 완료' : '다시 촬영하기',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}