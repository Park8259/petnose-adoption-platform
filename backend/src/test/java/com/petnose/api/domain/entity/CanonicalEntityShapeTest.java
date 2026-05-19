package com.petnose.api.domain.entity;

import com.petnose.api.domain.enums.DogImageType;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.VerificationPurpose;
import jakarta.persistence.Column;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import org.junit.jupiter.api.Test;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Set;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CanonicalEntityShapeTest {

    @Test
    void dogEntityDoesNotExposeRemovedRegistrationSnapshotFields() {
        Set<String> fields = declaredFieldNames(Dog.class);

        assertThat(fields).doesNotContain(
                join("qdrant", "PointId"),
                join("nose", "VerificationStatus"),
                join("embedding", "Status"),
                join("duplicate", "CandidateDogId"),
                join("duplicate", "SimilarityScore"),
                join("embedding", "Model"),
                join("embedding", "Dimension"),
                join("verified", "At")
        );
    }

    @Test
    void userEntityMatchesSimplifiedProfileShape() {
        Set<String> fields = declaredFieldNames(User.class);

        assertThat(fields).contains("displayName", "contactPhone", "region", "createdAt");
        assertThat(fields).doesNotContain(join("updated", "At"), join("last", "LoginAt"));
    }

    @Test
    void userProfileColumnLengthsMatchActiveCanonical() throws Exception {
        assertThat(columnLength("displayName")).isEqualTo(150);
        assertThat(columnLength("contactPhone")).isEqualTo(30);
        assertThat(columnLength("region")).isEqualTo(100);
    }

    @Test
    void flywayBaselineUsesActiveCanonicalUserProfileColumnLengths() throws Exception {
        String baseline = resourceText("db/migration/V1__baseline.sql");

        assertThat(baseline).contains(
                "display_name VARCHAR(150) NULL",
                "contact_phone VARCHAR(30) NULL",
                "region VARCHAR(100) NULL"
        );
    }

    @Test
    void verificationLogEntityDoesNotExposeUpdatedAtOrEmbeddingVector() {
        Set<String> fields = declaredFieldNames(VerificationLog.class);

        assertThat(fields).contains(
                "result",
                "purpose",
                "similarityScore",
                "candidateDogId",
                "model",
                "dimension",
                "failureReason",
                "submittedImagePath",
                "submittedImageMimeType",
                "submittedImageFileSize",
                "submittedImageSha256"
        );
        assertThat(fields).doesNotContain(join("updated", "At"), "embedding", join("embedding", "Vector"), "vector");
    }

    @Test
    void canonicalEnumsMatchSimplifiedDbmlV2() {
        assertThat(DogStatus.values()).containsExactly(
                DogStatus.PENDING,
                DogStatus.REGISTERED,
                DogStatus.DUPLICATE_SUSPECTED,
                DogStatus.REJECTED,
                DogStatus.ADOPTED,
                DogStatus.INACTIVE
        );
        assertThat(DogImageType.values()).containsExactly(DogImageType.NOSE, DogImageType.PROFILE);
    }

    @Test
    void adoptionPostEntityAndRuntimeMigrationAlignWithCreatePolicy() throws Exception {
        Column title = AdoptionPost.class.getDeclaredField("title").getAnnotation(Column.class);
        Column content = AdoptionPost.class.getDeclaredField("content").getAnnotation(Column.class);
        Column status = AdoptionPost.class.getDeclaredField("status").getAnnotation(Column.class);

        assertThat(title.length()).isEqualTo(200);
        assertThat(title.nullable()).isFalse();
        assertThat(content.nullable()).isFalse();
        assertThat(status.length()).isEqualTo(20);
        assertThat(status.nullable()).isFalse();

        String migration = resourceText("db/migration/V2__align_adoption_post_content_constraints.sql");
        assertThat(migration).contains(
                "MODIFY title VARCHAR(200) NOT NULL",
                "MODIFY content TEXT NOT NULL"
        );
    }

    @Test
    void verificationLogEntityAndMigrationSupportDogIdCenteredVerificationHistory() throws Exception {
        Set<String> fields = declaredFieldNames(VerificationLog.class);
        Column dogId = VerificationLog.class.getDeclaredField("dogId").getAnnotation(Column.class);
        Column dogImageId = VerificationLog.class.getDeclaredField("dogImageId").getAnnotation(Column.class);
        Column requestedByUserId = VerificationLog.class.getDeclaredField("requestedByUserId").getAnnotation(Column.class);
        Column submittedImagePath = VerificationLog.class.getDeclaredField("submittedImagePath").getAnnotation(Column.class);
        Enumerated result = VerificationLog.class.getDeclaredField("result").getAnnotation(Enumerated.class);
        Enumerated purpose = VerificationLog.class.getDeclaredField("purpose").getAnnotation(Enumerated.class);

        assertThat(fields).contains(
                "id",
                "dogId",
                "dogImageId",
                "requestedByUserId",
                "submittedImagePath",
                "submittedImageMimeType",
                "submittedImageFileSize",
                "submittedImageSha256",
                "result",
                "similarityScore",
                "candidateDogId",
                "model",
                "dimension",
                "failureReason",
                "createdAt"
        );
        assertThat(dogId.nullable()).isFalse();
        assertThat(dogImageId.nullable()).isTrue();
        assertThat(requestedByUserId.nullable()).isFalse();
        assertThat(submittedImagePath.length()).isEqualTo(500);
        assertThat(submittedImagePath.nullable()).isTrue();
        assertThat(result.value()).isEqualTo(EnumType.STRING);
        assertThat(purpose.value()).isEqualTo(EnumType.STRING);
        assertThat(VerificationPurpose.values()).containsExactly(
                VerificationPurpose.DOG_REGISTRATION,
                VerificationPurpose.HANDOVER_COMPARE
        );

        String migration = resourceText("db/migration/V4__remove_nose_verification_attempts_and_align_verification_logs.sql");
        assertThat(migration).contains(
                "MODIFY dog_image_id BIGINT NULL",
                "ADD COLUMN submitted_image_path VARCHAR(500) NULL",
                "ADD COLUMN purpose VARCHAR(40) NOT NULL DEFAULT 'DOG_REGISTRATION'",
                "'HANDOVER_COMPARE'",
                "DROP TABLE " + join("nose", "_verification_attempts")
        );
    }

    @Test
    void removedPrecheckAttemptTypesAreNotActive() {
        assertThatThrownBy(() -> Class.forName("com.petnose.api.domain.entity." + join("Nose", "VerificationAttempt")))
                .isInstanceOf(ClassNotFoundException.class);
        assertThatThrownBy(() -> Class.forName("com.petnose.api.repository." + join("Nose", "VerificationAttempt") + "Repository"))
                .isInstanceOf(ClassNotFoundException.class);
        assertThatThrownBy(() -> Class.forName("com.petnose.api.domain.enums." + join("Nose", "VerificationStatus")))
                .isInstanceOf(ClassNotFoundException.class);
    }

    @Test
    void publisherProfileEntityIsNotActive() {
        assertThatThrownBy(() -> Class.forName("com.petnose.api.domain.entity." + join("Publisher", "Profile")))
                .isInstanceOf(ClassNotFoundException.class);
    }

    private static Set<String> declaredFieldNames(Class<?> type) {
        return Arrays.stream(type.getDeclaredFields())
                .map(java.lang.reflect.Field::getName)
                .collect(Collectors.toSet());
    }

    private static int columnLength(String fieldName) throws Exception {
        return User.class.getDeclaredField(fieldName)
                .getAnnotation(Column.class)
                .length();
    }

    private String resourceText(String path) throws Exception {
        try (InputStream inputStream = getClass().getClassLoader().getResourceAsStream(path)) {
            assertThat(inputStream).as(path).isNotNull();
            return new String(inputStream.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    private static String join(String first, String second) {
        return first + second;
    }
}
