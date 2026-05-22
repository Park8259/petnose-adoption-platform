package com.petnose.api.service.chat;

import com.petnose.api.exception.ApiException;
import org.springframework.http.HttpStatus;

import java.util.List;

final class ChatParticipantUserIds {

    private ChatParticipantUserIds() {
    }

    static List<Long> parse(Object rawParticipants) {
        if (!(rawParticipants instanceof List<?> participants)) {
            throw invalidParticipantData();
        }

        return participants.stream()
                .map(ChatParticipantUserIds::parseParticipantId)
                .toList();
    }

    private static Long parseParticipantId(Object value) {
        if (value instanceof Number number) {
            return number.longValue();
        }
        if (value instanceof String text) {
            try {
                return Long.parseLong(text);
            } catch (NumberFormatException e) {
                throw invalidParticipantData();
            }
        }
        throw invalidParticipantData();
    }

    private static ApiException invalidParticipantData() {
        return new ApiException(HttpStatus.CONFLICT, "CHAT_ROOM_NOT_FOUND", "채팅방 참여자 정보가 올바르지 않습니다.");
    }
}
