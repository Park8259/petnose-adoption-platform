package com.petnose.api.config;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;

@Getter
@Setter
@ConfigurationProperties(prefix = "petnose.handover-verification")
public class HandoverVerificationProperties {

    private double matchThreshold = 0.65;
    private double ambiguousThreshold = 0.60;
    private int topK = 5;

    public int effectiveTopK() {
        return Math.max(1, topK);
    }
}
