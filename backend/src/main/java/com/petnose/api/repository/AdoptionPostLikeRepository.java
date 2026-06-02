package com.petnose.api.repository;

import com.petnose.api.domain.entity.AdoptionPostLike;
import com.petnose.api.domain.enums.AdoptionPostStatus;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Collection;
import java.util.List;
import java.util.Optional;

public interface AdoptionPostLikeRepository extends JpaRepository<AdoptionPostLike, Long> {

    boolean existsByUserIdAndPostId(Long userId, Long postId);

    Optional<AdoptionPostLike> findByUserIdAndPostId(Long userId, Long postId);

    long deleteByUserIdAndPostId(Long userId, Long postId);

    List<AdoptionPostLike> findByUserIdAndPostIdIn(Long userId, Collection<Long> postIds);

    long countByUserIdAndPostId(Long userId, Long postId);

    @Query(
            value = """
                    select l
                    from AdoptionPostLike l
                    join AdoptionPost p on p.id = l.postId
                    where l.userId = :userId
                      and p.status in :statuses
                    order by l.createdAt desc, l.id desc
                    """,
            countQuery = """
                    select count(l)
                    from AdoptionPostLike l
                    join AdoptionPost p on p.id = l.postId
                    where l.userId = :userId
                      and p.status in :statuses
                    """
    )
    Page<AdoptionPostLike> findVisibleLikedPosts(
            @Param("userId") Long userId,
            @Param("statuses") Collection<AdoptionPostStatus> statuses,
            Pageable pageable
    );
}
