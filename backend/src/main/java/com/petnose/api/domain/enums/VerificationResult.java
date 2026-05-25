package com.petnose.api.domain.enums;

public enum VerificationResult {
    PENDING,
    PASSED,
    DUPLICATE_SUSPECTED,
    REVIEW_REQUIRED,
    EMBED_FAILED,
    QDRANT_SEARCH_FAILED,
    QDRANT_UPSERT_FAILED
}
