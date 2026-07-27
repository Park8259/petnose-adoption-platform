class AppData {
  static List<Map<String, dynamic>> dogPosts = [

    {
      'id': 1,
      'userId': 1,
      'breed': '포메라니안',
      'gender': '암컷',
      'age': '2살',
      'region': '서울',
      'price': '300,000원',
      'owner': '홍홍홍 보호자',
      'tags': ['활발함', '사람좋아함'],
      'description': '보리는 활발하고 사람을 좋아하는 아이예요...',
      'isReserved': true, //예약 여부, true=예약 중, false=예약 가능
      'needNoseAuth': true, //비문 인증 필요 여부
      'noseAuthDone': false, // 현재 비문 인증 완료 여부
      'isAdopted': true, // 입양 완료 여부
      'adopterId': 2, // 입양한 사용자 ID
      'adoptedAt': '2026-05-12', // 입양 일자
      'noseAuth1Done': true, // 1차 비문 인증 완료 여부
      'noseAuth2Done': false, //2차
      'noseAuth3Done': false, //3차
    },

    {
      'id': 2,
      'userId': 2,
      'breed': '말티즈',
      'gender': '수컷',
      'age': '5살',
      'region': '대구',
      'price': '200,000원',
      'owner': '홍길동 보호자',
      'tags': ['온순함'],
      'description': '조용하고 차분한 성격입니다...',
      'isReserved': false,
      'needNoseAuth': false,
      'noseAuthDone': true,
      'isAdopted': false,
      'adopterId': null,
      'adoptedAt': null,
      'noseAuth1Done': false,
      'noseAuth2Done': false,
      'noseAuth3Done': false,
    },
  ];
}

class AppUser {

  static List<Map<String, dynamic>> users = [

    {
      'id': 1,
      'loginId': 'test1',
      'password': '1234',
      'email': 'test1@naver.com',
      'name': '홍홍홍',
      'phone_number': '010-0000-0000',
      'joinDate': '2025.01.01',
      'rating': 4.5,
      'liked': <int, bool>{
        1: false,
        2: true,
      },
    },

    {
      'id': 2,
      'loginId': 'hello',
      'password': 'hi',
      'email': 'hello@naver.com',
      'name': '홍길동',
      'phone_number': '010-1234-5678',
      'joinDate': '2025.01.10',
      'rating': 4.0,

      'liked': <int, bool>{
        1: true,
        2: false,
      },
    },
  ];

  static int currentUserId = 2;

  static String accessToken = '';

  static Map<String, dynamic> get me {
    return users.firstWhere((u) => u['id'] == currentUserId);
  }

  static Map<String, dynamic>? getUserById(int id) {
    return users.firstWhere(
          (user) => user['id'] == id,
      orElse: () => {},
    );
  }
}