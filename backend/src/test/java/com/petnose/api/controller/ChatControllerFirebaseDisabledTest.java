package com.petnose.api.controller;

import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.enums.UserRole;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.service.JwtTokenService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.ResultActions;

import java.util.UUID;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class ChatControllerFirebaseDisabledTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private UserRepository userRepository;

    @Autowired
    private JwtTokenService jwtTokenService;

    private String token;

    @BeforeEach
    void setUp() {
        User user = new User();
        user.setEmail("chat-user-" + UUID.randomUUID() + "@example.com");
        user.setPasswordHash("hash");
        user.setRole(UserRole.USER);
        user.setDisplayName("채팅사용자");
        user.setContactPhone("01012345678");
        user.setRegion("서울");
        user.setActive(true);
        User saved = userRepository.save(user);

        token = jwtTokenService.createAccessToken(saved);
    }

    @Test
    void firebaseCustomTokenFailsWithFirebaseDisabled() throws Exception {
        expectFirebaseDisabled(mockMvc.perform(post("/api/firebase/custom-token")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)));
    }

    @Test
    void fcmTokenUpdateFailsWithFirebaseDisabled() throws Exception {
        expectFirebaseDisabled(mockMvc.perform(put("/api/users/me/fcm-token")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                        {
                          "fcm_token": "dummy-token",
                          "platform": "WEB"
                        }
                        """)));
    }

    @Test
    void createRoomFailsWithFirebaseDisabled() throws Exception {
        expectFirebaseDisabled(mockMvc.perform(post("/api/chat/rooms")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                        {
                          "post_id": 1
                        }
                        """)));
    }

    @Test
    void listRoomsFailsWithFirebaseDisabled() throws Exception {
        expectFirebaseDisabled(mockMvc.perform(get("/api/chat/rooms")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)));
    }

    @Test
    void sendMessageFailsWithFirebaseDisabled() throws Exception {
        expectFirebaseDisabled(mockMvc.perform(post("/api/chat/rooms/{room_id}/messages", "post_1_user_1")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                        {
                          "text": "hello",
                          "client_message_id": "disabled-test-1"
                        }
                        """)));
    }

    @Test
    void markRoomReadFailsWithFirebaseDisabled() throws Exception {
        expectFirebaseDisabled(mockMvc.perform(patch("/api/chat/rooms/{room_id}/read", "post_1_user_1")
                .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)));
    }

    private void expectFirebaseDisabled(ResultActions actions) throws Exception {
        actions.andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.error_code").value("FIREBASE_DISABLED"));
    }
}
