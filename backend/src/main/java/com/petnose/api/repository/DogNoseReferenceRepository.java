package com.petnose.api.repository;

import com.petnose.api.domain.entity.DogNoseReference;
import com.petnose.api.domain.enums.DogNoseEmbeddingKind;
import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;

public interface DogNoseReferenceRepository extends JpaRepository<DogNoseReference, String> {

    List<DogNoseReference> findByDogIdAndActiveTrueOrderByCreatedAtAsc(String dogId);

    List<DogNoseReference> findByDogIdAndEmbeddingKindAndActiveTrueOrderByReferenceIndexAsc(
            String dogId,
            DogNoseEmbeddingKind embeddingKind
    );
}
