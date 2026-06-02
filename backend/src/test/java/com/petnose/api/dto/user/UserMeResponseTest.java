package com.petnose.api.dto.user;

import com.petnose.api.domain.entity.User;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class UserMeResponseTest {

    @Test
    void fromReturnsNullProfileImageUrlWhenProfileImagePathIsNull() {
        User user = user();

        UserMeResponse response = UserMeResponse.from(user);

        assertThat(response.profileImageUrl()).isNull();
    }

    @Test
    void fromReturnsFilesUrlWhenProfileImagePathIsRelative() {
        User user = user();
        user.setProfileImagePath("users/1/profile/a.jpg");

        UserMeResponse response = UserMeResponse.from(user);

        assertThat(response.profileImageUrl()).isEqualTo("/files/users/1/profile/a.jpg");
    }

    @Test
    void fromNormalizesStoredProfileImagePath() {
        User user = user();
        user.setProfileImagePath("users\\1\\profile\\a.jpg");

        assertThat(UserMeResponse.from(user).profileImageUrl())
                .isEqualTo("/files/users/1/profile/a.jpg");

        user.setProfileImagePath("files/users/1/profile/a.jpg");
        assertThat(UserMeResponse.from(user).profileImageUrl())
                .isEqualTo("/files/users/1/profile/a.jpg");

        user.setProfileImagePath("/files/users/1/profile/a.jpg");
        assertThat(UserMeResponse.from(user).profileImageUrl())
                .isEqualTo("/files/users/1/profile/a.jpg");
    }

    private User user() {
        User user = new User();
        user.setId(1L);
        user.setEmail("user@example.com");
        user.setDisplayName("User");
        user.setContactPhone("01012341234");
        user.setRegion("Seoul");
        user.setActive(true);
        return user;
    }
}
