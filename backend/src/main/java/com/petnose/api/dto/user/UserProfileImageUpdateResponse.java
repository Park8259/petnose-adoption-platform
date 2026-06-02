package com.petnose.api.dto.user;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.petnose.api.domain.entity.User;

public record UserProfileImageUpdateResponse(
        @JsonProperty("user_id")
        Long userId,
        @JsonProperty("profile_image_url")
        String profileImageUrl
) {
    public static UserProfileImageUpdateResponse from(User user) {
        return new UserProfileImageUpdateResponse(
                user.getId(),
                UserMeResponse.profileImageUrl(user)
        );
    }
}
