package com.petnose.api.service.chat;

import com.google.cloud.firestore.Firestore;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.messaging.FirebaseMessaging;
import com.petnose.api.domain.entity.User;
import com.petnose.api.dto.chat.FirebaseTokenResponse;
import com.petnose.api.repository.AdoptionPostRepository;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.service.FileStorageService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.beans.factory.ObjectProvider;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class FirebaseChatServiceTest {

    @Mock
    private AdoptionPostRepository adoptionPostRepository;
    @Mock
    private DogRepository dogRepository;
    @Mock
    private DogImageRepository dogImageRepository;
    @Mock
    private UserRepository userRepository;
    @Mock
    private FileStorageService fileStorageService;
    @Mock
    private ObjectProvider<Firestore> firestoreProvider;
    @Mock
    private ObjectProvider<FirebaseAuth> firebaseAuthProvider;
    @Mock
    private ObjectProvider<FirebaseMessaging> firebaseMessagingProvider;
    @Mock
    private FirebaseAuth firebaseAuth;

    @Test
    void createFirebaseTokenUsesUidOnlyWithoutReservedClaims() throws Exception {
        User user = activeUser(42L);
        when(userRepository.findById(user.getId())).thenReturn(Optional.of(user));
        when(firebaseAuthProvider.getIfAvailable()).thenReturn(firebaseAuth);
        when(firebaseAuth.createCustomToken("user_42")).thenReturn("custom-token");

        FirebaseChatService service = new FirebaseChatService(
                adoptionPostRepository,
                dogRepository,
                dogImageRepository,
                userRepository,
                fileStorageService,
                firestoreProvider,
                firebaseAuthProvider,
                firebaseMessagingProvider
        );

        FirebaseTokenResponse response = service.createFirebaseToken(user.getId());

        assertThat(response.firebaseUid()).isEqualTo("user_42");
        assertThat(response.firebaseCustomToken()).isEqualTo("custom-token");
        verify(firebaseAuth).createCustomToken("user_42");
        verify(firebaseAuth, never()).createCustomToken(anyString(), anyMap());
    }

    private User activeUser(Long userId) {
        User user = new User();
        user.setId(userId);
        user.setEmail("user@example.com");
        user.setPasswordHash("hash");
        user.setActive(true);
        return user;
    }
}
