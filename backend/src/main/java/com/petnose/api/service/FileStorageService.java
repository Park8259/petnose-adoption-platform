package com.petnose.api.service;

import com.petnose.api.exception.ApiException;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.nio.file.DirectoryNotEmptyException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Collection;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

@Slf4j
@Service
public class FileStorageService {

    private static final DateTimeFormatter TS_FORMAT = DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss");
    private static final Set<String> ALLOWED_EXTENSIONS = Set.of("jpg", "jpeg", "png");
    private static final Set<String> ALLOWED_CONTENT_TYPES = Set.of("image/jpeg", "image/png", "image/jpg");

    private final Path uploadBasePath;

    public FileStorageService(@Value("${upload.base-path:/var/uploads}") String uploadBasePath) {
        this.uploadBasePath = Paths.get(uploadBasePath).normalize().toAbsolutePath();
    }

    public StoredFile storeNoseImage(String dogId, MultipartFile file) {
        return storeImageAt("dogs/%s/nose".formatted(dogId), file);
    }

    public StoredFile storeProfileImage(String dogId, MultipartFile file) {
        return storeImageAt("dogs/%s/profile".formatted(dogId), file);
    }

    public StoredFile storeUserProfileImage(Long userId, MultipartFile file) {
        return storeImageAt("users/%s/profile".formatted(userId), file);
    }

    private StoredFile storeImageAt(String relativeDirectory, MultipartFile file) {
        if (file == null || file.isEmpty()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_IMAGE", "이미지 파일이 비어 있습니다.");
        }

        String originalFilename = sanitizeOriginalFilename(file.getOriginalFilename());
        String extension = extractExtension(originalFilename);
        String contentType = normalizeContentType(file.getContentType());
        validateImageType(extension, contentType);

        String timestamp = TS_FORMAT.format(LocalDateTime.now());
        String baseName = stripExtension(originalFilename);
        String sanitizedBase = sanitizeBaseName(baseName);
        String candidateName = timestamp + "_" + sanitizedBase + "." + extension;

        String relativePath = relativeDirectory + "/" + candidateName;
        Path absolutePath = resolveSafePath(relativePath);
        Path parentDir = absolutePath.getParent();

        try {
            Files.createDirectories(parentDir);
            Path finalPath = resolveCollisionSafePath(absolutePath);
            byte[] bytes = file.getBytes();
            Files.write(finalPath, bytes);

            String normalizedRelativePath = uploadBasePath.relativize(finalPath).toString().replace('\\', '/');
            return new StoredFile(
                    normalizedRelativePath,
                    contentType,
                    (long) bytes.length,
                    sha256Hex(bytes),
                    originalFilename,
                    bytes
            );
        } catch (IOException e) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "FILE_STORE_FAILED", "이미지 저장에 실패했습니다.");
        }
    }

    public String toPublicUrl(String relativePath) {
        return "/files/" + relativePath;
    }

    public void deleteStoredFileQuietly(StoredFile storedFile) {
        if (storedFile == null) {
            return;
        }
        deleteRelativePathQuietly(storedFile.relativePath());
    }

    public void deleteStoredFilesQuietly(Collection<StoredFile> storedFiles) {
        if (storedFiles == null || storedFiles.isEmpty()) {
            return;
        }
        storedFiles.forEach(this::deleteStoredFileQuietly);
    }

    public void deleteRelativePathQuietly(String relativePath) {
        if (relativePath == null || relativePath.isBlank()) {
            return;
        }
        try {
            Path path = resolveSafePath(relativePath);
            Files.deleteIfExists(path);
            cleanupEmptyParentDirectories(path.getParent());
        } catch (ApiException e) {
            log.warn("[FileStorage] upload delete skipped for invalid relativePath={}", relativePath);
        } catch (IOException | RuntimeException e) {
            log.warn("[FileStorage] upload delete failed for relativePath={}, message={}", relativePath, e.getMessage());
        }
    }

    public void deleteOnTransactionRollback(StoredFile storedFile) {
        if (storedFile == null || !TransactionSynchronizationManager.isSynchronizationActive()) {
            return;
        }
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCompletion(int status) {
                if (status == TransactionSynchronization.STATUS_ROLLED_BACK) {
                    deleteStoredFileQuietly(storedFile);
                }
            }
        });
    }

    public StoredFile readStoredImage(String relativePath, String mimeType, Long fileSize, String sha256) {
        if (relativePath == null || relativePath.isBlank()) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "FILE_READ_FAILED", "저장된 이미지 경로가 없습니다.");
        }
        Path path = resolveSafePath(relativePath);
        try {
            byte[] bytes = Files.readAllBytes(path);
            String filename = path.getFileName().toString();
            return new StoredFile(
                    uploadBasePath.relativize(path).toString().replace('\\', '/'),
                    mimeType,
                    fileSize == null ? (long) bytes.length : fileSize,
                    sha256,
                    filename,
                    bytes
            );
        } catch (IOException e) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "FILE_READ_FAILED", "저장된 이미지를 읽을 수 없습니다.");
        }
    }

    private static String sanitizeOriginalFilename(String originalFilename) {
        String fallback = "upload.png";
        String raw = (originalFilename == null || originalFilename.isBlank()) ? fallback : originalFilename;
        return Paths.get(raw).getFileName().toString();
    }

    private static String extractExtension(String filename) {
        int lastDot = filename.lastIndexOf('.');
        if (lastDot < 0 || lastDot == filename.length() - 1) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_IMAGE_EXTENSION", "확장자가 없는 파일은 업로드할 수 없습니다.");
        }
        String ext = filename.substring(lastDot + 1).toLowerCase(Locale.ROOT);
        if (!ALLOWED_EXTENSIONS.contains(ext)) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_IMAGE_EXTENSION", "jpg/jpeg/png 파일만 업로드할 수 있습니다.");
        }
        return ext;
    }

    private static String normalizeContentType(String contentType) {
        if (contentType == null || contentType.isBlank()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_CONTENT_TYPE", "이미지 Content-Type이 누락되었습니다.");
        }
        return contentType.toLowerCase(Locale.ROOT);
    }

    private static void validateImageType(String extension, String contentType) {
        if (!ALLOWED_CONTENT_TYPES.contains(contentType)) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_CONTENT_TYPE", "지원하지 않는 이미지 Content-Type입니다.");
        }
        if ("png".equals(extension) && !contentType.contains("png")) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_IMAGE_TYPE", "PNG 확장자와 Content-Type이 일치하지 않습니다.");
        }
        if (("jpg".equals(extension) || "jpeg".equals(extension)) && !contentType.contains("jpeg") && !contentType.contains("jpg")) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_IMAGE_TYPE", "JPG 확장자와 Content-Type이 일치하지 않습니다.");
        }
    }

    private static String stripExtension(String filename) {
        int lastDot = filename.lastIndexOf('.');
        return lastDot < 0 ? filename : filename.substring(0, lastDot);
    }

    private static String sanitizeBaseName(String baseName) {
        String sanitized = baseName.replaceAll("[^A-Za-z0-9._-]", "_");
        if (sanitized.isBlank()) {
            sanitized = "image";
        }
        if (sanitized.length() > 40) {
            return sanitized.substring(0, 40);
        }
        return sanitized;
    }

    private Path resolveSafePath(String relativePath) {
        Path normalizedRelative = Paths.get(relativePath).normalize();
        Path resolved = uploadBasePath.resolve(normalizedRelative).normalize();
        if (!resolved.startsWith(uploadBasePath)) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_PATH", "유효하지 않은 파일 경로입니다.");
        }
        return resolved;
    }

    private void cleanupEmptyParentDirectories(Path parentDir) throws IOException {
        Path current = parentDir;
        while (current != null && !current.equals(uploadBasePath) && current.startsWith(uploadBasePath)) {
            try {
                Files.deleteIfExists(current);
            } catch (DirectoryNotEmptyException e) {
                return;
            }
            current = current.getParent();
        }
    }

    private static Path resolveCollisionSafePath(Path requestedPath) {
        if (!Files.exists(requestedPath)) {
            return requestedPath;
        }
        String fileName = requestedPath.getFileName().toString();
        int dot = fileName.lastIndexOf('.');
        String name = dot >= 0 ? fileName.substring(0, dot) : fileName;
        String ext = dot >= 0 ? fileName.substring(dot) : "";

        Path parent = requestedPath.getParent();
        for (int i = 0; i < 5; i++) {
            String candidate = name + "_" + UUID.randomUUID().toString().substring(0, 4) + ext;
            Path candidatePath = parent.resolve(candidate);
            if (!Files.exists(candidatePath)) {
                return candidatePath;
            }
        }
        throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "FILE_NAME_CONFLICT", "파일명 충돌로 저장에 실패했습니다.");
    }

    private static String sha256Hex(byte[] bytes) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            return HexFormat.of().formatHex(digest.digest(bytes));
        } catch (NoSuchAlgorithmException e) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "HASH_ERROR", "파일 해시 계산에 실패했습니다.");
        }
    }

    public record StoredFile(
            String relativePath,
            String mimeType,
            Long fileSize,
            String sha256,
            String originalFilename,
            byte[] bytes
    ) {
    }
}
