package com.petnose.api.service.chat;

import com.petnose.api.domain.enums.AdoptionPostStatus;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class ChatRoomStateTest {

    @Test
    void openAllowsActiveMessages() {
        ChatRoomState state = ChatRoomState.from(AdoptionPostStatus.OPEN);

        assertThat(state.roomStatus()).isEqualTo(ChatRoomState.ACTIVE);
        assertThat(state.messageEnabled()).isTrue();
    }

    @Test
    void reservedAllowsExistingMessagesForMvp() {
        ChatRoomState state = ChatRoomState.from(AdoptionPostStatus.RESERVED);

        assertThat(state.roomStatus()).isEqualTo(ChatRoomState.ACTIVE);
        assertThat(state.messageEnabled()).isTrue();
    }

    @Test
    void completedIsReadOnly() {
        ChatRoomState state = ChatRoomState.from(AdoptionPostStatus.COMPLETED);

        assertThat(state.roomStatus()).isEqualTo(ChatRoomState.READ_ONLY);
        assertThat(state.messageEnabled()).isFalse();
    }

    @Test
    void closedIsReadOnly() {
        ChatRoomState state = ChatRoomState.from(AdoptionPostStatus.CLOSED);

        assertThat(state.roomStatus()).isEqualTo(ChatRoomState.READ_ONLY);
        assertThat(state.messageEnabled()).isFalse();
    }

    @Test
    void draftIsDisabled() {
        ChatRoomState state = ChatRoomState.from(AdoptionPostStatus.DRAFT);

        assertThat(state.roomStatus()).isEqualTo(ChatRoomState.DISABLED);
        assertThat(state.messageEnabled()).isFalse();
    }

    @Test
    void nullStatusIsDisabled() {
        ChatRoomState state = ChatRoomState.from(null);

        assertThat(state.roomStatus()).isEqualTo(ChatRoomState.DISABLED);
        assertThat(state.messageEnabled()).isFalse();
    }
}
