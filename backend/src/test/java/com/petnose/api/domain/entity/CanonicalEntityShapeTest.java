package com.petnose.api.domain.entity;

import com.petnose.api.domain.enums.DogNoseEmbeddingKind;
import com.petnose.api.domain.enums.DogImageType;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.NoseReferenceQualityStatus;
import com.petnose.api.domain.enums.VerificationPurpose;
import com.petnose.api.domain.enums.VerificationResult;
import jakarta.persistence.Column;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Table;
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

        assertThat(fields).contains(
                "displayName",
                "contactPhone",
                "region",
                "profileImagePath",
                "profileImageMimeType",
                "profileImageFileSize",
                "profileImageSha256",
                "createdAt"
        );
        assertThat(fields).doesNotContain(join("updated", "At"), join("last", "LoginAt"));
    }

    @Test
    void userProfileColumnLengthsMatchActiveCanonical() throws Exception {
        assertThat(columnLength("displayName")).isEqualTo(150);
        assertThat(columnLength("contactPhone")).isEqualTo(30);
        assertThat(columnLength("region")).isEqualTo(100);
        assertThat(columnLength("profileImagePath")).isEqualTo(500);
        assertThat(columnLength("profileImageMimeType")).isEqualTo(100);
        assertThat(columnLength("profileImageSha256")).isEqualTo(64);
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
    void userProfileImageEntityAndMigrationTrackStorageMetadata() throws Exception {
        Column path = User.class.getDeclaredField("profileImagePath").getAnnotation(Column.class);
        Column mimeType = User.class.getDeclaredField("profileImageMimeType").getAnnotation(Column.class);
        Column fileSize = User.class.getDeclaredField("profileImageFileSize").getAnnotation(Column.class);
        Column sha256 = User.class.getDeclaredField("profileImageSha256").getAnnotation(Column.class);

        assertThat(path.name()).isEqualTo("profile_image_path");
        assertThat(path.length()).isEqualTo(500);
        assertThat(mimeType.name()).isEqualTo("profile_image_mime_type");
        assertThat(mimeType.length()).isEqualTo(100);
        assertThat(fileSize.name()).isEqualTo("profile_image_file_size");
        assertThat(sha256.name()).isEqualTo("profile_image_sha256");
        assertThat(sha256.length()).isEqualTo(64);

        String migration = resourceText("db/migration/V6__add_user_profile_image_fields.sql");
        assertThat(migration).contains(
                "ADD COLUMN profile_image_path VARCHAR(500) NULL AFTER region",
                "ADD COLUMN profile_image_mime_type VARCHAR(100) NULL AFTER profile_image_path",
                "ADD COLUMN profile_image_file_size BIGINT NULL AFTER profile_image_mime_type",
                "ADD COLUMN profile_image_sha256 CHAR(64) NULL AFTER profile_image_file_size"
        );
    }

    @Test
    void passwordResetTokenEntityAndMigrationStoreOnlyTokenHash() throws Exception {
        Set<String> fields = declaredFieldNames(PasswordResetToken.class);
        Column userId = PasswordResetToken.class.getDeclaredField("userId").getAnnotation(Column.class);
        Column tokenHash = PasswordResetToken.class.getDeclaredField("tokenHash").getAnnotation(Column.class);
        Column expiresAt = PasswordResetToken.class.getDeclaredField("expiresAt").getAnnotation(Column.class);
        Column usedAt = PasswordResetToken.class.getDeclaredField("usedAt").getAnnotation(Column.class);

        assertThat(fields).contains(
                "id",
                "userId",
                "tokenHash",
                "expiresAt",
                "usedAt",
                "createdAt"
        );
        assertThat(fields).doesNotContain("resetToken", "rawToken", "plainToken");
        assertThat(userId.name()).isEqualTo("user_id");
        assertThat(userId.nullable()).isFalse();
        assertThat(tokenHash.name()).isEqualTo("token_hash");
        assertThat(tokenHash.length()).isEqualTo(64);
        assertThat(tokenHash.nullable()).isFalse();
        assertThat(tokenHash.unique()).isTrue();
        assertThat(expiresAt.name()).isEqualTo("expires_at");
        assertThat(expiresAt.nullable()).isFalse();
        assertThat(usedAt.name()).isEqualTo("used_at");
        assertThat(usedAt.nullable()).isTrue();

        String migration = resourceText("db/migration/V7__add_password_reset_tokens.sql");
        assertThat(migration).contains(
                "CREATE TABLE password_reset_tokens",
                "token_hash CHAR(64) NOT NULL",
                "UNIQUE KEY uk_password_reset_tokens_hash (token_hash)",
                "KEY idx_password_reset_tokens_expires_at (expires_at)",
                "KEY idx_password_reset_tokens_user_used (user_id, used_at)",
                "FOREIGN KEY (user_id) REFERENCES users(id)"
        );
        assertThat(migration).doesNotContain("reset_token VARCHAR", "reset_token TEXT", "raw_token", "plain_token");
    }

    @Test
    void adoptionPostLikeEntityAndMigrationUseRelationTable() throws Exception {
        Set<String> fields = declaredFieldNames(AdoptionPostLike.class);
        Table table = AdoptionPostLike.class.getAnnotation(Table.class);
        Column userId = AdoptionPostLike.class.getDeclaredField("userId").getAnnotation(Column.class);
        Column postId = AdoptionPostLike.class.getDeclaredField("postId").getAnnotation(Column.class);
        Column createdAt = AdoptionPostLike.class.getDeclaredField("createdAt").getAnnotation(Column.class);

        assertThat(fields).containsExactlyInAnyOrder("id", "userId", "postId", "createdAt");
        assertThat(fields).doesNotContain("liked", "likedAt");
        assertThat(table.name()).isEqualTo("adoption_post_likes");
        assertThat(userId.name()).isEqualTo("user_id");
        assertThat(userId.nullable()).isFalse();
        assertThat(postId.name()).isEqualTo("post_id");
        assertThat(postId.nullable()).isFalse();
        assertThat(createdAt.name()).isEqualTo("created_at");
        assertThat(createdAt.nullable()).isFalse();
        assertThat(createdAt.updatable()).isFalse();

        String migration = resourceText("db/migration/V8__add_adoption_post_likes.sql");
        assertThat(migration).contains(
                "CREATE TABLE adoption_post_likes",
                "user_id BIGINT NOT NULL",
                "post_id BIGINT NOT NULL",
                "created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP",
                "UNIQUE KEY uk_adoption_post_likes_user_post (user_id, post_id)",
                "KEY idx_adoption_post_likes_user_created_at (user_id, created_at)",
                "KEY idx_adoption_post_likes_post_id (post_id)",
                "FOREIGN KEY (user_id) REFERENCES users(id)",
                "FOREIGN KEY (post_id) REFERENCES adoption_posts(id)"
        );
    }

    @Test
    void verificationLogEntityDoesNotExposeUpdatedAtOrEmbeddingVector() {
        Set<String> fields = declaredFieldNames(VerificationLog.class);

        assertThat(fields).contains(
                "result",
                "purpose",
                "similarityScore",
                "scoreBreakdownJson",
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
                DogStatus.REVIEW_REQUIRED,
                DogStatus.REJECTED,
                DogStatus.ADOPTED,
                DogStatus.INACTIVE
        );
        assertThat(DogImageType.values()).containsExactly(DogImageType.NOSE, DogImageType.PROFILE);
        assertThat(VerificationResult.values()).containsExactly(
                VerificationResult.PENDING,
                VerificationResult.PASSED,
                VerificationResult.DUPLICATE_SUSPECTED,
                VerificationResult.REVIEW_REQUIRED,
                VerificationResult.EMBED_FAILED,
                VerificationResult.QDRANT_SEARCH_FAILED,
                VerificationResult.QDRANT_UPSERT_FAILED
        );
        assertThat(DogNoseEmbeddingKind.values()).containsExactly(
                DogNoseEmbeddingKind.REFERENCE,
                DogNoseEmbeddingKind.CENTROID
        );
        assertThat(NoseReferenceQualityStatus.values()).containsExactly(
                NoseReferenceQualityStatus.ACCEPTED,
                NoseReferenceQualityStatus.REJECTED,
                NoseReferenceQualityStatus.NEEDS_REVIEW
        );
    }

    @Test
    void adoptionPostEntityAndRuntimeMigrationAlignWithCreatePolicy() throws Exception {
        Set<String> fields = declaredFieldNames(AdoptionPost.class);
        Column adopterUserId = AdoptionPost.class.getDeclaredField("adopterUserId").getAnnotation(Column.class);
        Column adoptedAt = AdoptionPost.class.getDeclaredField("adoptedAt").getAnnotation(Column.class);
        Column title = AdoptionPost.class.getDeclaredField("title").getAnnotation(Column.class);
        Column content = AdoptionPost.class.getDeclaredField("content").getAnnotation(Column.class);
        Column status = AdoptionPost.class.getDeclaredField("status").getAnnotation(Column.class);

        assertThat(fields).contains("adopterUserId", "adoptedAt");
        assertThat(adopterUserId.name()).isEqualTo("adopter_user_id");
        assertThat(adopterUserId.nullable()).isTrue();
        assertThat(adoptedAt.name()).isEqualTo("adopted_at");
        assertThat(adoptedAt.nullable()).isTrue();
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

        String adopterMigration = resourceText("db/migration/V9__add_adoption_completion_adopter.sql");
        assertThat(adopterMigration).contains(
                "ADD COLUMN adopter_user_id BIGINT NULL AFTER author_user_id",
                "ADD COLUMN adopted_at TIMESTAMP NULL AFTER closed_at",
                "ADD KEY idx_adoption_posts_adopter_user_id (adopter_user_id)",
                "ADD KEY idx_adoption_posts_adopter_status_adopted_at (adopter_user_id, status, adopted_at)",
                "FOREIGN KEY (adopter_user_id) REFERENCES users(id)"
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
                "scoreBreakdownJson",
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
    void dogNoseReferenceEntityAndMigrationTrackMultiReferenceQdrantPoints() throws Exception {
        Set<String> fields = declaredFieldNames(DogNoseReference.class);
        Column dogId = DogNoseReference.class.getDeclaredField("dogId").getAnnotation(Column.class);
        Column dogImageId = DogNoseReference.class.getDeclaredField("dogImageId").getAnnotation(Column.class);
        Column qdrantPointId = DogNoseReference.class.getDeclaredField("qdrantPointId").getAnnotation(Column.class);
        Enumerated embeddingKind = DogNoseReference.class.getDeclaredField("embeddingKind").getAnnotation(Enumerated.class);
        Column model = DogNoseReference.class.getDeclaredField("model").getAnnotation(Column.class);
        Column dimension = DogNoseReference.class.getDeclaredField("dimension").getAnnotation(Column.class);
        Column preprocessVersion = DogNoseReference.class.getDeclaredField("preprocessVersion").getAnnotation(Column.class);
        Enumerated qualityStatus = DogNoseReference.class.getDeclaredField("qualityStatus").getAnnotation(Enumerated.class);
        Column qualityScore = DogNoseReference.class.getDeclaredField("qualityScore").getAnnotation(Column.class);
        Column active = DogNoseReference.class.getDeclaredField("active").getAnnotation(Column.class);

        assertThat(fields).contains(
                "id",
                "dogId",
                "dogImageId",
                "qdrantPointId",
                "embeddingKind",
                "referenceIndex",
                "model",
                "dimension",
                "preprocessVersion",
                "qualityStatus",
                "qualityScore",
                "active",
                "createdAt"
        );
        assertThat(dogId.length()).isEqualTo(36);
        assertThat(dogId.nullable()).isFalse();
        assertThat(dogImageId.nullable()).isTrue();
        assertThat(qdrantPointId.length()).isEqualTo(36);
        assertThat(qdrantPointId.nullable()).isFalse();
        assertThat(qdrantPointId.unique()).isTrue();
        assertThat(embeddingKind.value()).isEqualTo(EnumType.STRING);
        assertThat(model.length()).isEqualTo(100);
        assertThat(model.nullable()).isFalse();
        assertThat(dimension.nullable()).isFalse();
        assertThat(preprocessVersion.length()).isEqualTo(100);
        assertThat(preprocessVersion.nullable()).isFalse();
        assertThat(qualityStatus.value()).isEqualTo(EnumType.STRING);
        assertThat(qualityScore.precision()).isEqualTo(6);
        assertThat(qualityScore.scale()).isEqualTo(5);
        assertThat(active.name()).isEqualTo("is_active");
        assertThat(active.nullable()).isFalse();

        String migration = resourceText("db/migration/V5__add_multi_reference_nose_references.sql");
        assertThat(migration).contains(
                "CREATE TABLE dog_nose_references",
                "qdrant_point_id CHAR(36) NOT NULL",
                "CHECK (embedding_kind IN ('REFERENCE', 'CENTROID'))",
                "CHECK (quality_status IN ('ACCEPTED', 'REJECTED', 'NEEDS_REVIEW'))",
                "ADD COLUMN score_breakdown_json TEXT NULL AFTER similarity_score"
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
