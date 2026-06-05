package com.petnose.api.controller;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.domain.entity.AdoptionPost;
import com.petnose.api.domain.entity.AdoptionPostLike;
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
import com.petnose.api.repository.AdoptionPostLikeRepository;
import com.petnose.api.repository.AdoptionPostRepository;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.repository.VerificationLogRepository;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.Base64;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.hasSize;
import static org.hamcrest.Matchers.nullValue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class AdoptionPostPublicQueryControllerTest {

    private static final String JWT_SECRET = "test-petnose-jwt-secret-change-me-32bytes";

    private static final Set<String> PUBLIC_LIST_ITEM_FIELDS = Set.of(
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
            "author_display_name",
            "author_region",
            "liked",
            "published_at",
            "created_at"
    );

    private static final Set<String> PUBLIC_DETAIL_FIELDS = Set.of(
            "post_id",
            "dog_id",
            "title",
            "content",
            "status",
            "dog_name",
            "breed",
            "gender",
            "birth_date",
            "description",
            "profile_image_url",
            "verification_status",
            "author_display_name",
            "author_contact_phone",
            "author_region",
            "liked",
            "published_at",
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

    @Autowired
    private AdoptionPostLikeRepository adoptionPostLikeRepository;

    private int sequence;

    @BeforeEach
    void setUp() {
        adoptionPostLikeRepository.deleteAll();
        adoptionPostRepository.deleteAll();
        verificationLogRepository.deleteAll();
        dogImageRepository.deleteAll();
        dogRepository.deleteAll();
        userRepository.deleteAll();
        sequence = 0;
    }

    @AfterEach
    void tearDown() {
        adoptionPostLikeRepository.deleteAll();
    }

    @Test
    void listDefaultsToOpenAndExcludesDraftAndClosedPosts() throws Exception {
        User author = saveUser("Happy Foster", "01012345678", "Seoul");
        Dog dog = saveDog(author, "Choco");
        String profilePath = saveProfileImage(dog, "profile.jpg").getFilePath();
        saveVerificationLog(author, dog, VerificationResult.PENDING);
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost openPost = savePost(author, dog, AdoptionPostStatus.OPEN, "Open adoption post");
        savePost(author, dog, AdoptionPostStatus.DRAFT, "Draft adoption post");
        savePost(author, dog, AdoptionPostStatus.CLOSED, "Closed adoption post");

        MvcResult result = mockMvc.perform(get("/api/adoption-posts"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(1)))
                .andExpect(jsonPath("$.page").value(0))
                .andExpect(jsonPath("$.size").value(20))
                .andExpect(jsonPath("$.total_count").value(1))
                .andExpect(jsonPath("$.totalCount").doesNotExist())
                .andExpect(jsonPath("$.items[0].post_id").value(openPost.getId()))
                .andExpect(jsonPath("$.items[0].dog_id").value(dog.getId()))
                .andExpect(jsonPath("$.items[0].title").value("Open adoption post"))
                .andExpect(jsonPath("$.items[0].status").value("OPEN"))
                .andExpect(jsonPath("$.items[0].dog_name").value("Choco"))
                .andExpect(jsonPath("$.items[0].breed").value("Maltese"))
                .andExpect(jsonPath("$.items[0].gender").value("MALE"))
                .andExpect(jsonPath("$.items[0].birth_date").value("2023-01-01"))
                .andExpect(jsonPath("$.items[0].profile_image_url").value("/files/" + profilePath))
                .andExpect(jsonPath("$.items[0].verification_status").value("VERIFIED"))
                .andExpect(jsonPath("$.items[0].author_display_name").value("Happy Foster"))
                .andExpect(jsonPath("$.items[0].author_region").value("Seoul"))
                .andExpect(jsonPath("$.items[0].liked").value(false))
                .andExpect(jsonPath("$.items[0].published_at").isNotEmpty())
                .andExpect(jsonPath("$.items[0].created_at").isNotEmpty())
                .andExpect(jsonPath("$.items[0].content").doesNotExist())
                .andExpect(jsonPath("$.items[0].author_contact_phone").doesNotExist())
                .andExpect(jsonPath("$.items[0].author_user_id").doesNotExist())
                .andExpect(jsonPath("$.items[0].nose_image_url").doesNotExist())
                .andReturn();

        assertPublicListItemFields(result);
        assertThat(responseBody(result)).doesNotContain(
                "nose_image_url",
                "content",
                "author_contact_phone",
                "author_user_id",
                "password_hash",
                "email",
                "postId",
                "dogId",
                "dogName",
                "profileImageUrl",
                "verificationStatus",
                "authorDisplayName",
                "authorRegion",
                "likedAt",
                "publishedAt",
                "createdAt",
                "totalCount"
        );
    }

    @ParameterizedTest
    @ValueSource(strings = {"OPEN", "RESERVED", "COMPLETED"})
    void listAllowsPublicStatuses(String statusValue) throws Exception {
        User author = saveUser("Public Author", "01022223333", "Busan");
        Dog dog = saveDog(author, statusValue.toLowerCase() + "-dog");
        saveProfileImage(dog, "public-profile.jpg");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        savePost(author, dog, AdoptionPostStatus.valueOf(statusValue), statusValue + " adoption post");

        MvcResult result = mockMvc.perform(get("/api/adoption-posts")
                        .param("status", statusValue))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(1)))
                .andExpect(jsonPath("$.items[0].status").value(statusValue))
                .andExpect(jsonPath("$.items[0].profile_image_url").value("/files/dogs/%s/profile/public-profile.jpg".formatted(dog.getId())))
                .andExpect(jsonPath("$.items[0].verification_status").value("VERIFIED"))
                .andExpect(jsonPath("$.items[0].nose_image_url").doesNotExist())
                .andReturn();

        assertPublicListItemFields(result);
        assertThat(responseBody(result)).doesNotContain("nose_image_url");
    }

    @ParameterizedTest
    @ValueSource(strings = {"DRAFT", "CLOSED", "UNKNOWN"})
    void listRejectsNonPublicStatus(String statusValue) throws Exception {
        mockMvc.perform(get("/api/adoption-posts")
                        .param("status", statusValue))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_POST_STATUS"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @ParameterizedTest
    @ValueSource(strings = {"open", "completed", "Draft"})
    void listRejectsLowercaseAndMixedCaseStatus(String statusValue) throws Exception {
        mockMvc.perform(get("/api/adoption-posts")
                        .param("status", statusValue))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_POST_STATUS"));
    }

    @Test
    void listRejectsInvalidPageRequest() throws Exception {
        mockMvc.perform(get("/api/adoption-posts")
                        .param("page", "-1"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_PAGE_REQUEST"));

        mockMvc.perform(get("/api/adoption-posts")
                        .param("page", "abc"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_PAGE_REQUEST"));

        mockMvc.perform(get("/api/adoption-posts")
                        .param("size", "0"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_PAGE_REQUEST"));

        mockMvc.perform(get("/api/adoption-posts")
                        .param("size", "101"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_PAGE_REQUEST"));

        mockMvc.perform(get("/api/adoption-posts")
                        .param("size", "abc"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_PAGE_REQUEST"));
    }

    @Test
    void listReturnsEmptyPageWithStableEnvelope() throws Exception {
        MvcResult result = mockMvc.perform(get("/api/adoption-posts"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(0)))
                .andExpect(jsonPath("$.page").value(0))
                .andExpect(jsonPath("$.size").value(20))
                .andExpect(jsonPath("$.total_count").value(0))
                .andReturn();

        assertThat(responseBody(result)).isEqualTo("{\"items\":[],\"page\":0,\"size\":20,\"total_count\":0}");
    }

    @Test
    void listOrdersLatestFirstByPublishedAtThenId() throws Exception {
        User author = saveUser("Order Author", "01011112222", "Seoul");
        Dog dog = saveDog(author, "OrderDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);

        AdoptionPost olderPost = savePost(
                author,
                dog,
                AdoptionPostStatus.OPEN,
                "Older published post",
                LocalDateTime.of(2026, 1, 1, 9, 0)
        );
        AdoptionPost lowerIdTiePost = savePost(
                author,
                dog,
                AdoptionPostStatus.OPEN,
                "Lower id tie post",
                LocalDateTime.of(2026, 1, 2, 9, 0)
        );
        AdoptionPost higherIdTiePost = savePost(
                author,
                dog,
                AdoptionPostStatus.OPEN,
                "Higher id tie post",
                LocalDateTime.of(2026, 1, 2, 9, 0)
        );
        AdoptionPost unpublishedPost = savePost(
                author,
                dog,
                AdoptionPostStatus.OPEN,
                "Unpublished post",
                null
        );

        mockMvc.perform(get("/api/adoption-posts"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(4)))
                .andExpect(jsonPath("$.items[0].post_id").value(higherIdTiePost.getId()))
                .andExpect(jsonPath("$.items[1].post_id").value(lowerIdTiePost.getId()))
                .andExpect(jsonPath("$.items[2].post_id").value(olderPost.getId()))
                .andExpect(jsonPath("$.items[3].post_id").value(unpublishedPost.getId()));
    }

    @Test
    void detailReturnsPublicPostWithoutAuthorizationHeader() throws Exception {
        User author = saveUser("Detail Author", "01012345678", "Seoul");
        Dog dog = saveDog(author, "Bori");
        String profilePath = saveProfileImage(dog, "detail-profile.jpg").getFilePath();
        saveVerificationLog(author, dog, VerificationResult.PENDING);
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.RESERVED, "Reserved adoption post");

        MvcResult result = mockMvc.perform(get("/api/adoption-posts/{post_id}", post.getId()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.post_id").value(post.getId()))
                .andExpect(jsonPath("$.dog_id").value(dog.getId()))
                .andExpect(jsonPath("$.title").value("Reserved adoption post"))
                .andExpect(jsonPath("$.content").value("Friendly dog looking for a family."))
                .andExpect(jsonPath("$.status").value("RESERVED"))
                .andExpect(jsonPath("$.dog_name").value("Bori"))
                .andExpect(jsonPath("$.breed").value("Maltese"))
                .andExpect(jsonPath("$.gender").value("MALE"))
                .andExpect(jsonPath("$.birth_date").value("2023-01-01"))
                .andExpect(jsonPath("$.description").value("Likes people and walks."))
                .andExpect(jsonPath("$.profile_image_url").value("/files/" + profilePath))
                .andExpect(jsonPath("$.verification_status").value("VERIFIED"))
                .andExpect(jsonPath("$.author_display_name").value("Detail Author"))
                .andExpect(jsonPath("$.author_contact_phone").value("01012345678"))
                .andExpect(jsonPath("$.author_region").value("Seoul"))
                .andExpect(jsonPath("$.liked").value(false))
                .andExpect(jsonPath("$.published_at").isNotEmpty())
                .andExpect(jsonPath("$.created_at").isNotEmpty())
                .andExpect(jsonPath("$.updated_at").isNotEmpty())
                .andExpect(jsonPath("$.nose_image_url").doesNotExist())
                .andReturn();

        assertThat(responseBody(result)).doesNotContain("nose_image_url", "postId");
    }

    @ParameterizedTest
    @ValueSource(strings = {"OPEN", "RESERVED", "COMPLETED"})
    void detailAllowsPublicStatuses(String statusValue) throws Exception {
        User author = saveUser("Detail Status Author", "01023234545", "Seoul");
        Dog dog = saveDog(author, statusValue + "DetailDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.valueOf(statusValue), statusValue + " detail post");

        MvcResult result = mockMvc.perform(get("/api/adoption-posts/{post_id}", post.getId()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.post_id").value(post.getId()))
                .andExpect(jsonPath("$.status").value(statusValue))
                .andExpect(jsonPath("$.nose_image_url").doesNotExist())
                .andReturn();

        assertPublicDetailFields(result);
        assertThat(responseBody(result)).doesNotContain("nose_image_url", "postId", "dogId");
    }

    @Test
    void detailMapsLatestFailureVerificationResultToFailed() throws Exception {
        User author = saveUser("Failed Author", "01033334444", "Incheon");
        Dog dog = saveDog(author, "FailedDog");
        saveProfileImage(dog, "failed-profile.jpg");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        saveVerificationLog(author, dog, VerificationResult.QDRANT_SEARCH_FAILED);
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.OPEN, "Failed verification status post");

        MvcResult result = mockMvc.perform(get("/api/adoption-posts/{post_id}", post.getId()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.verification_status").value("FAILED"))
                .andExpect(jsonPath("$.nose_image_url").doesNotExist())
                .andReturn();

        assertThat(responseBody(result)).doesNotContain("nose_image_url");
    }

    @Test
    void detailDefaultsMissingProfileAndVerificationLogToNullAndPending() throws Exception {
        User author = saveUser("Pending Author", "01055556666", "Jeju");
        Dog dog = saveDog(author, "PendingDog");
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.OPEN, "Pending verification post");

        MvcResult result = mockMvc.perform(get("/api/adoption-posts/{post_id}", post.getId()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.profile_image_url").value(nullValue()))
                .andExpect(jsonPath("$.verification_status").value("PENDING"))
                .andExpect(jsonPath("$.nose_image_url").doesNotExist())
                .andReturn();

        assertThat(responseBody(result)).doesNotContain("nose_image_url");
    }

    @Test
    void listDoesNotDuplicateFilesPrefixForExistingFilesUrl() throws Exception {
        User author = saveUser("Prefix Author", "01077778888", "Gwangju");
        Dog dog = saveDog(author, "PrefixDog");
        saveProfileImagePath(dog, "/files/dogs/%s/profile/existing-prefix.jpg".formatted(dog.getId()));
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        savePost(author, dog, AdoptionPostStatus.OPEN, "Existing files prefix post");

        MvcResult result = mockMvc.perform(get("/api/adoption-posts"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[0].profile_image_url").value("/files/dogs/%s/profile/existing-prefix.jpg".formatted(dog.getId())))
                .andExpect(jsonPath("$.items[0].nose_image_url").doesNotExist())
                .andReturn();

        assertThat(responseBody(result)).doesNotContain("/files/files/", "nose_image_url");
    }

    @Test
    void listNormalizesRelativeFilesPrefixWithoutDuplicatingFilesPrefix() throws Exception {
        User author = saveUser("Relative Prefix Author", "01012123434", "Gwangju");
        Dog dog = saveDog(author, "RelativePrefixDog");
        saveProfileImagePath(dog, "files/dogs/%s/profile/relative-prefix.jpg".formatted(dog.getId()));
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        savePost(author, dog, AdoptionPostStatus.OPEN, "Relative files prefix post");

        MvcResult result = mockMvc.perform(get("/api/adoption-posts"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[0].profile_image_url").value("/files/dogs/%s/profile/relative-prefix.jpg".formatted(dog.getId())))
                .andExpect(jsonPath("$.items[0].nose_image_url").doesNotExist())
                .andReturn();

        assertThat(responseBody(result)).doesNotContain("/files/files/", "nose_image_url");
    }

    @Test
    void listDefaultsMissingProfileAndVerificationLogToNullAndPending() throws Exception {
        User author = saveUser("List Pending Author", "01045456767", "Jeju");
        Dog dog = saveDog(author, "ListPendingDog");
        savePost(author, dog, AdoptionPostStatus.OPEN, "List pending post");

        MvcResult result = mockMvc.perform(get("/api/adoption-posts"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[0].profile_image_url").value(nullValue()))
                .andExpect(jsonPath("$.items[0].verification_status").value("PENDING"))
                .andExpect(jsonPath("$.items[0].nose_image_url").doesNotExist())
                .andReturn();

        assertThat(responseBody(result)).doesNotContain("nose_image_url");
    }

    @Test
    void listSelectsLatestProfileImageDeterministically() throws Exception {
        User author = saveUser("Image Author", "01099990000", "Daejeon");
        Dog dog = saveDog(author, "ImageDog");
        saveProfileImage(dog, "old-profile.jpg");
        saveProfileImage(dog, "latest-profile.jpg");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        savePost(author, dog, AdoptionPostStatus.OPEN, "Latest profile image post");

        mockMvc.perform(get("/api/adoption-posts"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[0].profile_image_url").value("/files/dogs/%s/profile/latest-profile.jpg".formatted(dog.getId())));
    }

    @ParameterizedTest
    @ValueSource(strings = {"DRAFT", "CLOSED"})
    void detailRejectsNonPublicPost(String statusValue) throws Exception {
        User author = saveUser("Private Author", "01012341234", "Daegu");
        Dog dog = saveDog(author, "PrivateDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.valueOf(statusValue), statusValue + " post");

        mockMvc.perform(get("/api/adoption-posts/{post_id}", post.getId()))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("POST_NOT_PUBLIC"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void detailReturnsPostNotFoundForMissingPost() throws Exception {
        mockMvc.perform(get("/api/adoption-posts/{post_id}", 999999L))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("POST_NOT_FOUND"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void meEndpointRequiresAuthorizationInsteadOfFallingThroughToPostDetail() throws Exception {
        mockMvc.perform(get("/api/adoption-posts/me"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));
    }

    @Test
    void likeCreatesRowForPublicPost() throws Exception {
        User author = saveUser("Like Author", "01010101010", "Seoul");
        User currentUser = saveUser("Like User", "01010101011", "Busan");
        Dog dog = saveDog(author, "LikeDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.OPEN, "Likeable post");

        mockMvc.perform(put("/api/adoption-posts/{post_id}/like", post.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor(currentUser)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.post_id").value(post.getId()))
                .andExpect(jsonPath("$.liked").value(true));

        assertThat(adoptionPostLikeRepository.existsByUserIdAndPostId(currentUser.getId(), post.getId())).isTrue();
    }

    @Test
    void likeIsIdempotentForSameUserAndPost() throws Exception {
        User author = saveUser("Idempotent Author", "01010101012", "Seoul");
        User currentUser = saveUser("Idempotent User", "01010101013", "Busan");
        Dog dog = saveDog(author, "IdempotentDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.OPEN, "Idempotent like post");
        String token = tokenFor(currentUser);

        mockMvc.perform(put("/api/adoption-posts/{post_id}/like", post.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + token))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.liked").value(true));
        mockMvc.perform(put("/api/adoption-posts/{post_id}/like", post.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + token))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.liked").value(true));

        assertThat(adoptionPostLikeRepository.countByUserIdAndPostId(currentUser.getId(), post.getId())).isEqualTo(1);
    }

    @Test
    void unlikeDeletesRowAndIsIdempotent() throws Exception {
        User author = saveUser("Unlike Author", "01010101014", "Seoul");
        User currentUser = saveUser("Unlike User", "01010101015", "Busan");
        Dog dog = saveDog(author, "UnlikeDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.OPEN, "Unlike post");
        saveLike(currentUser, post);
        String token = tokenFor(currentUser);

        mockMvc.perform(delete("/api/adoption-posts/{post_id}/like", post.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + token))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.post_id").value(post.getId()))
                .andExpect(jsonPath("$.liked").value(false));

        assertThat(adoptionPostLikeRepository.existsByUserIdAndPostId(currentUser.getId(), post.getId())).isFalse();

        mockMvc.perform(delete("/api/adoption-posts/{post_id}/like", post.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + token))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.post_id").value(post.getId()))
                .andExpect(jsonPath("$.liked").value(false));
    }

    @Test
    void likeRequiresAuthorization() throws Exception {
        mockMvc.perform(put("/api/adoption-posts/{post_id}/like", 1L))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));
    }

    @Test
    void likeReturnsPostNotFoundForMissingPost() throws Exception {
        User currentUser = saveUser("Missing Like User", "01010101016", "Seoul");

        mockMvc.perform(put("/api/adoption-posts/{post_id}/like", 999999L)
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor(currentUser)))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("POST_NOT_FOUND"));
    }

    @ParameterizedTest
    @ValueSource(strings = {"DRAFT", "CLOSED"})
    void likeRejectsNonPublicPost(String statusValue) throws Exception {
        User author = saveUser("Private Like Author", "01010101017", "Seoul");
        User currentUser = saveUser("Private Like User", "01010101018", "Busan");
        Dog dog = saveDog(author, statusValue + "LikeDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.valueOf(statusValue), statusValue + " private like post");

        mockMvc.perform(put("/api/adoption-posts/{post_id}/like", post.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor(currentUser)))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("POST_NOT_PUBLIC"));
    }

    @Test
    void unlikeAllowsExistingPrivatePostSoUsersCanCleanUpOldLikes() throws Exception {
        User author = saveUser("Private Unlike Author", "01010101019", "Seoul");
        User currentUser = saveUser("Private Unlike User", "01010101020", "Busan");
        Dog dog = saveDog(author, "PrivateUnlikeDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.CLOSED, "Closed unlike post");
        saveLike(currentUser, post);

        mockMvc.perform(delete("/api/adoption-posts/{post_id}/like", post.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor(currentUser)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.liked").value(false));

        assertThat(adoptionPostLikeRepository.existsByUserIdAndPostId(currentUser.getId(), post.getId())).isFalse();
    }

    @Test
    void likedListReturnsOnlyCurrentUsersVisibleLikesOrderedByLikedAt() throws Exception {
        User author = saveUser("Liked List Author", "01010101021", "Seoul");
        User currentUser = saveUser("Liked List User", "01010101022", "Busan");
        User otherUser = saveUser("Other Liker", "01010101023", "Daegu");
        Dog dog = saveDog(author, "LikedListDog");
        saveProfileImage(dog, "liked-list-profile.jpg");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost olderLikedPost = savePost(author, dog, AdoptionPostStatus.OPEN, "Older liked post");
        AdoptionPost newerLikedPost = savePost(author, dog, AdoptionPostStatus.RESERVED, "Newer liked post");
        AdoptionPost otherUsersPost = savePost(author, dog, AdoptionPostStatus.OPEN, "Other user liked post");
        saveLikeAt(currentUser, olderLikedPost, LocalDateTime.of(2026, 6, 1, 10, 0));
        saveLikeAt(currentUser, newerLikedPost, LocalDateTime.of(2026, 6, 2, 10, 0));
        saveLikeAt(otherUser, otherUsersPost, LocalDateTime.of(2026, 6, 3, 10, 0));

        MvcResult result = mockMvc.perform(get("/api/adoption-posts/liked/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor(currentUser))
                        .param("page", "0")
                        .param("size", "20"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(2)))
                .andExpect(jsonPath("$.page").value(0))
                .andExpect(jsonPath("$.size").value(20))
                .andExpect(jsonPath("$.total_count").value(2))
                .andExpect(jsonPath("$.items[0].post_id").value(newerLikedPost.getId()))
                .andExpect(jsonPath("$.items[0].status").value("RESERVED"))
                .andExpect(jsonPath("$.items[0].liked").value(true))
                .andExpect(jsonPath("$.items[0].liked_at").value("2026-06-02T10:00:00"))
                .andExpect(jsonPath("$.items[0].published_at").isNotEmpty())
                .andExpect(jsonPath("$.items[0].created_at").isNotEmpty())
                .andExpect(jsonPath("$.items[0].profile_image_url").value("/files/dogs/%s/profile/liked-list-profile.jpg".formatted(dog.getId())))
                .andExpect(jsonPath("$.items[1].post_id").value(olderLikedPost.getId()))
                .andExpect(jsonPath("$.items[1].liked").value(true))
                .andReturn();

        assertThat(responseBody(result)).doesNotContain("Other user liked post", "nose_image_url", "likedAt");
    }

    @Test
    void likedListExcludesDraftAndClosedPostsFromItemsAndTotalCount() throws Exception {
        User author = saveUser("Visible Like Author", "01010101024", "Seoul");
        User currentUser = saveUser("Visible Like User", "01010101025", "Busan");
        Dog dog = saveDog(author, "VisibleLikeDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost openPost = savePost(author, dog, AdoptionPostStatus.OPEN, "Visible liked post");
        AdoptionPost draftPost = savePost(author, dog, AdoptionPostStatus.DRAFT, "Draft liked post");
        AdoptionPost closedPost = savePost(author, dog, AdoptionPostStatus.CLOSED, "Closed liked post");
        saveLike(currentUser, openPost);
        saveLike(currentUser, draftPost);
        saveLike(currentUser, closedPost);

        MvcResult result = mockMvc.perform(get("/api/adoption-posts/liked/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor(currentUser)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(1)))
                .andExpect(jsonPath("$.total_count").value(1))
                .andExpect(jsonPath("$.items[0].post_id").value(openPost.getId()))
                .andExpect(jsonPath("$.items[0].liked").value(true))
                .andExpect(jsonPath("$.items[0].liked_at").isNotEmpty())
                .andReturn();

        assertThat(responseBody(result)).doesNotContain("Draft liked post", "Closed liked post", "nose_image_url");
    }

    @Test
    void publicListMapsLikedPerAuthenticatedUserAndFalseForOthers() throws Exception {
        User author = saveUser("Public Like Author", "01010101026", "Seoul");
        User currentUser = saveUser("Public Like User", "01010101027", "Busan");
        Dog dog = saveDog(author, "PublicLikeDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost likedPost = savePost(author, dog, AdoptionPostStatus.OPEN, "Liked public post", LocalDateTime.of(2026, 1, 2, 9, 0));
        AdoptionPost unlikedPost = savePost(author, dog, AdoptionPostStatus.OPEN, "Unliked public post", LocalDateTime.of(2026, 1, 1, 9, 0));
        saveLike(currentUser, likedPost);

        mockMvc.perform(get("/api/adoption-posts")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor(currentUser)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(2)))
                .andExpect(jsonPath("$.items[0].post_id").value(likedPost.getId()))
                .andExpect(jsonPath("$.items[0].liked").value(true))
                .andExpect(jsonPath("$.items[1].post_id").value(unlikedPost.getId()))
                .andExpect(jsonPath("$.items[1].liked").value(false));
    }

    @Test
    void publicListMapsLikedFalseWithoutAuthorizationHeader() throws Exception {
        User author = saveUser("Anonymous Like Author", "01010101028", "Seoul");
        Dog dog = saveDog(author, "AnonymousLikeDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        savePost(author, dog, AdoptionPostStatus.OPEN, "Anonymous public post");

        mockMvc.perform(get("/api/adoption-posts"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items", hasSize(1)))
                .andExpect(jsonPath("$.items[0].liked").value(false));
    }

    @Test
    void publicDetailMapsLikedByAuthorizationHeader() throws Exception {
        User author = saveUser("Detail Like Author", "01010101029", "Seoul");
        User currentUser = saveUser("Detail Like User", "01010101030", "Busan");
        User otherUser = saveUser("Detail Other User", "01010101031", "Daegu");
        Dog dog = saveDog(author, "DetailLikeDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.OPEN, "Detail liked post");
        saveLike(currentUser, post);

        mockMvc.perform(get("/api/adoption-posts/{post_id}", post.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor(currentUser)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.liked").value(true));

        mockMvc.perform(get("/api/adoption-posts/{post_id}", post.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenFor(otherUser)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.liked").value(false));

        mockMvc.perform(get("/api/adoption-posts/{post_id}", post.getId()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.liked").value(false));
    }

    @Test
    void publicListAndDetailRejectInvalidAuthorizationHeaderWhenProvided() throws Exception {
        User author = saveUser("Invalid Optional Auth Author", "01010101032", "Seoul");
        Dog dog = saveDog(author, "InvalidOptionalAuthDog");
        saveVerificationLog(author, dog, VerificationResult.PASSED);
        AdoptionPost post = savePost(author, dog, AdoptionPostStatus.OPEN, "Invalid optional auth post");

        mockMvc.perform(get("/api/adoption-posts")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer invalid-token"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));

        mockMvc.perform(get("/api/adoption-posts/{post_id}", post.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer invalid-token"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));
    }

    private User saveUser(String displayName, String contactPhone, String region) {
        User user = new User();
        user.setEmail("public-query-%d@example.com".formatted(++sequence));
        user.setPasswordHash("hash");
        user.setRole(UserRole.USER);
        user.setDisplayName(displayName);
        user.setContactPhone(contactPhone);
        user.setRegion(region);
        user.setActive(true);
        return userRepository.saveAndFlush(user);
    }

    private Dog saveDog(User owner, String name) {
        Dog dog = new Dog();
        dog.setId(UUID.randomUUID().toString());
        dog.setOwnerUserId(owner.getId());
        dog.setName(name);
        dog.setBreed("Maltese");
        dog.setGender(DogGender.MALE);
        dog.setBirthDate(LocalDate.of(2023, 1, 1));
        dog.setDescription("Likes people and walks.");
        dog.setStatus(DogStatus.REGISTERED);
        return dogRepository.saveAndFlush(dog);
    }

    private DogImage saveProfileImage(Dog dog, String filename) {
        return saveProfileImagePath(dog, "dogs/%s/profile/%s".formatted(dog.getId(), filename));
    }

    private DogImage saveProfileImagePath(Dog dog, String filePath) {
        DogImage image = new DogImage();
        image.setDogId(dog.getId());
        image.setImageType(DogImageType.PROFILE);
        image.setFilePath(filePath);
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
        LocalDateTime publishedAt = null;
        if (status == AdoptionPostStatus.OPEN || status == AdoptionPostStatus.RESERVED || status == AdoptionPostStatus.COMPLETED) {
            publishedAt = LocalDateTime.now();
        }
        return savePost(author, dog, status, title, publishedAt);
    }

    private AdoptionPost savePost(User author, Dog dog, AdoptionPostStatus status, String title, LocalDateTime publishedAt) {
        AdoptionPost post = new AdoptionPost();
        post.setAuthorUserId(author.getId());
        post.setDogId(dog.getId());
        post.setTitle(title);
        post.setContent("Friendly dog looking for a family.");
        post.setStatus(status);
        post.setPublishedAt(publishedAt);
        if (status == AdoptionPostStatus.CLOSED) {
            post.setClosedAt(LocalDateTime.now());
        }
        return adoptionPostRepository.saveAndFlush(post);
    }

    private AdoptionPostLike saveLike(User user, AdoptionPost post) {
        return saveLikeAt(user, post, LocalDateTime.now());
    }

    private AdoptionPostLike saveLikeAt(User user, AdoptionPost post, LocalDateTime createdAt) {
        AdoptionPostLike like = new AdoptionPostLike();
        like.setUserId(user.getId());
        like.setPostId(post.getId());
        like.setCreatedAt(createdAt);
        return adoptionPostLikeRepository.saveAndFlush(like);
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
        String signature = Base64.getUrlEncoder().withoutPadding().encodeToString(mac.doFinal(signingInput.getBytes(StandardCharsets.UTF_8)));
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

    private void assertPublicListItemFields(MvcResult result) throws Exception {
        JsonNode item = objectMapper.readTree(responseBody(result)).path("items").get(0);
        assertThat(fieldNames(item)).containsExactlyInAnyOrderElementsOf(PUBLIC_LIST_ITEM_FIELDS);
    }

    private void assertPublicDetailFields(MvcResult result) throws Exception {
        JsonNode body = objectMapper.readTree(responseBody(result));
        assertThat(fieldNames(body)).containsExactlyInAnyOrderElementsOf(PUBLIC_DETAIL_FIELDS);
    }

    private Set<String> fieldNames(JsonNode node) {
        Set<String> names = new LinkedHashSet<>();
        node.fieldNames().forEachRemaining(names::add);
        return names;
    }
}
