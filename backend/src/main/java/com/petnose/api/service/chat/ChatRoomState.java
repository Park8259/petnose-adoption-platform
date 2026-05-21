package com.petnose.api.service.chat;

import com.petnose.api.domain.enums.AdoptionPostStatus;

public record ChatRoomState(String roomStatus, boolean messageEnabled) {

    public static final String ACTIVE = "ACTIVE";
    public static final String READ_ONLY = "READ_ONLY";
    public static final String DISABLED = "DISABLED";

    public static ChatRoomState from(AdoptionPostStatus status) {
        if (status == null) {
            return new ChatRoomState(DISABLED, false);
        }

        return switch (status) {
            case OPEN, RESERVED -> new ChatRoomState(ACTIVE, true);
            case COMPLETED, CLOSED -> new ChatRoomState(READ_ONLY, false);
            case DRAFT -> new ChatRoomState(DISABLED, false);
        };
    }
}
