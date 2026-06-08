package com.petnose.api.dto.registration;

import org.springframework.web.multipart.MultipartFile;

import java.util.List;

public record DogRegisterRequest(
        Long userId,
        String name,
        String breed,
        String gender,
        String birthDate,
        String age,
        String price,
        String description,
        String health,
        List<MultipartFile> noseImages
) {
}
