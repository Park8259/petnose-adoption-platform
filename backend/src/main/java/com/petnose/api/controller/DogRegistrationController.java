package com.petnose.api.controller;

import com.petnose.api.dto.registration.DogRegisterRequest;
import com.petnose.api.dto.registration.DogRegisterResponse;
import com.petnose.api.service.AuthService;
import com.petnose.api.service.DogRegistrationService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.util.List;

@RestController
@RequestMapping("/api/dogs")
@RequiredArgsConstructor
public class DogRegistrationController {

    private final AuthService authService;
    private final DogRegistrationService dogRegistrationService;

    @PostMapping(value = "/register", consumes = "multipart/form-data")
    public ResponseEntity<DogRegisterResponse> registerDog(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization,
            @RequestParam(value = "name", required = false) String name,
            @RequestParam(value = "breed", required = false) String breed,
            @RequestParam(value = "gender", required = false) String gender,
            @RequestParam(value = "birth_date", required = false) String birthDate,
            @RequestParam(value = "age", required = false) String age,
            @RequestParam(value = "price", required = false) String price,
            @RequestParam(value = "description", required = false) String description,
            @RequestParam(value = "health", required = false) String health,
            @RequestParam(value = "nose_images", required = false) List<MultipartFile> noseImages
    ) {
        Long ownerUserId = authService.currentActiveUserId(authorization);
        DogRegisterResponse response = dogRegistrationService.register(
                new DogRegisterRequest(ownerUserId, name, breed, gender, birthDate, age, price, description, health, noseImages)
        );

        if (response.registrationAllowed()) {
            return ResponseEntity.status(HttpStatus.CREATED).body(response);
        }
        // TODO: 추후 프론트 협의 후 DUPLICATE_SUSPECTED를 HTTP 409로 전환 가능.
        return ResponseEntity.ok(response);
    }
}
