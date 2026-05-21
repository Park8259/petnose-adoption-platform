package com.petnose.api.service.chat;

import com.google.cloud.firestore.FieldValue;
import com.google.cloud.firestore.Firestore;
import com.google.cloud.firestore.QueryDocumentSnapshot;
import com.google.cloud.firestore.WriteBatch;
import com.petnose.api.domain.enums.AdoptionPostStatus;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.stereotype.Service;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@Slf4j
@Service
public class FirebaseChatRoomPostStatusSyncService implements ChatRoomPostStatusSyncService {

    private static final String CHAT_ROOMS = "chat_rooms";

    private final ObjectProvider<Firestore> firestoreProvider;

    public FirebaseChatRoomPostStatusSyncService(ObjectProvider<Firestore> firestoreProvider) {
        this.firestoreProvider = firestoreProvider;
    }

    @Override
    public void syncPostStatus(Long postId, AdoptionPostStatus status) {
        if (postId == null || status == null) {
            log.warn("[FirebaseChatStatusSync] skipped invalid status sync request: postId={}, status={}", postId, status);
            return;
        }

        try {
            Firestore db = firestoreProvider.getIfAvailable();
            if (db == null) {
                log.debug("[FirebaseChatStatusSync] Firebase disabled; skip chat room status sync: postId={}, status={}", postId, status);
                return;
            }

            ChatRoomState roomState = ChatRoomState.from(status);
            Map<String, Object> updates = new LinkedHashMap<>();
            updates.put("post_status_snapshot", status.name());
            updates.put("room_status", roomState.roomStatus());
            updates.put("message_enabled", roomState.messageEnabled());
            updates.put("synced_at", FieldValue.serverTimestamp());

            List<QueryDocumentSnapshot> rooms = db.collection(CHAT_ROOMS)
                    .whereEqualTo("post_id", postId)
                    .get()
                    .get()
                    .getDocuments();
            if (rooms.isEmpty()) {
                log.debug("[FirebaseChatStatusSync] no chat rooms to sync: postId={}, status={}", postId, status);
                return;
            }

            WriteBatch batch = db.batch();
            rooms.forEach(room -> batch.update(room.getReference(), updates));
            batch.commit().get();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            log.warn("[FirebaseChatStatusSync] interrupted while syncing chat room status: postId={}, status={}",
                    postId,
                    status);
        } catch (Exception e) {
            log.warn("[FirebaseChatStatusSync] failed to sync chat room status: postId={}, status={}, error={}",
                    postId,
                    status,
                    e.getClass().getSimpleName());
        }
    }
}
