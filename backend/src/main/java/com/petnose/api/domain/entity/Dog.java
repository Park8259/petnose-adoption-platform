package com.petnose.api.domain.entity;

import com.petnose.api.domain.enums.DogGender;
import com.petnose.api.domain.enums.DogStatus;
import jakarta.persistence.*;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;
import java.time.LocalDate;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "dogs")
public class Dog {

    @Id
    @Column(length = 36)
    private String id;

    @Column(name = "owner_user_id", nullable = false)
    private Long ownerUserId;

    @Column(nullable = false, length = 100)
    private String name;

    @Column(length = 100)
    private String breed;

    @Enumerated(EnumType.STRING)
    @Column(length = 10)
    private DogGender gender;

    @Column(name = "birth_date")
    private LocalDate birthDate;

    @Column(name = "age")
    private Integer age;

    @Column(columnDefinition = "TEXT")
    private String description;

    @Column(name = "health", columnDefinition = "TEXT")
    private String health;

    @Column(name = "price")
    private Long price;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 30)
    private DogStatus status;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt;

    @PrePersist
    public void prePersist() {
        Instant now = Instant.now();
        this.createdAt = now;
        this.updatedAt = now;
    }

    @PreUpdate
    public void preUpdate() {
        this.updatedAt = Instant.now();
    }
}
