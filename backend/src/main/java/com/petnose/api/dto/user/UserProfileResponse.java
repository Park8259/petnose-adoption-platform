package com.petnose.api.dto.user;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.petnose.api.domain.entity.User;

public record UserProfileResponse(
        @JsonProperty("user_id")
        Long userId,
        @JsonProperty("display_name")
        String displayName,
        @JsonProperty("contact_phone")
        String contactPhone,
        @JsonProperty("region")
        String region,
        @JsonProperty("profile_image_url")
        String profileImageUrl
) {
    public static UserProfileResponse from(User user) {
        return new UserProfileResponse(
                user.getId(),
                user.getDisplayName(),
                user.getContactPhone(),
                user.getRegion(),
                UserMeResponse.profileImageUrl(user)
        );
    }
}
