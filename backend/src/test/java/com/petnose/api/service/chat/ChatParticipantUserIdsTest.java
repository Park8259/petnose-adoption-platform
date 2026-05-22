package com.petnose.api.service.chat;

import com.petnose.api.exception.ApiException;
import org.junit.jupiter.api.Test;

import java.util.Arrays;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ChatParticipantUserIdsTest {

    @Test
    void parsesLongValues() {
        List<Long> parsed = ChatParticipantUserIds.parse(List.of(1L, 2L));

        assertThat(parsed).containsExactly(1L, 2L);
    }

    @Test
    void parsesMixedNumberTypes() {
        List<Long> parsed = ChatParticipantUserIds.parse(List.of(1, 2L));

        assertThat(parsed).containsExactly(1L, 2L);
    }

    @Test
    void parsesNumericStrings() {
        List<Long> parsed = ChatParticipantUserIds.parse(List.of("1", "2"));

        assertThat(parsed).containsExactly(1L, 2L);
    }

    @Test
    void rejectsNullRawValue() {
        assertInvalid(null);
    }

    @Test
    void rejectsNonListRawValue() {
        assertInvalid("1,2");
    }

    @Test
    void rejectsNullElement() {
        assertInvalid(Arrays.asList(1L, null));
    }

    @Test
    void rejectsNonNumericString() {
        assertInvalid(List.of("1", "not-a-number"));
    }

    @Test
    void rejectsUnsupportedObject() {
        assertInvalid(List.of(new Object()));
    }

    private static void assertInvalid(Object rawParticipants) {
        assertThatThrownBy(() -> ChatParticipantUserIds.parse(rawParticipants))
                .isInstanceOf(ApiException.class)
                .extracting("errorCode")
                .isEqualTo("CHAT_ROOM_NOT_FOUND");
    }
}
