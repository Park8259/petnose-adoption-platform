package com.petnose.api.controller;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.domain.entity.User;
import com.petnose.api.repository.UserRepository;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.util.FileSystemUtils;

import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@ActiveProfiles("test")
class AuthRegisterMultipartContentTypeIntegrationTest {

    private static final Path TEST_UPLOAD_ROOT = Path.of("/tmp/uploads-test");
    private static final byte[] PROFILE_IMAGE_BYTES = new byte[]{1, 2, 3};

    private final HttpClient httpClient = HttpClient.newHttpClient();

    @LocalServerPort
    private int port;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private UserRepository userRepository;

    @AfterEach
    void cleanState() throws Exception {
        userRepository.deleteAll();
        FileSystemUtils.deleteRecursively(TEST_UPLOAD_ROOT);
    }

    @Test
    void registerMultipartWithTrailingCharsetWithoutProfileImageSucceeds() throws Exception {
        String displayName = "\uD64D\uAE38\uB3D9";

        HttpResponse<String> response = postMultipartRegister(
                "petnose-register-no-image",
                validRegisterFields(
                        "CharsetNoImage@Example.COM",
                        displayName,
                        "\uC11C\uC6B8"
                ),
                null
        );

        assertThat(response.statusCode()).as(response.body()).isEqualTo(201);
        JsonNode body = objectMapper.readTree(response.body());
        assertThat(body.get("email").asText()).isEqualTo("charsetnoimage@example.com");
        assertThat(body.get("display_name").asText()).isEqualTo(displayName);
        assertThat(body.get("profile_image_url").isNull()).isTrue();

        User saved = userRepository.findByEmail("charsetnoimage@example.com").orElseThrow();
        assertThat(saved.getId()).isEqualTo(body.get("user_id").asLong());
        assertThat(saved.getDisplayName()).isEqualTo(displayName);
        assertThat(saved.getProfileImagePath()).isNull();
    }

    @Test
    void registerMultipartWithTrailingCharsetAndProfileImageStoresMetadata() throws Exception {
        HttpResponse<String> response = postMultipartRegister(
                "petnose-register-image",
                validRegisterFields(
                        "CharsetImage@Example.COM",
                        "Image User",
                        "\uBD80\uC0B0"
                ),
                new RawFile("profile_image", "avatar.png", "image/png", PROFILE_IMAGE_BYTES)
        );

        assertThat(response.statusCode()).as(response.body()).isEqualTo(201);
        JsonNode body = objectMapper.readTree(response.body());
        Long userId = body.get("user_id").asLong();
        String profileImageUrl = body.get("profile_image_url").asText();
        assertThat(profileImageUrl).startsWith("/files/users/%d/profile/".formatted(userId));
        assertThat(profileImageUrl).endsWith("_avatar.png");

        User saved = userRepository.findByEmail("charsetimage@example.com").orElseThrow();
        assertThat(saved.getId()).isEqualTo(userId);
        assertThat(saved.getProfileImagePath()).startsWith("users/%d/profile/".formatted(userId));
        assertThat(saved.getProfileImageMimeType()).isEqualTo("image/png");
        assertThat(saved.getProfileImageFileSize()).isEqualTo((long) PROFILE_IMAGE_BYTES.length);
        assertThat(saved.getProfileImageSha256()).hasSize(64);
    }

    private HttpResponse<String> postMultipartRegister(
            String boundary,
            Map<String, String> fields,
            RawFile file
    ) throws Exception {
        byte[] body = multipartBody(boundary, fields, file);
        HttpRequest request = HttpRequest.newBuilder(uri("/api/auth/register"))
                .header("Accept", "application/json")
                .header("Content-Type", "multipart/form-data; boundary=" + boundary + "; charset=UTF-8")
                .POST(HttpRequest.BodyPublishers.ofByteArray(body))
                .build();

        return httpClient.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
    }

    private URI uri(String path) {
        return URI.create("http://127.0.0.1:" + port + path);
    }

    private Map<String, String> validRegisterFields(String email, String displayName, String region) {
        Map<String, String> fields = new LinkedHashMap<>();
        fields.put("email", email);
        fields.put("password", "password123");
        fields.put("display_name", displayName);
        fields.put("contact_phone", "01012341234");
        fields.put("region", region);
        return fields;
    }

    private byte[] multipartBody(String boundary, Map<String, String> fields, RawFile file) {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        for (Map.Entry<String, String> field : fields.entrySet()) {
            writeUtf8(output, "--" + boundary + "\r\n");
            writeUtf8(output, "Content-Disposition: form-data; name=\"" + field.getKey() + "\"\r\n");
            writeUtf8(output, "Content-Type: text/plain; charset=UTF-8\r\n\r\n");
            writeUtf8(output, field.getValue());
            writeUtf8(output, "\r\n");
        }

        if (file != null) {
            writeUtf8(output, "--" + boundary + "\r\n");
            writeUtf8(output, "Content-Disposition: form-data; name=\"" + file.fieldName()
                    + "\"; filename=\"" + file.filename() + "\"\r\n");
            writeUtf8(output, "Content-Type: " + file.contentType() + "\r\n\r\n");
            output.writeBytes(file.content());
            writeUtf8(output, "\r\n");
        }

        writeUtf8(output, "--" + boundary + "--\r\n");
        return output.toByteArray();
    }

    private void writeUtf8(ByteArrayOutputStream output, String value) {
        output.writeBytes(value.getBytes(StandardCharsets.UTF_8));
    }

    private record RawFile(String fieldName, String filename, String contentType, byte[] content) {
    }
}
