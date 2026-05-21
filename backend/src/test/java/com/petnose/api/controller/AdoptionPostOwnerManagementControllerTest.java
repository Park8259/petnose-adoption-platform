package com.petnose.api.controller;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.domain.entity.AdoptionPost;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.entity.DogImage;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.entity.VerificationLog;
import com.petnose.api.domain.enums.AdoptionPostStatus;
import com.petnose.api.domain.enums.DogGender;
import com.petnose.api.domain.enums.DogImageType;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.UserRole;
import com.petnose.api.domain.enums.VerificationResult;
import com.petnose.api.repository.AdoptionPostRepository;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.repository.VerificationLogRepository;
import com.petnose.api.service.chat.ChatRoomPostStatusSyncService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.ResultActions;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.hasSize;
import static org.hamcrest.Matchers.nullValue;
import static org.mockito.Mockito.reset;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class AdoptionPostOwnerManagementControllerTest {

    private static final String JWT_SECRET = "test-petnose-jwt-secret-change-me-32bytes";

    private static final Set<String> OWNER_LIST_ITEM_FIELDS = Set.of(
            "post_id",
            "dog_id",
            "title",
            "status",
            "dog_name",
            "breed",
            "gender",
            "birth_date",
            "profile_image_url",
            "verification_status",
            "published_at",
            "closed_at",
            "created_at",
            "updated_at"
    );

    private static final Set<String> STATUS_UPDATE_FIELDS = Set.of(
            "post_id",
            "dog_id",
            "title",
            "content",
            "status",
            "published_at",
            "closed_at",
            "created_at",
            "updated_at"
    );

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private UserRepository userRepository;

    @Autowired
    private DogRepository dogRepository;

    @Autowired
    private DogImageRepository dogImageRepository;

    @Autowired
    private VerificationLogRepository verificationLogRepository;

    @Autowired
    private AdoptionPostRepository adoptionPostRepository;

    @MockBean
    private ChatRoomPostStatusSyncService chatRoomPostStatusSyncService;

    private int sequence;

    @BeforeEach
    void setUp() {
        adoptionPostRepository.deleteAll();
        verificationLogRepository.deleteAll();
        dogImageRepository.deleteAll();
        dogRepository.deleteAll();
        userRepository.deleteAll();
        reset(chatRoomPostStatusSyncService);
        sequence = 0;
    }

    @Test
    void ownerListRequiresAuthorization() throws Exception {
        mockMvc.perform(get("/api/adoption-posts/me"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));
    }

    @Test
    void ownerListRejectsInvalidToken() throws Exception {
        mockMvc.perform(get("/api/adoption-posts/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer invalid-token"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));
    }

    @Test
    void ownerListReturnsOnlyCurrentUsersPostsWhenStatusIsOmitted() throws Exception {
        User currentUser = saveUser("Owner", true);
        User otherUser = saveUser("Other", true);
        Dog currentDog = saveDog(currentUser, "CurrentDog", DogStatus.REGISTERED);
        Dog otherDog = saveDog(otherUser, "OtherDog", DogStatus.REGISTERED);
        String profilePath = saveProfileImage(currentDog, "owner-profile.jpg").getFilePath();
        saveVerificationLog(currentUser, currentDog, VerificationResult.PENDING);
        saveVerificationLog(currentUser, currentDog, VerificationResult.PASSED);
        AdoptionPost ownDraft = savePost(currentUser, currentDog, AdoptionPostStatus.DRAFT, "Own draft");
        AdoptionPost ownOpen = savePost(currentUser, currentDog, AdoptionPostStatus.OPEN, "Own open");
        savePost(otherUser, otherDog, AdoptionPostStatus.OPEN, "Other open");

        MvcResult result = ownerList(tokenFor(currentUser))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(2)))
                .andExpect(jsonPath("$.page").value(0))
                .andExpect(jsonPath("$.size").value(20))
                .andExpect(jsonPath("$.total_count").value(2))
                .andExpect(jsonPath("$.totalCount").doesNotExist())
                .andExpect(jsonPath("$.items[0].post_id").value(ownOpen.getId()))
                .andExpect(jsonPath("$.items[1].post_id").value(ownDraft.getId()))
                .andExpect(jsonPath("$.items[0].dog_id").value(currentDog.getId()))
                .andExpect(jsonPath("$.items[0].title").value("Own open"))
                .andExpect(jsonPath("$.items[0].status").value("OPEN"))
                .andExpect(jsonPath("$.items[0].dog_name").value("CurrentDog"))
                .andExpect(jsonPath("$.items[0].breed").value("Maltese"))
                .andExpect(jsonPath("$.items[0].gender").value("MALE"))
                .andExpect(jsonPath("$.items[0].birth_date").value("2023-01-01"))
                .andExpect(jsonPath("$.items[0].profile_image_url").value("/files/" + profilePath))
                .andExpect(jsonPath("$.items[0].verification_status").value("VERIFIED"))
                .andExpect(jsonPath("$.items[0].published_at").isNotEmpty())
                .andExpect(jsonPath("$.items[0].created_at").isNotEmpty())
                .andExpect(jsonPath("$.items[0].updated_at").isNotEmpty())
                .andExpect(jsonPath("$.items[0].nose_image_url").doesNotExist())
                .andExpect(jsonPath("$.items[0].author_user_id").doesNotExist())
                .andReturn();

        assertOwnerListItemFields(result);
        assertThat(responseBody(result)).doesNotContain(
                "Other open",
                "nose_image_url",
                "author_user_id",
                "author_display_name",
                "author_region",
                "postId",
                "dogId",
                "dogName",
                "profileImageUrl",
                "verificationStatus",
                "publishedAt",
                "closedAt",
                "createdAt",
                "updatedAt",
                "totalCount"
        );
    }

    @Test
    void ownerListWithoutStatusReturnsEveryOwnedStatus() throws Exception {
        User currentUser = saveUser("All Status Owner", true);
        User otherUser = saveUser("Other Status Owner", true);
        Dog currentDog = saveDog(currentUser, "AllStatusDog", DogStatus.REGISTERED);
        Dog otherDog = saveDog(otherUser, "OtherStatusDog", DogStatus.REGISTERED);

        AdoptionPost draft = savePostCreatedAt(
                currentUser,
                currentDog,
                AdoptionPostStatus.DRAFT,
                "Owned draft",
                LocalDateTime.of(2026, 1, 1, 9, 0)
        );
        AdoptionPost open = savePostCreatedAt(
                currentUser,
                currentDog,
                AdoptionPostStatus.OPEN,
                "Owned open",
                LocalDateTime.of(2026, 1, 2, 9, 0)
        );
        AdoptionPost reserved = savePostCreatedAt(
                currentUser,
                currentDog,
                AdoptionPostStatus.RESERVED,
                "Owned reserved",
                LocalDateTime.of(2026, 1, 3, 9, 0)
        );
        AdoptionPost completed = savePostCreatedAt(
                currentUser,
                currentDog,
                AdoptionPostStatus.COMPLETED,
                "Owned completed",
                LocalDateTime.of(2026, 1, 4, 9, 0)
        );
        AdoptionPost closed = savePostCreatedAt(
                currentUser,
                currentDog,
                AdoptionPostStatus.CLOSED,
                "Owned closed",
                LocalDateTime.of(2026, 1, 5, 9, 0)
        );
        savePostCreatedAt(
                otherUser,
                otherDog,
                AdoptionPostStatus.CLOSED,
                "Other closed",
                LocalDateTime.of(2026, 1, 6, 9, 0)
        );

        MvcResult result = ownerList(tokenFor(currentUser))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(5)))
                .andExpect(jsonPath("$.total_count").value(5))
                .andExpect(jsonPath("$.items[0].post_id").value(closed.getId()))
                .andExpect(jsonPath("$.items[0].status").value("CLOSED"))
                .andExpect(jsonPath("$.items[1].post_id").value(completed.getId()))
                .andExpect(jsonPath("$.items[1].status").value("COMPLETED"))
                .andExpect(jsonPath("$.items[2].post_id").value(reserved.getId()))
                .andExpect(jsonPath("$.items[2].status").value("RESERVED"))
                .andExpect(jsonPath("$.items[3].post_id").value(open.getId()))
                .andExpect(jsonPath("$.items[3].status").value("OPEN"))
                .andExpect(jsonPath("$.items[4].post_id").value(draft.getId()))
                .andExpect(jsonPath("$.items[4].status").value("DRAFT"))
                .andExpect(jsonPath("$.items[0].nose_image_url").doesNotExist())
                .andReturn();

        assertOwnerListItemFields(result);
        assertThat(responseBody(result)).doesNotContain("Other closed", "nose_image_url");
    }

    @ParameterizedTest
    @ValueSource(strings = {"DRAFT", "OPEN", "RESERVED", "COMPLETED", "CLOSED"})
    void ownerListFiltersByAllowedStatus(String statusValue) throws Exception {
        User user = saveUser("Filter Owner", true);
        Dog dog = saveDog(user, statusValue + "Dog", DogStatus.REGISTERED);
        saveVerificationLog(user, dog, VerificationResult.PASSED);
        AdoptionPost matchingPost = savePost(user, dog, AdoptionPostStatus.valueOf(statusValue), statusValue + " post");
        savePost(user, dog, otherStatus(statusValue), "Other status post");

        ownerList(tokenFor(user), Map.of("status", statusValue))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(1)))
                .andExpect(jsonPath("$.items[0].post_id").value(matchingPost.getId()))
                .andExpect(jsonPath("$.items[0].status").value(statusValue));
    }

    @ParameterizedTest
    @ValueSource(strings = {"UNKNOWN", "open", "Draft"})
    void ownerListRejectsInvalidStatus(String statusValue) throws Exception {
        User user = saveUser("Invalid Status Owner", true);

        ownerList(tokenFor(user), Map.of("status", statusValue))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_POST_STATUS"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @ParameterizedTest
    @CsvSource({
            "page,-1",
            "page,abc",
            "size,0",
            "size,101",
            "size,abc"
    })
    void ownerListRejectsInvalidPagination(String paramName, String value) throws Exception {
        User user = saveUser("Paging Owner", true);

        ownerList(tokenFor(user), Map.of(paramName, value))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_PAGE_REQUEST"));
    }

    @Test
    void ownerListOrdersByCreatedAtDescThenIdDesc() throws Exception {
        User user = saveUser("Ordering Owner", true);
        Dog dog = saveDog(user, "OrderDog", DogStatus.REGISTERED);
        saveVerificationLog(user, dog, VerificationResult.PASSED);
        AdoptionPost olderPost = savePostCreatedAt(
                user,
                dog,
                AdoptionPostStatus.OPEN,
                "Older",
                LocalDateTime.of(2026, 1, 1, 10, 0)
        );
        LocalDateTime tieTime = LocalDateTime.of(2026, 1, 2, 10, 0);
        AdoptionPost lowerIdTiePost = savePostCreatedAt(user, dog, AdoptionPostStatus.OPEN, "Lower tie", tieTime);
        AdoptionPost higherIdTiePost = savePostCreatedAt(user, dog, AdoptionPostStatus.OPEN, "Higher tie", tieTime);

        ownerList(tokenFor(user))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(3)))
                .andExpect(jsonPath("$.items[0].post_id").value(higherIdTiePost.getId()))
                .andExpect(jsonPath("$.items[1].post_id").value(lowerIdTiePost.getId()))
                .andExpect(jsonPath("$.items[2].post_id").value(olderPost.getId()));
    }

    @Test
    void statusUpdateRequiresAuthorization() throws Exception {
        statusPatch(null, 1L, "OPEN")
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));
    }

    @Test
    void statusUpdateRejectsInvalidToken() throws Exception {
        statusPatch("invalid-token", 1L, "OPEN")
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));
    }

    @Test
    void statusUpdateReturnsPostNotFoundBeforeOwnerCheck() throws Exception {
        User user = saveUser("Missing Post User", true);

        statusPatch(tokenFor(user), 999999L, "OPEN")
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("POST_NOT_FOUND"));
    }

    @Test
    void statusUpdateRejectsNonOwner() throws Exception {
        User owner = saveUser("Owner", true);
        User other = saveUser("Other", true);
        Dog dog = saveDog(owner, "OwnerDog", DogStatus.REGISTERED);
        AdoptionPost post = savePost(owner, dog, AdoptionPostStatus.OPEN, "Owner post");

        statusPatch(tokenFor(other), post.getId(), "RESERVED")
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error_code").value("POST_OWNER_MISMATCH"));
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {"   ", "UNKNOWN", "open", "Draft"})
    void statusUpdateRejectsInvalidTargetStatus(String statusValue) throws Exception {
        User user = saveUser("Status Owner", true);
        Dog dog = saveDog(user, "Dog", DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN, "Owner post");

        statusPatch(tokenFor(user), post.getId(), statusValue)
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_POST_STATUS"));
    }

    @Test
    void statusUpdateRejectsMissingTargetStatus() throws Exception {
        User user = saveUser("Missing Status Owner", true);
        Dog dog = saveDog(user, "Dog", DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN, "Owner post");

        statusPatchBody(tokenFor(user), post.getId(), Map.of())
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_POST_STATUS"));
    }

    @Test
    void draftToOpenSucceedsAndSetsPublishedAtWithoutChangingDogStatus() throws Exception {
        User user = saveUser("Publish Owner", true);
        Dog dog = saveDog(user, "PublishDog", DogStatus.REGISTERED);
        saveVerificationLog(user, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.DRAFT, "Draft post");

        MvcResult result = statusPatch(tokenFor(user), post.getId(), "OPEN")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.post_id").value(post.getId()))
                .andExpect(jsonPath("$.dog_id").value(dog.getId()))
                .andExpect(jsonPath("$.title").value("Draft post"))
                .andExpect(jsonPath("$.content").value("Owner managed adoption content."))
                .andExpect(jsonPath("$.status").value("OPEN"))
                .andExpect(jsonPath("$.published_at").isNotEmpty())
                .andExpect(jsonPath("$.closed_at").value(nullValue()))
                .andExpect(jsonPath("$.created_at").isNotEmpty())
                .andExpect(jsonPath("$.updated_at").isNotEmpty())
                .andExpect(jsonPath("$.author_user_id").doesNotExist())
                .andExpect(jsonPath("$.nose_image_url").doesNotExist())
                .andReturn();

        AdoptionPost saved = adoptionPostRepository.findById(post.getId()).orElseThrow();
        assertThat(saved.getStatus()).isEqualTo(AdoptionPostStatus.OPEN);
        assertThat(saved.getPublishedAt()).isNotNull();
        assertThat(dogRepository.findById(dog.getId()).orElseThrow().getStatus()).isEqualTo(DogStatus.REGISTERED);
        assertStatusUpdateFields(result);
        assertThat(responseBody(result)).doesNotContain(
                "author_user_id",
                "nose_image_url",
                "postId",
                "dogId",
                "publishedAt",
                "closedAt",
                "createdAt",
                "updatedAt"
        );
    }

    @ParameterizedTest
    @NullAndEmptySource
    @ValueSource(strings = {"   "})
    void draftToOpenRejectsMissingDisplayName(String displayName) throws Exception {
        User user = saveUser(displayName, true);
        Dog dog = saveDog(user, "ProfileDog", DogStatus.REGISTERED);
        saveVerificationLog(user, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.DRAFT, "Draft post");

        statusPatch(tokenFor(user), post.getId(), "OPEN")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("USER_PROFILE_REQUIRED"));
    }

    @Test
    void draftToOpenRejectsMissingDog() throws Exception {
        User user = saveUser("Missing Dog Owner", true);
        AdoptionPost post = savePost(user, UUID.randomUUID().toString(), AdoptionPostStatus.DRAFT, "Missing dog draft");

        statusPatch(tokenFor(user), post.getId(), "OPEN")
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("DOG_NOT_FOUND"));
    }

    @Test
    void draftToOpenRejectsDogOwnedByAnotherUser() throws Exception {
        User currentUser = saveUser("Current Owner", true);
        User dogOwner = saveUser("Dog Owner", true);
        Dog dog = saveDog(dogOwner, "OtherDog", DogStatus.REGISTERED);
        saveVerificationLog(dogOwner, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(currentUser, dog, AdoptionPostStatus.DRAFT, "Mismatched dog draft");

        statusPatch(tokenFor(currentUser), post.getId(), "OPEN")
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error_code").value("DOG_OWNER_MISMATCH"));
    }

    @Test
    void draftToOpenRejectsDogThatIsNotRegistered() throws Exception {
        User user = saveUser("Dog Status Owner", true);
        Dog dog = saveDog(user, "PendingDog", DogStatus.PENDING);
        saveVerificationLog(user, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.DRAFT, "Pending dog draft");

        statusPatch(tokenFor(user), post.getId(), "OPEN")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("DOG_NOT_REGISTERED"));
    }

    @Test
    void draftToOpenRejectsLatestVerificationThatIsNotPassed() throws Exception {
        User user = saveUser("Verification Owner", true);
        Dog dog = saveDog(user, "PendingVerificationDog", DogStatus.REGISTERED);
        saveVerificationLog(user, dog, VerificationResult.PASSED);
        saveVerificationLog(user, dog, VerificationResult.PENDING);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.DRAFT, "Pending verification draft");

        statusPatch(tokenFor(user), post.getId(), "OPEN")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("DOG_NOT_VERIFIED"));
    }

    @Test
    void draftToOpenRejectsAnotherActivePostForSameDogButExcludesCurrentPost() throws Exception {
        User user = saveUser("Duplicate Owner", true);
        Dog dog = saveDog(user, "DuplicateDog", DogStatus.REGISTERED);
        saveVerificationLog(user, dog, VerificationResult.PASSED);
        AdoptionPost currentPost = savePost(user, dog, AdoptionPostStatus.DRAFT, "Current draft");
        savePost(user, dog, AdoptionPostStatus.RESERVED, "Other active post");

        statusPatch(tokenFor(user), currentPost.getId(), "OPEN")
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.error_code").value("DOG_ALREADY_HAS_ACTIVE_POST"));
    }

    @Test
    void draftToOpenDoesNotCountCurrentDraftAsDuplicateActivePost() throws Exception {
        User user = saveUser("Self Excluding Owner", true);
        Dog dog = saveDog(user, "SelfDog", DogStatus.REGISTERED);
        saveVerificationLog(user, dog, VerificationResult.PASSED);
        AdoptionPost currentPost = savePost(user, dog, AdoptionPostStatus.DRAFT, "Current draft");

        statusPatch(tokenFor(user), currentPost.getId(), "OPEN")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("OPEN"));
    }

    @Test
    void draftToClosedSucceedsAndSetsClosedAtWithoutPublishingOrAdoptingDog() throws Exception {
        User user = saveUser("Close Draft Owner", true);
        Dog dog = saveDog(user, "CloseDog", DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.DRAFT, "Draft to close");

        statusPatch(tokenFor(user), post.getId(), "CLOSED")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("CLOSED"))
                .andExpect(jsonPath("$.published_at").value(nullValue()))
                .andExpect(jsonPath("$.closed_at").isNotEmpty());

        assertThat(dogRepository.findById(dog.getId()).orElseThrow().getStatus()).isEqualTo(DogStatus.REGISTERED);
    }

    @ParameterizedTest
    @ValueSource(strings = {"RESERVED", "COMPLETED"})
    void draftRejectsReservedAndCompletedTransitions(String targetStatus) throws Exception {
        User user = saveUser("Draft Invalid Owner", true);
        Dog dog = saveDog(user, "InvalidDog", DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.DRAFT, "Draft invalid");

        statusPatch(tokenFor(user), post.getId(), targetStatus)
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_STATUS_TRANSITION"));
    }

    @Test
    void openToReservedSucceeds() throws Exception {
        User user = saveUser("Reserve Owner", true);
        Dog dog = saveDog(user, "ReserveDog", DogStatus.REGISTERED);
        LocalDateTime publishedAt = LocalDateTime.of(2026, 1, 1, 9, 0);
        AdoptionPost post = savePostWithPublishedAt(user, dog, AdoptionPostStatus.OPEN, "Open post", publishedAt);

        statusPatch(tokenFor(user), post.getId(), "RESERVED")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("RESERVED"))
                .andExpect(jsonPath("$.published_at").value("2026-01-01T09:00:00"))
                .andExpect(jsonPath("$.closed_at").value(nullValue()));

        verify(chatRoomPostStatusSyncService).syncPostStatus(post.getId(), AdoptionPostStatus.RESERVED);
    }

    @Test
    void reservedToOpenSucceedsAndFillsMissingLegacyPublishedAt() throws Exception {
        User user = saveUser("Reopen Owner", true);
        Dog dog = saveDog(user, "ReopenDog", DogStatus.REGISTERED);
        AdoptionPost post = savePostWithPublishedAt(user, dog, AdoptionPostStatus.RESERVED, "Reserved legacy", null);

        statusPatch(tokenFor(user), post.getId(), "OPEN")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("OPEN"))
                .andExpect(jsonPath("$.published_at").isNotEmpty())
                .andExpect(jsonPath("$.closed_at").value(nullValue()));
    }

    @ParameterizedTest
    @ValueSource(strings = {"OPEN", "RESERVED"})
    void activePostToCompletedSucceedsAndMarksDogAdopted(String currentStatusValue) throws Exception {
        User user = saveUser("Complete Owner", true);
        Dog dog = saveDog(user, currentStatusValue + "CompleteDog", DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.valueOf(currentStatusValue), "Complete post");

        statusPatch(tokenFor(user), post.getId(), "COMPLETED")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("COMPLETED"))
                .andExpect(jsonPath("$.closed_at").isNotEmpty());

        assertThat(dogRepository.findById(dog.getId()).orElseThrow().getStatus()).isEqualTo(DogStatus.ADOPTED);
        verify(chatRoomPostStatusSyncService).syncPostStatus(post.getId(), AdoptionPostStatus.COMPLETED);
    }

    @ParameterizedTest
    @ValueSource(strings = {"OPEN", "RESERVED"})
    void activePostToClosedSucceedsWithoutMarkingDogAdopted(String currentStatusValue) throws Exception {
        User user = saveUser("Close Owner", true);
        Dog dog = saveDog(user, currentStatusValue + "CloseDog", DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.valueOf(currentStatusValue), "Close post");

        statusPatch(tokenFor(user), post.getId(), "CLOSED")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("CLOSED"))
                .andExpect(jsonPath("$.closed_at").isNotEmpty());

        assertThat(dogRepository.findById(dog.getId()).orElseThrow().getStatus()).isEqualTo(DogStatus.REGISTERED);
    }

    @ParameterizedTest
    @ValueSource(strings = {"OPEN", "RESERVED"})
    void openAndReservedRejectTransitionBackToDraft(String currentStatusValue) throws Exception {
        User user = saveUser("Back Draft Owner", true);
        Dog dog = saveDog(user, currentStatusValue + "Dog", DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.valueOf(currentStatusValue), "Back draft post");

        statusPatch(tokenFor(user), post.getId(), "DRAFT")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_STATUS_TRANSITION"));
    }

    @ParameterizedTest
    @CsvSource({
            "COMPLETED,OPEN",
            "COMPLETED,CLOSED",
            "CLOSED,OPEN",
            "CLOSED,RESERVED"
    })
    void completedAndClosedAreTerminal(String currentStatusValue, String targetStatusValue) throws Exception {
        User user = saveUser("Terminal Owner", true);
        Dog dog = saveDog(user, currentStatusValue + "Dog", DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.valueOf(currentStatusValue), "Terminal post");

        statusPatch(tokenFor(user), post.getId(), targetStatusValue)
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_STATUS_TRANSITION"));

        verifyNoInteractions(chatRoomPostStatusSyncService);
    }

    @Test
    void sameStatusPatchIsNoOpAndDoesNotChangeTimestamps() throws Exception {
        User user = saveUser("Noop Owner", true);
        Dog dog = saveDog(user, "NoopDog", DogStatus.REGISTERED);
        LocalDateTime publishedAt = LocalDateTime.of(2026, 1, 1, 9, 0);
        LocalDateTime closedAt = LocalDateTime.of(2026, 1, 2, 9, 0);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.CLOSED, "Noop post", publishedAt, closedAt);
        AdoptionPost persistedBefore = adoptionPostRepository.findById(post.getId()).orElseThrow();
        LocalDateTime createdAtBefore = persistedBefore.getCreatedAt();
        LocalDateTime updatedAtBefore = persistedBefore.getUpdatedAt();

        statusPatch(tokenFor(user), post.getId(), "CLOSED")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("CLOSED"))
                .andExpect(jsonPath("$.published_at").value("2026-01-01T09:00:00"))
                .andExpect(jsonPath("$.closed_at").value("2026-01-02T09:00:00"))
                .andExpect(jsonPath("$.created_at").isNotEmpty())
                .andExpect(jsonPath("$.updated_at").isNotEmpty());

        AdoptionPost saved = adoptionPostRepository.findById(post.getId()).orElseThrow();
        assertThat(saved.getPublishedAt()).isEqualTo(publishedAt);
        assertThat(saved.getClosedAt()).isEqualTo(closedAt);
        assertThat(saved.getCreatedAt()).isEqualTo(createdAtBefore);
        assertThat(saved.getUpdatedAt()).isEqualTo(updatedAtBefore);
        verifyNoInteractions(chatRoomPostStatusSyncService);
    }

    private ResultActions ownerList(String token) throws Exception {
        return ownerList(token, Map.of());
    }

    private ResultActions ownerList(String token, Map<String, String> params) throws Exception {
        var request = get("/api/adoption-posts/me");
        params.forEach(request::param);
        if (token != null) {
            request.header(HttpHeaders.AUTHORIZATION, "Bearer " + token);
        }
        return mockMvc.perform(request);
    }

    private ResultActions statusPatch(String token, Long postId, String targetStatus) throws Exception {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", targetStatus);
        return statusPatchBody(token, postId, body);
    }

    private ResultActions statusPatchBody(String token, Long postId, Map<String, Object> body) throws Exception {
        var request = patch("/api/adoption-posts/{post_id}/status", postId)
                .contentType(MediaType.APPLICATION_JSON)
                .content(objectMapper.writeValueAsString(body));
        if (token != null) {
            request.header(HttpHeaders.AUTHORIZATION, "Bearer " + token);
        }
        return mockMvc.perform(request);
    }

    private User saveUser(String displayName, boolean active) {
        User user = new User();
        user.setEmail("owner-management-%d@example.com".formatted(++sequence));
        user.setPasswordHash("hash");
        user.setRole(UserRole.USER);
        user.setDisplayName(displayName);
        user.setContactPhone("01012341234");
        user.setRegion("Seoul");
        user.setActive(active);
        return userRepository.saveAndFlush(user);
    }

    private Dog saveDog(User owner, String name, DogStatus status) {
        Dog dog = new Dog();
        dog.setId(UUID.randomUUID().toString());
        dog.setOwnerUserId(owner.getId());
        dog.setName(name);
        dog.setBreed("Maltese");
        dog.setGender(DogGender.MALE);
        dog.setBirthDate(LocalDate.of(2023, 1, 1));
        dog.setDescription("Owner management test dog.");
        dog.setStatus(status);
        return dogRepository.saveAndFlush(dog);
    }

    private DogImage saveProfileImage(Dog dog, String filename) {
        DogImage image = new DogImage();
        image.setDogId(dog.getId());
        image.setImageType(DogImageType.PROFILE);
        image.setFilePath("dogs/%s/profile/%s".formatted(dog.getId(), filename));
        image.setMimeType("image/jpeg");
        image.setFileSize(100L);
        image.setSha256(sha256());
        return dogImageRepository.saveAndFlush(image);
    }

    private VerificationLog saveVerificationLog(User user, Dog dog, VerificationResult result) {
        DogImage noseImage = new DogImage();
        noseImage.setDogId(dog.getId());
        noseImage.setImageType(DogImageType.NOSE);
        noseImage.setFilePath("dogs/%s/nose/%s.jpg".formatted(dog.getId(), UUID.randomUUID()));
        noseImage.setMimeType("image/jpeg");
        noseImage.setFileSize(100L);
        noseImage.setSha256(sha256());
        dogImageRepository.saveAndFlush(noseImage);

        VerificationLog log = new VerificationLog();
        log.setDogId(dog.getId());
        log.setDogImageId(noseImage.getId());
        log.setRequestedByUserId(user.getId());
        log.setResult(result);
        return verificationLogRepository.saveAndFlush(log);
    }

    private AdoptionPost savePost(User author, Dog dog, AdoptionPostStatus status, String title) {
        return savePostWithPublishedAt(author, dog, status, title, defaultPublishedAt(status));
    }

    private AdoptionPost savePostWithPublishedAt(
            User author,
            Dog dog,
            AdoptionPostStatus status,
            String title,
            LocalDateTime publishedAt
    ) {
        return savePost(author, dog.getId(), status, title, publishedAt, defaultClosedAt(status));
    }

    private AdoptionPost savePost(
            User author,
            Dog dog,
            AdoptionPostStatus status,
            String title,
            LocalDateTime publishedAt,
            LocalDateTime closedAt
    ) {
        return savePost(author, dog.getId(), status, title, publishedAt, closedAt);
    }

    private AdoptionPost savePostCreatedAt(
            User author,
            Dog dog,
            AdoptionPostStatus status,
            String title,
            LocalDateTime createdAt
    ) {
        AdoptionPost post = newPost(author, dog.getId(), status, title, defaultPublishedAt(status), defaultClosedAt(status));
        post.setCreatedAt(createdAt);
        return adoptionPostRepository.saveAndFlush(post);
    }

    private AdoptionPost savePost(User author, String dogId, AdoptionPostStatus status, String title) {
        return savePost(author, dogId, status, title, defaultPublishedAt(status), defaultClosedAt(status));
    }

    private AdoptionPost savePost(
            User author,
            String dogId,
            AdoptionPostStatus status,
            String title,
            LocalDateTime publishedAt,
            LocalDateTime closedAt
    ) {
        return adoptionPostRepository.saveAndFlush(newPost(author, dogId, status, title, publishedAt, closedAt));
    }

    private AdoptionPost newPost(
            User author,
            String dogId,
            AdoptionPostStatus status,
            String title,
            LocalDateTime publishedAt,
            LocalDateTime closedAt
    ) {
        AdoptionPost post = new AdoptionPost();
        post.setAuthorUserId(author.getId());
        post.setDogId(dogId);
        post.setTitle(title);
        post.setContent("Owner managed adoption content.");
        post.setStatus(status);
        post.setPublishedAt(publishedAt);
        post.setClosedAt(closedAt);
        return post;
    }

    private LocalDateTime defaultPublishedAt(AdoptionPostStatus status) {
        if (status == AdoptionPostStatus.OPEN
                || status == AdoptionPostStatus.RESERVED
                || status == AdoptionPostStatus.COMPLETED) {
            return LocalDateTime.now();
        }
        return null;
    }

    private LocalDateTime defaultClosedAt(AdoptionPostStatus status) {
        if (status == AdoptionPostStatus.COMPLETED || status == AdoptionPostStatus.CLOSED) {
            return LocalDateTime.now();
        }
        return null;
    }

    private AdoptionPostStatus otherStatus(String statusValue) {
        return "DRAFT".equals(statusValue) ? AdoptionPostStatus.OPEN : AdoptionPostStatus.DRAFT;
    }

    private String tokenFor(User user) throws Exception {
        String header = encodeJson(Map.of("alg", "HS256", "typ", "JWT"));
        String payload = encodeJson(Map.of(
                "sub", user.getId().toString(),
                "exp", Instant.now().plusSeconds(3600).getEpochSecond()
        ));
        String signingInput = header + "." + payload;
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(JWT_SECRET.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        String signature = Base64.getUrlEncoder().withoutPadding()
                .encodeToString(mac.doFinal(signingInput.getBytes(StandardCharsets.UTF_8)));
        return signingInput + "." + signature;
    }

    private String encodeJson(Map<String, Object> value) throws Exception {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(objectMapper.writeValueAsBytes(value));
    }

    private String sha256() {
        return UUID.randomUUID().toString().replace("-", "") + UUID.randomUUID().toString().replace("-", "");
    }

    private String responseBody(MvcResult result) {
        return new String(result.getResponse().getContentAsByteArray(), StandardCharsets.UTF_8);
    }

    private void assertOwnerListItemFields(MvcResult result) throws Exception {
        JsonNode item = objectMapper.readTree(responseBody(result)).path("items").get(0);
        assertThat(fieldNames(item)).containsExactlyInAnyOrderElementsOf(OWNER_LIST_ITEM_FIELDS);
    }

    private void assertStatusUpdateFields(MvcResult result) throws Exception {
        JsonNode body = objectMapper.readTree(responseBody(result));
        assertThat(fieldNames(body)).containsExactlyInAnyOrderElementsOf(STATUS_UPDATE_FIELDS);
    }

    private Set<String> fieldNames(JsonNode node) {
        Set<String> names = new LinkedHashSet<>();
        node.fieldNames().forEachRemaining(names::add);
        return names;
    }
}
