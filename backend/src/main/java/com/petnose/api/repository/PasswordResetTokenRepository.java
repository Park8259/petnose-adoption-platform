package com.petnose.api.repository;

import com.petnose.api.domain.entity.PasswordResetToken;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.Optional;

public interface PasswordResetTokenRepository extends JpaRepository<PasswordResetToken, Long> {

    Optional<PasswordResetToken> findByTokenHash(String tokenHash);

    @Modifying(flushAutomatically = true, clearAutomatically = true)
    @Query("""
            UPDATE PasswordResetToken token
            SET token.usedAt = :usedAt
            WHERE token.userId = :userId
              AND token.usedAt IS NULL
            """)
    int markUnusedTokensUsedByUserId(@Param("userId") Long userId, @Param("usedAt") Instant usedAt);

    @Modifying(flushAutomatically = true, clearAutomatically = true)
    @Query("""
            UPDATE PasswordResetToken token
            SET token.usedAt = :usedAt
            WHERE token.userId = :userId
              AND token.usedAt IS NULL
              AND token.id <> :tokenId
            """)
    int markOtherUnusedTokensUsed(
            @Param("userId") Long userId,
            @Param("tokenId") Long tokenId,
            @Param("usedAt") Instant usedAt
    );
}
