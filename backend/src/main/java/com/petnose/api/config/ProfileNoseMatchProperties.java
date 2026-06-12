package com.petnose.api.config;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;

@Getter
@Setter
@ConfigurationProperties(prefix = "petnose.profile-nose-match")
public class ProfileNoseMatchProperties {

    private double threshold = 0.65;
    private int minPassCount = 4;
    private String aggregate = "median";
}
