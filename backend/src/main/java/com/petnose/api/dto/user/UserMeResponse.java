package com.petnose.api.dto.user;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.petnose.api.domain.entity.User;

public record UserMeResponse(
        @JsonProperty("user_id")
        Long userId,
        @JsonProperty("email")
        String email,
        @JsonProperty("role")
        String role,
        @JsonProperty("display_name")
        String displayName,
        @JsonProperty("contact_phone")
        String contactPhone,
        @JsonProperty("region")
        String region,
        @JsonProperty("profile_image_url")
        String profileImageUrl,
        @JsonProperty("is_active")
        boolean active
) {
    public static UserMeResponse from(User user) {
        return new UserMeResponse(
                user.getId(),
                user.getEmail(),
                user.getRole().name(),
                user.getDisplayName(),
                user.getContactPhone(),
                user.getRegion(),
                profileImageUrl(user),
                user.isActive()
        );
    }

    static String profileImageUrl(User user) {
        return toFileUrl(user.getProfileImagePath());
    }

    private static String toFileUrl(String relativePath) {
        if (relativePath == null || relativePath.isBlank()) {
            return null;
        }
        String normalized = relativePath.trim().replace('\\', '/');
        if (normalized.startsWith("/files/")) {
            return normalized;
        }
        if (normalized.startsWith("files/")) {
            return "/" + normalized;
        }
        return "/files/" + normalized;
    }
}
