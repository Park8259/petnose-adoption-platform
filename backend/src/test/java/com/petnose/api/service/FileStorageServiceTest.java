package com.petnose.api.service;

import com.petnose.api.exception.ApiException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThatNoException;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class FileStorageServiceTest {

    @TempDir
    Path uploadRoot;

    @Test
    void storeUserProfileImageStoresBelowUserProfileDirectory() {
        FileStorageService service = new FileStorageService(uploadRoot.toString());

        FileStorageService.StoredFile stored = service.storeUserProfileImage(
                101L,
                new MockMultipartFile("profile_image", "avatar.jpg", "image/jpeg", new byte[]{1, 2, 3})
        );

        assertThat(stored.relativePath()).startsWith("users/101/profile/");
        assertThat(stored.relativePath()).endsWith("_avatar.jpg");
        assertThat(stored.mimeType()).isEqualTo("image/jpeg");
        assertThat(stored.fileSize()).isEqualTo(3L);
        assertThat(stored.sha256()).hasSize(64);
        assertThat(Files.exists(uploadRoot.resolve(stored.relativePath()))).isTrue();
    }

    @Test
    void storeUserProfileImageRejectsInvalidExtensionWithExistingImagePolicy() {
        FileStorageService service = new FileStorageService(uploadRoot.toString());

        assertThatThrownBy(() -> service.storeUserProfileImage(
                101L,
                new MockMultipartFile("profile_image", "avatar.gif", "image/gif", new byte[]{1, 2, 3})
        ))
                .isInstanceOfSatisfying(ApiException.class, e ->
                        assertThat(e.getErrorCode()).isEqualTo("INVALID_IMAGE_EXTENSION"));
    }

    @Test
    void deleteStoredFileQuietlyDeletesStoredFile() {
        FileStorageService service = new FileStorageService(uploadRoot.toString());
        FileStorageService.StoredFile stored = service.storeUserProfileImage(
                101L,
                new MockMultipartFile("profile_image", "avatar.jpg", "image/jpeg", new byte[]{1, 2, 3})
        );

        service.deleteStoredFileQuietly(stored);

        assertThat(Files.exists(uploadRoot.resolve(stored.relativePath()))).isFalse();
    }

    @Test
    void deleteStoredFileQuietlyIgnoresAlreadyMissingFile() {
        FileStorageService service = new FileStorageService(uploadRoot.toString());
        FileStorageService.StoredFile stored = service.storeUserProfileImage(
                101L,
                new MockMultipartFile("profile_image", "avatar.jpg", "image/jpeg", new byte[]{1, 2, 3})
        );
        service.deleteStoredFileQuietly(stored);

        assertThatNoException().isThrownBy(() -> service.deleteStoredFileQuietly(stored));
    }

    @Test
    void deleteRelativePathQuietlyIgnoresNullAndBlankPath() {
        FileStorageService service = new FileStorageService(uploadRoot.toString());

        assertThatNoException().isThrownBy(() -> {
            service.deleteRelativePathQuietly(null);
            service.deleteRelativePathQuietly("");
            service.deleteRelativePathQuietly("   ");
        });
    }

    @Test
    void deleteRelativePathQuietlyDoesNotDeleteOutsideUploadRoot() throws Exception {
        FileStorageService service = new FileStorageService(uploadRoot.toString());
        Path outside = Files.createTempFile(uploadRoot.getParent(), "outside-upload-root-", ".txt");
        Files.writeString(outside, "keep");

        try {
            service.deleteRelativePathQuietly("../" + outside.getFileName());

            assertThat(Files.exists(outside)).isTrue();
        } finally {
            Files.deleteIfExists(outside);
        }
    }

    @Test
    void deleteOnTransactionRollbackDeletesStoredFileOnRollback() {
        FileStorageService service = new FileStorageService(uploadRoot.toString());
        FileStorageService.StoredFile stored = service.storeUserProfileImage(
                101L,
                new MockMultipartFile("profile_image", "avatar.jpg", "image/jpeg", new byte[]{1, 2, 3})
        );

        completeSynchronization(TransactionSynchronization.STATUS_ROLLED_BACK, () ->
                service.deleteOnTransactionRollback(stored)
        );

        assertThat(Files.exists(uploadRoot.resolve(stored.relativePath()))).isFalse();
    }

    @Test
    void deleteOnTransactionRollbackKeepsStoredFileOnCommit() {
        FileStorageService service = new FileStorageService(uploadRoot.toString());
        FileStorageService.StoredFile stored = service.storeUserProfileImage(
                101L,
                new MockMultipartFile("profile_image", "avatar.jpg", "image/jpeg", new byte[]{1, 2, 3})
        );

        completeSynchronization(TransactionSynchronization.STATUS_COMMITTED, () ->
                service.deleteOnTransactionRollback(stored)
        );

        assertThat(Files.exists(uploadRoot.resolve(stored.relativePath()))).isTrue();
    }

    private void completeSynchronization(int status, Runnable registerCleanup) {
        TransactionSynchronizationManager.initSynchronization();
        try {
            registerCleanup.run();
            TransactionSynchronizationManager.getSynchronizations()
                    .forEach(synchronization -> synchronization.afterCompletion(status));
        } finally {
            TransactionSynchronizationManager.clearSynchronization();
        }
    }
}
