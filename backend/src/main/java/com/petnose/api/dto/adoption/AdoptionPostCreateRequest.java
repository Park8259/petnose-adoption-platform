package com.petnose.api.dto.adoption;

import com.fasterxml.jackson.annotation.JsonProperty;
import org.springframework.web.multipart.MultipartFile;

public record AdoptionPostCreateRequest(
        @JsonProperty("dog_id")
        String dogId,
        String title,
        String content,
        String status,
        MultipartFile profileImage
) {
}
