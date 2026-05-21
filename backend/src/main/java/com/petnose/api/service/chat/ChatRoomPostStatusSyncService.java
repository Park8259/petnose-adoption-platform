package com.petnose.api.service.chat;

import com.petnose.api.domain.enums.AdoptionPostStatus;

public interface ChatRoomPostStatusSyncService {

    void syncPostStatus(Long postId, AdoptionPostStatus status);
}
