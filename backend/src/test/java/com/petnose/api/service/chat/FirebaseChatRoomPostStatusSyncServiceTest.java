package com.petnose.api.service.chat;

import com.google.cloud.firestore.Firestore;
import com.petnose.api.domain.enums.AdoptionPostStatus;
import org.junit.jupiter.api.Test;
import org.springframework.context.support.StaticApplicationContext;

import static org.assertj.core.api.Assertions.assertThatCode;

class FirebaseChatRoomPostStatusSyncServiceTest {

    @Test
    void firebaseDisabledDoesNotThrow() {
        try (StaticApplicationContext context = new StaticApplicationContext()) {
            FirebaseChatRoomPostStatusSyncService service = new FirebaseChatRoomPostStatusSyncService(
                    context.getBeanProvider(Firestore.class)
            );

            assertThatCode(() -> service.syncPostStatus(1L, AdoptionPostStatus.OPEN))
                    .doesNotThrowAnyException();
        }
    }
}
