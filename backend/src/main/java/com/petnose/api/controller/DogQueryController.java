package com.petnose.api.controller;

import com.petnose.api.dto.dog.DogAdoptedListResponse;
import com.petnose.api.dto.dog.DogListResponse;
import com.petnose.api.service.AuthService;
import com.petnose.api.service.DogQueryService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpHeaders;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/dogs")
@RequiredArgsConstructor
public class DogQueryController {

    private final AuthService authService;
    private final DogQueryService dogQueryService;

    @GetMapping("/me")
    public DogListResponse myDogs(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization,
            @RequestParam(value = "page", defaultValue = "0") int page,
            @RequestParam(value = "size", defaultValue = "20") int size
    ) {
        Long currentUserId = authService.currentActiveUserId(authorization);
        return dogQueryService.findMyDogs(currentUserId, page, size);
    }

    @GetMapping("/adopted/me")
    public DogAdoptedListResponse myAdoptedDogs(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization,
            @RequestParam(value = "page", defaultValue = "0") int page,
            @RequestParam(value = "size", defaultValue = "20") int size
    ) {
        Long currentUserId = authService.currentActiveUserId(authorization);
        return dogQueryService.findMyAdoptedDogs(currentUserId, page, size);
    }

    @GetMapping("/{dog_id}")
    public Object detail(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization,
            @PathVariable("dog_id") String dogId
    ) {
        Long currentUserId = resolveOptionalCurrentUserId(authorization);
        return dogQueryService.findDogDetail(dogId, currentUserId);
    }

    private Long resolveOptionalCurrentUserId(String authorization) {
        if (authorization == null || authorization.isBlank()) {
            return null;
        }
        return authService.currentActiveUserId(authorization);
    }
}
