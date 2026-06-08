package com.petnose.api.controller;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.client.EmbedClient;
import com.petnose.api.client.QdrantDogVectorClient;
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
import com.petnose.api.domain.enums.VerificationPurpose;
import com.petnose.api.domain.enums.VerificationResult;
import com.petnose.api.repository.AdoptionPostRepository;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.repository.VerificationLogRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.ResultActions;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.nullValue;
import static org.mockito.Mockito.reset;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class AdoptionPostCreateControllerTest {

    private static final String JWT_SECRET = "test-petnose-jwt-secret-change-me-32bytes";

    @Autowired
    private org.springframework.test.web.servlet.MockMvc mockMvc;

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
    private EmbedClient embedClient;

    @MockBean
    private QdrantDogVectorClient qdrantDogVectorClient;

    private int sequence;

    @BeforeEach
    void setUp() {
        adoptionPostRepository.deleteAll();
        verificationLogRepository.deleteAll();
        dogImageRepository.deleteAll();
        dogRepository.deleteAll();
        userRepository.deleteAll();
        reset(embedClient, qdrantDogVectorClient);
        sequence = 0;
    }

    @Test
    void createOpenPostUsesRegisteredDogIdStoresProfileImageAndDoesNotEmbedOrUpsertAgain() throws Exception {
        User user = saveUser("초코 보호자", true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        DogImage noseImage = saveNoseImage(dog);
        saveVerificationLog(user, dog, noseImage, VerificationResult.PASSED);
        String token = tokenFor(user);

        ResultActions result = createPostWithPrice(token, dog.getId(), "말티즈 초코 가족을 찾습니다", "활발하고 사람을 좋아하는 아이입니다.", "150000", "OPEN");

        result.andExpect(status().isCreated())
                .andExpect(jsonPath("$.post_id").isNumber())
                .andExpect(jsonPath("$.dog_id").value(dog.getId()))
                .andExpect(jsonPath("$.title").value("말티즈 초코 가족을 찾습니다"))
                .andExpect(jsonPath("$.content").value("활발하고 사람을 좋아하는 아이입니다."))
                .andExpect(jsonPath("$.price").value(150000))
                .andExpect(jsonPath("$.status").value("OPEN"))
                .andExpect(jsonPath("$.published_at").isNotEmpty())
                .andExpect(jsonPath("$.created_at").isNotEmpty())
                .andExpect(jsonPath("$.author_user_id").doesNotExist());

        AdoptionPost saved = adoptionPostRepository.findAll().getFirst();
        assertThat(saved.getDogId()).isEqualTo(dog.getId());
        assertThat(saved.getAuthorUserId()).isEqualTo(user.getId());
        assertThat(saved.getPrice()).isEqualTo(150000L);
        assertThat(dogRepository.count()).isEqualTo(1);
        assertThat(dogImageRepository.count()).isEqualTo(2);
        assertThat(verificationLogRepository.count()).isEqualTo(1);

        List<DogImage> profileImages = dogImageRepository.findAll().stream()
                .filter(image -> image.getImageType() == DogImageType.PROFILE)
                .toList();
        assertThat(profileImages).hasSize(1);
        DogImage profileImage = profileImages.getFirst();
        assertThat(profileImage.getDogId()).isEqualTo(dog.getId());
        assertThat(profileImage.getFilePath()).contains("/profile/");
        assertThat(profileImage.getMimeType()).isEqualTo("image/jpeg");
        assertThat(profileImage.getFileSize()).isGreaterThan(0);
        assertThat(profileImage.getSha256()).isNotBlank();

        String profileImageUrl = "/files/" + profileImage.getFilePath();
        mockMvc.perform(get("/api/adoption-posts")
                        .param("status", "OPEN")
                        .param("page", "0")
                        .param("size", "20"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[0].post_id").value(saved.getId()))
                .andExpect(jsonPath("$.items[0].profile_image_url").value(profileImageUrl))
                .andExpect(jsonPath("$.items[0].price").doesNotExist());
        mockMvc.perform(get("/api/adoption-posts/{post_id}", saved.getId()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.post_id").value(saved.getId()))
                .andExpect(jsonPath("$.price").value(150000))
                .andExpect(jsonPath("$.profile_image_url").value(profileImageUrl));
        mockMvc.perform(get("/api/adoption-posts/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + token)
                        .param("page", "0")
                        .param("size", "20"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items[0].post_id").value(saved.getId()))
                .andExpect(jsonPath("$.items[0].profile_image_url").value(profileImageUrl));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void createDefaultsToDraftWhenStatusIsOmitted() throws Exception {
        User user = saveUser("초코 보호자", true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        saveVerificationLog(user, dog, saveNoseImage(dog), VerificationResult.PASSED);

        createPost(tokenFor(user), dog.getId(), "임시 제목", "임시 내용", null)
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.status").value("DRAFT"))
                .andExpect(jsonPath("$.published_at").value(nullValue()));

        AdoptionPost saved = adoptionPostRepository.findAll().getFirst();
        assertThat(saved.getStatus()).isEqualTo(AdoptionPostStatus.DRAFT);
        assertThat(saved.getPublishedAt()).isNull();
        assertThat(saved.getPrice()).isNull();
    }

    @Test
    void createStoresNullPriceWhenPriceIsBlank() throws Exception {
        User user = saveUser("초코 보호자", true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        dog.setPrice(75000L);
        dogRepository.saveAndFlush(dog);
        saveVerificationLog(user, dog, saveNoseImage(dog), VerificationResult.PASSED);

        createPostWithPrice(tokenFor(user), dog.getId(), "제목", "내용", "   ", "OPEN")
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.price").value(nullValue()));

        AdoptionPost saved = adoptionPostRepository.findAll().getFirst();
        assertThat(saved.getPrice()).isNull();
    }

    @Test
    void createUsesRegisteredDogPriceWhenCreatePriceIsMissing() throws Exception {
        User user = saveUser("초코 보호자", true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        dog.setPrice(75000L);
        dogRepository.saveAndFlush(dog);
        saveVerificationLog(user, dog, saveNoseImage(dog), VerificationResult.PASSED);

        createPost(tokenFor(user), dog.getId(), "제목", "내용", "OPEN")
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.price").value(75000));

        AdoptionPost saved = adoptionPostRepository.findAll().getFirst();
        assertThat(saved.getPrice()).isEqualTo(75000L);
    }

    @Test
    void rejectWhenPriceIsNegative() throws Exception {
        User user = saveUser("초코 보호자", true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        saveVerificationLog(user, dog, saveNoseImage(dog), VerificationResult.PASSED);

        createPostWithPrice(tokenFor(user), dog.getId(), "제목", "내용", "-1", "OPEN")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"));
    }

    @Test
    void rejectWhenPriceIsNotNumeric() throws Exception {
        User user = saveUser("초코 보호자", true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        saveVerificationLog(user, dog, saveNoseImage(dog), VerificationResult.PASSED);

        createPostWithPrice(tokenFor(user), dog.getId(), "제목", "내용", "free", "OPEN")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"));
    }

    @Test
    void rejectWhenPriceOverflowsLong() throws Exception {
        User user = saveUser("초코 보호자", true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        saveVerificationLog(user, dog, saveNoseImage(dog), VerificationResult.PASSED);

        createPostWithPrice(tokenFor(user), dog.getId(), "제목", "내용", "9223372036854775808", "OPEN")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"));
    }

    @Test
    void rejectWhenProfileImageIsMissing() throws Exception {
        User user = saveUser("초코 보호자", true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        saveVerificationLog(user, dog, saveNoseImage(dog), VerificationResult.PASSED);

        createPost(tokenFor(user), dog.getId(), "제목", "내용", "OPEN", null)
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("PROFILE_IMAGE_REQUIRED"));
    }

    @Test
    void rejectWhenDogBelongsToOtherUser() throws Exception {
        User owner = saveUser("원래 보호자", true);
        User currentUser = saveUser("다른 사용자", true);
        Dog dog = saveDog(owner, DogStatus.REGISTERED);
        saveVerificationLog(owner, dog, saveNoseImage(dog), VerificationResult.PASSED);

        createPost(tokenFor(currentUser), dog.getId(), "제목", "내용", "OPEN")
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error_code").value("DOG_OWNER_MISMATCH"));
    }

    @Test
    void rejectWhenDogIsDuplicateSuspected() throws Exception {
        User user = saveUser("초코 보호자", true);
        Dog dog = saveDog(user, DogStatus.DUPLICATE_SUSPECTED);
        saveVerificationLog(user, dog, saveNoseImage(dog), VerificationResult.DUPLICATE_SUSPECTED);

        createPost(tokenFor(user), dog.getId(), "제목", "내용", "OPEN")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("DOG_NOT_REGISTERED"));
    }

    @Test
    void rejectWhenPassedVerificationLogIsMissing() throws Exception {
        User user = saveUser("초코 보호자", true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);

        createPost(tokenFor(user), dog.getId(), "제목", "내용", "OPEN")
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("DOG_NOT_VERIFIED"));
    }

    @Test
    void rejectWhenDogAlreadyHasActivePost() throws Exception {
        User user = saveUser("초코 보호자", true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        saveVerificationLog(user, dog, saveNoseImage(dog), VerificationResult.PASSED);
        savePost(user, dog, AdoptionPostStatus.OPEN);

        createPost(tokenFor(user), dog.getId(), "제목", "내용", "OPEN")
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.error_code").value("DOG_ALREADY_HAS_ACTIVE_POST"));
    }

    @Test
    void rejectWhenAuthorizationHeaderIsMissing() throws Exception {
        createPost(null, UUID.randomUUID().toString(), "제목", "내용", "OPEN")
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));
    }

    @Test
    void rejectInactiveCurrentUser() throws Exception {
        User user = saveUser("초코 보호자", false);
        Dog dog = saveDog(user, DogStatus.REGISTERED);

        createPost(tokenFor(user), dog.getId(), "제목", "내용", "OPEN")
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error_code").value("USER_INACTIVE"));
    }

    private ResultActions createPost(String token, String dogId, String title, String content, String status) throws Exception {
        return createPost(token, dogId, title, content, null, status, profileImage());
    }

    private ResultActions createPost(String token, String dogId, String title, String content, String status, MockMultipartFile profileImage) throws Exception {
        return createPost(token, dogId, title, content, null, status, profileImage);
    }

    private ResultActions createPostWithPrice(String token, String dogId, String title, String content, String price, String status) throws Exception {
        return createPost(token, dogId, title, content, price, status, profileImage());
    }

    private ResultActions createPost(
            String token,
            String dogId,
            String title,
            String content,
            String price,
            String status,
            MockMultipartFile profileImage
    ) throws Exception {
        var request = multipart("/api/adoption-posts");
        if (dogId != null) {
            request.param("dog_id", dogId);
        }
        if (title != null) {
            request.param("title", title);
        }
        if (content != null) {
            request.param("content", content);
        }
        if (price != null) {
            request.param("price", price);
        }
        if (status != null) {
            request.param("status", status);
        }
        if (profileImage != null) {
            request.file(profileImage);
        }
        if (token != null) {
            request.header(HttpHeaders.AUTHORIZATION, "Bearer " + token);
        }
        return mockMvc.perform(request);
    }

    private MockMultipartFile profileImage() {
        return new MockMultipartFile(
                "profile_image",
                "profile.jpg",
                MediaType.IMAGE_JPEG_VALUE,
                new byte[]{1, 2, 3, 4, 5}
        );
    }

    private User saveUser(String displayName, boolean active) {
        User user = new User();
        user.setEmail("user-%d@example.com".formatted(++sequence));
        user.setPasswordHash("hash");
        user.setRole(UserRole.USER);
        user.setDisplayName(displayName);
        user.setContactPhone("01012341234");
        user.setRegion("Seoul");
        user.setActive(active);
        return userRepository.saveAndFlush(user);
    }

    private Dog saveDog(User owner, DogStatus status) {
        Dog dog = new Dog();
        dog.setId(UUID.randomUUID().toString());
        dog.setOwnerUserId(owner.getId());
        dog.setName("초코");
        dog.setBreed("Maltese");
        dog.setGender(DogGender.UNKNOWN);
        dog.setBirthDate(LocalDate.of(2024, 1, 1));
        dog.setDescription("밝은 아이입니다.");
        dog.setStatus(status);
        return dogRepository.saveAndFlush(dog);
    }

    private DogImage saveNoseImage(Dog dog) {
        DogImage image = new DogImage();
        image.setDogId(dog.getId());
        image.setImageType(DogImageType.NOSE);
        image.setFilePath("dogs/%s/nose/nose.jpg".formatted(dog.getId()));
        image.setMimeType("image/jpeg");
        image.setFileSize(3L);
        image.setSha256("nosehash%s".formatted(++sequence));
        return dogImageRepository.saveAndFlush(image);
    }

    private VerificationLog saveVerificationLog(User user, Dog dog, DogImage noseImage, VerificationResult result) {
        VerificationLog log = new VerificationLog();
        log.setDogId(dog.getId());
        log.setDogImageId(noseImage.getId());
        log.setRequestedByUserId(user.getId());
        log.setSubmittedImagePath(noseImage.getFilePath());
        log.setSubmittedImageMimeType(noseImage.getMimeType());
        log.setSubmittedImageFileSize(noseImage.getFileSize());
        log.setSubmittedImageSha256(noseImage.getSha256());
        log.setPurpose(VerificationPurpose.DOG_REGISTRATION);
        log.setResult(result);
        log.setModel("dog-nose-identification2:s101_224");
        log.setDimension(2048);
        return verificationLogRepository.saveAndFlush(log);
    }

    private AdoptionPost savePost(User author, Dog dog, AdoptionPostStatus status) {
        AdoptionPost post = new AdoptionPost();
        post.setAuthorUserId(author.getId());
        post.setDogId(dog.getId());
        post.setTitle("Existing post");
        post.setContent("Already active.");
        post.setStatus(status);
        if (status == AdoptionPostStatus.OPEN || status == AdoptionPostStatus.RESERVED || status == AdoptionPostStatus.COMPLETED) {
            post.setPublishedAt(LocalDateTime.now());
        }
        return adoptionPostRepository.saveAndFlush(post);
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
}
