package com.petnose.api.service;

import com.petnose.api.domain.entity.AdoptionPost;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.entity.DogImage;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.entity.VerificationLog;
import com.petnose.api.domain.enums.DogImageType;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.VerificationPurpose;
import com.petnose.api.domain.enums.VerificationResult;
import com.petnose.api.dto.adoption.AdoptionPostCreateRequest;
import com.petnose.api.exception.ApiException;
import com.petnose.api.repository.AdoptionPostRepository;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.repository.VerificationLogRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.mock.web.MockMultipartFile;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class AdoptionPostServiceTest {

    @Mock
    private UserRepository userRepository;

    @Mock
    private DogRepository dogRepository;

    @Mock
    private VerificationLogRepository verificationLogRepository;

    @Mock
    private DogImageRepository dogImageRepository;

    @Mock
    private AdoptionPostRepository adoptionPostRepository;

    @Mock
    private FileStorageService fileStorageService;

    @InjectMocks
    private AdoptionPostService adoptionPostService;

    @Test
    void createOpenPostStoresProfileImageWithoutCreatingDogOrVectors() {
        User user = user(1L);
        Dog dog = dog(user.getId(), DogStatus.REGISTERED);
        VerificationLog log = passedDogRegistrationLog(dog);
        FileStorageService.StoredFile stored = storedProfileFile();
        when(userRepository.findById(user.getId())).thenReturn(Optional.of(user));
        when(dogRepository.findById(dog.getId())).thenReturn(Optional.of(dog));
        when(verificationLogRepository.findFirstByDogIdOrderByCreatedAtDescIdDesc(dog.getId())).thenReturn(Optional.of(log));
        when(adoptionPostRepository.existsByDogIdAndStatusIn(eq(dog.getId()), anyCollection()))
                .thenReturn(false);
        when(fileStorageService.storeProfileImage(eq(dog.getId()), any()))
                .thenReturn(stored);
        when(dogImageRepository.save(any(DogImage.class))).thenAnswer(invocation -> invocation.getArgument(0));
        when(adoptionPostRepository.save(any(AdoptionPost.class))).thenAnswer(invocation -> {
            AdoptionPost post = invocation.getArgument(0);
            post.setId(10L);
            post.prePersist();
            return post;
        });

        var response = adoptionPostService.create(user.getId(), validRequest(dog.getId(), "OPEN"));

        assertThat(response.postId()).isEqualTo(10L);
        assertThat(response.dogId()).isEqualTo(dog.getId());
        assertThat(response.status()).isEqualTo("OPEN");
        assertThat(response.publishedAt()).isNotNull();

        verify(dogRepository, never()).save(any());
        verify(verificationLogRepository, never()).save(any());
        verify(fileStorageService).storeProfileImage(eq(dog.getId()), any());
        verify(dogImageRepository).save(org.mockito.ArgumentMatchers.argThat(image ->
                image.getDogId().equals(dog.getId())
                        && image.getImageType() == DogImageType.PROFILE
                        && image.getFilePath().equals(stored.relativePath())
                        && image.getMimeType().equals(stored.mimeType())
                        && image.getFileSize().equals(stored.fileSize())
                        && image.getSha256().equals(stored.sha256())
        ));
    }

    @Test
    void createRejectsMissingProfileImage() {
        assertThatThrownBy(() -> adoptionPostService.create(1L, validRequest("dog-1", "OPEN", null)))
                .isInstanceOf(ApiException.class)
                .extracting("errorCode")
                .isEqualTo("PROFILE_IMAGE_REQUIRED");

        verifyNoInteractions(userRepository, dogRepository, verificationLogRepository, dogImageRepository, adoptionPostRepository, fileStorageService);
    }

    @Test
    void createRejectsDogOwnedByAnotherUser() {
        User currentUser = user(1L);
        Dog dog = dog(999L, DogStatus.REGISTERED);
        when(userRepository.findById(currentUser.getId())).thenReturn(Optional.of(currentUser));
        when(dogRepository.findById(dog.getId())).thenReturn(Optional.of(dog));

        assertThatThrownBy(() -> adoptionPostService.create(currentUser.getId(), validRequest(dog.getId(), "OPEN")))
                .isInstanceOf(ApiException.class)
                .extracting("errorCode")
                .isEqualTo("DOG_OWNER_MISMATCH");

        verifyNoInteractions(verificationLogRepository, dogImageRepository, fileStorageService);
    }

    @Test
    void createRejectsDogThatIsNotRegistered() {
        User user = user(1L);
        Dog dog = dog(user.getId(), DogStatus.DUPLICATE_SUSPECTED);
        when(userRepository.findById(user.getId())).thenReturn(Optional.of(user));
        when(dogRepository.findById(dog.getId())).thenReturn(Optional.of(dog));

        assertThatThrownBy(() -> adoptionPostService.create(user.getId(), validRequest(dog.getId(), "OPEN")))
                .isInstanceOf(ApiException.class)
                .extracting("errorCode")
                .isEqualTo("DOG_NOT_REGISTERED");

        verifyNoInteractions(verificationLogRepository, dogImageRepository, fileStorageService);
    }

    @Test
    void createRejectsRegisteredDogWithoutPassedVerificationLog() {
        User user = user(1L);
        Dog dog = dog(user.getId(), DogStatus.REGISTERED);
        VerificationLog duplicateLog = passedDogRegistrationLog(dog);
        duplicateLog.setResult(VerificationResult.DUPLICATE_SUSPECTED);
        when(userRepository.findById(user.getId())).thenReturn(Optional.of(user));
        when(dogRepository.findById(dog.getId())).thenReturn(Optional.of(dog));
        when(verificationLogRepository.findFirstByDogIdOrderByCreatedAtDescIdDesc(dog.getId())).thenReturn(Optional.of(duplicateLog));

        assertThatThrownBy(() -> adoptionPostService.create(user.getId(), validRequest(dog.getId(), "OPEN")))
                .isInstanceOf(ApiException.class)
                .extracting("errorCode")
                .isEqualTo("DOG_NOT_VERIFIED");

        verify(adoptionPostRepository, never()).save(any());
        verifyNoInteractions(dogImageRepository, fileStorageService);
    }

    @Test
    void createRejectsDogThatAlreadyHasActivePost() {
        User user = user(1L);
        Dog dog = dog(user.getId(), DogStatus.REGISTERED);
        when(userRepository.findById(user.getId())).thenReturn(Optional.of(user));
        when(dogRepository.findById(dog.getId())).thenReturn(Optional.of(dog));
        when(verificationLogRepository.findFirstByDogIdOrderByCreatedAtDescIdDesc(dog.getId()))
                .thenReturn(Optional.of(passedDogRegistrationLog(dog)));
        when(adoptionPostRepository.existsByDogIdAndStatusIn(eq(dog.getId()), anyCollection()))
                .thenReturn(true);

        assertThatThrownBy(() -> adoptionPostService.create(user.getId(), validRequest(dog.getId(), "OPEN")))
                .isInstanceOf(ApiException.class)
                .extracting("errorCode")
                .isEqualTo("DOG_ALREADY_HAS_ACTIVE_POST");

        verify(adoptionPostRepository, never()).save(any());
        verifyNoInteractions(dogImageRepository, fileStorageService);
    }

    private User user(Long id) {
        User user = new User();
        user.setId(id);
        user.setDisplayName("초코보호자");
        user.setActive(true);
        return user;
    }

    private Dog dog(Long ownerUserId, DogStatus status) {
        Dog dog = new Dog();
        dog.setId("dog-1");
        dog.setOwnerUserId(ownerUserId);
        dog.setName("초코");
        dog.setBreed("Maltese");
        dog.setStatus(status);
        return dog;
    }

    private VerificationLog passedDogRegistrationLog(Dog dog) {
        VerificationLog log = new VerificationLog();
        log.setId(100L);
        log.setDogId(dog.getId());
        log.setDogImageId(1L);
        log.setRequestedByUserId(dog.getOwnerUserId());
        log.setPurpose(VerificationPurpose.DOG_REGISTRATION);
        log.setResult(VerificationResult.PASSED);
        log.setModel("dog-nose-identification2:s101_224");
        log.setDimension(2048);
        return log;
    }

    private AdoptionPostCreateRequest validRequest(String dogId, String status) {
        return validRequest(dogId, status, profileImage());
    }

    private AdoptionPostCreateRequest validRequest(String dogId, String status, MockMultipartFile profileImage) {
        return new AdoptionPostCreateRequest(
                dogId,
                "제목",
                "내용",
                status,
                profileImage
        );
    }

    private MockMultipartFile profileImage() {
        return new MockMultipartFile(
                "profile_image",
                "profile.jpg",
                "image/jpeg",
                new byte[]{1, 2, 3}
        );
    }

    private FileStorageService.StoredFile storedProfileFile() {
        return new FileStorageService.StoredFile(
                "dogs/dog-1/profile/profile.jpg",
                "image/jpeg",
                3L,
                "profile-sha256",
                "profile.jpg",
                new byte[]{1, 2, 3}
        );
    }
}
