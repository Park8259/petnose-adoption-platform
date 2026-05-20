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
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
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
        user.setEmail("chat-user@example.com");
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
        mockMvc.perform(post("/api/firebase/custom-token")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + token))
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.error_code").value("FIREBASE_DISABLED"));
    }
}
